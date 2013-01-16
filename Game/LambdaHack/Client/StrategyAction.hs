{-# LANGUAGE OverloadedStrings #-}
-- | AI strategy operations implemented with the 'Action' monad.
module Game.LambdaHack.Client.StrategyAction
  ( targetStrategy, actionStrategy
  ) where

import Control.Arrow
import Control.Monad
import Data.Function
import qualified Data.IntMap as IM
import qualified Data.List as L
import Data.Maybe

import Game.LambdaHack.Ability (Ability)
import qualified Game.LambdaHack.Ability as Ability
import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Client.Action
import Game.LambdaHack.CmdSer
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.StrategyKind
import qualified Game.LambdaHack.Effect as Effect
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.State
import Game.LambdaHack.Client.Strategy
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Utils.Frequency
import Game.LambdaHack.Vector

-- TODO: extress many (all?) functions as MonadActionRO

-- | AI proposes possible targets for the actor. Never empty.
targetStrategy :: MonadClientRO m => ActorId -> m (Strategy (Maybe Target))
targetStrategy actor = do
  cops@Kind.COps{costrat=Kind.Ops{okind}} <- getsState scops
  per <- askPerception
  glo <- getState
  btarget <- getsClient $ getTarget actor
  let Actor{bfaction} = getActorBody actor glo
      factionAI = gAiIdle $ sfaction glo IM.! bfaction
      factionAbilities = sabilities (okind factionAI)
  return $! reacquireTgt cops actor btarget glo per factionAbilities

reacquireTgt :: Kind.COps -> ActorId -> Maybe Target -> State
             -> Perception -> [Ability]
             -> Strategy (Maybe Target)
reacquireTgt cops actor btarget glo per factionAbilities =
  reacquire btarget
 where
  Kind.COps{coactor=coactor@Kind.Ops{okind}} = cops
  lvl@Level{lxsize} = getArena glo
  actorBody@Actor{ bkind, bpos = me, bfaction, bpath } =
    getActorBody actor glo
  mk = okind bkind
  enemyVisible l =
    asight mk
    && actorSeesLoc per actor l
    -- Enemy can be felt if adjacent, even if invisible or disguise.
    -- TODO: can this be replaced by setting 'lights' to [me]?
    || adjacent lxsize me l
       && (asmell mk || asight mk)
  actorAbilities = acanDo (okind bkind) `L.intersect` factionAbilities
  focused = actorSpeed coactor actorBody <= speedNormal
            -- Don't focus on a distant enemy, when you can't chase him.
            -- TODO: or only if another enemy adjacent? consider Flee?
            && Ability.Chase `elem` actorAbilities
  reacquire :: Maybe Target -> Strategy (Maybe Target)
  reacquire tgt | isJust bpath = returN "TPath" tgt  -- don't animate missiles
  reacquire tgt =
    case tgt of
      Just (TEnemy a ll) | focused
                    && memActor a glo ->  -- present on this level
        let l = bpos $ getActorBody a glo
        in if enemyVisible l           -- prefer visible foes
           then returN "TEnemy" $ Just $ TEnemy a l
           else if null visibleFoes    -- prefer visible foes
                   && me /= ll         -- not yet reached the last enemy pos
                then returN "last known" $ Just $ TPos ll
                                       -- chase the last known pos
                else closest
      Just TEnemy{} -> closest            -- foe is gone and we forget
      Just (TPos pos) | me == pos -> closest  -- already reached the pos
      Just TPos{} | null visibleFoes -> returN "TPos" tgt
                                       -- nothing visible, go to pos
      Just TPos{} -> closest                -- prefer visible foes
      Nothing -> closest
  foes = hostileAssocs bfaction lvl
  visibleFoes = L.filter (enemyVisible . snd) (L.map (second bpos) foes)
  closest :: Strategy (Maybe Target)
  closest =
    let foeDist = L.map (\ (_, l) -> chessDist lxsize me l) visibleFoes
        minDist = L.minimum foeDist
        minFoes =
          L.filter (\ (_, l) -> chessDist lxsize me l == minDist) visibleFoes
        minTargets = map (\ (a, l) -> Just $ TEnemy a l) minFoes
        minTgtS = liftFrequency $ uniformFreq "closest" minTargets
    in minTgtS .| noFoes .| returN "TCursor" Nothing  -- never empty
  -- TODO: set distant targets so that monsters behave as if they have
  -- a plan. We need pathfinding for that.
  noFoes :: Strategy (Maybe Target)
  noFoes =
    (Just . TPos . (me `shift`)) `liftM` moveStrategy cops actor glo Nothing

-- | AI strategy based on actor's sight, smell, intelligence, etc. Never empty.
actionStrategy :: MonadClientRO m => ActorId -> m (Strategy CmdSer)
actionStrategy actor = do
  cops@Kind.COps{costrat=Kind.Ops{okind}} <- getsState scops
  glo <- getState
  btarget <- getsClient $ getTarget actor
  let Actor{bfaction} = getActorBody actor glo
      factionAI = gAiIdle $ sfaction glo IM.! bfaction
      factionAbilities = sabilities (okind factionAI)
  return $! proposeAction cops actor btarget glo factionAbilities

proposeAction :: Kind.COps -> ActorId
              -> Maybe Target -> State -> [Ability]
              -> Strategy CmdSer
proposeAction cops actor btarget glo factionAbilities =
  sumS prefix .| combineDistant distant .| sumS suffix
  .| waitBlockNow actor  -- wait until friends sidestep, ensures never empty
 where
  Kind.COps{coactor=Kind.Ops{okind}} = cops
  Actor{ bkind, bpos, bpath } = getActorBody actor glo
  (fpos, foeVisible) | isJust bpath = (bpos, False)  -- a missile
                     | otherwise =
    case btarget of
      Just (TEnemy _ l) -> (l, True)
      Just (TPos l) -> (l, False)
      Nothing -> (bpos, False)  -- an actor blocked by friends
  combineDistant = liftFrequency . sumF
  aFrequency :: Ability -> Frequency CmdSer
  aFrequency Ability.Ranged = if foeVisible
                              then rangedFreq cops actor glo fpos
                              else mzero
  aFrequency Ability.Tools  = if foeVisible
                              then toolsFreq cops actor glo
                              else mzero
  aFrequency Ability.Chase  = if (fpos /= bpos)
                              then chaseFreq
                              else mzero
  aFrequency _              = assert `failure` distant
  chaseFreq =
    scaleFreq 30 $ bestVariant $ chase cops actor glo (fpos, foeVisible)
  aStrategy :: Ability -> Strategy CmdSer
  aStrategy Ability.Track  = track cops actor glo
  aStrategy Ability.Heal   = mzero  -- TODO
  aStrategy Ability.Flee   = mzero  -- TODO
  aStrategy Ability.Melee  = foeVisible .=> melee actor glo fpos
  aStrategy Ability.Pickup = not foeVisible .=> pickup actor glo
  aStrategy Ability.Wander = wander cops actor glo
  aStrategy _              = assert `failure` actorAbilities
  actorAbilities = acanDo (okind bkind) `L.intersect` factionAbilities
  isDistant = (`elem` [Ability.Ranged, Ability.Tools, Ability.Chase])
  (prefix, rest)    = L.break isDistant actorAbilities
  (distant, suffix) = L.partition isDistant rest
  sumS = msum . map aStrategy
  sumF = msum . map aFrequency

-- | A strategy to always just wait.
waitBlockNow :: ActorId -> Strategy CmdSer
waitBlockNow actor = returN "wait" $ WaitSer actor

-- | Strategy for dumb missiles.
track :: Kind.COps -> ActorId -> State -> Strategy CmdSer
track cops actor glo =
  strat
 where
  lvl = getArena glo
  Actor{ bpos, bpath, bhp } = getActorBody actor glo
  dieOrReset | bhp <= 0  = returN "die" $ DieSer actor
             | otherwise = returN "reset TPath" $ ClearPath actor
  strat = case bpath of
    Just [] -> dieOrReset
    Just (d : _) | not $ accessible cops lvl bpos (shift bpos d) -> dieOrReset
    -- TODO: perhaps colour differently the whole second turn of movement?
    Just [d] -> returN "last TPath" $ FollowPath actor d [] True
    Just (d : lv) -> returN "follow TPath" $ FollowPath actor d lv False
    Nothing -> reject

pickup :: ActorId -> State -> Strategy CmdSer
pickup actor glo =
  lootHere bpos .=> actionPickup
 where
  lvl = getArena glo
  Actor{bpos, bletter} = getActorBody actor glo
  lootHere x = not $ L.null $ lvl `atI` x
  bitems = getActorItem actor glo
  actionPickup = case lvl `atI` bpos of
    [] -> assert `failure` (actor, bpos, lvl)
    i : _ ->  -- pick up first item
      case assignLetter (jletter i) bletter bitems of
        Just l -> returN "pickup" $ PickupSer actor i l
        Nothing -> returN "pickup" $ WaitSer actor

melee :: ActorId -> State -> Point -> Strategy CmdSer
melee actor glo fpos =
  foeAdjacent .=> (returN "melee" $ MoveSer actor dir)
 where
  Level{lxsize} = getArena glo
  Actor{bpos} = getActorBody actor glo
  foeAdjacent = adjacent lxsize bpos fpos
  dir = displacement bpos fpos

rangedFreq :: Kind.COps -> ActorId -> State -> Point -> Frequency CmdSer
rangedFreq cops actor glo fpos =
  toFreq "throwFreq" $
    if not foesAdj
       && asight mk
       && accessible cops lvl bpos pos1      -- first accessible
       && isNothing (posToActor pos1 glo)  -- no friends on first
    then throwFreq bitems 3 ++ throwFreq tis 6
    else []
 where
  Kind.COps{ coactor=Kind.Ops{okind}
           , coitem=Kind.Ops{okind=iokind}
           , corule
           } = cops
  lvl@Level{lxsize, lysize} = getArena glo
  Actor{ bkind, bpos, bfaction } = getActorBody actor glo
  bitems = getActorItem actor glo
  mk = okind bkind
  tis = lvl `atI` bpos
  foes = hostileAssocs bfaction lvl
  foesAdj = foesAdjacent lxsize lysize bpos (map snd foes)
  -- TODO: also don't throw if any pos on path is visibly not accessible
  -- from previous (and tweak eps in bla to make it accessible).
  -- Also don't throw if target not in range.
  eps = 0
  bl = bla lxsize lysize eps bpos fpos  -- TODO:make an arg of projectGroupItem
  pos1 = case bl of
    Nothing -> bpos  -- TODO
    Just [] -> bpos  -- TODO
    Just (lbl:_) -> lbl
  throwFreq is multi =
    [ (benefit * multi,
       ProjectSer actor fpos eps (iverbProject ik) i)
    | i <- is,
      let (ik, benefit) =
            case jkind (sdisco glo) i of
              Nothing -> (undefined, 0)
              Just ki ->
                let kik = iokind ki
                in (kik,
                    - (1 + jpower i) * Effect.effectToBenefit (ieffect kik)),
      benefit > 0,
      -- Wasting weapons and armour would be too cruel to the player.
      isymbol ik `elem` (ritemProject $ Kind.stdRuleset corule)]

toolsFreq :: Kind.COps -> ActorId -> State -> Frequency CmdSer
toolsFreq cops actor glo =
  toFreq "quaffFreq" $ quaffFreq bitems 1 ++ quaffFreq tis 2
 where
  Kind.COps{coitem=Kind.Ops{okind=iokind}} = cops
  lvl = getArena glo
  Actor{bpos} = getActorBody actor glo
  bitems = getActorItem actor glo
  tis = lvl `atI` bpos
  quaffFreq is multi =
    [ (benefit * multi, ApplySer actor (iverbApply ik) i)
    | i <- is,
      let (ik, benefit) =
            case jkind (sdisco glo) i of
              Nothing -> (undefined, 0)
              Just ki ->
                let kik = iokind ki
                in (kik,
                    - (1 + jpower i) * Effect.effectToBenefit (ieffect kik)),
      benefit > 0, isymbol ik == '!']

-- | AI finds interesting moves in the absense of visible foes.
-- This strategy can be null (e.g., if the actor is blocked by friends).
moveStrategy :: Kind.COps -> ActorId -> State -> Maybe (Point, Bool)
             -> Strategy Vector
moveStrategy cops actor glo mFoe =
  case mFoe of
    -- Target set and we chase the foe or his last position or another target.
    Just (fpos, foeVisible) ->
      let towardsFoe =
            let foeDir = towards lxsize bpos fpos
                tolerance | isUnit lxsize foeDir = 0
                          | otherwise = 1
            in only (\ x -> euclidDistSq lxsize foeDir x <= tolerance)
      in if fpos == bpos
         then reject
         else towardsFoe
              $ if foeVisible
                then moveClear  -- enemies in sight, don't waste time for doors
                     .| moveOpenable
                else moveOpenable  -- no enemy in sight, explore doors
                     .| moveClear
    Nothing ->
      let smells =
            map (map fst)
            $ L.groupBy ((==) `on` snd)
            $ L.sortBy (flip compare `on` snd)
            $ L.filter (\ (_, s) -> s > timeZero)
            $ L.map (\ x ->
                      let sml = IM.findWithDefault
                                  timeZero (bpos `shift` x) lsmell
                      in (x, sml `timeAdd` timeNegate ltime))
                sensible
      in asmell mk .=> L.foldr ((.|)
                                . liftFrequency
                                . uniformFreq "smell k") reject smells
         .| moveOpenable  -- no enemy in sight, explore doors
         .| moveClear
 where
  Kind.COps{ cotile
           , coactor=Kind.Ops{okind}
           } = cops
  lvl@Level{lsmell, lxsize, lysize, ltime} = getArena glo
  Actor{ bkind, bpos, bdirAI, bfaction } = getActorBody actor glo
  mk = okind bkind
  lootHere x = not $ L.null $ lvl `atI` x
  onlyLoot   = onlyMoves lootHere bpos
  interestHere x = let t = lvl `at` x
                       ts = map (lvl `at`) $ vicinity lxsize lysize x
                   in Tile.hasFeature cotile F.Exit t
                      -- Lit indirectly. E.g., a room entrance.
                      || (not (Tile.hasFeature cotile F.Lit t)
                          && L.any (Tile.hasFeature cotile F.Lit) ts)
  onlyInterest   = onlyMoves interestHere bpos
  onlyKeepsDir k =
    only (\ x -> maybe True (\ (d, _) -> euclidDistSq lxsize d x <= k) bdirAI)
  onlyKeepsDir_9 = only (\ x -> maybe True (\ (d, _) -> neg x /= d) bdirAI)
  moveIQ = aiq mk > 15 .=> onlyKeepsDir 0 moveRandomly
        .| aiq mk > 10 .=> onlyKeepsDir 1 moveRandomly
        .| aiq mk > 5  .=> onlyKeepsDir 2 moveRandomly
        .| onlyKeepsDir_9 moveRandomly
  interestFreq | interestHere bpos =
    -- Don't detour towards an interest if already on one.
    mzero
               | otherwise =
    -- Prefer interests, but don't exclude other focused moves.
    scaleFreq 5 $ bestVariant $ onlyInterest $ onlyKeepsDir 2 moveRandomly
  interestIQFreq = interestFreq `mplus` bestVariant moveIQ
  moveClear    = onlyMoves (not . openableHere) bpos moveFreely
  moveOpenable = onlyMoves openableHere bpos moveFreely
  moveFreely = onlyLoot moveRandomly
               .| liftFrequency interestIQFreq
               .| moveIQ  -- sometimes interestIQFreq is excluded later on
               .| moveRandomly
  onlyMoves :: (Point -> Bool) -> Point -> Strategy Vector -> Strategy Vector
  onlyMoves p l = only (\ x -> p (l `shift` x))
  moveRandomly :: Strategy Vector
  moveRandomly = liftFrequency $ uniformFreq "moveRandomly" sensible
  openableHere   = openable cotile lvl
  accessibleHere = accessible cops lvl bpos
  noFriends | asight mk = unoccupied (factionList [bfaction] glo)
            | otherwise = const True
  isSensible l = noFriends l && (accessibleHere l || openableHere l)
  sensible = filter (isSensible . (bpos `shift`)) (moves lxsize)

chase :: Kind.COps -> ActorId -> State -> (Point, Bool) -> Strategy CmdSer
chase cops actor glo foe@(_, foeVisible) =
  -- Target set and we chase the foe or offer null strategy if we can't.
  -- The foe is visible, or we remember his last position.
  let mFoe = Just foe
      fight = not foeVisible  -- don't pick fights if the real foe is close
  in DirToAction actor fight `liftM` moveStrategy cops actor glo mFoe

wander :: Kind.COps -> ActorId -> State -> Strategy CmdSer
wander cops actor glo =
  -- Target set, but we don't chase the foe, e.g., because we are blocked
  -- or we cannot chase at all.
  let mFoe = Nothing
  in DirToAction actor True `liftM` moveStrategy cops actor glo mFoe