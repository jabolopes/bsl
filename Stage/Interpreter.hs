{-# LANGUAGE ParallelListComp, LambdaCase, TupleSections #-}
module Stage.Interpreter where

import Prelude hiding (mod, pred)

import Control.Arrow ((***))
import Control.Exception (throw)
import Control.Monad.State
import Data.Functor ((<$>))
import Data.IORef
import qualified Data.Map as Map (empty, fromList)
import Data.Maybe (isJust)
import Data.Either

import Data.Definition (Definition(..))
import qualified Data.Definition as Definition
import qualified Data.Env as Env (findBind, initial)
import Data.Exception
import Data.Expr (DefnKw(..), Expr(..))
import qualified Data.Expr as Expr
import Data.FileSystem (FileSystem)
import qualified Data.FileSystem as FileSystem
import Data.Literal (Literal(..))
import Data.Module (ModuleT(..), Module(..))
import qualified Data.Module as Module
import qualified Data.Name as Name
import Data.Result (Result(..))
import Monad.InterpreterM
import qualified Pretty.Data.Expr as Pretty
import Data.PrettyString (($+$), (<+>))
import qualified Data.PrettyString as PrettyString

evalLiteral :: Literal -> Val
evalLiteral (CharL c) = CharVal c
evalLiteral (IntL i) = IntVal i
evalLiteral (RealL d) = RealVal d
evalLiteral (StringL s) = StringVal s

evalM :: Expr -> InterpreterM Val
evalM (AnnotationE expr _) =
  evalM expr
evalM (IdE str) =
  do msym <- findBindM (Name.nameStr str)
     case msym of
       Just val -> liftIO $ readIORef val
       Nothing -> error $ "Interpreter.evalM(IdE): unbound symbols must be caught by the renamer" ++
                          "\n\n\t str = " ++ show str ++ "\n"
evalM (AppE expr1 expr2) =
  do val1 <- evalM expr1
     val2 <- evalM expr2
     case val1 of
       FnVal fn ->
         liftIO $
           liftInterpreterM (fn val2)
             `catchUserException`
               \case
                 InterpreterException err ->
                   do let symbol = case Expr.appToList expr1 of
                            IdE name:_ -> Name.nameStr name
                            _ -> "closure"
                      throwInterpreterException $ err $+$ PrettyString.text "in" <+> PrettyString.text symbol
                 err ->
                   throw err
       _ ->
         error $
           "Interpreter.evalM(AppE): application of non-functions must be detected by the renamer" ++
           "\n\n\t expr1 = " ++ PrettyString.toString (Pretty.docExpr expr1) ++
           "\n\n\t -> val1 = " ++ show val1 ++
           "\n\n\t expr2 = " ++ PrettyString.toString (Pretty.docExpr expr2) ++
           "\n\n\t -> val2 = " ++ show val2 ++ "\n"
evalM (CondE ms) = evalMatches ms
  where
    evalMatches [] =
      throwInterpreterException . PrettyString.text $ "non-exhaustive pattern matching"
    evalMatches ((pred, val):xs) =
      do pred' <- evalM pred
         case pred' of
           BoolVal False -> evalMatches xs
           _ -> evalM val
evalM (FnDecl Def name body) =
  do ref <- liftIO . newIORef $ FnVal (\_ -> error $ Name.nameStr name ++ ": loop")
     addBindM (Name.nameStr name) ref
     val <- evalM body
     replaceBindM (Name.nameStr name) val
     return val
evalM (FnDecl NrDef name body) =
  do val <- evalM body
     ref <- liftIO $ newIORef val
     addBindM (Name.nameStr name) ref
     return val
evalM expr@(LambdaE arg body) =
  do vars <- freeVars
     return . FnVal $ closure vars
  where
    freeVars =
      do vals <- mapM (\name -> (name,) <$> findBindM (Name.nameStr name)) $ Expr.freeVars expr
         if all (isJust . snd) vals
           then return $ map (id *** (\(Just x) -> x)) vals
           else error $ "Interpreter.evalM.freeVars: undefined free variables must be caught in previous stages" ++
                        "\n\n\t vals = " ++ show (Expr.freeVars expr) ++ "\n\n"

    closure vars val =
      withEmptyEnvM $ do
        forM_ vars $ \(name, ref) ->
          addBindM (Name.nameStr name) ref
        addBindM (Name.nameStr arg) =<< liftIO (newIORef val)
        evalM body
evalM (LetE defn body) =
  withEnvM $ do
    _ <- evalM defn
    withEnvM (evalM body)
evalM (LiteralE literal) =
  return $ evalLiteral literal

freeNameDefinitions :: FileSystem -> Definition -> [Definition]
freeNameDefinitions fs def =
  case mapM (FileSystem.lookupDefinition fs) $ Definition.defFreeNames def of
    Bad _ -> error "Interpreter.freeNamesDefinitions: undefined free variables must be caught in previous stages"
    Ok defs -> defs

liftInterpreterM :: InterpreterM a -> IO a
liftInterpreterM m =
  fst <$> runStateT m (Env.initial Map.empty)

interpretDefinition :: FileSystem -> Definition -> IO Definition
interpretDefinition fs def@Definition { defRen = Right expr@(FnDecl _ name _) } =
  do let defs = freeNameDefinitions fs def
     case partitionEithers $ map Definition.defVal defs of
       ([], vals) ->
         do let env = Env.initial . Map.fromList $ initialEnvironment defs vals
            (_, env') <- runStateT (evalM expr) env
            case Env.findBind env' (Name.nameStr name) of
              Nothing -> return def { defVal = Left $ "failed to evaluate " ++ show (Definition.defName def) }
              Just ref -> return def { defVal = Right ref }
       _ ->
         return def { defVal = Left "definition depends on free names that failed to evaluate" }
  where
    initialEnvironment defs vals =
      let defNames = map (Name.nameStr . Definition.defName) defs in
      zip defNames vals
interpretDefinition _ def = return def

interpretDefinitions :: FileSystem -> Module -> [Definition] -> IO Module
interpretDefinitions _ mod [] = return mod
interpretDefinitions fs mod (def:defs) =
  case Definition.defRen def of
    Left _ -> interpretDefinitions fs mod defs
    Right _ ->
      do def' <- interpretDefinition fs def
         let mod' = Module.ensureDefinitions mod [def']
             fs' = FileSystem.add fs mod'
         interpretDefinitions fs' mod' defs

interpret :: FileSystem -> Module -> IO Module
interpret _ mod@Module { modType = CoreT } = return mod
interpret fs mod = interpretDefinitions fs mod (Module.defsAsc mod)
