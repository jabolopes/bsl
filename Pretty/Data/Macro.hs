module Pretty.Data.Macro where

import Data.Macro
import Data.PrettyString (PrettyString, (<>), (<+>), ($$), ($+$))
import qualified Data.PrettyString as PrettyString

docPat :: Pat -> PrettyString
docPat pat =
  docBinder (patBinder pat) <> PrettyString.text "@" <> docGuard (patGuard pat)
  where docBinder "" = PrettyString.empty
        docBinder name = PrettyString.text name 

        docGuard AllPG = PrettyString.empty
        docGuard (PredicatePG pred) = docMacro pred
        docGuard (ListPG hdPat tlPat) =
          PrettyString.sep
            [PrettyString.char '(' <> docPat hdPat,
             PrettyString.text "+>",
             docPat tlPat <> PrettyString.char ')']
        docGuard (TuplePG pats) =
          PrettyString.char '[' <>
          PrettyString.sep (PrettyString.intercalate (PrettyString.char ',') (map docPat pats)) <>
          PrettyString.char ']'

docMatch :: ([Pat], Macro) -> PrettyString
docMatch (pats, body) =
  PrettyString.sep [docPats, PrettyString.parens . PrettyString.nest . docMacro $ body]
  where docPats = PrettyString.sep (map docPat pats)

docCond :: [([Pat], Macro)] -> PrettyString
docCond ms = PrettyString.vcat (map docMatch ms)

docMacro :: Macro -> PrettyString
docMacro (AndM m1 m2) = docMacro m1 <+> PrettyString.text "&&" <+> docMacro m2
docMacro (AppM m1 m2@AppM {}) =
  PrettyString.sep [docMacro m1, PrettyString.parens (docMacro m2)]
docMacro (AppM m1 m2) =
  PrettyString.sep [docMacro m1, PrettyString.nest (docMacro m2)]
docMacro (BinOpM op m1 m2) =
  docMacro m1 <+> PrettyString.text op <+> docMacro m2
docMacro (CharM c) = PrettyString.char '\'' <> PrettyString.char c <> PrettyString.char '\''
docMacro (CondM ms) = docCond ms
docMacro (FnDeclM name body) =
  PrettyString.sep [PrettyString.text name <+> PrettyString.equals,
                    PrettyString.nest (docMacro body)]
docMacro (IdM name) = PrettyString.text (show name)
docMacro (IntM i) = PrettyString.int i
docMacro (ModuleM name uses defns) =
  PrettyString.text "me" <+> PrettyString.text name
  $+$
  PrettyString.empty
  $+$
  PrettyString.vcat (map docUse uses)
  $+$
  PrettyString.vcat
    (PrettyString.intercalate (PrettyString.text "\n") (map docMacro defns))
  where docUse (use, "") =
          PrettyString.text "use" <+> PrettyString.text use
        docUse (use, qual) =
          docUse (use, "") <+> PrettyString.text "as" <+> PrettyString.text qual
docMacro (OrM m1 m2) = docMacro m1 <+> PrettyString.text "||" <+> docMacro m2
docMacro (RealM r) = PrettyString.double r
docMacro (SeqM ms) =
  PrettyString.char '[' <>
  PrettyString.sep (PrettyString.intercalate (PrettyString.text ", ") (map docMacro ms)) <>
  PrettyString.char ']'
docMacro (StringM str) =
  PrettyString.char '"' <> PrettyString.text str <> PrettyString.char '"'
docMacro (WhereM m ms) =
  PrettyString.sep
  [docMacro m,
   PrettyString.sep [PrettyString.text "where {",
                     PrettyString.nest (PrettyString.vcat (map docMacro ms)),
                     PrettyString.char '}']]