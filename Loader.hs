{-# LANGUAGE NamedFieldPuns, ParallelListComp,
             TupleSections #-}
module Loader where

import Prelude hiding (lex)

import Control.Monad.State
import Data.Functor ((<$>))
import Data.Graph (buildG, topSort, scc)
import Data.List (intercalate, nub, sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Tree

import Config
import Data.Exception (throwParseException)
import Data.FileSystem (FileSystem)
import qualified Data.FileSystem as FileSystem
import Data.SrcFile
import qualified Data.SrcFile as SrcFile
import Data.Stx
import Parser (parsePrelude, parseFile)
import Utils


type LoaderM a = StateT [String] IO a


dependenciesNsM :: Namespace String -> LoaderM ()
dependenciesNsM (Namespace uses stxs) =
    modify (map fst uses ++) >> mapM_ dependenciesM stxs


dependenciesM :: Stx String -> LoaderM ()
dependenciesM (CharStx _) = return ()
dependenciesM (IntStx _) = return ()
dependenciesM (DoubleStx _) = return ()
dependenciesM (SeqStx stxs) = mapM_ dependenciesM stxs
dependenciesM (IdStx _) = return ()
dependenciesM (AppStx stx1 stx2) = dependenciesM stx1 >> dependenciesM stx2
dependenciesM (CondMacro ms _) = mapM_ dependenciesM (snd (unzip ms))
dependenciesM (CondStx ms _) = mapM_ dependenciesM (snd (unzip ms))
dependenciesM (DefnStx _ _ _ body) = dependenciesM body
dependenciesM (LambdaMacro _ body) = dependenciesM body
dependenciesM (LambdaStx _ _ body) = dependenciesM body
dependenciesM (ModuleStx _ ns) = dependenciesNsM ns
dependenciesM (TypeStx _ stxs) = mapM_ dependenciesM stxs
dependenciesM (TypeMkStx _) = return ()
dependenciesM (TypeUnStx) = return ()
dependenciesM (TypeIsStx _) = return ()
dependenciesM (WhereStx _ stxs) = mapM_ dependenciesM stxs


readFileM :: String -> IO String
readFileM filename = readFile $ toFilename filename ++ ".bsl"
    where toFilename = map f
              where f '.' = '/'
                    f c = c


dependenciesFileM :: String -> IO SrcFile
dependenciesFileM filename =
    do str <- readFileM filename
       let parseFn | isPrelude filename = parsePrelude
                   | otherwise = parseFile
           srcfile@SrcFile { name, srcNs = Just ns } = case parseFn filename str of
                                                         Left str -> throwParseException str
                                                         Right x -> x
       (_, deps) <- runStateT (dependenciesNsM ns) []
       if name /= filename
       then error $ "Loader.dependenciesFileM: me " ++ show name ++ " and filename " ++ show filename ++ " mismatch"
       else return srcfile { deps = nub (sort deps) }


preloadSrcFile :: FileSystem -> String -> IO [SrcFile]
preloadSrcFile fs filename = preloadSrcFile' [] Set.empty [filename]
    where preloadSrcFile' srcfiles _ [] = return srcfiles
          preloadSrcFile' srcfiles loaded (filename:filenames)
              | filename `Set.member` loaded =
                  preloadSrcFile' srcfiles loaded filenames
              | fs `FileSystem.member` filename =
                  do let srcfile = FileSystem.get fs filename
                     preloadSrcFile' (srcfile:srcfiles) (Set.insert filename loaded) (deps srcfile ++ filenames)
              | otherwise =
                  do srcfile <- dependenciesFileM filename
                     preloadSrcFile' (srcfile:srcfiles) (Set.insert filename loaded) (deps srcfile ++ filenames)


buildNodes :: [SrcFile] -> Map String Int
buildNodes srcfiles =
    Map.fromList [ (SrcFile.name srcfile, i) | srcfile <- srcfiles | i <- [1..] ]


buildEdges :: Map String Int -> [SrcFile] -> [(Int, Int)]
buildEdges nodes =
    concatMap (\srcfile -> zip (repeat (nodes Map.! SrcFile.name srcfile)) (map (nodes Map.!) (SrcFile.deps srcfile)))


replaceIndexes :: [SrcFile] -> [Int] -> [SrcFile]
replaceIndexes srcfiles is = [ srcfiles !! (i - 1) | i <- is ]


hasCycle :: [[[Int]]] -> Maybe [Int]
hasCycle [] = Nothing
hasCycle (is:iss)
    | singleton is = hasCycle iss
    | otherwise = Just $ concat is


buildGraph :: [SrcFile] -> Either [SrcFile] [SrcFile]
buildGraph srcfiles =
    let
        nodes = buildNodes srcfiles
        edges = buildEdges nodes srcfiles
        graph = buildG (1, length srcfiles) edges
        srcfiles' = replaceIndexes srcfiles (topSort graph)
    in
      case hasCycle $ map levels $ scc graph of
        Nothing -> Right $ reverse srcfiles'
        Just is -> Left $ replaceIndexes srcfiles is


preload :: FileSystem -> String -> IO [SrcFile]
preload fs filename =
    do srcfiles <- preloadSrcFile fs filename
       case buildGraph srcfiles of
         Left srcfiles' -> error $ "Loader.preload: module cycle in " ++ show (map SrcFile.name srcfiles')
         Right srcfiles' -> return srcfiles'