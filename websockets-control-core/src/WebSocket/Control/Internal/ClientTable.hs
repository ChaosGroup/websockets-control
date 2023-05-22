module WebSocket.Control.Internal.ClientTable where

import Control.Concurrent.MVar
import Control.Exception (evaluate)
import Control.Monad (when)
import qualified Control.Concurrent.Chan.Unagi.Bounded as U
import qualified Data.Map.Strict as M
import qualified Data.Time.Clock.System as SystemTime
import qualified Network.WebSockets as WS


-- |Opaque unique identifier for a connected client
newtype ClientId = ClientId SystemTime.SystemTime
    deriving newtype (Eq, Ord)

instance Show ClientId where
    show (ClientId s) = show (SystemTime.systemSeconds s) <> "." <> show (SystemTime.systemNanoseconds s)


-- |Generate a new client identifier
newClientId :: IO ClientId
newClientId = ClientId <$> SystemTime.getSystemTime


-- |Connected client
newtype Client = Client { clientConnection :: WS.Connection }


-- |Message sent when client changes its state
data ClientControl
    = Connected ClientId
    | Disconnected ClientId


-- |Collection of connected clients
data ClientTable = ClientTable
    { tblClients :: MVar (M.Map ClientId Client)
    , tblControl :: U.InChan ClientControl
    }

-- |Create an empty table
newClientTable :: IO ClientTable
newClientTable = do
    tblClients <- newMVar mempty
    tblControl <- fst <$> U.newChan 64
    pure ClientTable {..}


-- |Add new client to the table when the client connects
addClient :: ClientTable -> WS.Connection -> IO (ClientId, U.OutChan ClientControl)
addClient tbl conn = do
    !cid <- newClientId
    modifyMVar_ (tblClients tbl) (evaluate . M.insert cid (Client conn))
    U.writeChan (tblControl tbl) (Connected cid)
    outChan <- U.dupChan (tblControl tbl)
    pure (cid, outChan)


-- |Remove the client from the table when the client disconnects
removeClient :: ClientTable -> ClientId -> IO ()
removeClient tbl cid = do
    removed <- modifyMVar (tblClients tbl) $ \m -> evaluate $ case M.lookup cid m of
        Just _  -> (M.delete cid m, True)
        Nothing -> (m, False)
    when removed $ U.writeChan (tblControl tbl) (Disconnected cid)


-- |Get just the connection of all connected clients
getConnections :: ClientTable -> IO [WS.Connection]
getConnections tbl = do
    clients <- M.elems <$> readMVar (tblClients tbl)
    pure $ map clientConnection clients
