-- | Screen frames and animations.
module Game.LambdaHack.Animation
  ( Attr(..), defaultAttr, AttrChar(..)
  , SingleFrame(..), Animation, rederAnim
  , twirlSplash, blockHit, blockMiss, deathBody, swapPlaces
  ) where

import qualified Data.IntMap as IM
import Data.Maybe
import qualified Data.List as L
import Data.Monoid
import Data.Text (Text)

import Game.LambdaHack.PointXY
import Game.LambdaHack.Point
import Game.LambdaHack.Color

-- | The data sufficent to draw a single game screen frame.
data SingleFrame = SingleFrame
  { sfLevel  :: ![[AttrChar]]  -- ^ content of the screen, line by line
  , sfTop    :: Text           -- ^ an extra line to show at the top
  , sfBottom :: Text           -- ^ an extra line to show at the bottom
  }
  deriving Eq

-- | Animation is a list of frame modifications to play one by one,
-- where each modification if a map from locations to level map symbols.
newtype Animation = Animation [IM.IntMap AttrChar]

instance Monoid Animation where
  mempty = Animation []
  mappend (Animation a1) (Animation a2) = Animation (a1 ++ a2)

-- | Render animations on top of a screen frame.
rederAnim :: X -> Y -> SingleFrame -> Animation
          -> [Maybe SingleFrame]
rederAnim lxsize lysize basicFrame (Animation anim) =
  let modifyFrame SingleFrame{sfLevel = levelOld, ..} am =
        let fLine y lineOld =
              let f l (x, acOld) =
                    let loc = toPoint lxsize (PointXY (x, y))
                        !ac = fromMaybe acOld $ IM.lookup loc am
                    in ac : l
              in L.foldl' f [] (zip [lxsize-1,lxsize-2..0] (reverse lineOld))
            sfLevel =  -- Fully evaluated.
              let f l (y, lineOld) = let !line = fLine y lineOld in line : l
              in L.foldl' f [] (zip [lysize-1,lysize-2..0] (reverse levelOld))
        in Just SingleFrame{..}
  in map (modifyFrame basicFrame) anim

blank :: Maybe AttrChar
blank = Nothing

coloredSymbol :: Color -> Char -> Maybe AttrChar
coloredSymbol color symbol = Just $ AttrChar (Attr color defBG) symbol

mzipPairs :: (Maybe Point, Maybe Point) -> (Maybe AttrChar, Maybe AttrChar)
          -> [(Point, AttrChar)]
mzipPairs (mloc1, mloc2) (mattr1, mattr2) =
  let mzip (Just loc, Just attr) = Just (loc, attr)
      mzip _ = Nothing
  in if mloc1 /= mloc2
     then catMaybes [mzip (mloc1, mattr1), mzip (mloc2, mattr2)]
     else -- If actor affects himself, show only the effect, not the action.
          catMaybes [mzip (mloc1, mattr1)]

-- | Attack animation. A part of it also reused for self-damage and healing.
twirlSplash :: (Maybe Point, Maybe Point) -> Color -> Color -> Animation
twirlSplash locs c1 c2 = Animation $ map (IM.fromList . mzipPairs locs)
  [ (coloredSymbol BrWhite '*', blank)
  , (coloredSymbol c1      '/', coloredSymbol BrCyan '^')
  , (coloredSymbol c1      '-', blank)
  , (coloredSymbol c1      '\\',blank)
  , (coloredSymbol c1      '|', blank)
  , (coloredSymbol c2      '/', blank)
  , (coloredSymbol c2      '%', coloredSymbol BrCyan '^')
  , (coloredSymbol c2      '%', blank)
  , (blank                    , blank)
  ]

-- | Attack that hits through a block.
blockHit :: (Maybe Point, Maybe Point) -> Color -> Color -> Animation
blockHit locs c1 c2 = Animation $ map (IM.fromList . mzipPairs locs)
  [ (coloredSymbol BrWhite '*', blank)
  , (coloredSymbol BrBlue  '{', coloredSymbol BrCyan '^')
  , (coloredSymbol BrBlue  '{', blank)
  , (coloredSymbol c1      '}', blank)
  , (coloredSymbol c1      '}', coloredSymbol BrCyan '^')
  , (coloredSymbol c2      '/', blank)
  , (coloredSymbol c2      '%', blank)
  , (coloredSymbol c2      '%', blank)
  , (blank                    , blank)
  ]

-- | Attack that is blocked.
blockMiss :: (Maybe Point, Maybe Point) -> Animation
blockMiss locs = Animation $ map (IM.fromList . mzipPairs locs)
  [ (coloredSymbol BrWhite '*', blank)
  , (coloredSymbol BrBlue  '{', coloredSymbol BrCyan '^')
  , (coloredSymbol BrBlue  '}', blank)
  , (coloredSymbol BrBlue  '}', blank)
  , (blank                    , blank)
  ]

-- | Death animation for an organic body.
deathBody :: Point -> Animation
deathBody loc = Animation $ map (maybe IM.empty (IM.singleton loc))
  [ coloredSymbol BrRed '\\'
  , coloredSymbol BrRed '\\'
  , coloredSymbol BrRed '|'
  , coloredSymbol BrRed '|'
  , coloredSymbol BrRed '%'
  , coloredSymbol BrRed '%'
  , coloredSymbol Red   '%'
  , coloredSymbol Red   '%'
  , coloredSymbol Red   ';'
  , coloredSymbol Red   ';'
  , coloredSymbol Red   ','
  ]

-- | Swap-places animation, both hostile and friendly.
swapPlaces :: (Maybe Point, Maybe Point) -> Animation
swapPlaces locs = Animation $ map (IM.fromList . mzipPairs locs)
  [ (coloredSymbol BrMagenta '.', coloredSymbol Magenta   'o')
  , (coloredSymbol BrMagenta 'd', coloredSymbol Magenta   'p')
  , (coloredSymbol Magenta   'p', coloredSymbol BrMagenta 'd')
  , (coloredSymbol Magenta   'o', blank)
  ]