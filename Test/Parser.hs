{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test.Parser where

import Data.QualName (QualName(..))
import qualified Data.PrettyString as PrettyString
import Data.Source
import qualified Parser
import qualified Pretty.Data.Source as Pretty

deriving instance Eq QualName
deriving instance Eq Source
deriving instance Show Source

parseTestFile :: String -> IO Source
parseTestFile filename =
  do str <- readFile filename
     case Parser.parseFile filename str of
       Left err -> fail err
       Right src -> return src

parseSnippet :: Monad m => String -> m Source
parseSnippet str =
  do case Parser.parseRepl "" str of
       Left err -> fail $ show err
       Right src -> return src

data Actual = File String
            | Snippet String

-- edit: Use pretty strings instead
expect :: Source -> Actual -> IO ()
expect expected actual =
  case actual of
    File filename -> expect' filename =<< parseTestFile filename
    Snippet snippet -> expect' snippet =<< parseSnippet snippet
  where
    expect' filename src
      | expected == src = return ()
      | otherwise =
        fail $ "In: " ++ filename ++ "\n" ++
               "Expected: " ++ "\n" ++ PrettyString.toString (Pretty.docSource expected) ++ "\n" ++
               "Src: " ++ "\n" ++ PrettyString.toString (Pretty.docSource src)

testParser :: IO ()
testParser =
  do expect expectedSnippet1 $ Snippet "def not id = false | @ = true"
     expect expected1 $ File "Test/TestData1.bsl"
     expect expected2 $ File "Test/TestData2.bsl"
     expect expected4 $ File "Test/TestData4.bsl"
  where
    expectedSnippet1 =
      FnDeclS "not"
      (CondS [([IdS (QualName {fromQualName = "id"})], IdS (QualName {fromQualName = "false"})),
              ([PatS "" Nothing], IdS (QualName {fromQualName = "true"}))])

    expected1 =
      ModuleS "Test.TestData1" []
        [FnDeclS "f1"
         (WhereS
          (CondS [([PatS "x" (Just (IdS (QualName {fromQualName = "isInt"}))),
                    PatS "y" (Just (IdS (QualName {fromQualName = "isInt"})))],
                   AppS (IdS (QualName {fromQualName = "f2"})) (IdS (QualName {fromQualName = "x"})))])
          [FnDeclS "f2"
           (CondS
            [([PatS "z" Nothing], BinOpS "+" (IdS (QualName {fromQualName = "z"})) (IdS (QualName {fromQualName = "y"})))])])]

    expected2 =
      ModuleS "Test.TestData2" []
        [FnDeclS "f1"
         (WhereS
          (CondS [([PatS "x" (Just (IdS (QualName {fromQualName = "isInt"})))],
                   LetS [FnDeclS "y" (IntS 0)]
                   (AppS (IdS (QualName {fromQualName = "f2"})) (IdS (QualName {fromQualName = "y"}))))])
          [FnDeclS "f2"
           (CondS
            [([PatS "z" Nothing], BinOpS "+" (IdS (QualName {fromQualName = "z"})) (IntS 1))])])]

    expected4 =
      ModuleS "Test.TestData4" []
        [FnDeclS "eq"
         (WhereS
          (CondS [([PatS "x" (Just (IdS (QualName {fromQualName = "isInt"}))), PatS "y" (Just (IdS (QualName {fromQualName = "isInt"})))],
                   AppS (AppS (IdS (QualName {fromQualName = "eqInt"})) (IdS (QualName {fromQualName = "x"}))) (IdS (QualName {fromQualName = "y"}))),
                  ([PatS "x" Nothing, PatS "y" Nothing],
                   AppS (AppS (IdS (QualName {fromQualName = "eqSeq"})) (IdS (QualName {fromQualName = "x"}))) (IdS (QualName {fromQualName = "y"})))])
          [FnDeclS "eqSeq"
           (CondS [([SeqS [], SeqS []],
                    IdS (QualName {fromQualName = "true"})),
                   ([BinOpS "+>" (PatS "z" Nothing) (PatS "zs" Nothing), BinOpS "+>" (PatS "w" Nothing) (PatS "ws" Nothing)],
                    AndS
                    (AppS (AppS (IdS (QualName {fromQualName = "eq"})) (IdS (QualName {fromQualName = "z"}))) (IdS (QualName {fromQualName = "w"})))
                    (AppS (AppS (IdS (QualName {fromQualName = "eqSeq"})) (IdS (QualName {fromQualName = "zs"}))) (IdS (QualName {fromQualName = "ws"})))),
                   ([PatS "" Nothing, PatS "" Nothing],
                    IdS (QualName {fromQualName = "false"}))])])]