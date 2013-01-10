{-# LANGUAGE BangPatterns #-}
module Repl where

import Prelude hiding (lex, catch)

import Control.Monad.State
import Data.Char (isSpace)
import Data.List (isPrefixOf, nub)
import Data.Map (Map)
import qualified Data.Map as Map ((!), insert, empty)
import System.Console.Readline

--import System.IO.Error (catchIOError)
import System.IO.Error (catch)

import Data.Exception
import Data.SrcFile
import Data.Stx
import Data.Type
import Interpreter
import Lexer
import Loader
import Monad.InterpreterM
import Parser
import Printer.PrettyStx (prettyPrint)
import Renamer
import Typechecker


data ReplState = ReplState [SrcFile] RenamerState ExprEnv (Map String Type)
type ReplM a = StateT ReplState IO a


catchIOError :: IO a -> (IOError -> IO a) -> IO a
catchIOError = catch


doPutLine = False
doPutTokens = False
doPutParsedStx = True
doPutRenamedStx = False
doPutExpr = True
doPutExprT = True
doPutEnvironment = False

doTypecheck = False


putLine :: String -> IO ()
putLine str
    | doPutLine = putStrLn $ "> " ++ str
    | otherwise = return ()


putTokens :: [Token] -> IO ()
putTokens tokens
    | doPutTokens =
        do putStrLn "> Tokens"
           mapM_ (putStrLn . show) tokens
           putStrLn ""
    | otherwise = return ()


putParsedStx :: Stx String -> IO ()
putParsedStx stx
    | doPutParsedStx =
        do putStrLn "> Parsed stx"
           prettyPrint stx
           putStrLn ""
           putStrLn ""
    | otherwise = return ()


putRenamedStx :: Stx String -> IO ()
putRenamedStx stx
    | doPutRenamedStx =
        do putStrLn "> Renamed stx"
           prettyPrint stx
           putStrLn ""
           putStrLn ""
    | otherwise = return ()


putExpr :: Show a => a -> IO ()
putExpr expr
    | doPutExpr = putStrLn $ show expr
    | otherwise = return ()


putExprT :: (Show a, Show b) => a -> b -> IO ()
putExprT expr t
    | doPutExprT = putStrLn $ show expr ++ " :: " ++ show t
    | otherwise = return ()


putEnvironment :: Show a => a -> IO ()
putEnvironment env
    | doPutEnvironment =
        do putStrLn ""
           putStrLn "Environment"
           putStrLn $ show env
           putStrLn ""
    | otherwise = return ()


renamerEither :: Either String a -> a
renamerEither fn = either throwRenamerException id fn


typecheckerEither :: Either String a -> a
typecheckerEither fn = either throwTypecheckerException id fn


importFile :: [SrcFile] -> String -> IO ReplState
importFile corefiles filename =
    do srcfiles <- preload corefiles filename
       let (srcfiles', renamerState) = renamerEither $ rename srcfiles
           (_, exprEnv) = interpret srcfiles'
       putStrLn $ show exprEnv -- edit: forcing evaluation
       -- !symbols' <- liftIO $ return $ typecheckerEither $ typecheckStxs symbols stxs
       return $ ReplState corefiles (mkInteractiveFrame (nub ["Core", "Prelude", filename]) renamerState) exprEnv Map.empty


runM :: ExprEnv -> Stx String -> ReplM ExprEnv
runM exprEnv stx =
    do let (expr, exprEnv') = interpretIncremental exprEnv [stx]
       liftIO $ do
         putExpr expr
         putEnvironment exprEnv'
       return exprEnv'


runTypecheckM :: ExprEnv -> Map String Type -> Stx String -> ReplM (ExprEnv, Map String Type)
runTypecheckM exprEnv symbols stx =
    case typecheckIncremental symbols stx of
      Left str -> throwTypecheckerException str
      Right (t, symbols') -> do let (expr, exprEnv') = interpretIncremental exprEnv [stx]
                                liftIO $ do
                                  putStrLn $ show symbols'
                                  putStrLn ""
                                  putExprT expr t
                                  putEnvironment exprEnv'
                                return (exprEnv', symbols')


runSnippetM :: String -> ReplM ()
runSnippetM ln =
    do ReplState corefiles renamerState exprEnv symbols <- get
       let tokens = lex ln
           stx = parseRepl tokens
           (stx', renamerState') = renamerEither $ renameIncremental renamerState stx
       liftIO $ putRenamedStx stx'
       if doTypecheck
       then do (exprEnv', symbols') <- runTypecheckM exprEnv symbols stx'
               put $ ReplState corefiles renamerState' exprEnv' symbols'
       else do exprEnv' <- runM exprEnv stx'
               put $ ReplState corefiles renamerState' exprEnv' symbols


-- runSnippetM :: String -> ReplM ()
-- runSnippetM ln =
--     do ReplState renamerState exprEnv symbols prelude <- get
--        let tokens = lex ln
--            stx = parseDefnOrExpr tokens
--            (stx', renamerState') = renamerEither $ renameIncremental renamerState stx
--        liftIO $ putRenamedStx stx'
--        case typecheckIncremental symbols stx' of
--          Left str -> throwTypecheckerException str
--          Right (t, symbols') -> do let (expr, exprEnv') = interpret exprEnv [stx']
--                                    liftIO $ do
--                                      putStrLn $ show symbols'
--                                      putStrLn ""
--                                      putExprT expr t
--                                      putStrLn ""
--                                      putEnvironment exprEnv'
--                                    put $ ReplState renamerState' exprEnv' symbols' prelude


promptM :: String -> ReplM Bool
promptM ln =
    do liftIO $ do
         addHistory ln
         putLine ln
       process ln
    where processM modName =
              do ReplState corefiles _ _ symbols <- get
                 liftIO (importFile corefiles modName) >>= put
                 return False

          process :: String -> ReplM Bool
          process (':':line)
                  | "load \"" `isPrefixOf` line = processM $ init $ tail $ dropWhile (/= '"') line
                  | "load " `isPrefixOf` line = processM $ tail $ dropWhile (/= ' ') line
                  | "l " `isPrefixOf` line = processM $ tail $ dropWhile (/= ' ') line
                  | otherwise = do liftIO $ putStrLn $ "command error: " ++ show ln ++ " is not a valid command"
                                   replM

          process ln =
              do runSnippetM ln
                 return False


replM :: ReplM Bool
replM =
    do mprompt <- liftIO $ readline "fl$ "
       case mprompt of 
         Nothing -> return True
         Just ln | ln == ":quit" -> return True
                 | all isSpace ln -> replM
                 | otherwise -> promptM ln


repl :: ReplState -> IO ()
repl state =
    do (b, state') <- (runStateT replM state
                       `catchIOError` finallyIOException state)
                      `catchFlException` finallyFlException state
       if b then return () else repl state'
    where finallyIOException state e =
              ioException e >> return (False, state)

          finallyFlException state e =
              flException e >> return (False, state)

          ioException e =
              putStrLn $ show e

          flException (RenamerException str) =
              putStrLn $ "renamer error: " ++ str

          flException (TypecheckerException str) =
              putStrLn $ "typechecker error: " ++ str

          flException (InterpreterException str) =
              putStrLn $ "interpreter error: " ++ str

          flException (ParseException str) =
              putStrLn $ "parse error: " ++ str

          flException (SignalException str) =
              putStrLn $ "uncaught exception: " ++ str