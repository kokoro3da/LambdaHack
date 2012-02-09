-- | Actors perceiving other actors and the dungeon level.
module Game.LambdaHack.Perception
  ( Perception, totalVisible, debugTotalReachable, perception
  , actorReachesLoc, actorReachesActor, monsterSeesHero
  ) where

import qualified Data.IntSet as IS
import qualified Data.List as L
import qualified Data.IntMap as IM
import Data.Maybe
import Control.Monad

import Game.LambdaHack.Point
import Game.LambdaHack.State
import Game.LambdaHack.Level
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.FOV
import qualified Game.LambdaHack.Config as Config
import qualified Game.LambdaHack.Tile as Tile
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Content.TileKind

newtype PerceptionReachable = PerceptionReachable
  { preachable :: IS.IntSet
  }

newtype PerceptionVisible = PerceptionVisible
  { pvisible :: IS.IntSet
  }

-- Note: Heroes share visibility and only have separate reachability.
-- The pplayer field must be void if the player is not on the current level.
-- Right now, the field is used only for player-controlled monsters.
-- | The type representing the perception of all actors on the level.
data Perception = Perception
  { pplayer :: Maybe PerceptionReachable
  , pheroes :: IM.IntMap PerceptionReachable
  , ptotal  :: PerceptionVisible
  }

-- | The set of tiles visible by at least one hero.
totalVisible :: Perception -> IS.IntSet
totalVisible = pvisible . ptotal

-- | For debug only: the set of tiles reachable
-- (would be visible if lit) by at least one hero.
debugTotalReachable :: Perception -> IS.IntSet
debugTotalReachable per =
  let lpers = maybeToList (pplayer per) ++ IM.elems (pheroes per)
  in IS.unions (map preachable lpers)

-- | Check whether a location is within the visually reachable area
-- of the given actor (disregarding lighting).
-- Defaults to false if the actor is not player-controlled (monster or hero).
actorReachesLoc :: ActorId -> Point -> Perception -> Maybe ActorId -> Bool
actorReachesLoc actor loc per pl =
  let tryHero = case actor of
                  AMonster _ -> Nothing
                  AHero i -> do
                    hper <- IM.lookup i (pheroes per)
                    return $ loc `IS.member` preachable hper
      tryPl   = do -- the case for a monster under player control
                   guard $ Just actor == pl
                   pper <- pplayer per
                   return $ loc `IS.member` preachable pper
      tryAny  = tryHero `mplus` tryPl
  in fromMaybe False tryAny  -- assume not visible, if no perception found

-- | Check whether an actor is within the visually reachable area
-- of the given actor (disregarding lighting).
-- Not quite correct if FOV not symmetric (e.g., @Shadow@).
-- Defaults to false if neither actor is player-controlled.
actorReachesActor :: ActorId -> ActorId -> Point -> Point
                  -> Perception -> Maybe ActorId
                  -> Bool
actorReachesActor actor1 actor2 loc1 loc2 per pl =
  actorReachesLoc actor1 loc2 per pl ||
  actorReachesLoc actor2 loc1 per pl

-- TODO: When the code for throwing, digital lines and lights is complete.
-- make this a special case of ActorSeesActor.
-- | Whether a monster can see a hero (@False@ if the target is not a hero).
-- An approximation, to avoid computing FOV for the monster.
-- If the target actor has no FOV pre-computed, we assume it can't be seen.
monsterSeesHero :: Kind.Ops TileKind -> Perception -> Level
                 -> ActorId -> ActorId -> Point -> Point -> Bool
monsterSeesHero cotile per lvl _source target sloc tloc =
  let rempty = PerceptionReachable IS.empty
      reachable@PerceptionReachable{preachable} = case target of
        AMonster _ -> rempty
        -- TODO: instead of this fromMaybe clean up how Perception
        -- is regenerated when levels are switched
        AHero    i -> fromMaybe rempty $ IM.lookup i $ pheroes per
  in sloc `IS.member` preachable
     && isVisible cotile reachable lvl IS.empty tloc

