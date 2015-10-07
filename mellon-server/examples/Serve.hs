-- Compile from top-level with:
-- ghc -i src/Mellon/Server/API -i src/Mellon/Server/Docs examples/Serve

module Main where

import Mellon.Controller
import Mellon.Lock.Mock
import Mellon.Server.Docs (docsApp)
import Network.Wai.Handler.Warp

main :: IO ()
main =
  do ml <- mockLock
     cc <- concurrentControllerCtx ml
     putStrLn "Running on port 8081"
     run 8081 $ docsApp cc

