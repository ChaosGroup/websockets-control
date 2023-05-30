import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Monad
import Data.Time (getCurrentTime)
import Network.WebSockets qualified as WS
import WebSocket.Control


{-| Here we send a message to the client once,
    and then process incoming messages forever.
-}
simple :: ClientTable -> WS.Connection -> IO ()
simple = withControl $ \ctx -> do
    putStrLn ("I am " <> show (myId ctx))
    send ctx Me "Hello"
    forever $ do
        res <- recv ctx
        case res of
            Control (Connected clientId) -> putStrLn ("Connected: " <> show clientId)
            Control (Disconnected clientId) -> putStrLn ("Disconnected: " <> show clientId)
            Message msg -> putStrLn ("Received: " <> show @Int msg)


{-| In this one we have two processes:

        * one that sends the current time every second
        * another that processes the incoming messages

    The handler can be a separate testable function
    where you can pass some 'Context' value with
    dummy implementation and verify that you send
    the proper messages, for example.
-}
twoProc :: ClientTable -> WS.Connection -> IO ()
twoProc = withControl hdl
  where
    hdl :: Handler Int String
    hdl ctx = do
        let timeProc = forever $ do
                now <- getCurrentTime
                send ctx All (show now)
                threadDelay 1_000_000

            process = forever $ do
                res <- recv ctx
                case res of
                    Message msg -> send ctx Me $ show (msg + 1)
                    _           -> pure ()

        withAsync timeProc $ const process
