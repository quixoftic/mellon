{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Mellon.Controller.Concurrent
         ( ConcurrentController
         , ConcurrentControllerT(..)
         , concurrentController
         , runConcurrentControllerT
         ) where

import Control.Applicative (Alternative)
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Monad.Trans.Free (iterT)
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime, picosecondsToDiffTime)
import System.Mellon.Controller.Class
import System.Mellon.StateMachine (Cmd(..), State(..), StateMachineF(..), execCmdT)
import System.Mellon.Lock

-- | A 'ConcurrentController' uses 'MVar's and other Concurrent
-- Haskell mechanisms to run a controller/state machine in a
-- background thread(s).
--
-- Note that the constructor is not exported. Use
-- 'concurrentController' to create a new instance.
data ConcurrentController =
  ConcurrentController (MVar State) (MockLock)
  deriving (Eq)

-- | Create a new 'ConcurrentController'.
concurrentController :: MockLock -> State -> IO ConcurrentController
concurrentController l initialState =
  do m <- newEmptyMVar
     putMVar m initialState
     return $ ConcurrentController m l

newtype ConcurrentControllerT m a =
  ConcurrentControllerT (ReaderT ConcurrentController m a)
  deriving (Alternative,Applicative,Functor,Monad,MonadTrans,MonadIO,MonadFix,MonadPlus)

runConcurrentControllerT :: (MonadIO m) => ConcurrentController -> ConcurrentControllerT m a -> m a
runConcurrentControllerT c (ConcurrentControllerT action) = runReaderT action c

runInMutex :: (MonadIO m) => Cmd -> ConcurrentControllerT m ()
runInMutex cmd =
  do (ConcurrentController c _) <- ConcurrentControllerT ask
     state <- liftIO $ takeMVar c
     newState <- iterT runSM (execCmdT cmd state)
     liftIO $ putMVar c newState

instance (MonadIO m) => MonadController (ConcurrentControllerT m) where
  lockNow = runInMutex LockNowCmd
  unlockUntil = runInMutex . UnlockCmd

lockAt :: (MonadIO m) => UTCTime -> ConcurrentControllerT m ()
lockAt = runInMutex . LockCmd

scheduleLockAt :: (MonadIO m) => UTCTime -> ConcurrentControllerT m ()
scheduleLockAt date =
  do cc <- ConcurrentControllerT ask
     _ <- liftIO $ forkIO (threadSleepUntil date >> runConcurrentControllerT cc (lockAt date))
     return ()

runSM :: (MonadIO m) => StateMachineF (ConcurrentControllerT m a) -> ConcurrentControllerT m a
runSM (RunLock next) =
  do (ConcurrentController _ l) <- ConcurrentControllerT ask
     runMockLockT l lock
     next
runSM (ScheduleLock atDate next) =
  do scheduleLockAt atDate
     next
runSM (RunUnlock next) =
  do (ConcurrentController _ l) <- ConcurrentControllerT ask
     runMockLockT l unlock
     next
-- For this particular implementation, it's safe simply to
-- ignore this command. When the "unscheduled" lock fires, the
-- state machine will simply ignore it.
runSM (UnscheduleLock next) = next

-- 'threadDelay' takes an 'Int' argument which is measured in
-- microseconds, so on 32-bit platforms, 'threadDelay' might not be
-- able to delay long enough to accommodate even a day's sleep.
-- Therefore, we need this mess.
--
-- Does not account for leap seconds and is only precise to about 1
-- second, but I think that's probably OK.
threadSleepUntil :: UTCTime -> IO ()
threadSleepUntil t =
  do now <- getCurrentTime
     let timeRemaining = diffUTCTime t now
     sleep timeRemaining
  where sleep :: NominalDiffTime -> IO ()
        sleep r
          | r <= 0 = return ()
          | r > maxThreadDelayInDiffTime = threadDelay maxThreadDelay >>
                                            threadSleepUntil t
          | otherwise = threadDelay $ nominalDiffTimeToMicroseconds r
        maxThreadDelay :: Int
        maxThreadDelay = maxBound
        maxThreadDelayInDiffTime :: NominalDiffTime
        maxThreadDelayInDiffTime = diffTimeToNominalDiffTime $ picosecondsToDiffTime $
                                                               toInteger maxThreadDelay *
                                                               1000000
          where diffTimeToNominalDiffTime = realToFrac
        nominalDiffTimeToMicroseconds :: NominalDiffTime -> Int
        nominalDiffTimeToMicroseconds d = truncate $ d * 1000000
