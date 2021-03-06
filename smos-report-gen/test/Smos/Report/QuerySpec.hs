{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}

module Smos.Report.QuerySpec where

import Data.Text (Text)

import Test.Hspec
import Test.Validity

import Text.Megaparsec

import Smos.Report.Query
import Smos.Report.Query.Gen ()

spec :: Spec
spec = do
    eqSpec @Filter
    genValidSpec @Filter
    describe "filterP" $ do
        parsesValidSpec filterP
        parseJustSpec filterP "tag:work" (FilterHasTag "work")
        parseJustSpec filterP "state:NEXT" (FilterTodoState "NEXT")
    describe "filterHasTagP" $ parsesValidSpec filterHasTagP
    describe "filterTodoStateP" $ parsesValidSpec filterTodoStateP
    describe "filterParentP" $ parsesValidSpec filterParentP
    describe "filterAncestorP" $ parsesValidSpec filterAncestorP
    describe "filterNotP" $ parsesValidSpec filterNotP
    describe "filterBinrelP" $ parsesValidSpec filterBinRelP
    describe "filterOrP" $ parsesValidSpec filterOrP
    describe "filterAndP" $ parsesValidSpec filterAndP
    describe "renderFilter" $ do
        it "produces valid texts" $ producesValidsOnValids renderFilter
        it "renders filters that parse to the same" $
            forAllValid $ \f -> parseJust filterP (renderFilter f) f

parseJustSpec :: (Show a, Eq a) => P a -> Text -> a -> Spec
parseJustSpec p s res =
    it (unwords ["parses", show s, "as", show res]) $ parseJust p s res

parseNothingSpec :: (Show a, Eq a) => P a -> Text -> Spec
parseNothingSpec p s =
    it (unwords ["fails to parse", show s]) $ parseNothing p s

parsesValidSpec :: (Show a, Eq a, Validity a) => P a -> Spec
parsesValidSpec p = it "only parses valid values" $ forAllValid $ parsesValid p

parseJust :: (Show a, Eq a) => P a -> Text -> a -> Expectation
parseJust p s res =
    case parse (p <* eof) "test input" s of
        Left err ->
            expectationFailure $
            unlines
                [ "P failed on input"
                , show s
                , "with error"
                , parseErrorPretty err
                ]
        Right out -> out `shouldBe` res

parseNothing :: (Show a, Eq a) => P a -> Text -> Expectation
parseNothing p s =
    case parse (p <* eof) "test input" s of
        Right v ->
            expectationFailure $
            unlines
                [ "P succeeded on input"
                , show s
                , "at parsing"
                , show v
                , "but it should have failed."
                ]
        Left _ -> pure ()

parsesValid :: (Show a, Eq a, Validity a) => P a -> Text -> Expectation
parsesValid p s =
    case parse (p <* eof) "test input" s of
        Left _ -> pure ()
        Right out -> shouldBeValid out
