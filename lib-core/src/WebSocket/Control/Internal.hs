module WebSocket.Control.Internal where

import Control.Concurrent.Async
import Control.Exception.Safe (finally)
import Control.Monad (forever)
import Data.Foldable (for_)
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Data.Aeson as A
import qualified Network.WebSockets as WS
import WebSocket.Control.Internal.ClientTable


data Incoming msg
    = Control ClientControl
    | Message msg

data Outgoing msg = Send Receiver msg

data Receiver
    = Me
    | All


type Handler i o = ClientId -> IO (Incoming i) -> (Receiver -> o -> IO ()) -> IO ()


withControl :: (A.FromJSON i, A.ToJSON o) => Handler i o -> ClientTable -> WS.Connection -> IO ()
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
            in handler cid recv send

    withAsync app $ const $ withAsync writer $ const reader


usage :: ClientTable -> WS.Connection -> IO ()
usage = withControl $ \cid recv send -> do
    putStrLn ("I am " <> show cid)
    send Me "Hello"
    res <- recv
    case res of
        Control (Connected c) -> putStrLn ("Connected: " <> show c)
        Control (Disconnected c) -> putStrLn ("Disconnected: " <> show c)
        Message msg -> putStrLn ("Received: " <> show @Int msg)
