module WebSocket.Control.Internal where

import Control.Concurrent.Async
import Control.Exception.Safe (finally)
import Control.Monad (forever)
import Data.Foldable (for_)
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Data.Aeson as A
import qualified Network.WebSockets as WS
import WebSocket.Control.Internal.ClientTable

import Control.Concurrent (threadDelay)
import Data.Time (getCurrentTime)


data Incoming msg
    = Control ClientControl
    | Message msg

data Outgoing msg = Send Receiver msg

data Receiver
    = Me
    | All


data Context m i o = Context
    { myId :: ClientId
    , recv :: m (Incoming i)
    , send :: Receiver -> o -> m ()
    }


type Handler m i o = Context m i o -> m ()


withControl :: (A.FromJSON i, A.ToJSON o) => Handler IO i o -> ClientTable -> WS.Connection -> IO ()
withControl handler tbl conn = WS.withPingThread conn 30 mempty $ do
    (cid, control) <- addClient tbl conn
    (rin, rout) <- U.newChan 4
    (win, wout) <- U.newChan 4

    let reader =
            let fromControl = forever $ U.readChan control >>= U.writeChan rin . Control
                fromWebsocket = forever $ WS.receiveData conn >>= \d -> do
                    case A.decode' d of
                        Just msg -> U.writeChan rin (Message msg)
                        Nothing  -> pure ()
            in flip finally (removeClient tbl cid) $ withAsync fromControl $ const fromWebsocket

        writer = forever $ do
            Send receiver msg <- U.readChan wout
            let encodedMsg = A.encode msg
            conns <- case receiver of
                Me -> pure [conn]
                All -> getConnections tbl
            for_ conns $ flip WS.sendTextData encodedMsg

        app =
            let send receiver msg = U.writeChan win (Send receiver msg)
                recv = U.readChan rout
            in handler Context
                { myId = cid
                , ..
                }

    withAsync app $ const $ withAsync writer $ const reader


usage :: ClientTable -> WS.Connection -> IO ()
usage = withControl $ \ctx -> do
    putStrLn ("I am " <> show (myId ctx))
    send ctx Me "Hello"
    res <- recv ctx
    case res of
        Control (Connected clientId) -> putStrLn ("Connected: " <> show clientId)
        Control (Disconnected clientId) -> putStrLn ("Disconnected: " <> show clientId)
        Message msg -> putStrLn ("Received: " <> show @Int msg)


usage2 :: ClientTable -> WS.Connection -> IO ()
usage2 = withControl hdl
  where
    hdl :: Handler IO Int String
    hdl ctx = do
        let currentTime = forever $ do
                now <- getCurrentTime
                send ctx All (show now)
                threadDelay 1_000_000

            process msg = send ctx Me $ show (msg + 1)

        withAsync currentTime $ \_ -> forever $ do
            res <- recv ctx
            case res of
                Message msg -> process msg
                _ -> pure ()
