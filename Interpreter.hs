{-# LANGUAGE RecursiveDo, NamedFieldPuns #-}
module Interpreter where

import Control.Monad.State
import Data.Functor ((<$>))
import Data.Map as Map (Map)
import qualified Data.Map as Map ((!), fromList, insert, keys, lookup, toList, union)
import Data.Maybe (catMaybes)

import Data.FileSystem (FileSystem)
import qualified Data.FileSystem as FileSystem
import qualified Data.Env as Env (initial, empty, getBinds)
import Data.SrcFile
import qualified Data.SrcFile as SrcFile (updateDefinitions, defsAsc, deps, name)
import Data.Stx
import Monad.InterpreterM
import Utils


import Data.Maybe (fromJust)
import Data.Symbol

import Data.Definition (Definition(..))
import qualified Data.Definition as Definition



evalM :: Stx String -> InterpreterM Val
evalM (CharStx c) = return $ CharVal c
evalM (IntStx i) = return $ IntVal i
evalM (DoubleStx d) = return $ DoubleVal d
evalM (SeqStx stxs) = SeqVal <$> mapM evalM stxs

evalM (IdStx str) =
    do msym <- findBindM str
       case msym of
         Just val -> return val
         Nothing -> error $ "Interpreter.evalM(IdStx): unbound symbols must be caught by the renamer" ++
                            "\n\n\t str = " ++ str ++ "\n"

evalM (AppStx stx1 stx2) =
    do val1 <- evalM stx1
       val2 <- evalM stx2
       case val1 of
         FnVal fn -> fn val2
         _ -> error $ "Interpreter.evalM(AppStx): application of non-functions must be detected by the renamer" ++
                      "\n\n\t stx1 = " ++ show stx1 ++
                      "\n\n\t -> val1 = " ++ show val1 ++
                      "\n\n\t stx2 = " ++ show stx2 ++
                      "\n\n\t -> val2 = " ++ show val2 ++ "\n"

evalM (CondStx ms blame) = evalMatches ms
    where evalMatches [] =
              error $ "Interpreter.evalM(CondStx): non-exhaustive patterns in " ++ blame
                    
          evalMatches ((pred, val):ms) =
              do pred' <- evalM pred
                 case pred' of
                   BoolVal False -> evalMatches ms
                   _ -> evalM val

evalM CotypeStx {} =
  error "Interpreter.evalM(CotypeStx): cotypes must be eliminated in reoderer"

evalM (DefnStx _ Def str body) =
    do rec addBindM str val
           val <- evalM body
       return val

evalM (DefnStx _ NrDef str body) =
    do val <- evalM body
       addBindM str val
       return val

evalM (LambdaStx str _ body) =
    FnVal . closure <$> get
    where closure env val =
              withLexicalEnvM env $ do
                addBindM str val
                withEnvM (evalM body)

evalM (MergeStx vals) =
  TypeVal <$> SeqVal <$> mapM (evalM . snd) vals

evalM (ModuleStx prefix ns) =
    error $ "Interpreter.evalM(ModuleStx): modules must be flattened by the renamer" ++
            "\n\n\t prefix = " ++ show prefix ++
            "\n\n\t namespace = " ++ show ns ++ "\n"

evalM (WhereStx stx stxs) =
    withEnvM $ do
      mapM_ evalM stxs
      withEnvM (evalM stx)


interpretDefinition :: FileSystem -> Definition -> Definition
interpretDefinition fs def@Definition { renStx = Just stx } =
    do let defs = map (FileSystem.definition fs) (freeNames def)
           vals = Map.fromList [ (sym, fromJust (Definition.val def)) | def <- defs, let Just (FnSymbol sym) = Definition.symbol def ]
           val = fst $ runState (evalM stx) (Env.initial vals)
       def { val = Just val }


interpretDefinitions :: FileSystem -> SrcFile -> [Definition] -> SrcFile
interpretDefinitions _ srcfile [] = srcfile

interpretDefinitions fs srcfile (def:defs) =
    let
        def' = interpretDefinition fs def
        srcfile' = SrcFile.updateDefinitions srcfile [def']
        fs' = FileSystem.add fs srcfile'
    in
      interpretDefinitions fs' srcfile' defs


interpret :: FileSystem -> SrcFile -> SrcFile
interpret _ srcfile@SrcFile { t = CoreT } =
    srcfile

interpret fs srcfile =
    interpretDefinitions fs srcfile (SrcFile.defsAsc srcfile)