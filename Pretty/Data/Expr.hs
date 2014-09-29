module Pretty.Data.Expr where

import Data.Expr
import qualified Data.QualName as QualName
import Data.PrettyString (PrettyString, (<>), (<+>), ($+$))
import qualified Data.PrettyString as PrettyString

-- edit: is this unused?
data DocType = ExpDocT | RenDocT

isParens :: Bool -> Expr -> Bool
isParens right AppE {} = right
isParens _ CharE {}    = False
isParens _ IdE {}      = False
isParens _ IntE {}     = False
isParens _ LetE {}     = False
isParens _ RealE {}    = False
isParens _ _           = True

docCond :: (a -> PrettyString) -> DocType -> [(a, Expr)] -> String -> PrettyString
docCond fn t ms blame =
  foldl1 ($+$) (map docMatch ms ++ docBlame)
  where
    docMatch (x, e) =
      PrettyString.sep [fn x <+> PrettyString.equals, PrettyString.nest (docExpr t e)]

    docBlame =
      [PrettyString.text "_" <+>
       PrettyString.equals <+>
       PrettyString.text "blame" <+>
       PrettyString.text blame]

docExpr :: DocType -> Expr -> PrettyString
docExpr t (AppE e1 e2) =
  let
    fn1 | isParens False e1 = PrettyString.parens . docExpr t
        | otherwise = docExpr t
    fn2 | isParens True e2 = PrettyString.parens . docExpr t
        | otherwise = docExpr t
  in
    PrettyString.sep [fn1 e1, PrettyString.nest (fn2 e2)]
docExpr _ (CharE c) = PrettyString.quotes (PrettyString.char c)
docExpr t (CondE ms blame) =
  PrettyString.sep [PrettyString.text "cond", PrettyString.nest (docCond (docExpr t) t ms blame)]
docExpr t (FnDecl kw name body) =
  PrettyString.sep [kwDoc kw <+> PrettyString.text name, PrettyString.nest (docExpr t body)]
  where kwDoc Def = PrettyString.text "def"
        kwDoc NrDef = PrettyString.text "nrdef"
docExpr _ (IdE name) = PrettyString.text (QualName.fromQualName name)
docExpr _ (IntE i) = PrettyString.int i
docExpr t (LetE defn body) =
  PrettyString.sep
  [PrettyString.text "let", PrettyString.nest (docExpr t defn),
   PrettyString.text "in", docExpr t body]
docExpr t (LambdaE arg body) =
  PrettyString.sep [PrettyString.text "\\" <> PrettyString.text arg <+> PrettyString.text "->", PrettyString.nest (docExpr t body)]
docExpr _ MergeE {} =
  error "Pretty.Data.Expr.docExpr: unhandled case for MergeE"
docExpr _ (RealE d) = PrettyString.double d

-- PrettyString for a list of 'Expr's.
docExprList :: [Expr] -> PrettyString
docExprList [] = PrettyString.text "[]"
docExprList (src:srcs) =
  PrettyString.sep .
  (++ [PrettyString.text "]"]) .
  PrettyString.intercalate (PrettyString.text ",") $
  ((PrettyString.text "[" <+> docExpr ExpDocT src):) $
  map (\x -> PrettyString.text "," <+> docExpr ExpDocT x) srcs