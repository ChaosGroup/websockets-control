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


type Handler i o = ClientId -> U.OutChan (Incoming i) -> U.InChan (Outgoing o) -> IO ()


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
            Send recv msg <- U.readChan wout
            let encodedMsg = A.encode msg
            conns <- case recv of
                Me -> pure [conn]
                All -> getConnections tbl
            for_ conns $ flip WS.sendTextData encodedMsg

    withAsync (handler cid rout win) $ const $ withAsync writer $ const reader


usage :: ClientTable -> WS.Connection -> IO ()
usage = withControl $ \cid incoming outgoing -> do
    putStrLn ("I am " <> show cid)
    U.writeChan outgoing (Send @Int Me 42)
    _ :: Incoming Int <- U.readChan incoming
    pure ()
