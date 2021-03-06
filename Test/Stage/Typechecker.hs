{-# LANGUAGE FlexibleContexts #-}
module Test.Stage.Typechecker where

import Control.Monad.Except (MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.State hiding (state)

import Data.Expr (Expr(..))
import qualified Data.Name as Name
import Data.PrettyString (PrettyString)
import qualified Data.PrettyString as PrettyString
import Monad.NameT (MonadName)
import qualified Monad.NameT as NameT
import qualified Pretty.Data.Expr as Pretty
import Stage.Renamer (RenamerState)
import qualified Stage.Renamer as Renamer
import Typechecker.Context (Context(..))
import qualified Typechecker.Context as Context
import Typechecker.Type (Type(..))
import qualified Typechecker.Type as Type
import qualified Typechecker.TypeName as TypeName
import qualified Test.Diff as Diff
import qualified Test.Stage as Stage

initialRenamerState :: MonadError PrettyString m => m RenamerState
initialRenamerState =
  case snd <$> runStateT getRenamerState Renamer.initialRenamerState of
    Left err -> throwError err
    Right state -> return state
  where
    getRenamerState =
      do Renamer.addFnSymbolM "check#" "check#"
         Renamer.addFnSymbolM "true#" "true#"
         Renamer.addFnSymbolM "true" "true#"
         Renamer.addFnSymbolM "false#" "false#"
         Renamer.addFnSymbolM "false" "false#"
         Renamer.addFnSymbolM "+" "+"
         Renamer.addFnSymbolM ">" ">"
         Renamer.addFnSymbolM "addIntReal" "addIntReal"
         Renamer.addFnSymbolM "isInt" "isInt#"
         Renamer.addFnSymbolM "isReal" "isReal"
         Renamer.addFnSymbolM "isChar" "isChar#"
         Renamer.addFnSymbolM "isList#" "isList#"
         Renamer.addFnSymbolM "null#" "null#"
         Renamer.addFnSymbolM "null" "null#"
         Renamer.addFnSymbolM "case" "case"
         Renamer.addFnSymbolM "cons" "cons"
         Renamer.addFnSymbolM "head#" "head#"
         Renamer.addFnSymbolM "tail#" "tail#"
         Renamer.addFnSymbolM "isHeadTail#" "isHeadTail#"
         Renamer.addFnSymbolM "eqInt" "eqInt"
         -- Tuple
         Renamer.addFnSymbolM "isTuple0" "isTuple0"
         Renamer.addFnSymbolM "isTuple2" "isTuple2"
         Renamer.addFnSymbolM "mkTuple0" "mkTuple0"
         Renamer.addFnSymbolM "mkTuple2" "mkTuple2"
         Renamer.addFnSymbolM "tuple2Ref0#" "tuple2Ref0#"
         Renamer.addFnSymbolM "tuple2Ref1#" "tuple2Ref1#"
         -- Type
         Renamer.addFnSymbolM "isType#" "isType#"
         -- Variant
         Renamer.addFnSymbolM "isVariant0#" "isVariant0#"
         Renamer.addFnSymbolM "isVariant#" "isVariant#"
         Renamer.addFnSymbolM "mkVariant0#" "mkVariant0#"
         Renamer.addFnSymbolM "mkVariant#" "mkVariant#"
         Renamer.addFnSymbolM "unVariant#" "unVariant#"

initialTypecheckerContext :: Context
initialTypecheckerContext =
  Context.Context { scope = map (\(name, typ) -> Context.assigned (Name.untyped name) typ) initialBindings,
                    vars = [] }

  where
    typeVar :: Char -> Type
    typeVar = TypeVar . TypeName.typeName

    forall :: Char -> Type -> Type
    forall name = Forall (TypeName.typeName name)

    initialBindings :: [(String, Type)]
    initialBindings =
      [("check#", forall 'a' (Arrow (Arrow (typeVar 'a') Type.boolT) (Arrow (typeVar 'a') (typeVar 'a')))),
       ("true#", Type.boolT),
       ("true", Type.boolT),
       ("false#", Type.boolT),
       ("false", Type.boolT),
       ("+", Arrow Type.intT (Arrow Type.intT Type.intT)),
       ("addIntReal", Arrow Type.intT (Arrow Type.realT Type.realT)),
       (">", Arrow Type.intT (Arrow Type.intT Type.boolT)),
       ("isInt#", Arrow Type.intT Type.boolT),
       ("isReal", Arrow Type.realT Type.boolT),
       ("isChar#", Arrow Type.charT Type.boolT),
       ("isList#", forall 'a' (Arrow (Type.ListT (Arrow (typeVar 'a') Type.boolT)) (Arrow (Type.ListT (typeVar 'a')) Type.boolT))),
       ("isHeadTail#", forall 'a' (Arrow (Arrow (typeVar 'a') Type.boolT) (Arrow (Arrow (Type.ListT (typeVar 'a')) Type.boolT) (Arrow (Type.ListT (typeVar 'a')) Type.boolT)))),
       ("null#", forall 'a' (Type.ListT (typeVar 'a'))),
       ("head#", forall 'a' (Arrow (Type.ListT (typeVar 'a')) (typeVar 'a'))),
       ("tail#", forall 'a' (Arrow (Type.ListT (typeVar 'a')) (Type.ListT (typeVar 'a')))),
       ("eqInt", Arrow Type.intT (Arrow Type.intT Type.boolT)),
       ("cons", forall 'a' (Arrow (typeVar 'a') (Arrow (Type.ListT (typeVar 'a')) (Type.ListT (typeVar 'a'))))),
       ("case", forall 'a' (forall 'b' (Arrow (typeVar 'a') (Arrow (Arrow (typeVar 'a') (typeVar 'b')) (typeVar 'b'))))),
       -- Tuple
       ("isTuple0", Type.unitT `Arrow` Type.boolT),
       ("isTuple2",
        forall 'a'
         (forall 'b'
          (Arrow
            (TupleT [typeVar 'a' `Arrow` Type.boolT, typeVar 'b' `Arrow` Type.boolT])
            (Arrow
              (TupleT [typeVar 'a', typeVar 'b'])
              Type.boolT)))),
       ("mkTuple0", Type.unitT),
       ("mkTuple2",
        forall 'a'
         (forall 'b'
          (Arrow (typeVar 'a')
           (Arrow (typeVar 'b')
            (TupleT [typeVar 'a', typeVar 'b']))))),
       ("tuple2Ref0#", forall 'a' (forall 'b' (Arrow (TupleT [typeVar 'a', typeVar 'b']) (typeVar 'a')))),
       ("tuple2Ref1#", forall 'a' (forall 'b' (Arrow (TupleT [typeVar 'a', typeVar 'b']) (typeVar 'b')))),
       -- Type
       ("isType#", forall 'a' (Arrow Type.stringT (Arrow (typeVar 'a') Type.boolT))),
       -- Variant
       ("isVariant0#",
        forall 'a'
         (Arrow Type.stringT
          (Arrow Type.intT
            (Arrow (typeVar 'a')
             Type.boolT)))),
       ("isVariant#",
        forall 'a'
        (forall 'b'
         (Arrow Type.stringT
          (Arrow Type.intT
           (Arrow (Arrow (typeVar 'a') Type.boolT)
            (Arrow (typeVar 'b')
             Type.boolT)))))),
       ("mkVariant0#", forall 'a' (Arrow Type.stringT (Arrow Type.intT (typeVar 'a')))),
       ("mkVariant#", forall 'a' (forall 'b' (Arrow Type.stringT (Arrow Type.intT (Arrow (typeVar 'a') (typeVar 'b')))))),
       ("unVariant#", forall 'a' (forall 'b' (Arrow (typeVar 'a') (typeVar 'b'))))
      ]

typecheckTestFile :: (MonadError PrettyString m, MonadIO m, MonadName m) => String -> m [Expr]
typecheckTestFile filename =
  do initialState <- initialRenamerState
     Stage.typecheckFile filename initialState initialTypecheckerContext

testTypechecker :: Bool -> IO ()
testTypechecker generateTestExpectations =
  do -- TODO: The following test cases should be running the typechecker in check mode.
     expect "Test/TypeTestData1.typechecker" "Test/TypeTestData1.bsl"
     expect "Test/TypeTestData2.typechecker" "Test/TypeTestData2.bsl"
     expect "Test/TypeTestData3.typechecker" "Test/TypeTestData3.bsl"

     expect "Test/TestData1.typechecker" "Test/TestData1.bsl"
     expect "Test/TestData2.typechecker" "Test/TestData2.bsl"
     expect "Test/TestData3.typechecker" "Test/TestData3.bsl"
     -- Note that 'Test/TestData4.bsl' is not typecheckable because
     -- the main function accepts both Int and List.
     expect "Test/TestData5.typechecker" "Test/TestData5.bsl"
     expect "Test/TestData6.typechecker" "Test/TestData6.bsl"
     expect "Test/TestData7.typechecker" "Test/TestData7.bsl"
     expect "Test/Tuple.typechecker" "Test/Tuple.bsl"
     expect "Test/Unit.typechecker" "Test/Unit.bsl"
     expect "Test/Variant.typechecker" "Test/Variant.bsl"

  where
    expect expectedFilename filename =
      do result <- NameT.runNameT . runExceptT $ typecheckTestFile filename
         let actual = PrettyString.toString . PrettyString.vcat . map Pretty.docExpr <$> result
         Diff.expectFiles "Typechecker" filename generateTestExpectations expectedFilename actual
