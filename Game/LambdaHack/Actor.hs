-- | Actors in the game: monsters and heroes. No operation in this module
-- involves the 'State' or 'Action' type.
module Game.LambdaHack.Actor
  ( -- * Actor identifiers and related operations
    ActorId, invalidActorId
  , findHeroName, monsterGenChance
    -- * Party identifiers
  , PartyId, heroParty, monsterParty, neutralParty
    -- * The@ Acto@r type
  , Actor(..), template, addHp, unoccupied, heroKindId
    -- * Type of na actor target
  , Target(..)
  ) where

import Control.Monad
import Data.Binary
import Data.Maybe
import Data.Ratio

import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Misc
import Game.LambdaHack.Vector
import Game.LambdaHack.Point
import Game.LambdaHack.Content.ActorKind
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Random
import qualified Game.LambdaHack.Config as Config

newtype PartyId = PartyId Int
  deriving (Show, Eq)

heroParty, monsterParty, neutralParty :: PartyId
heroParty = PartyId 0
monsterParty = PartyId 1
neutralParty = PartyId 2

instance Binary PartyId where
  put (PartyId n) = put n
  get = fmap PartyId get

-- | Actor properties that are changing throughout the game.
-- If they are dublets of properties from @ActorKind@,
-- they are usually modified temporarily, but tend to return
-- to the original value from @ActorKind@ over time. E.g., HP.
data Actor = Actor
  { bkind   :: !(Kind.Id ActorKind)    -- ^ the kind of the actor
  , bsymbol :: !(Maybe Char)           -- ^ individual map symbol
  , bname   :: !(Maybe String)         -- ^ individual name
  , bhp     :: !Int                    -- ^ current hit points
  , bdir    :: !(Maybe (Vector, Int))  -- ^ direction and distance of running
  , btarget :: Target                  -- ^ target for ranged attacks and AI
  , bloc    :: !Point                  -- ^ current location
  , bletter :: !Char                   -- ^ next inventory letter
  , btime   :: !Time                   -- ^ time of next action
  , bparty  :: !PartyId                -- ^ to which party the actor belongs
  }
  deriving Show

instance Binary Actor where
  put (Actor ak an as ah ad at al ale ati pp) = do
    put ak
    put an
    put as
    put ah
    put ad
    put at
    put al
    put ale
    put ati
    put pp
  get = do
    ak  <- get
    an  <- get
    as  <- get
    ah  <- get
    ad  <- get
    at  <- get
    al  <- get
    ale <- get
    ati <- get
    pp  <- get
    return (Actor ak an as ah ad at al ale ati pp)

-- ActorId operations

-- | A unique identifier of an actor in a dungeon.
type ActorId = Int

-- | An actor that is not on any level.
invalidActorId :: ActorId
invalidActorId = -1

-- | Find a hero name in the config file, or create a stock name.
findHeroName :: Config.CP -> Int -> String
findHeroName config n =
  let heroName = Config.getOption config "heroes" ("HeroName_" ++ show n)
  in fromMaybe ("hero number " ++ show n) heroName

-- | Chance that a new monster is generated. Currently depends on the
-- number of monsters already present, and on the level. In the future,
-- the strength of the character and the strength of the monsters present
-- could further influence the chance, and the chance could also affect
-- which monster is generated. How many and which monsters are generated
-- will also depend on the cave kind used to build the level.
monsterGenChance :: Int -> Int -> Rnd Bool
monsterGenChance d numMonsters =
  chance $ 1%(fromIntegral (250 + 200 * (numMonsters - d)) `max` 50)

-- Actor operations

-- TODO: Setting the time of new monsters to 0 makes them able to
-- move immediately after generation. This does not seem like
-- a bad idea, but it would certainly be "more correct" to set
-- the time to the creation time instead.
-- | A template for a new actor. The initial target is invalid
-- to force a reset ASAP.
template :: Kind.Id ActorKind -> Maybe Char -> Maybe String -> Int -> Point
         -> PartyId -> Actor
template mk mc ms hp loc pp =
  let invalidTarget = TEnemy invalidActorId loc
  in Actor mk mc ms hp Nothing invalidTarget loc 'a' 0 pp

-- | Increment current hit points of an actor.
addHp :: Kind.Ops ActorKind -> Int -> Actor -> Actor
addHp Kind.Ops{okind} extra m =
  assert (extra >= 0 `blame` extra) $
  let maxHP = maxDice (ahp $ okind $ bkind m)
      currentHP = bhp m
  in if currentHP > maxHP
     then m
     else m {bhp = min maxHP (currentHP + extra)}

-- | Checks for the presence of actors in a location.
-- Does not check if the tile is walkable.
unoccupied :: [Actor] -> Point -> Bool
unoccupied actors loc =
  all (\ body -> bloc body /= loc) actors

-- | The unique kind of heroes.
heroKindId :: Kind.Ops ActorKind -> Kind.Id ActorKind
heroKindId Kind.Ops{ouniqGroup} = ouniqGroup "hero"

-- Target

-- | The type of na actor target.
data Target =
    TEnemy ActorId Point  -- ^ target an actor with its last seen location
  | TLoc Point            -- ^ target a given location
  | TCursor               -- ^ target current position of the cursor; default
  deriving (Show, Eq)

instance Binary Target where
  put (TEnemy a ll) = putWord8 0 >> put a >> put ll
  put (TLoc loc) = putWord8 1 >> put loc
  put TCursor    = putWord8 2
  get = do
    tag <- getWord8
    case tag of
      0 -> liftM2 TEnemy get get
      1 -> liftM TLoc get
      2 -> return TCursor
      _ -> fail "no parse (Target)"
