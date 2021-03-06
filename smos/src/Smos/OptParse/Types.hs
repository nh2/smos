{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

module Smos.OptParse.Types where

import Import

import qualified Data.Text as T
import Data.Yaml as Yaml
import Text.Read

import Graphics.Vty.Input.Events

import qualified Smos.Report.OptParse.Types as Report

import Smos.Types

data Arguments =
    Arguments FilePath
              Flags

data Flags = Flags
    { flagConfigFile :: !(Maybe FilePath)
    , flagReportFlags :: !Report.Flags
    } deriving (Show, Eq)

data Environment = Environment
    { envConfigFile :: !(Maybe FilePath)
    , envReportEnv :: !Report.Environment
    } deriving (Show, Eq)

data Configuration = Configuration
    { confReportConf :: !Report.Configuration
    , confKeybindingsConf :: !(Maybe KeybindingsConfiguration)
    } deriving (Show, Eq, Generic)

instance Validity Configuration

instance FromJSON Configuration where
    parseJSON v =
        flip (withObject "Configuration") v $ \o ->
            Configuration <$> parseJSON v <*> o .:? "keys"

data KeybindingsConfiguration = KeybindingsConfiguration
    { confReset :: !(Maybe Bool)
    , confFileKeyConfig :: !(Maybe FileKeyConfigs)
    , confReportsKeyConfig :: !(Maybe ReportsKeyConfigs)
    , confHelpKeyConfig :: !(Maybe KeyConfigs)
    } deriving (Show, Eq, Generic)

instance Validity KeybindingsConfiguration

instance FromJSON KeybindingsConfiguration where
    parseJSON =
        withObject "KeybindingsConfiguration" $ \o ->
            KeybindingsConfiguration <$> o .:? "reset" <*> o .:? "file" <*>
            o .:? "reports" <*>
            o .:? "help"

data FileKeyConfigs = FileKeyConfigs
    { emptyKeyConfigs :: !(Maybe KeyConfigs)
    , entryKeyConfigs :: !(Maybe KeyConfigs)
    , headerKeyConfigs :: !(Maybe KeyConfigs)
    , contentsKeyConfigs :: !(Maybe KeyConfigs)
    , timestampsKeyConfigs :: !(Maybe KeyConfigs)
    , propertiesKeyConfigs :: !(Maybe KeyConfigs)
    , stateHistoryKeyConfigs :: !(Maybe KeyConfigs)
    , tagsKeyConfigs :: !(Maybe KeyConfigs)
    , logbookKeyConfigs :: !(Maybe KeyConfigs)
    , anyKeyConfigs :: !(Maybe KeyConfigs)
    } deriving (Show, Eq, Generic)

instance Validity FileKeyConfigs

instance FromJSON FileKeyConfigs where
    parseJSON =
        withObject "FileKeyConfigs" $ \o ->
            FileKeyConfigs <$> o .:? "empty" <*> o .:? "entry" <*>
            o .:? "header" <*>
            o .:? "contents" <*>
            o .:? "timestamps" <*>
            o .:? "properties" <*>
            o .:? "state-history" <*>
            o .:? "tags" <*>
            o .:? "logbook" <*>
            o .:? "any"

data ReportsKeyConfigs = ReportsKeyConfigs
    { nextActionReportKeyConfigs :: !(Maybe KeyConfigs)
    } deriving (Show, Eq, Generic)

instance Validity ReportsKeyConfigs

instance FromJSON ReportsKeyConfigs where
    parseJSON =
        withObject "ReportsKeyConfigs" $ \o ->
            ReportsKeyConfigs <$> o .:? "next-action"

newtype KeyConfigs = KeyConfigs
    { keyConfigs :: [KeyConfig]
    } deriving (Show, Eq, Generic, FromJSON)

instance Validity KeyConfigs

data KeyConfig = KeyConfig
    { keyConfigMatcher :: !MatcherConfig
    , keyConfigAction :: !ActionName
    } deriving (Show, Eq, Generic)

instance Validity KeyConfig

instance FromJSON KeyConfig where
    parseJSON =
        withObject "KeyConfig" $ \o ->
            KeyConfig <$> o .: "key" <*> o .: "action"

data MatcherConfig
    = MatchConfKeyPress !KeyPress
    | MatchConfAnyChar
    | MatchConfCatchAll
    | MatchConfCombination !KeyPress
                           !MatcherConfig
    deriving (Show, Eq, Generic)

instance Validity MatcherConfig

-- TODO this doesn't actually work if you want to use the key-combo: 'c'+'h'+'a'+'r'
-- It also doesn't work with 'c' + <anychar> yet.
instance FromJSON MatcherConfig where
    parseJSON =
        withText "MatcherConfig" $ \t ->
            case T.unpack t of
                [c] -> pure $ MatchConfKeyPress (KeyPress (KChar c) [])
                "Escape" -> pure $ MatchConfKeyPress (KeyPress KEsc [])
                "char" -> pure MatchConfAnyChar
                [] -> pure MatchConfCatchAll
                s@(c:cs) ->
                    case readMaybe ('K' : s) of
                        Nothing ->
                            pure $
                            foldl
                                (\cc_ c_ ->
                                     MatchConfCombination
                                         (KeyPress (KChar c_) [])
                                         cc_)
                                (MatchConfKeyPress $ KeyPress (KChar c) [])
                                cs
                        Just k -> pure $ MatchConfKeyPress (KeyPress k [])

data Instructions =
    Instructions (Path Abs File)
                 SmosConfig

data CombineError
    = ActionNotFound ActionName
    | ActionWrongType ActionName
    deriving (Show, Eq, Generic)

data Comb a
    = Combined a
    | CombErr [CombineError]
    deriving (Show, Eq, Generic)

instance Functor Comb where
    fmap f (Combined a) = Combined (f a)
    fmap _ (CombErr errs) = CombErr errs

instance Applicative Comb where
    pure = Combined
    cfa <*> ca =
        case (cfa, ca) of
            (Combined f, Combined a) -> Combined (f a)
            (CombErr err1, CombErr err2) -> CombErr $ err1 ++ err2
            (CombErr err1, _) -> CombErr err1
            (_, CombErr err2) -> CombErr err2
