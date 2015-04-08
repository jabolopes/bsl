{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test.Stage.Renamer where

import Control.Applicative
import Control.Monad.State hiding (state)

import Data.Expr (DefnKw(..), Expr(..))
import qualified Data.Expr as Expr
import qualified Data.PrettyString as PrettyString
import qualified Data.QualName as QualName
import Data.Source
import qualified Parser
import qualified Pretty.Data.Expr as Pretty
import qualified Stage.Expander as Expander
import Stage.Renamer (RenamerState)
import qualified Stage.Renamer as Renamer

deriving instance Eq DefnKw
deriving instance Eq Expr

initialRenamerState :: Monad m => m RenamerState
initialRenamerState =
  case snd <$> runStateT getRenamerState Renamer.initialRenamerState of
    Left err -> fail $ show err
    Right state -> return state
  where
    getRenamerState =
      do Renamer.addFnSymbolM "true#" "true#"
         Renamer.addFnSymbolM "false#" "false#"
         Renamer.addFnSymbolM "+" "+"
         Renamer.addFnSymbolM "isInt" "isInt#"

renameTestFile :: String -> IO [Expr]
renameTestFile filename =
  do expr <- expandFile
     state <- initialRenamerState
     case fst <$> runStateT (Renamer.renameM expr) state of
       Left err -> fail $ show err
       Right expr' -> return expr'
  where
    parseFile =
      do str <- readFile filename
         case Parser.parseFile filename str of
           Left err -> fail err
           Right src -> return src

    expandFile =
      do ModuleS _ _ [src] <- parseFile
         case Expander.expand src of
           Left err -> fail $ show err
           Right exprs -> return (head exprs)

-- edit: Use pretty strings instead
expect :: [Expr] -> String -> IO ()
expect expected filename =
  expect' =<< renameTestFile filename
  where
    expect' actual
      | expected == actual = return ()
      | otherwise =
        fail $ "Renamer" ++ "\n" ++
               "In: " ++ filename ++ "\n" ++
               "Expected: " ++ "\n" ++ PrettyString.toString (Pretty.docExprList expected) ++ "\n" ++
               "Actual: " ++ "\n" ++ PrettyString.toString (Pretty.docExprList actual)

testRenamer :: IO ()
testRenamer =
  do expect [expected1] "Test/TestData1.bsl"
     expect [expected2] "Test/TestData2.bsl"
  where
    expected1 =
      FnDecl NrDef (QualName.unqualified "f10")
      (LambdaE (QualName.unqualified "x#01")
       (LambdaE (QualName.unqualified "y#12")
        (CondE
         [(CondE
           [(AppE (Expr.idE "isInt#") (Expr.idE "x#01"),
             CondE [(AppE (Expr.idE "isInt#") (Expr.idE "y#12"),Expr.idE "true#"),
                    (Expr.idE "true#",Expr.idE "false#")]
             "irrefutable 'and' pattern"),
            (Expr.idE "true#",Expr.idE "false#")]
           "irrefutable 'and' pattern",
           LetE (FnDecl NrDef (QualName.unqualified "x3") (Expr.idE "x#01"))
           (LetE (FnDecl NrDef (QualName.unqualified "y4") (Expr.idE "y#12"))
            (LetE
             (FnDecl NrDef (QualName.unqualified "f25")
              (LambdaE (QualName.unqualified "z#26")
               (CondE
                [(AppE (LambdaE (QualName.unqualified "_7") (Expr.idE "true#")) (Expr.idE "z#26"),
                  LetE (FnDecl NrDef (QualName.unqualified "z8") (Expr.idE "z#26"))
                  (AppE (AppE (Expr.idE "+") (Expr.idE "z8")) (Expr.idE "y4")))]
                "f2")))
             (AppE (Expr.idE "f25") (Expr.idE "x3")))))]
         "f1")))

    expected2 =
      FnDecl NrDef (QualName.unqualified "f10")
      (LambdaE (QualName.unqualified "x#01")
       (CondE [(AppE (Expr.idE "isInt#") (Expr.idE "x#01"),
                LetE (FnDecl NrDef (QualName.unqualified "x2") (Expr.idE "x#01"))
                (LetE (FnDecl NrDef (QualName.unqualified "f23")
                       (LambdaE (QualName.unqualified "z#14")
                        (CondE [(AppE (LambdaE (QualName.unqualified "_5") (Expr.idE "true#")) (Expr.idE "z#14"),
                                 LetE (FnDecl NrDef (QualName.unqualified "z6") (Expr.idE "z#14"))
                                 (AppE (AppE (Expr.idE "+") (Expr.idE "z6")) (IntE 1)))]
                         "f2")))
                 (LetE (FnDecl NrDef (QualName.unqualified "y7") (IntE 0))
                  (AppE (Expr.idE "f23") (Expr.idE "y7")))))]
        "f1"))
