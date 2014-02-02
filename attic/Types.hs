{-# LANGUAGE DeriveDataTypeable, RankNTypes, RecordWildCards #-}
module Types where

import Pipes
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import Data.Data
import Network.Socket (SockAddr)
import Text.PrettyPrint.HughesPJ
import Pipes.Attoparsec
import Pipes.Parse
import Control.Monad.State.Strict
import Control.Monad.Trans.Error       (ErrorT)
------------------------------------------------------------------------------
-- HTTPVersion
------------------------------------------------------------------------------

data HTTPVersion
    = HTTP10
    | HTTP11
      deriving (Eq, Ord, Read, Show, Data, Typeable)

ppHTTPVersion :: HTTPVersion -> Doc
ppHTTPVersion HTTP10 = text "HTTP/1.0"
ppHTTPVersion HTTP11 = text "HTTP/1.1"

------------------------------------------------------------------------------
-- Method
------------------------------------------------------------------------------

data Method
    = OPTIONS
    | GET
    | GETONLY
    | HEAD
    | POST
    | PUT
    | DELETE
    | TRACE
    | CONNECT
    | EXTENSION ByteString  -- FIXME: don't use ByteString (use Ascii or something?)
      deriving (Eq, Ord, Read, Show, Data, Typeable)

ppMethod :: Method -> Doc
ppMethod OPTIONS         = text "OPTIONS"
ppMethod GET             = text "GET"
ppMethod GETONLY         = text "GETONLY"
ppMethod HEAD            = text "HEAD"
ppMethod POST            = text "POST"
ppMethod PUT             = text "PUT"
ppMethod DELETE          = text "DELETE"
ppMethod TRACE           = text "TRACE"
ppMethod CONNECT         = text "CONNECT"
ppMethod (EXTENSION ext) = text (C.unpack ext)

------------------------------------------------------------------------------
-- Handler
------------------------------------------------------------------------------


-- | a 'Handler' essentially a 'Request' and returns a 'Response'
--
-- The Pipe allows use to incrementally read 'ByteString' chuncks from
-- the Request body and incrementally write 'ByteString' chunks in the
-- 'Response' body.
type Handler m = Request -> Proxy () (Maybe ByteString) () ByteString (ErrorT ParsingError (StateT [ByteString] m)) Response

------------------------------------------------------------------------------
-- HTTPPipe
------------------------------------------------------------------------------

type HTTPPipe = Bool
              -> SockAddr
              -> Handler IO
              -> () -> Proxy () (Maybe ByteString) () ByteString (ErrorT ParsingError (StateT [ByteString] IO)) ()

------------------------------------------------------------------------------
-- MessageBody
------------------------------------------------------------------------------

type MessageBody = ByteString

------------------------------------------------------------------------------
-- Request
------------------------------------------------------------------------------

data Request = Request
    { rqMethod      :: !Method
    , rqURIbs       :: !ByteString
    , rqHTTPVersion :: !HTTPVersion
    , rqHeaders     :: ![(ByteString, ByteString)]
    , rqSecure      :: !Bool
    , rqClient      :: !SockAddr
    , rqBody        :: Producer ByteString IO ()
--    , rqBody        :: Producer' ByteString (StateT (Producer ByteString IO ()) IO) ()
    }
    deriving Typeable

instance Show Request where
    show = show . ppRequest

ppRequest :: Request -> Doc
ppRequest Request{..} =
    text "Request {" $+$
      nest 2 (
        vcat [ field "  rqMethod"      (ppMethod            rqMethod)
             , field ", rqURIbs"       (bytestring          rqURIbs)
             , field ", rqHTTPVersion" (ppHTTPVersion       rqHTTPVersion)
             , field ", rqHeaders"     (vcat $ map ppHeader rqHeaders)
             , field ", rqSecure"      (text $ show         rqSecure)
             , field ", rqClient"      (text $ show         rqClient)
             , field ", rqBody"        (text $ show         "<not shown>")
             ]) $+$
    text "}"

ppHeader :: (ByteString, ByteString) -> Doc
ppHeader (fieldName, fieldValue) =
    bytestring fieldName <> char ':' <> bytestring fieldValue

------------------------------------------------------------------------------
-- Response
------------------------------------------------------------------------------

data Response = Response
    { rsCode    :: {-# UNPACK #-} !Int
    , rsHeaders :: [(ByteString, ByteString)]
    , rsBody    :: Producer' ByteString IO ()
    }

instance Show (Response) where
    show = show . ppResponse

ppResponse :: Response -> Doc
ppResponse Response{..} =
    text "Response {"  $+$
      nest 2 (vcat [ field "rsCode"      (text $ show rsCode)
                   , field "rsHeaders"   (vcat $ map ppHeader rsHeaders)
                   , field "rsBody   "   (text "<not shown>")
                   ])  $+$
    text "}"


------------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------------

bytestring :: ByteString -> Doc
bytestring = text . C.unpack

field :: String -> Doc -> Doc
field name doc = text name $$ nest 20 (char '=' <+> doc)
