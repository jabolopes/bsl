{-# LANGUAGE ParallelListComp #-}
module Data.Stx where

import Data.List (nub, sort)

import Data.Type


data DefnKw
    = Def
    | NrDef
      deriving (Show)


data Namespace a
    = Namespace [(String, String)] [Stx a]
      deriving (Show)


type PatDefn a = (String, [Stx a])


data Pat a
    = Pat { patPred :: Stx a
          , patDefns :: [PatDefn a] }
      deriving (Show)


mkGeneralPat :: Stx a -> [[Stx a]] -> [Pat a] -> Pat a
mkGeneralPat pred mods pats =
    Pat (mkPred pred pats) (modPats mods pats)
    where mkPred pred [] = pred
          mkPred pred pats =
              AppStx pred $ SeqStx $ map patPred pats

          modDefns _ [] = []
          modDefns mod ((str, mod'):defns) =
              (str, mod' ++ mod):modDefns mod defns

          modPats [] [] = []    
          modPats (mod:mods) (Pat _ defns:pats) =
              modDefns mod defns ++ modPats mods pats


mkPat :: Stx String -> [Stx String] -> [Pat String] -> Pat String
mkPat pred mods pats =
    mkGeneralPat pred (map (:[]) mods) pats


mkPredPat :: Stx String -> Pat String
mkPredPat pred =
    mkGeneralPat pred [] []


-- edit: plist already checks the lenght of the list, however, it
-- might be better to generate end of list pattern
-- @
-- nrdef [] = tail (... (tail xs)...)
-- @
mkListPat :: [Pat String] -> Pat String
mkListPat pats =
    mkGeneralPat (IdStx "plist") (map (reverse . listRef) [1..length pats]) pats
    where listRef 1 = [IdStx "hd"]
          listRef i = IdStx "tl":listRef (i - 1)


namePat :: String -> Pat String -> Pat String
namePat name (Pat pred defns) =
    Pat pred $ (name, []):defns


type Observation = (String, Type)


data Stx a
    = CharStx Char
    | IntStx Int
    | DoubleStx Double
    | SeqStx [Stx a]

    | IdStx a

    | AppStx (Stx a) (Stx a)

    -- |
    -- This construct is not available in the parser
    -- @
    -- x@Int y@isInt = val1
    -- x@Int y@isReal = val2
    --  @     @ = blame "..."
    -- @
    | CondMacro [([Pat a], Stx a)] String

    -- |
    -- This construct is not available in the parser
    -- @
    -- case
    --   pred1 val1 -> val1'
    --   pred2 val2 -> val2'
    --   ...
    --   _ -> blame "..."
    -- @
    | CondStx [(Stx a, Stx a)] String

    -- info: observations (2nd argument) are sorted in Parser
    | CotypeStx String [Observation] (Namespace a)

    | DefnStx (Maybe Type) DefnKw String (Stx a)

    | LambdaMacro [Pat a] (Stx a)
    | LambdaStx String (Maybe String) (Stx a)

    -- info: initialization vals (2nd argument) are sorted in Parser
    | MergeStx String [(String, Stx a)]
    | ModuleStx [String] (Namespace a)

    | WhereStx (Stx a) [Stx a]
      deriving (Show)


isCharStx :: Stx a -> Bool
isCharStx (CharStx _) = True
isCharStx _ = False


isAppStx :: Stx a -> Bool
isAppStx (AppStx _ _) = True
isAppStx _ = False


isDefnStx DefnStx {} = True
isDefnStx _ = False


isLambdaStx :: Stx a -> Bool
isLambdaStx (LambdaStx _ _ _) = True
isLambdaStx _ = False


isModuleStx :: Stx a -> Bool
isModuleStx (ModuleStx _ _) = True
isModuleStx _ = False


isWhereStx :: Stx a -> Bool
isWhereStx (WhereStx _ _) = True
isWhereStx _ = False


isValueStx :: Stx a -> Bool
isValueStx (CharStx _) = True
isValueStx (IntStx _) = True
isValueStx (DoubleStx _) = True
isValueStx (SeqStx _) = True
isValueStx (IdStx _) = True
isValueStx (LambdaStx _ _ _) = True
isValueStx _ = False


andStx :: Stx String -> Stx String -> Stx String
andStx stx1 stx2 =
    -- note: not using 'stx1' and 'stx2' directly in the Boolean
    -- expression in order to force them to have type 'Bool'.
    let
        err = "irrefutable 'and' pattern"
        m2 = (stx2, IdStx "true")
        m3 = (IdStx "true", IdStx "false")
        m1 = (stx1, CondStx [m2, m3] err)
    in
      CondStx [m1, m3] err


appStx :: a -> Stx a -> Stx a
appStx str stx = AppStx (IdStx str) stx


applyStx :: a -> [Stx a] -> Stx a
applyStx str = appStx str . SeqStx


binOpStx :: a -> Stx a -> Stx a -> Stx a
binOpStx op stx1 stx2 =
    AppStx (appStx op stx1) stx2


constStx :: Stx a -> Stx a
constStx stx1 = LambdaStx "_" Nothing stx1
-- edit: maybe it should be TvarT or Evar instead of Nothing?


constTrueStx :: Stx String
constTrueStx = constStx (IdStx "true")


foldAppStx :: Stx a -> [Stx a] -> Stx a
foldAppStx x [] = x
foldAppStx x (y:ys) = AppStx y (foldAppStx x ys)


orStx :: Stx String -> Stx String -> Stx String
orStx stx1 stx2 =
    -- note: not using 'stx1' and 'stx2' directly in the Boolean
    -- expression in order to force them to have type 'Bool'.
    let
        err = "irrefutable 'or' pattern"
        m1 = (stx1, IdStx "true")
        m2 = (stx2, IdStx "true")
        m3 = (IdStx "true", IdStx "false")
    in
      CondStx [m1, m2, m3] err


signalStx :: String -> String -> Stx String -> Stx String
signalStx id str val =
    appStx "signal" (SeqStx [stringStx id, stringStx str, val])


stringStx :: String -> Stx a
stringStx str = SeqStx $ map CharStx str


freeVarsList :: [String] -> [String] -> [Stx String] -> ([String], [String])
freeVarsList env fvars [] = (env, fvars)
freeVarsList env fvars (x:xs) =
    let (env', fvars') = freeVars' env fvars x in
    freeVarsList env' fvars' xs


freeVarsPat :: [String] -> [String] -> Pat String -> ([String], [String])
freeVarsPat env fvars pat =
    let (env', fvars') = freeVars' env fvars (patPred pat) in
    freeVarsList (env' ++ map fst (patDefns pat)) fvars' (concatMap snd (patDefns pat))


freeVarsPats :: [String] -> [String] -> [Pat String] -> ([String], [String])
freeVarsPats env fvars [] = (env, fvars)
freeVarsPats env fvars (pat:pats) =
    let (env', fvars') = freeVarsPat env fvars pat in
    freeVarsPats env' fvars' pats


freeVars' :: [String] -> [String] -> Stx String -> ([String], [String])
freeVars' env fvars (CharStx _) = (env, fvars)
freeVars' env fvars (IntStx _) = (env, fvars)
freeVars' env fvars (DoubleStx _) = (env, fvars)

freeVars' env fvars (SeqStx stxs) =
    loop env fvars stxs
    where loop env fvars [] = (env, fvars)
          loop env fvars (stx:stxs) =
              let (env', fvars') = freeVars' env fvars stx in
              loop env' fvars' stxs

freeVars' env fvars (IdStx name)
    | name `elem` env = (env, fvars)
    | otherwise = (env, name:fvars)

freeVars' env fvars (AppStx stx1 stx2) =
    let (env', fvars') = freeVars' env fvars stx1 in
    freeVars' env' fvars' stx2

freeVars' env fvars (CondMacro ms _) =
    loop env fvars ms
    where loop env fvars [] = (env, fvars)
          loop env fvars ((pats, stx):ms) =
              let
                  (env', fvars') = freeVarsPats env fvars pats
                  (env'', fvars'') = freeVars' env' fvars' stx
              in
                loop env'' fvars'' ms
              

freeVars' env fvars (CondStx ms _) =
    loop env fvars ms
    where loop env fvars [] = (env, fvars)
          loop env fvars ((stx1, stx2):stxs) =
              let
                  (env', fvars') = freeVars' env fvars stx1
                  (env'', fvars'') = freeVars' env' fvars' stx2
              in
                loop env'' fvars'' stxs

freeVars' env fvars (DefnStx _ Def name stx) =
    freeVars' (name:env) fvars stx

freeVars' env fvars (DefnStx _ NrDef name stx) =
    let (env', fvars') = freeVars' env fvars stx in
    (name:env', fvars')

freeVars' _ _ (LambdaMacro _ _) =
    error "freeVars'(LambdaMacro): not implemented"

freeVars' env fvars (LambdaStx arg _ body) =
    freeVars' (arg:env) fvars body

freeVars' env fvars (MergeStx _ vals) =
    loop env fvars vals
    where loop env fvars [] = (env, fvars)
          loop env fvars ((_, stx):vals) =
              let (env', fvars') = freeVars' env fvars stx in
              loop env' fvars' vals

freeVars' env fvars (WhereStx stx stxs) =
    let (env', fvars') = loop env fvars stxs in
    freeVars' env' fvars' stx
    where loop env fvars [] = (env, fvars)
          loop env fvars (stx:stxs) =
              let (env', fvars') = freeVars' env fvars stx in
              loop env' fvars' stxs

freeVars' _ _ _ =
    error "freeVars': unhandled case"


freeVars :: Stx String -> [String]
freeVars = nub . sort . snd . freeVars' [] []
