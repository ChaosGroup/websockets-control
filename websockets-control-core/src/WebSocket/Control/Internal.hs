module WebSocket.Control.Internal where

import Control.Concurrent.Async
import Control.Concurrent.Chan.Unagi.Bounded qualified as U
import Control.Exception.Safe (finally)
import Control.Monad (forever)
import Data.Aeson qualified as A
import Data.Foldable (for_, foldMap')
import Data.Set qualified as S
import Network.WebSockets qualified as WS
import WebSocket.Control.Internal.ClientTable



data Incoming msg
    = Control ClientControl
    | Message msg

data Outgoing msg = Send Receiver msg

data Receiver
    = Me
    | forall f. Foldable f => Selected (f ClientId)
    | All


data Context i o = Context
    { myId :: ClientId
    , recv :: IO (Incoming i)
    , send :: Receiver -> o -> IO ()
    }


type Handler i o = Context i o -> IO ()


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
                Selected clientIds ->
                    let uniqIds = foldMap' S.singleton clientIds
                    in getConnections (`S.member` uniqIds) tbl
                All -> getConnections (const True) tbl
            for_ conns $ flip WS.sendTextData encodedMsg

        app =
            let send receiver msg = U.writeChan win (Send receiver msg)
                recv = U.readChan rout
            in handler Context
                { myId = cid
                , ..
                }

    withAsync app $ const $ withAsync writer $ const reader
