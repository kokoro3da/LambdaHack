{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | High score table operations.
module Game.LambdaHack.Common.HighScore
  ( ScoreTable, empty, register, highSlideshow
  ) where

import Data.Binary
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU
import System.Time
import Text.Printf

import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Time

-- | A single score record. Records are ordered in the highscore table,
-- from the best to the worst, in lexicographic ordering wrt the fields below.
data ScoreRecord = ScoreRecord
  { points     :: !Int        -- ^ the score
  , negTime    :: !Time       -- ^ game time spent (negated, so less better)
  , date       :: !ClockTime  -- ^ date of the last game interruption
  , status     :: !Status     -- ^ reason of the game interruption
  , difficulty :: !Int        -- ^ difficulty of the game
  }
  deriving (Eq, Ord)

-- TODO: move all to Text
-- | Show a single high score, from the given ranking in the high score table.
showScore :: (Int, ScoreRecord) -> [Text]
showScore (pos, score) =
  let Status{stOutcome, stDepth} = status score
      died = case stOutcome of
        Killed   -> "Perished on level " ++ show (abs stDepth)
        Defeated -> "Was defeated"
        Camping  -> "Camps somewhere"
        Conquer  -> "Slew all opposition"
        Escape   -> "Emerged victorious"
        Restart  -> "Resigned prematurely"
      curDate = calendarTimeToString . toUTCTime . date $ score
      turns = - (negTime score `timeFit` timeTurn)
      diff = 5 - difficulty score
      diffText :: String
      diffText | diff == 5 = ""
               | otherwise = printf " (difficulty %d)" diff
     -- TODO: the spaces at the end are hand-crafted. Remove when display
     -- of overlays adds such spaces automatically.
  in map T.pack
       [ ""
       , printf "%4d. %6d  %s%s"
                pos (points score) died diffText
       , "              " ++ printf "after %d turns on %s." turns curDate
       ]

-- | The list of scores, in decreasing order.
newtype ScoreTable = ScoreTable [ScoreRecord]
  deriving (Eq, Binary)

instance Show ScoreTable where
  show _ = "a score table"

-- | Empty score table
empty :: ScoreTable
empty = ScoreTable []

-- | Insert a new score into the table, Return new table and the ranking.
-- Make sure the table doesn't grow too large.
insertPos :: ScoreRecord -> ScoreTable -> (ScoreTable, Int)
insertPos s (ScoreTable table) =
  let (prefix, suffix) = span (> s) table
      pos = length prefix + 1
  in (ScoreTable $ prefix ++ [s] ++ take (100 - pos) suffix, pos)

-- | Register a new score in a score table.
register :: ScoreTable  -- ^ old table
         -> Int         -- ^ the total score. not halved yet
         -> Time        -- ^ game time spent
         -> Status      -- ^ reason of the game interruption
         -> ClockTime   -- ^ current date
         -> Int         -- ^ difficulty level
         -> Maybe (ScoreTable, Int)
register table total time status@Status{stOutcome} date difficulty =
  let pUnscaled = if stOutcome `elem` [Killed, Defeated, Restart]
                  then (total + 1) `div` 2
                  else if stOutcome == Conquer
                       then let turnsSpent = timeFit time timeTurn
                                speedup = 10000 - 5 * turnsSpent
                                bonus = sqrt $ fromIntegral speedup :: Double
                            in 10 + floor bonus
                       else total
      points = (round :: Double -> Int)
               $ fromIntegral pUnscaled * 1.5 ^^ difficulty
      negTime = timeNegate time
      score = ScoreRecord{..}
  in if points > 0 then Just $ insertPos score table else Nothing

-- | Show a screenful of the high scores table.
-- Parameter height is the number of (3-line) scores to be shown.
tshowable :: ScoreTable -> Int -> Int -> [Text]
tshowable (ScoreTable table) start height =
  let zipped    = zip [1..] table
      screenful = take height . drop (start - 1) $ zipped
  in concatMap showScore screenful ++ [moreMsg]

-- | Produce a couple of renderings of the high scores table.
showCloseScores :: Int -> ScoreTable -> Int -> [[Text]]
showCloseScores pos h height =
  if pos <= height
  then [tshowable h 1 height]
  else [tshowable h 1 height,
        tshowable h (max (height + 1) (pos - height `div` 2)) height]

-- | Generate a slideshow with the current and previous scores.
highSlideshow :: ScoreTable -- ^ current score table
              -> Int        -- ^ position of the current score in the table
              -> Status     -- ^ reason of the game interruption
              -> Slideshow
highSlideshow table pos status =
  let (_, nlines) = normalLevelBound  -- TODO: query terminal size instead
      height = nlines `div` 3
      (subject, person, msgUnless) =
        case stOutcome status of
          Killed | stDepth status <= 1 ->
            ("your short-lived struggle", MU.Sg3rd, "(score halved)")
          Killed ->
            ("your heroic deeds", MU.PlEtc, "(score halved)")
          Defeated ->
            ("your futile efforts", MU.PlEtc, "(score halved)")
          Camping ->
            ("your valiant exploits", MU.PlEtc, "(unless you are slain)")
          Conquer ->
            ("your ruthless victory", MU.Sg3rd,
             if pos <= height
             then "among the greatest heroes"
             else "(score based on time)")
          Escape ->
            ("your dashing coup", MU.Sg3rd,
             if pos <= height
             then "among the greatest heroes"
             else "")
          Restart ->
            ("your abortive attempt", MU.Sg3rd, "(score halved)")
      msg = makeSentence
        [ MU.SubjectVerb person MU.Yes subject "award you"
        , MU.Ordinal pos, "place"
        , msgUnless ]
  in toSlideshow True $ map ([msg] ++) $ showCloseScores pos table height

instance Binary ScoreRecord where
  put (ScoreRecord p n (TOD cs cp) s difficulty) = do
    put p
    put n
    put cs
    put cp
    put s
    put difficulty
  get = do
    p <- get
    n <- get
    cs <- get
    cp <- get
    s <- get
    difficulty <- get
    return $! ScoreRecord p n (TOD cs cp) s difficulty
