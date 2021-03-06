{-# LANGUAGE DeriveFunctor, DeriveGeneric #-}
-- | Effects of content on other content. No operation in this module
-- involves the 'State' or 'Action' type.
module Game.LambdaHack.Common.Effect
  ( Effect(..), effectTrav, effectToSuffix
  ) where

import Control.Exception.Assert.Sugar
import qualified Control.Monad.State as St
import Data.Binary
import qualified Data.Hashable as Hashable
import Data.Text (Text)
import GHC.Generics (Generic)

import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Random

-- TODO: document each constructor
-- Effects of items, tiles, etc. The type argument represents power.
-- either as a random formula dependent on level, or as a final rolled value.
data Effect a =
    NoEffect
  | Heal !Int
  | Hurt !RollDice !a
  | Mindprobe Int    -- the @Int@ is a lazy hack to send the result to clients
  | Dominate
  | CallFriend !Int
  | Summon !Int
  | CreateItem !Int
  | ApplyPerfume
  | Regeneration !a
  | Searching !a
  | Ascend !Int
  | Escape !Int
  deriving (Show, Read, Eq, Ord, Generic, Functor)

instance Hashable.Hashable a => Hashable.Hashable (Effect a)

instance Binary a => Binary (Effect a)

-- TODO: Traversable?
-- | Transform an effect using a stateful function.
effectTrav :: Effect a -> (a -> St.State s b) -> St.State s (Effect b)
effectTrav NoEffect _ = return NoEffect
effectTrav (Heal p) _ = return $! Heal p
effectTrav (Hurt dice a) f = do
  b <- f a
  return $! Hurt dice b
effectTrav (Mindprobe x) _ = return $! Mindprobe x
effectTrav Dominate _ = return Dominate
effectTrav (CallFriend p) _ = return $! CallFriend p
effectTrav (Summon p) _ = return $! Summon p
effectTrav (CreateItem p) _ = return $! CreateItem p
effectTrav ApplyPerfume _ = return ApplyPerfume
effectTrav (Regeneration a) f = do
  b <- f a
  return $! Regeneration b
effectTrav (Searching a) f = do
  b <- f a
  return $! Searching b
effectTrav (Ascend p) _ = return $! Ascend p
effectTrav (Escape p) _ = return $! Escape p

-- | Suffix to append to a basic content name if the content causes the effect.
effectToSuff :: Show a => Effect a -> (a -> Text) -> Text
effectToSuff effect f =
  case St.evalState (effectTrav effect $ return . f) () of
    NoEffect -> ""
    Heal p | p > 0 -> "of healing" <> affixBonus p
    Heal 0 -> "of bloodletting"
    Heal p -> "of wounding" <> affixBonus p
    Hurt dice t -> "(" <> tshow dice <> ")" <> t
    Mindprobe{} -> "of soul searching"
    Dominate -> "of domination"
    CallFriend p -> "of aid calling" <> affixPower p
    Summon p -> "of summoning" <> affixPower p
    CreateItem p -> "of item creation" <> affixPower p
    ApplyPerfume -> "of rose water"
    Regeneration t -> "of regeneration" <> t
    Searching t -> "of searching" <> t
    Ascend p | p > 0 -> "of ascending" <> affixPower p
    Ascend p | p < 0 -> "of descending" <> affixPower (- p)
    Ascend{} -> assert `failure` effect
    Escape{} -> "of escaping"

effectToSuffix :: Effect Int -> Text
effectToSuffix effect = effectToSuff effect affixBonus

affixPower :: Int -> Text
affixPower p = case compare p 1 of
  EQ -> ""
  LT -> assert `failure` "power less than 1" `twith` p
  GT -> " (+" <> tshow p <> ")"

affixBonus :: Int -> Text
affixBonus p = case compare p 0 of
  EQ -> ""
  LT -> " (" <> tshow p <> ")"
  GT -> " (+" <> tshow p <> ")"
