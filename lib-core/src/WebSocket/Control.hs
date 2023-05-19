module WebSocket.Control
    ( ClientId
    , ClientControl (..)
    , ClientTable
    , Handler
    , newClientTable
    , withControl
     ) where

import WebSocket.Control.Internal
import WebSocket.Control.Internal.ClientTable