-- | Calculate the perception of all actors on the level.
perception :: Kind.COps -> State -> Perception
perception cops@Kind.COps{cotile}
           state@State{ splayer
                      , sconfig
                      , sdebug = DebugMode{smarkVision}
                      } =
  let lvl@Level{lheroes = hs} = slevel state
      mode   = Config.get sconfig "engine" "fovMode"
      radius = let r = Config.get sconfig "engine" "fovRadius"
               in if r < 1
                  then error $ "FOV radius is " ++ show r ++ ", should be >= 1"
                  else r
      -- Perception for a player-controlled monster on the current level.
      mLocPer =
        if isAMonster splayer && memActor splayer state
        then let m = getPlayerBody state
             in Just (bloc m,
                      computeReachable cops radius mode smarkVision m lvl)
        else Nothing
      (mLoc, mPer) = (fmap fst mLocPer, fmap snd mLocPer)
      pers = IM.map (\ h ->
                      computeReachable cops radius mode smarkVision h lvl) hs
      locs = IM.map bloc hs
      lpers = maybeToList mPer ++ IM.elems pers
      reachable = PerceptionReachable $ IS.unions (map preachable lpers)
      -- TODO: Instead of giving the monster a light source, alter vision.
      playerControlledMonsterLight = maybeToList mLoc
      lights = IS.fromList $ playerControlledMonsterLight ++ IM.elems locs
      visible = computeVisible cotile reachable lvl lights
  in  Perception { pplayer = mPer
                 , pheroes = pers
                 , ptotal  = visible
                 }

-- | A location can be directly lit by an ambient shine or a weak, portable
-- light source, e.g,, carried by a hero. (Only lights of radius 0
-- are considered for now and it's assumed they do not reveal hero's position.
-- TODO: change this to be radius 1 noctovision and introduce stronger
-- light sources that show more but make the hero visible.)
-- A location is visible if it's reachable and either directly lit
-- or adjacent to one that is at once directly lit and reachable.
-- The last condition approximates being
-- on the same side of obstacles as the light source.
-- The approximation is not exact for multiple heroes, but the discrepancy
-- can be attributed to deduction based on combined vague visual hints,
-- e.g., if I don't see the reachable light seen by another hero,
-- there must be a wall in-between. Stray rays indicate doors,
-- moving shadows indicate monsters, etc.
computeVisible :: Kind.Ops TileKind -> PerceptionReachable
               -> Level -> IS.IntSet -> PerceptionVisible
computeVisible cops reachable@PerceptionReachable{preachable} lvl lights' =
  let lights = IS.intersection lights' preachable  -- optimization
      isV = isVisible cops reachable lvl lights
  in PerceptionVisible $ IS.filter isV preachable

isVisible :: Kind.Ops TileKind -> PerceptionReachable
          -> Level -> IS.IntSet -> Point -> Bool
isVisible cotile PerceptionReachable{preachable}
               lvl@Level{lxsize, lysize} lights loc0 =
  let litDirectly loc = Tile.isLit cotile (lvl `at` loc)
                        || loc `IS.member` lights
      l_and_R loc = litDirectly loc && loc `IS.member` preachable
  in litDirectly loc0 || L.any l_and_R (vicinity lxsize lysize loc0)

-- | Reachable are all fields on an unblocked path from the hero position.
-- The player's own position is considred reachable by him.
computeReachable :: Kind.COps -> Int -> String -> Maybe FovMode
                 -> Actor -> Level -> PerceptionReachable
computeReachable Kind.COps{cotile, coactor=Kind.Ops{okind}}
                 radius mode smarkVision actor lvl =
  let fovMode m =
        if not $ asight $ okind $ bkind m
        then Blind
        else case smarkVision of
          Just fm -> fm
          Nothing -> case mode of
            "shadow"     -> Shadow
            "permissive" -> Permissive
            "digital"    -> Digital radius
            _            -> error $ "Unknown FOV mode: " ++ show mode
      ploc = bloc actor
  in PerceptionReachable $
       IS.insert ploc $ IS.fromList $ fullscan cotile (fovMode actor) ploc lvl