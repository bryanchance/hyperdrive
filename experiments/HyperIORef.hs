{-# LANGUAGE NoMonomorphismRestriction, OverloadedStrings #-}
module Main where

import Control.Applicative              ((<$>))
import Control.Monad.Trans.State.Strict (StateT(..))
import Control.Monad                    (when)
import Data.ByteString                  (ByteString)
import qualified Data.ByteString        as B
import qualified Data.ByteString.Char8  as B
import Data.ByteString.Lex.Integral     (readDecimal)
import           Data.Attoparsec.ByteString.Char8 (Parser, string, char)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Maybe                       (isNothing)
import Data.IORef                       (IORef, newIORef)
import Pipes
import qualified Pipes.Prelude as P
-- import Pipes.Parse (Parser)
import Pipes.Attoparsec
import qualified Pipes.ByteString as Pb
import Lens.Family.State.Strict (zoom)
import qualified Pipes.Parse as Ppi

type Hyperdrive m = StateT (Producer ByteString m (Producer ByteString m ())) m

data Request = Request
    { rqLength :: Int
--    , rqBody   :: IORef (Producer ByteString IO ())
    }

request :: ByteString
request =
    B.concat
          [ "Content-Length: 4\n"
          , "\n"
          , "1234\n"
          ]

notNL :: Parser ByteString
notNL = A.takeWhile (/= '\n')

pRequestHead :: A.Parser Request
pRequestHead =
    do string "Content-Length: "
       len <- notNL
       string "\n\n"
       case readDecimal len of
         Just (i,_) -> return $ Request { rqLength = i }
         _     -> error $ "Could not parse length: " ++ show len

parseWithBody printer handler =
    do eReq <- parse pRequestHead
       case eReq of
         (Left e) -> error (show e)
         (Right req) ->
             undefined
{-
             do a <- zoom (Pb.splitAt (rqLength req)) handler
                lift $ printer a
                r <- parse (char '\n' >> (isNothing <$> A.peekChar))
                case r of
                  (Right False) -> parseWithBody printer handler
                  (Right True)  -> return ()
                  (Left e)      -> error (show e)

pBody = parse $ A.many' A.anyChar

echoBody :: (Monad m) => Hyperdrive m String
echoBody =
    do bd <- pBody
       case bd of
         (Left e) -> error "Malformed Request"
         (Right bd) ->
             return bd

test :: IO ((), Producer ByteString IO ())
test = runStateT (parseWithBody print echoBody)  (yield request >> yield request) 
-}

{-
parser' :: (Monad m) =>
          StateT (Producer ByteString m x) m (Either ParsingError Int)
parser' = parse pRequestHead

parseOne :: Monad m =>
            Producer ByteString m x
         -> m (Either ParsingError Int, Producer ByteString m x)
parseOne = runStateT parser'

testHead =
    do (r, rest) <- parseOne (yield request)
       print r

pBody = parse $ A.many' A.anyChar

type Hyperdrive m = StateT (Producer ByteString m (Producer ByteString m ())) m

parseWithBody :: (Monad m) => Producer ByteString m () -> (a -> m ()) -> Hyperdrive m a -> m ()
parseWithBody p printer handler =
    do (r, rest) <- parseOne p
       case r of
         (Left e) -> error $ "Invalid Request: " ++  show e
         (Right len) ->
             do ((a, e), next) <- runStateT (do a <- zoom (Pb.splitAt len) handler
                                                r <- parse (char '\n' >> (isNothing <$> A.peekChar))
                                                case r of
                                                  (Right eof) -> return (a, eof)
                                                  (Left e) -> error (show e)
                                            ) rest
                printer a
                if e
                   then return ()
                   else parseWithBody next printer handler

parseWithBody2 p printer handler =
    do (r, rest) <- parseOne p

echoBody :: (Monad m) => Hyperdrive m String
echoBody =
    do bd <- pBody
       case bd of
         (Left e) -> error "Malformed Request"
         (Right bd) ->
             return bd

test = parseWithBody (yield request >> yield request) print echoBody
-}