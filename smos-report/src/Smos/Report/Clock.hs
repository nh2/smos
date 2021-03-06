{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Report.Clock
    ( module Smos.Report.Clock
    , module Smos.Report.Clock.Types
    ) where

import Cursor.Simple.Forest
import Cursor.Simple.Tree
import Data.Function
import Data.List
import qualified Data.List.NonEmpty as NE
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe
import qualified Data.Set as S
import Data.Set (Set)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Time
import Data.Time.Calendar.WeekDate
import Data.Validity
import Data.Validity.Path ()
import Lens.Micro

import Smos.Data

import Smos.Report.Clock.Types
import Smos.Report.Path
import Smos.Report.Period
import Smos.Report.Query
import Smos.Report.Streaming
import Smos.Report.TimeBlock

-- | Reset the timers of every entry that doesn't match the filter to zero
zeroOutByFilter :: Filter -> RootedPath -> SmosFile -> SmosFile
zeroOutByFilter f rp sf =
    let cursors = forestCursors $ smosFileForest sf
     in SmosFile $ map (fmap go) cursors
  where
    go :: ForestCursor Entry -> Entry
    go fc =
        (if filterPredicate f rp fc
             then id
             else zeroOutEntry) $
        (fc ^. (forestCursorSelectedTreeL . treeCursorCurrentL))

zeroOutEntry :: Entry -> Entry
zeroOutEntry e = e {entryLogbook = emptyLogbook}

findFileTimes :: UTCTime -> RootedPath -> SmosFile -> Maybe FileTimes
findFileTimes now rp (SmosFile ts) = do
    ne <- goF ts
    pure $ FileTimes {clockTimeFile = rp, clockTimeForest = ne}
  where
    goF :: Forest Entry -> Maybe (TForest HeaderTimes)
    goF = NE.nonEmpty . mapMaybe goT
    goT :: Tree Entry -> Maybe (TTree HeaderTimes)
    goT (Node e ts_) =
        case goF ts_ of
            Nothing -> do
                hts <- headerTimesNonEmpty $ findHeaderTimes now e
                pure $ TLeaf hts
            Just f -> pure $ TBranch (findHeaderTimes now e) f

findHeaderTimes :: UTCTime -> Entry -> HeaderTimes []
findHeaderTimes now Entry {..} =
    case entryLogbook of
        LogOpen s es ->
            (ht $
             (LogbookEntry {logbookEntryStart = s, logbookEntryEnd = now}) : es)
        LogClosed es -> ht es
  where
    ht es =
        HeaderTimes {headerTimesHeader = entryHeader, headerTimesEntries = es}

headerTimesList :: HeaderTimes NonEmpty -> HeaderTimes []
headerTimesList hts =
    HeaderTimes
        { headerTimesHeader = headerTimesHeader hts
        , headerTimesEntries = NE.toList $ headerTimesEntries hts
        }

headerTimesNonEmpty :: HeaderTimes [] -> Maybe (HeaderTimes NonEmpty)
headerTimesNonEmpty hts = do
    ne <- NE.nonEmpty $ headerTimesEntries hts
    pure $
        HeaderTimes
            {headerTimesHeader = headerTimesHeader hts, headerTimesEntries = ne}

trimHeaderTimes :: ZonedTime -> Period -> HeaderTimes [] -> HeaderTimes []
trimHeaderTimes zt cp ht =
    let es' = mapMaybe (trimLogbookEntry zt cp) $ headerTimesEntries ht
     in ht {headerTimesEntries = es'}

trimLogbookEntry :: ZonedTime -> Period -> LogbookEntry -> Maybe LogbookEntry
trimLogbookEntry now cp =
    case cp of
        AllTime -> pure
        Today -> trimToToday
        LastWeek -> trimToLastWeek
        ThisWeek -> trimToThisWeek
  where
    tz :: TimeZone
    tz = zonedTimeZone now
    nowLocal :: LocalTime
    nowLocal = zonedTimeToLocalTime now
    today :: Day
    today = localDay nowLocal
    trimToToday :: LogbookEntry -> Maybe LogbookEntry
    trimToToday = trimLogbookEntryToDay tz today
    lastWeekStart :: LocalTime
    lastWeekStart =
        let (y, wn, _) = toWeekDate today
         in LocalTime (fromWeekDate y (wn - 1) 1) midnight -- FIXME this will go wrong at the start of the year
    thisWeekStart :: LocalTime
    thisWeekStart =
        let (y, wn, _) = toWeekDate today
         in LocalTime (fromWeekDate y wn 1) midnight
    thisWeekEnd :: LocalTime
    thisWeekEnd =
        let (y, wn, _) = toWeekDate today
         in LocalTime (fromWeekDate y (wn + 1) 1) midnight -- FIXME this can wrong at the end of the year
    trimToThisWeek :: LogbookEntry -> Maybe LogbookEntry
    trimToThisWeek = trimLogbookEntryTo tz thisWeekStart thisWeekEnd
    trimToLastWeek :: LogbookEntry -> Maybe LogbookEntry
    trimToLastWeek = trimLogbookEntryTo tz lastWeekStart thisWeekStart

trimLogbookEntryToDay :: TimeZone -> Day -> LogbookEntry -> Maybe LogbookEntry
trimLogbookEntryToDay tz d = trimLogbookEntryTo tz dayStart dayEnd
  where
    dayStart = LocalTime d midnight
    dayEnd = LocalTime (addDays 1 d) midnight

trimLogbookEntryTo ::
       TimeZone -> LocalTime -> LocalTime -> LogbookEntry -> Maybe LogbookEntry
trimLogbookEntryTo tz begin end LogbookEntry {..} =
    constructValid $
    LogbookEntry
        { logbookEntryStart =
              if toLocal logbookEntryStart >= begin
                  then logbookEntryStart
                  else fromLocal begin
        , logbookEntryEnd =
              if toLocal logbookEntryEnd < end
                  then logbookEntryEnd
                  else fromLocal end
        }
  where
    toLocal :: UTCTime -> LocalTime
    toLocal = utcToLocalTime tz
    fromLocal :: LocalTime -> UTCTime
    fromLocal = localTimeToUTC tz

divideIntoClockTimeBlocks ::
       TimeZone -> TimeBlock -> [FileTimes] -> [ClockTimeBlock Text]
divideIntoClockTimeBlocks tz cb cts =
    case cb of
        OneBlock -> [Block {blockTitle = "All Time", blockEntries = cts}]
        DayBlock ->
            map (mapBlockTitle formatDayTitle) $
            combineBlocksByName $
            concatMap (divideClockTimeIntoDailyBlocks tz) cts
  where
    formatDayTitle :: Day -> Text
    formatDayTitle = T.pack . formatTime defaultTimeLocale "%F (%A)"

divideClockTimeIntoDailyBlocks :: TimeZone -> FileTimes -> [ClockTimeBlock Day]
divideClockTimeIntoDailyBlocks tz =
    map (uncurry makeClockTimeBlock) . sortAndGroupCombineOrd . divideFileTimes
  where
    makeClockTimeBlock :: a -> [FileTimes] -> ClockTimeBlock a
    makeClockTimeBlock n cts = Block {blockTitle = n, blockEntries = cts}
    divideFileTimes :: FileTimes -> [(Day, FileTimes)]
    divideFileTimes fts =
        mapMaybe
            (\d -> (,) d <$> trimFileTimesToDay tz d fts)
            (S.toList $ fileTimesDays fts)
    fileTimesDays :: FileTimes -> Set Day
    fileTimesDays = goTF . clockTimeForest
      where
        goTF :: TForest HeaderTimes -> Set Day
        goTF = S.unions . map goTT . NE.toList
        goTT :: TTree HeaderTimes -> Set Day
        goTT (TLeaf hts) = goHT $ headerTimesList hts
        goTT (TBranch hts tf) = goHT hts `S.union` goTF tf
        goHT :: HeaderTimes [] -> Set Day
        goHT = S.unions . map logbookEntryDays . headerTimesEntries
        logbookEntryDays :: LogbookEntry -> Set Day
        logbookEntryDays LogbookEntry {..} =
            S.fromList [utcDay logbookEntryStart .. utcDay logbookEntryEnd]
        utcDay :: UTCTime -> Day
        utcDay = localDay . toLocal
    toLocal :: UTCTime -> LocalTime
    toLocal = utcToLocalTime tz

trimFileTimesToDay :: TimeZone -> Day -> FileTimes -> Maybe FileTimes
trimFileTimesToDay tz d fts =
    (\f -> fts {clockTimeForest = f}) <$> goTF (clockTimeForest fts)
  where
    goTF :: TForest HeaderTimes -> Maybe (TForest HeaderTimes)
    goTF ts = do
        let ts' = mapMaybe goTT $ NE.toList ts
        NE.nonEmpty ts'
    goTT :: TTree HeaderTimes -> Maybe (TTree HeaderTimes)
    goTT (TLeaf hts) = do
        hts' <- headerTimesNonEmpty $ goHT $ headerTimesList hts
        pure $ TLeaf hts'
    goTT (TBranch hts tf) = case goTF tf of
        Nothing -> TLeaf <$> (headerTimesNonEmpty $ goHT hts)
        Just f -> pure $ TBranch (goHT hts) f
    goHT :: HeaderTimes [] -> HeaderTimes []
    goHT hts =
        hts
            { headerTimesEntries =
                  mapMaybe (trimLogbookEntryToDay tz d) (headerTimesEntries hts)
            }

sortAndGroupCombineOrd :: Ord a => [(a, b)] -> [(a, [b])]
sortAndGroupCombineOrd = sortGroupCombine compare

sortGroupCombine :: (a -> a -> Ordering) -> [(a, b)] -> [(a, [b])]
sortGroupCombine func =
    map combine .
    groupBy ((\a1 a2 -> func a1 a2 == EQ) `on` fst) . sortBy (func `on` fst)
  where
    combine [] = error "cannot happen due to groupBy above"
    combine ts@((a, _):_) = (a, map snd ts)

makeClockTable :: [ClockTimeBlock Text] -> ClockTable
makeClockTable = map makeClockTableBlock

makeClockTableBlock :: ClockTimeBlock Text -> ClockTableBlock
makeClockTableBlock Block {..} =
    Block
        { blockTitle = blockTitle
        , blockEntries = map makeClockTableFile blockEntries
        }

makeClockTableFile :: FileTimes -> ClockTableFile
makeClockTableFile FileTimes {..} =
    ClockTableFile
        { clockTableFile = clockTimeFile
        , clockTableForest = unTForest clockTimeForest
        }

unTForest :: TForest HeaderTimes -> Forest ClockTableHeaderEntry
unTForest = map unTTree . NE.toList

unTTree :: TTree HeaderTimes -> Tree ClockTableHeaderEntry
unTTree (TLeaf hts) = Node (makeClockTableHeaderEntry $ headerTimesList hts) []
unTTree (TBranch hts tf) = Node (makeClockTableHeaderEntry hts) (unTForest tf)

makeClockTableHeaderEntry :: HeaderTimes [] -> ClockTableHeaderEntry
makeClockTableHeaderEntry HeaderTimes {..} =
    ClockTableHeaderEntry
        { clockTableHeaderEntryHeader = headerTimesHeader
        , clockTableHeaderEntryTime = sumLogbookEntryTime $ headerTimesEntries
        }

sumLogbookEntryTime :: [LogbookEntry] -> NominalDiffTime
sumLogbookEntryTime = sum . map go
  where
    go :: LogbookEntry -> NominalDiffTime
    go LogbookEntry {..} = diffUTCTime logbookEntryEnd logbookEntryStart

trimFileTimes :: ZonedTime -> Period -> FileTimes -> Maybe FileTimes
trimFileTimes zt cp fts = do
    f <- goF $ clockTimeForest fts
    pure $ fts {clockTimeForest = f}
  where
    goF :: TForest HeaderTimes -> Maybe (TForest HeaderTimes)
    goF tf = NE.nonEmpty $ mapMaybe goT $ NE.toList tf
    goT :: TTree HeaderTimes -> Maybe (TTree HeaderTimes)
    goT (TLeaf hts) =
        TLeaf <$>
        (headerTimesNonEmpty $ trimHeaderTimes zt cp (headerTimesList hts))
    goT (TBranch hts tf) =
        case goF tf of
            Nothing ->
                TLeaf <$> (headerTimesNonEmpty $ trimHeaderTimes zt cp hts)
            Just f -> pure $ TBranch (trimHeaderTimes zt cp hts) f
