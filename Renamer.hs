{-# LANGUAGE NamedFieldPuns, ParallelListComp, TupleSections #-}
module Renamer where

import Prelude hiding (mod)

import Control.Monad.Error (catchError, throwError)
import Control.Monad.State
import Data.Functor ((<$>))
import Data.List (isPrefixOf)
import Data.Maybe (isNothing, mapMaybe)

import Data.Definition (Definition(..))
import qualified Data.Definition as Definition
import Data.FileSystem (FileSystem)
import qualified Data.FileSystem as FileSystem (add, lookupDefinition)
import Data.Frame (Frame)
import qualified Data.Frame as Frame (frId)
import Data.FrameTree (FrameTree)
import qualified Data.FrameTree as FrameTree (empty, rootId, getFrame, getLexicalSymbol, addSymbol, addFrame)
import Data.Module (ModuleT (..), Module(..))
import qualified Data.Module as Module
import Data.Expr (DefnKw(..), Expr(..))
import qualified Data.Expr as Expr (freeVars, idE)
import qualified Data.QualName as QualName (fromQualName)
import Data.Symbol (Symbol (..))
import qualified Data.PrettyString as PrettyString
import qualified Pretty.Renamer as Pretty
import Utils (rebaseName, flattenId, splitId)

data RenamerState =
    RenamerState { frameTree :: FrameTree
                 , nameCount :: Int
                 , typeCount :: Int
                 , currentFrame :: Int
                 , existFreeVars :: Bool }

initialRenamerState :: RenamerState
initialRenamerState =
    let frameTree = FrameTree.empty in
    RenamerState { frameTree = frameTree
                 , nameCount = 0
                 , typeCount = 0
                 , currentFrame = FrameTree.rootId frameTree
                 , existFreeVars = False }

type RenamerM a = StateT RenamerState (Either String) a

getCurrentFrameM :: RenamerM Frame
getCurrentFrameM =
    do tree <- frameTree <$> get
       fid <- currentFrame <$> get
       case FrameTree.getFrame tree fid of
         Nothing -> error "Renamer.getCurrentFrameM: current frame does not exist"
         Just x -> return x

genNumM :: RenamerM Int
genNumM =
    do count <- nameCount <$> get
       modify $ \s -> s { nameCount = count + 1 }
       return count

genNameM :: String -> RenamerM String
genNameM name = (name ++) . show <$> genNumM

genTypeIdM :: RenamerM Int
genTypeIdM =
    do count <- typeCount <$> get
       modify $ \s -> s { typeCount = count + 1 }
       return count

lookupSymbol :: FrameTree -> Frame -> String -> Maybe Symbol
lookupSymbol = FrameTree.getLexicalSymbol

lookupSymbolM :: String -> RenamerM (Maybe Symbol)
lookupSymbolM name =
    do tree <- frameTree <$> get
       currentFrame <- getCurrentFrameM
       return $ lookupSymbol tree currentFrame name

getSymbolM :: String -> RenamerM Symbol
getSymbolM name =
    do msym <- lookupSymbolM name
       case msym of
         Nothing -> throwError $ "name " ++ show name ++ " is not defined"
         Just t -> return t

getFnSymbolM :: String -> RenamerM String
getFnSymbolM name =
    do sym <- getSymbolM name
       case sym of
         FnSymbol x -> return x
         _ -> throwError $ "name " ++ show name ++ " is not a function"

getTypeSymbolM :: String -> RenamerM Int
getTypeSymbolM name =
    do sym <- getSymbolM name
       case sym of
         TypeSymbol tid -> return tid
         _ -> throwError $ "name " ++ show name ++ " is not an inductive type"

addSymbolM :: String -> Symbol -> RenamerM ()
addSymbolM name sym = checkShadowing >> addSymbol
    where checkShadowing =
              do msym <- lookupSymbolM name
                 case msym of
                   Nothing -> return ()
                   Just _ -> throwError $ "name " ++ show name ++ " is already defined"

          addSymbol =
              do tree <- frameTree <$> get
                 currentFrame <- getCurrentFrameM
                 let tree' = FrameTree.addSymbol tree currentFrame name sym
                 modify $ \s -> s { frameTree = tree' }

addFnSymbolM :: String -> String -> RenamerM ()
addFnSymbolM name = addSymbolM name . FnSymbol

addTypeSymbolM :: String -> Int -> RenamerM ()
addTypeSymbolM name = addSymbolM name . TypeSymbol

withScopeM :: RenamerM a -> RenamerM a
withScopeM m =
    do tree <- frameTree <$> get
       frame <- getCurrentFrameM
       let (tree', frame') = FrameTree.addFrame tree frame
       modify $ \s -> s { frameTree = tree', currentFrame = Frame.frId frame' }
       val <- m
       modify $ \s -> s { currentFrame = Frame.frId frame }
       return val

renameLambdaM :: String -> Expr -> RenamerM Expr
renameLambdaM arg body =
    do arg' <- genNameM arg
       LambdaE arg' <$>
         withScopeM
           (do addFnSymbolM arg arg'
               withScopeM (renameOneM body))

renameOneM :: Expr -> RenamerM Expr
renameOneM expr = head <$> renameM expr

renameM :: Expr -> RenamerM [Expr]
renameM (AppE expr1 expr2) =
    (:[]) <$> ((AppE <$> renameOneM expr1) `ap` renameOneM expr2)
renameM expr@CharE {} = return [expr]
renameM (CondE ms blame) =
    (:[]) . (`CondE` blame) <$> mapM renameMatch ms
    where renameMatch (expr1, expr2) =
              do expr1' <- renameOneM expr1
                 expr2' <- renameOneM expr2
                 return (expr1', expr2')
renameM (FnDecl Def name body) =
    if name `elem` Expr.freeVars body
    then do
      name' <- genNameM name
      addFnSymbolM name name'
      (:[]) . FnDecl Def name' <$> renameOneM body
    else
        renameM (FnDecl NrDef name body)
renameM (FnDecl NrDef name body) =
    do name' <- genNameM name
       body' <- renameOneM body
       addFnSymbolM name name'
       return [FnDecl NrDef name' body']
renameM expr@(IdE name) =
  do b <- existFreeVars <$> get
     if b
     then do
       msym <- lookupSymbolM (QualName.fromQualName name)
       case msym of
         Just (FnSymbol sym) -> return $ (:[]) $ Expr.idE sym
         _ -> return [expr]
     else
       (:[]) . Expr.idE <$> getFnSymbolM (QualName.fromQualName name)
renameM expr@IntE {} = return [expr]
renameM (LambdaE arg body) =
    (:[]) <$> renameLambdaM arg body
renameM (MergeE vals) =
  (:[]) <$> MergeE <$> mapM renameValsM vals
  where renameValsM (name, expr) =  (name,) <$> renameOneM expr
renameM expr@RealE {} = return [expr]
renameM (WhereE expr exprs) =
    withScopeM $ do
      exprs' <- concat <$> mapM renameM exprs
      expr' <- withScopeM (renameOneM expr)
      return [WhereE expr' exprs']

lookupUnprefixedFreeVar :: FileSystem -> [String] -> String -> [Definition]
lookupUnprefixedFreeVar fs unprefixed var =
    let unprefixedVars = map (++ '.':var) unprefixed in
    mapMaybe (FileSystem.lookupDefinition fs) unprefixedVars

lookupPrefixedFreeVar :: FileSystem -> [(String, String)] -> String -> [Definition]
lookupPrefixedFreeVar fs prefixed name =
    mapMaybe (definition . rebase) $ filter isPrefix prefixed
    where isPrefix (_, y) = splitId y `isPrefixOf` splitId name
          rebase (x, y) = rebaseName x y name
          definition = FileSystem.lookupDefinition fs

lookupFreeVars :: FileSystem -> [String] -> [(String, String)] -> [String] -> RenamerM [Definition]
lookupFreeVars _ _ _ [] = return []
lookupFreeVars fs unprefixed prefixed (name:names) =
    do let fns = [lookupUnprefixedFreeVar fs unprefixed,
                  lookupPrefixedFreeVar fs prefixed]
       case concatMap ($ name) fns of
         [] -> throwError $ "name " ++ show name ++ " is not defined"
         [def] -> (def:) <$> lookupFreeVars fs unprefixed prefixed names
         _ -> throwError $ "name " ++ show name ++ " is multiply defined"

renameDeclaration :: Expr -> Either String Expr
renameDeclaration expr@FnDecl {} =
  let state = initialRenamerState { existFreeVars = True } in
  fst <$> runStateT (renameOneM expr) state

renameDefinitionM :: FileSystem -> Definition -> RenamerM Definition
renameDefinitionM fs def@Definition { defExp = Right expr } =
    do let unprefixed = Definition.defUnprefixedUses def
           prefixed = Definition.defPrefixedUses def
           names = Expr.freeVars expr
       defs <- lookupFreeVars fs unprefixed prefixed names
       if any (isNothing . Definition.defSym) defs then
         return $ def { defFreeNames = map Definition.defName defs
                      , defSym = Nothing
                      , defRen = Left $ let freeNames = [ Definition.defName x | x <- defs, isNothing (Definition.defSym x) ] in
                                         Pretty.freeNamesFailedToRename freeNames }
       else do
         let syms = mapMaybe Definition.defSym defs
         sequence_ [ addSymbolM name sym | name <- names | sym <- syms ]
         (do expr' <- renameOneM expr
             sym <- getSymbolM $ flattenId $ tail $ splitId $ Definition.defName def
             return $ def { defFreeNames = map Definition.defName defs
                          , defSym = Just sym
                          , defRen = Right expr' }) `catchError` (\err -> return $ def { defFreeNames = map Definition.defName defs
                                                                                        , defSym = Nothing
                                                                                        , defRen = Left (PrettyString.text err) })
renameDefinition :: FileSystem -> Definition -> Either String Definition
renameDefinition fs def =
  fst <$> runStateT (renameDefinitionM fs def) initialRenamerState

renameDefinitions :: FileSystem -> Module -> [Definition] -> Either String Module
renameDefinitions _ mod [] = return mod
renameDefinitions fs mod (def:defs) =
    do def' <- renameDefinition fs def
       let mod' = Module.updateDefinitions mod [def']
           fs' = FileSystem.add fs mod'
       renameDefinitions fs' mod' defs

rename :: FileSystem -> Module -> Either String Module
rename _ mod@Module { modType = CoreT } = return mod
rename fs mod = renameDefinitions fs mod (Module.defsAsc mod)
