{-# LANGUAGE FlexibleContexts, LambdaCase, MultiWayIf #-}
module Repl where

import Prelude hiding (lex, mod)

import Control.Monad.State hiding (state)
import Control.Monad.Except (MonadError, runExceptT, throwError)
import qualified Data.Char as Char (isSpace)
import Data.Functor ((<$>))
import Data.IORef
import qualified Data.List as List (intercalate)
import System.Console.GetOpt (OptDescr(..), ArgDescr(..), ArgOrder(..), getOpt, usageInfo)
import System.Console.Readline
import System.IO (hFlush, stdout)
import System.IO.Error

import Data.Definition (Definition(..))
import qualified Data.Definition as Definition
import Data.Exception
import Data.FileSystem (FileSystem)
import qualified Data.FileSystem as FileSystem
import Data.Module (Module)
import qualified Data.Module as Module
import Data.Name (Name)
import qualified Data.Name as Name
import Data.PrettyString (PrettyString)
import qualified Data.PrettyString as PrettyString
import Data.Result (Result(..))
import Data.Source (Source(..))
import qualified Data.Source as Source
import Monad.InterpreterM (Val(..))
import Monad.NameT as NameT (MonadName)
import qualified Monad.NameT as NameT
import qualified Parser (parseRepl)
import qualified Pretty.Data.Definition as Pretty
import qualified Pretty.Data.Module as Pretty
import qualified Pretty.Repl as Pretty
import qualified Stage
import qualified Stage.Interpreter as Interpreter (interpretDefinition)
import qualified Stage.Loader as Loader (preload)
import qualified Stage.Renamer as Renamer
import qualified Utils (split)

data ReplState =
    ReplState { initialFs :: FileSystem, loadedFs :: FileSystem }

type ReplM a = StateT ReplState IO a

putVal :: Either String (IORef Val) -> IO ()
putVal (Left err) = putStrLn err
putVal (Right ref) = putVal' =<< readIORef ref
  where
    putVal' (IOVal m) = putVal' =<< m
    putVal' val = print val

stageFiles :: [Module] -> IO FileSystem
stageFiles mods =
  do putStrLn $ "Staging " ++ show n ++ " modules"
     loop FileSystem.empty mods [(1 :: Int)..]
  where n = length mods

        putHeader i =
          putStr $ "[" ++ show i ++ "/" ++ show n ++ "] "

        loop fs [] _ = return fs
        loop fs (mod:mods) (i:is) =
          do putHeader i
             putStrLn . show $ Module.modName mod
             res <- NameT.runNameT $ runExceptT $ Stage.stageModule fs mod
             case res of
               Right (fs', _) ->
                 loop fs' mods is
               Left err ->
                 do putStrLn (PrettyString.toString err)
                    loop fs mods is

importFile :: FileSystem -> Name -> IO ReplState
importFile fs modName =
  Loader.preload fs modName >>=
    \case
      Left err -> throwLoaderException err
      Right mods ->
        do fs' <- stageFiles mods
           let interactive = Module.mkInteractiveModule mods []
               fs'' = FileSystem.add fs' interactive
           return ReplState { initialFs = fs, loadedFs = fs'' }

mkSnippet :: FileSystem -> Source -> Definition
mkSnippet fs source@FnDefS {} =
  case FileSystem.lookup fs Module.interactiveName of
    Nothing -> error $ "Stage.mkSnippet: module " ++ show Module.interactiveName ++ " not found"
    Just mod -> Stage.makeDefinition mod source
mkSnippet fs source =
  mkSnippet fs $ FnDefS (Source.bindPat (Name.untyped "val") Source.allPat) Nothing source []

stageDefinition :: (MonadError PrettyString m, MonadIO m, MonadName m) => FileSystem -> String -> m (FileSystem, [Definition])
stageDefinition fs ln =
  do src <-
       case Parser.parseRepl Module.interactiveName ln of
         Left err -> throwError $ PrettyString.text err
         Right x -> return x
     interactive <-
       case FileSystem.lookup fs Module.interactiveName of
         Nothing -> throwError $ Pretty.moduleNotFound Module.interactiveName
         Just mod -> return mod
     let def = mkSnippet fs src
     expDefs <- Stage.expandDefinition interactive def
     renDefs <- mapM renameDefinition expDefs
     evalDefs <- liftIO $ mapM (Interpreter.interpretDefinition fs) renDefs
     let interactive' = Module.ensureDefinitions interactive evalDefs
     return $ (FileSystem.add fs interactive', evalDefs)
  where
    renameDefinition def =
      case Renamer.renameDefinition fs def of
        Left err -> throwError err
        Right def' -> return def'

runSnippetM :: String -> ReplM ()
runSnippetM ln =
  do fs <- loadedFs <$> get
     res <- liftIO $ NameT.runNameT $ runExceptT $ stageDefinition fs ln
     case res of
       Left err ->
         liftIO . putStrLn $ PrettyString.toString err
       Right (fs', defs) ->
         do modify $ \s -> s { loadedFs = fs' }
            liftIO $ putVal (Definition.defVal (last defs))

showMeM :: Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> String -> ReplM ()
showMeM showAll showBrief showOrd showFree showSrc showExp showRen filename =
  let
    filesM
      | showAll = FileSystem.toAscList . loadedFs <$> get
      | otherwise =
        do fs <- loadedFs <$> get
           case FileSystem.lookup fs $ Name.untyped filename of
             Nothing -> liftIO $ do
                          putStrLn $ "module " ++ show filename ++ " has not been staged"
                          putStrLn $ "staged modules are " ++ List.intercalate ", " (map (show . Module.modName) (FileSystem.toAscList fs))
                          return []
             Just mod -> return [mod]
  in
    do mods <- filesM
       let modDoc = Pretty.docModules showBrief showOrd showFree showSrc showExp showRen mods
       liftIO $ putStrLn $ PrettyString.toString modDoc

data Flag
  = ShowAll
  | ShowBrief
  | ShowHelp
  | ShowOrd

  | ShowFree
  | ShowSrc
  | ShowExp
  | ShowRen
    deriving (Eq, Show)

options :: [OptDescr Flag]
options = [Option "a" [] (NoArg ShowAll) "Show all",
           Option "b" [] (NoArg ShowBrief) "Show brief",
           Option "" ["help"] (NoArg ShowHelp) "Show help",
           Option "o" [] (NoArg ShowOrd) "Show in order",
           Option "" ["free"] (NoArg ShowFree) "Show free names of definition",
           Option "" ["src"] (NoArg ShowSrc) "Show source of definition",
           Option "" ["exp"] (NoArg ShowExp) "Show expanded definition",
           Option "" ["ren"] (NoArg ShowRen) "Show renamed definition"]

runCommandM :: String -> [Flag] -> [String] -> ReplM ()
runCommandM "def" opts nonOpts
  | showHelp = usageM
  | isDefinitionName nonOpts =
      do let moduleName = last $ init nonOpts
             definitionName = last nonOpts
         fs <- loadedFs <$> get
         liftIO . putStrLn . PrettyString.toString $
           case FileSystem.lookupDefinition fs . Name.untyped $ moduleName ++ "." ++ definitionName of
             Bad err -> err
             Ok def -> Pretty.docDefn showFree showSrc showExp showRen def
  | showAll || isModuleName nonOpts =
      do let moduleName
               | null nonOpts = ""
               | otherwise = last nonOpts
         showMeM showAll showBrief showOrd showFree showSrc showExp showRen moduleName
  | null nonOpts =
      do fs <- loadedFs <$> get
         let moduleNames = map Module.modName . FileSystem.toAscList $ fs
         liftIO . putStrLn . PrettyString.toString . Pretty.docModuleNames $ moduleNames
  | otherwise = usageM
  where
    showAll = ShowAll `elem` opts
    showBrief = ShowBrief `elem` opts
    showHelp = ShowHelp `elem` opts
    showOrd = ShowOrd `elem` opts
    showFree = ShowFree `elem` opts
    showSrc = ShowSrc `elem` opts
    showExp = ShowExp `elem` opts
    showRen = ShowRen `elem` opts

    isDefinitionName (_:_:_) = True
    isDefinitionName _ = False

    isModuleName (_:_) = True
    isModuleName _ = False

    usageM =
      liftIO . putStr $ usageInfo "def [-b] [--help] [--free] [--src] [--exp] [--ren] [-o] [-a | <me>]" options
runCommandM "load" _ nonOpts
  | null nonOpts =
    liftIO $ putStrLn ":load [ <me> | <file/me> ]"
  | otherwise =
    do fs <- initialFs <$> get
       liftIO (importFile fs (Name.untyped (last nonOpts))) >>= put
runCommandM "l" opts nonOpts =
  runCommandM "load" opts nonOpts
runCommandM _ _ _ =
  liftIO $ putStrLn ":def | :load | :me"

dispatchCommandM :: String -> ReplM ()
dispatchCommandM ln =
    case getOpt Permute options (Utils.split ' ' ln) of
      (opts, [], []) -> runCommandM "" opts []
      (opts, nonOpts, []) -> runCommandM (head nonOpts) opts (tail nonOpts)
      (_, _, errs) -> liftIO $ putStr $ List.intercalate "" errs

promptM :: String -> ReplM ()
promptM ln =
    do liftIO (addHistory ln)
       process ln
       liftIO (hFlush stdout)
    where process (':':x) = dispatchCommandM x
          process x = runSnippetM x

replM :: ReplM Bool
replM =
    do mprompt <- liftIO $ readline "bsl$ "
       case mprompt of
         Nothing -> return True
         Just ln | ln == ":quit" -> return True
                 | all Char.isSpace ln -> replM
                 | otherwise -> promptM ln >> return False

putUserException :: UserException -> IO ()
putUserException (LoaderException err) =
  putStrLn . PrettyString.toString $
  PrettyString.text "loader error: "
  PrettyString.$+$
  PrettyString.nest err
putUserException (InterpreterException err) =
  putStrLn . PrettyString.toString $
  PrettyString.text "interpreter error: "
  PrettyString.$+$
  PrettyString.nest err
putUserException (LexerException str) =
  putStrLn $ "lexical error: " ++ str
putUserException (SignalException str) =
  putStrLn $ "uncaught exception: " ++ str

finallyIOException :: Show a => ReplState -> a -> IO (Bool, ReplState)
finallyIOException state e =
  print e >> return (False, state)

finallyException :: a -> UserException -> IO (Bool, a)
finallyException state e =
  putUserException e >> return (False, state)

repl :: ReplState -> IO ()
repl state =
  do (b, state') <- (runStateT replM state
                     `catchIOError` finallyIOException state)
                    `catchUserException` finallyException state
     unless b (repl state')
