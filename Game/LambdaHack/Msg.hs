-- | Game messages displayed on top of the screen for the player to read.
module Game.LambdaHack.Msg
  ( Msg, more, msgEnd, yesno, addMsg, splitMsg, padMsg
  ) where

import qualified Data.List as L
import Data.Char

-- | The type of messages.
type Msg = String

-- | The \"press something to see more\" mark.
more :: Msg
more = " --more--  "

-- | The \"the end of overlays or messages\" mark.
msgEnd :: Msg
msgEnd = " --end--  "

-- | The confirmation request message.
yesno :: Msg
yesno = " [yn]"

-- | Append two messages.
addMsg :: Msg -> Msg -> Msg
addMsg [] x  = x
addMsg xs [] = xs
addMsg xs x  = xs ++ " " ++ x

-- | Split a message into chunks that fit in one line.
splitMsg :: Int -> Msg -> Int -> [String]
splitMsg w xs m
  | w <= m = [xs]   -- border case, we cannot make progress
  | w >= length xs = [xs]   -- no problem, everything fits
  | otherwise =
      let (pre, post) = splitAt (w - m) xs
          (ppre, ppost) = break (`elem` " .,:;!?") $ reverse pre
          rpost = dropWhile isSpace ppost
      in if L.null rpost
         then pre : splitMsg w post m
         else reverse rpost : splitMsg w (reverse ppre ++ post) m

-- | Add spaces at the message end, for display overlayed over the level map.
padMsg :: Int -> String -> String
padMsg w xs =
  case L.reverse xs of
    [] -> xs
    ' ' : _ -> xs
    _ | w == length xs -> xs
    reversed -> L.reverse $ ' ' : reversed