-- | An example Ginger CLI application.
--
-- Takes two optional arguments; the first one is a template file, the second
-- one a file containing some context data in JSON format.
{-#LANGUAGE OverloadedStrings #-}
{-#LANGUAGE ScopedTypeVariables #-}
module Main where

import Text.Ginger
import Text.Ginger.Html
import Text.Ginger.Compile.JS
import Data.Text as Text
import qualified Data.Aeson as JSON
import Data.Maybe
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Control.Applicative
import System.Environment ( getArgs )
import System.IO
import System.IO.Error
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Control.Monad.Trans.Class ( lift )
import Control.Monad.Trans.Maybe
import Control.Monad
import Data.Default ( def )
import System.Exit (exitFailure)

loadFile fn = openFile fn ReadMode >>= hGetContents

loadFileMay fn =
    tryIOError (loadFile fn) >>= \e ->
         case e of
            Right contents -> return (Just contents)
            Left err -> do
                print err
                return Nothing

decodeFile :: (JSON.FromJSON v) => FilePath -> IO (Maybe v)
decodeFile fn = JSON.decode <$> (openFile fn ReadMode >>= LBS.hGetContents)

printF :: GVal (Run IO Html)
printF = fromFunction $ go
    where
        go :: [(Maybe Text, GVal (Run IO Html))] -> Run IO Html (GVal (Run IO Html))
        go args = forM_ args printArg >> return def
        printArg (Nothing, v) = liftRun . putStrLn . Text.unpack . asText $ v
        printArg (Just x, _) = return ()

data Command = CmdRun | CmdCompileJS

main = do
    args <- getArgs
    let (command, srcFn, scopeFn) = case args of
            [] -> (CmdRun, Nothing, Nothing)
            "--js":[] -> (CmdCompileJS, Nothing, Nothing)
            "--js":a:[] -> (CmdCompileJS, Just a, Nothing)
            a:[] -> (CmdRun, Just a, Nothing)
            a:b:[] -> (CmdRun, Just a, Just b)

    let resolve = loadFileMay
    (result, src) <- case srcFn of
            Just fn -> (,) <$> parseGingerFile resolve fn <*> return Nothing
            Nothing -> getContents >>= \s -> (,) <$> parseGinger resolve Nothing s <*> return (Just s)

    -- TODO: do some sort of arg parsing thing so that we can turn
    -- template dumping on or off.
    -- print tpl

    tpl <- case result of
        Left err -> do
            tplSource <- case src of
                            Just s -> return (Just s)
                            Nothing -> do
                                let s = peSourceName err
                                case s of
                                    Nothing -> return Nothing
                                    Just sn -> Just <$> loadFile sn
            printParserError tplSource err
            exitFailure
        Right tpl -> return tpl
    case command of
        CmdRun -> do
            scope <- case scopeFn of
                Nothing -> return Nothing
                Just fn -> (decodeFile fn :: IO (Maybe (HashMap Text JSON.Value)))

            let scopeLookup key = toGVal (scope >>= HashMap.lookup key)
            let contextLookup :: Text -> Run IO Html (GVal (Run IO Html))
                contextLookup key =
                    case key of
                        "print" -> return printF
                        _ -> return $ scopeLookup key

            let context = makeContextHtmlM contextLookup (putStr . Text.unpack . htmlSource)
            runGingerT context tpl >>= hPutStrLn stderr . show
        CmdCompileJS ->
            printCompiled $ compileTemplate tpl

printParserError :: Maybe String -> ParserError -> IO ()
printParserError srcMay = putStrLn . formatParserError srcMay

displayParserError :: String -> ParserError -> IO ()
displayParserError src pe = do
    case (peSourceLine pe, peSourceColumn pe) of
        (Just l, cMay) -> do
            let ln = Prelude.take 1 . Prelude.drop (l - 1) . Prelude.lines $ src
            case ln of
                [] -> return ()
                x:_ -> do
                    putStrLn x
                    case cMay of
                        Just c -> putStrLn $ Prelude.replicate (c - 1) ' ' ++ "^"
                        _ -> return ()
        _ -> return ()
