{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module ParseRequestHand where

import Control.Monad                (forever)
import Control.Proxy                (Proxy, liftP, request, respond)
import Control.Proxy.Trans.State    (StateP, get, put)
import Control.Exception.Extensible (Exception, throw)

import           Data.ByteString    (ByteString, elemIndex, empty, split, uncons)
import qualified Data.ByteString    as B
import Data.ByteString.Lex.Integral (readDecimal)
import Data.ByteString.Internal     (c2w)
import Data.ByteString.Unsafe       (unsafeDrop, unsafeIndex, unsafeTake)
import Data.Monoid                  (mappend)
import Data.Typeable                (Typeable)
import Data.Word                    (Word8)
import Network.Socket               (SockAddr(..))
import Types                        (Method(..), Request(..), HTTPVersion(..))

------------------------------------------------------------------------------
-- 'Word8' constants for popular characters
------------------------------------------------------------------------------

colon, cr, nl, space :: Word8
colon = c2w ':'
cr    = c2w '\r'
nl    = c2w '\n'
space = c2w ' '

------------------------------------------------------------------------------
-- Parse Exception
------------------------------------------------------------------------------

data ParseError
    = Unexpected
    | MalformedRequestLine ByteString
    | MalformedHeader      ByteString
    | UnknownHTTPVersion   ByteString
      deriving (Typeable, Show, Eq)

instance Exception ParseError

------------------------------------------------------------------------------
-- Request Parser
------------------------------------------------------------------------------

{-
        Request       = Request-Line              ; Section 5.1
                        *(( general-header        ; Section 4.5
                         | request-header         ; Section 5.3
                         | entity-header ) CRLF)  ; Section 7.1
                        CRLF
                        [ message-body ]          ; Section 4.3
-}
parseRequest :: (Proxy p, Monad m) =>
                Bool -- ^ is this an HTTPS connection?
             -> SockAddr
             -> StateP ByteString p () ByteString a b m Request
parseRequest secure addr =
    do line <- takeLine
       let (method, requestURI, httpVersion) = parseRequestLine line
       headers <- parseHeaders
       let req =
               Request { rqMethod      = method
                       , rqURIbs       = requestURI
                       , rqHTTPVersion = httpVersion
                       , rqHeaders     = headers
                       , rqSecure      = secure
                       , rqClient      = addr
                       }
       return $! req

-- | currently if you consume the entire request body this will
-- terminate and return the 'ret' value that you supplied. But, that
-- seems wrong, because that will tear down the whole pipeline and
-- return that value instead of what you really wanted to return.
--
-- Perhaps this should return a 'Maybe ByteString' instead so you can
-- detect when the body ends? But that interfers with using
-- 'parseRequest' in 'httpPipe'. For now we will just return 'empty'
-- forever when you get to the end.
--
-- Perhaps pipes 2.5 will provide a better solution as it is supposed
-- to allow you to catch termination of the upstream pipe.
pipeBody :: (Proxy p, Monad m) =>
            Request
         -> ()
         -> StateP ByteString p () ByteString a ByteString m r
pipeBody req () =
    case lookup "Content-Length" (rqHeaders req) of
         Nothing ->
             do error "chunked bodies not supported yet"
         (Just value) ->
             case readDecimal (B.drop 1 value) of
               Nothing -> error $ "Failed to read Content-Length"
               (Just (n, _)) ->
                    do unconsumed <- get
                       go n unconsumed
    where
      go remaining unconsumed
          | remaining == 0 =
              do put unconsumed
                 done

          | remaining >= B.length unconsumed =
              do liftP $  respond unconsumed
                 bs <- liftP $ request ()
                 go (remaining - B.length unconsumed) bs

          | remaining == B.length unconsumed =
              do liftP $ respond unconsumed
                 put empty
                 done

          | otherwise =
              do let (bs', remainder) = B.splitAt remaining unconsumed
                 liftP $ respond bs'
                 put remainder
                 done

      done = forever $ liftP $ respond empty

{-
The Request-Line begins with a method token, followed by the Request-URI and the protocol version, and ending with CRLF. The elements are separated by SP characters. No CR or LF is allowed except in the final CRLF sequence.

        Request-Line   = Method SP Request-URI SP HTTP-Version CRLF
-}
parseRequestLine :: ByteString -> (Method, ByteString, HTTPVersion)
parseRequestLine bs =
    case split space bs of
      [method, requestURI, httpVersion] ->
          (parseMethod method, requestURI, parseHTTPVersion httpVersion)
      _ -> throw (MalformedRequestLine bs)


{-

The Method token indicates the method to be performed on the resource identified by the Request-URI. The method is case-sensitive.

       Method         = "OPTIONS"                ; Section 9.2
                      | "GET"                    ; Section 9.3
                      | "HEAD"                   ; Section 9.4
                      | "POST"                   ; Section 9.5
                      | "PUT"                    ; Section 9.6
                      | "DELETE"                 ; Section 9.7
                      | "TRACE"                  ; Section 9.8
                      | "CONNECT"                ; Section 9.9
                      | extension-method
       extension-method = token
-}

parseMethod :: ByteString -> Method
parseMethod bs
    | bs == "OPTIONS" = OPTIONS
    | bs == "GET"     = GET
    | bs == "HEAD"    = HEAD
    | bs == "POST"    = POST
    | bs == "PUT"     = PUT
    | bs == "DELETE"  = DELETE
    | bs == "TRACE"   = TRACE
    | bs == "CONNECT" = CONNECT
    | otherwise       = EXTENSION bs

parseHTTPVersion :: ByteString -> HTTPVersion
parseHTTPVersion bs
    | bs == "HTTP/1.1" = HTTP11
    | bs == "HTTP/1.0" = HTTP10
    | otherwise        = throw (UnknownHTTPVersion bs)

-- FIXME: add max header size checks
-- parseHeaders :: (Monad m) => ByteString -> Pipe ByteString b m ([(ByteString, ByteString)], ByteString)
parseHeaders :: (Proxy p, Monad m) => StateP ByteString p () ByteString a b m [(ByteString, ByteString)]
parseHeaders =
    do line <- takeLine
       if B.null line
          then do return []
          else do headers <- parseHeaders
                  return (parseHeader line : headers)


{-
       message-header = field-name ":" [ field-value ]
       field-name     = token
       field-value    = *( field-content | LWS )
       field-content  = <the OCTETs making up the field-value
                        and consisting of either *TEXT or combinations
                        of token, separators, and quoted-string>
-}

parseHeader :: ByteString -> (ByteString, ByteString)
parseHeader bs =
    let (fieldName, remaining) = parseToken bs
    in case uncons remaining of
         (Just (c, fieldValue))
             | c == colon -> (fieldName, fieldValue)
         _                -> throw (MalformedHeader bs)

{-
       token          = 1*<any CHAR except CTLs or separators>
       separators     = "(" | ")" | "<" | ">" | "@"
                      | "," | ";" | ":" | "\" | <">
                      | "/" | "[" | "]" | "?" | "="
                      | "{" | "}" | SP | HT
       CTL            = <any US-ASCII control character
                        (octets 0 - 31) and DEL (127)>
-}

-- FIXME: follow the spec
parseToken :: ByteString -> (ByteString, ByteString)
parseToken bs = B.span (/= colon) bs

-- | find a line terminated by a '\r\n'
takeLine :: (Proxy p, Monad m) =>
            StateP ByteString p () ByteString a b m ByteString
takeLine =
    do bs <- get
       case elemIndex nl bs of
         Nothing ->
             do x <- liftP $ request ()
                put (bs `mappend` x)
                takeLine
         (Just 0) -> throw Unexpected
         (Just i) ->
             if unsafeIndex bs (i - 1) /= cr
                then throw Unexpected
                else do put $ unsafeDrop (i + 1) bs
                        return $ unsafeTake (i - 1) bs

{-

parse :: (Monad m) => Pipe ByteString b m a -> String -> m (Maybe a)
parse parser str =
    runPipe $ (yield (C.pack str) >> return Nothing)
                >+> (fmap Just parser)
                >+> discard
-}