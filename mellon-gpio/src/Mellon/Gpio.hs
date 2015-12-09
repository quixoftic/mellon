{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Mellon.Gpio
         ( -- * Servers
           runTCPServerSysfs
         ) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Maybe (fromJust)
import Data.Tuple (swap)
import Mellon.Monad.Controller (controllerCtx)
import Mellon.Device.Class (Device(..))
import Mellon.Server.Docs (docsApp)
import Network (PortID(..), listenOn)
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket, setHost, setPort)
import System.GPIO.Free (GpioT, Pin(..), PinDirection(..), Value(..), open, close, direction, setDirection, writePin)
import System.GPIO.Linux.Sysfs (PinDescriptor, SysfsT, runSysfsT)

-- Convert errors in SysfsT to IO exceptions.
runSysfsUnsafe :: (MonadIO m) => SysfsT (ExceptT String m) a -> m a
runSysfsUnsafe action =
  do result <- runExceptT $ runSysfsT action
     case result of
       Left e -> fail e
       Right x -> return x

-- | Run the server on a TCP socket at the given port number. The
-- server will listen on all interfaces.
--
-- The server will control the physical access device by assering a
-- high logic level on the specified GPIO pin when the device is
-- unlocked, and a low logic level on the pin when the device is
-- locked. The server will also perform all necessary GPIO setup and
-- teardown for the specified pin (i.e., there is no need for the
-- caller to wrap this function with the 'withGPIO' function).
runTCPServerSysfs :: Pin -> Int -> IO ()
runTCPServerSysfs pin port =
  do pd <- runSysfsUnsafe $ prepPin pin
     runTCPServer (UnsafeSysfsLock pd) port
     runSysfsUnsafe $ close pd

runTCPServer :: (Device d) => d -> Int -> IO ()
runTCPServer device port =
  do cc <- controllerCtx device
     sock <- listenOn (PortNumber (fromIntegral port))
     runSettingsSocket (setPort port $ setHost "*" defaultSettings) sock (docsApp cc)

prepPin :: (MonadError String m) => Pin -> GpioT String h m h
prepPin pin =
  do result <- open pin
     case result of
       Left e -> throwError e
       Right h ->
         do maybeDir <- direction h
            case maybeDir of
              Nothing ->
                do close h
                   throwError $ "Can't set direction of " ++ show pin
              Just dir ->
                do setDirection h Out
                   return h

data UnsafeSysfsLock = UnsafeSysfsLock PinDescriptor deriving (Show, Eq)

-- Note: this will throw an exception if there's a problem writing to
-- the pin.
instance Device UnsafeSysfsLock where
  lockDevice (UnsafeSysfsLock pd) = runSysfsUnsafe $ writePin pd Low
  unlockDevice (UnsafeSysfsLock pd) = runSysfsUnsafe $ writePin pd High