{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A 'MonadFree' monad implementation of the @mellon@ state machine.
--
-- Typically, a user process does not interact directly with a
-- 'StateMachineT'. That is the job of a controller. Generally
-- speaking, you will only need to use 'StateMachineT' if you're
-- implementing a 'Mellon.Monad.Controller.MonadController'
-- instance.
--
-- The @mellon@ state machine model is shown in the following diagram:
--
-- <<https://s3-us-west-2.amazonaws.com/mellon/mellon-state-diagram.svg mellon state diagram>>
--
-- Note that the state machine model as implemented by 'StateMachineT'
-- is slightly different than the one shown in the diagram.
-- Specificaly, there is a difference between the 'LockNowCmd' and
-- 'LockCmd' commands that is not represented in the state diagram,
-- which only shows a single "lock" command. This is due to the fact
-- that, in a concurrent implementation of a controller, it may not be
-- possible to guarantee that the unlock-expiration-followed-by-lock
-- sequence is atomic: the controller could receive a new unlock
-- command from the user while it is arranging for the
-- previously-scheduled lock to fire. In this case, the controller
-- needs to distinguish between a synchronous lock command (i.e., a
-- user request, which is always executed) and an asynchronous lock
-- command (i.e., generated by an expiring unlock command, and to be
-- ignored if, by the time it is received, a new unlock command is
-- already in progress). 'LockNowCmd' corresponds to the former, while
-- 'LockCmd' corresponds to the latter.
--
-- (The state machine shown in the state diagram is implicitly atomic
-- as it does not attempt to represent the flow of time, therefore it
-- only needs the one lock command type.)

module Mellon.Monad.StateMachine
         ( Cmd(..)
         , StateMachine
         , StateMachineF(..)
         , StateMachineT
         , State(..)
         , transition
         ) where

import Control.Monad.Trans.Free (FreeT, MonadFree, liftF)
import Control.Monad.Free.TH (makeFreeCon)
import Data.Functor.Identity (Identity)
import Data.Time (UTCTime)
import GHC.Generics

-- | The states of a @mellon@ 'StateMachineT'.
data State
  -- | The state machine is in the locked state.
  = Locked
  -- | The state machine is unlocked until the specified time. If the
  -- time is in the past, then the state machine is unlocked
  -- indefinitely.
  | Unlocked UTCTime
  deriving (Eq, Show, Generic)

-- | The 'StateMachineT' commands. These represent the transitions
-- from one state to the next.
data Cmd
    -- | Lock immediately, canceling any unlock currently in effect.
  = LockNowCmd
    -- | Lock in response to an expiring unlock. The unlock's
    -- expiration date is given by the specified 'UTCTime' timestamp.
  | LockCmd UTCTime
    -- | Unlock until the specified time. If no existing unlock
    -- command with a later expiration is currently in effect when
    -- this command is executed, the controller managing the state
    -- machine must schedule a 'LockCmd' to run when this unlock
    -- expires.
  | UnlockCmd UTCTime
  deriving (Eq)

-- | The 'StateMachineT' embedded DSL (EDSL). Controllers
--  provide an implementation of the EDSL which turns the
--  `StateMachineT`'s pure state transformations into real-world
--  actions.
data StateMachineF next where
  RunLock :: next -> StateMachineF next
  ScheduleLock :: UTCTime -> next -> StateMachineF next
  RunUnlock :: next -> StateMachineF next
  UnscheduleLock :: next -> StateMachineF next

instance Functor StateMachineF where
  fmap f (RunLock x) = RunLock (f x)
  fmap f (ScheduleLock d x) = ScheduleLock d (f x)
  fmap f (RunUnlock x) = RunUnlock (f x)
  fmap f (UnscheduleLock x) = UnscheduleLock (f x)

-- | A transformer which adds a state machine to an existing monad.
type StateMachineT = FreeT StateMachineF

-- | A basic state machine monad.
type StateMachine = StateMachineT Identity

makeFreeCon 'RunLock
makeFreeCon 'ScheduleLock
makeFreeCon 'RunUnlock
makeFreeCon 'UnscheduleLock

-- | The pure 'StateMachineT' interpreter.
--
-- 'transition' provides an abstract, pure model of the core @mellon@
-- state machine. The state machine is the same for all
-- implementations; what changes from one implementation to the next
-- is the specific machinery for locking and scheduling, which is
-- provided by a controller.
transition :: (Monad m) => Cmd -> State -> StateMachineT m State

transition LockNowCmd Locked = return Locked
transition LockNowCmd (Unlocked _) =
  do unscheduleLock
     runLock
     return Locked

transition (LockCmd _) (Locked) = return Locked
transition (LockCmd lockDate) (Unlocked untilDate) =
  -- Only execute the lock command if its date matches the current
  -- outstanding unlock request's expiration date, i.e., if the lock
  -- command is the one that was scheduled by the current outstanding
  -- unlock request.
  --
  -- If the lock command's date does not match the current outstanding
  -- lock request's date, there are 2 possible cases:
  --
  -- 1. The lock command's date is earlier than the current
  -- outstanding unlock's expiration date. This means that the lock
  -- command's corresponding unlock command was overridden by a
  -- subsequent unlock with a later expiration date before the lock
  -- command fired, hence the state machine should ignore this lock
  -- command.
  --
  -- 2. The lock command's date is later than the current outstanding
  -- unlock's expiration date. You might think this should never
  -- happen, and indeed for a controller implementation that does
  -- strict bookkeeping and actually bothers to "unschedule" scheduled
  -- locks when a "lock now" command is received, it is extremely
  -- unlikely to occur... but I believe that for certain threaded
  -- controller implementations, it probably could, theoretically.
  -- Regardless, there's no harm in simply ignoring the request, as
  -- whatever unlock command is currently in progress, eventually it
  -- will either be canceled, or its own scheduled lock command will
  -- fire, in which case the dates will match exactly and everything
  -- will behave as expected.
  --
  -- In either case (1 or 2), the right thing to do is to ignore the
  -- lock command. The only question that remains is whether to treat
  -- case 2 as an error. For some very strict implementations, it's
  -- possible that it could be a real error, but I suspect that for
  -- most implementations, it's a very unlikely but probably harmless
  -- occurrence. That's how we treat it here.
  if lockDate == untilDate
     then runLock >> return Locked
     else return (Unlocked untilDate)

transition (UnlockCmd untilDate) Locked = unlockUntil untilDate
transition (UnlockCmd untilDate) (Unlocked scheduledDate) =
  if untilDate > scheduledDate
     then unlockUntil untilDate
     else return $ Unlocked scheduledDate

unlockUntil :: (Monad m) => UTCTime -> StateMachineT m State
unlockUntil date =
  do scheduleLock date
     runUnlock
     return $ Unlocked date
