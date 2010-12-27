module Turn where

import System.Time
import Control.Monad
import Data.List as L
import Data.Map as M
import Data.Set as S
import Data.Char
import Data.Maybe
import Data.Function

import State
import Geometry
import Level
import LevelState
import Dungeon
import Monster
import Actor
import Perception
import Item
import ItemState
import Display2
import Random
import Save
import Message
import Version
import Strategy
import StrategyState
import HighScores

-- | Perform a complete turn (i.e., monster moves etc.)
loop :: Session -> State -> Message -> IO ()
loop session (state@(State { splayer = player@(Monster { mhp = php, mloc = ploc }),
                             stime   = time,
                             slevel  = lvl@(Level nm sz ms smap lmap lmeta) }))
             oldmsg =
  do
    -- update smap
    let nsmap = M.insert ploc (time + smellTimeout) smap
    -- determine player perception
    let per = perception ploc lmap
    -- perform monster moves
    handleMonsters session (updateLevel (const (lvl { lsmell = nsmap })) state) per oldmsg

-- | Handle monster moves. The idea is that we perform moves
--   as long as there are monsters that have a move time which is
--   less than or equal to the current time.
handleMonsters :: Session -> State -> Perception -> Message -> IO ()
handleMonsters session
               (state@(State { stime  = time,
                               slevel = lvl@(Level { lmonsters = ms }) }))
               per oldmsg =
    -- for debugging: causes redraw of the current state for every monster move; slow!
    -- displayLevel session lvl per state oldmsg >>
    case ms of
      [] -> -- there are no monsters, just continue
            handlePlayer
      (m@(Monster { mtime = mt }) : ms)
         | mt > time  -> -- all the monsters are not yet ready for another move,
                         -- so continue
                            handlePlayer
         | mhp m <= 0 -> -- the monster dies
                            handleMonsters session
                                           (updateLevel (updateMonsters (const ms)) state)
                                           per oldmsg
         | otherwise  -> -- monster m should move
                            handleMonster m session
                                          (updateLevel (updateMonsters (const ms)) state)
                                          per oldmsg
  where
    nstate = state { stime = time + 1 }

    -- good place to do everything that has to be done for every *time*
    -- unit; currently, that's monster generation
    handlePlayer =
      do
        nlvl <- rndToIO (addMonster lvl (splayer nstate))
        handle session (updateLevel (const nlvl) nstate) per oldmsg

-- | Handle the move of a single monster.
handleMonster :: Monster -> Session -> State -> Perception -> Message ->
                 IO ()
handleMonster m session
              (state@(State { splayer = player@(Monster { mloc = ploc }),
                              stime   = time,
                              slevel  = lvl@(Level { lmonsters = ms, lsmell = nsmap, lmap = lmap }) }))
              per oldmsg =
  do
    nl <- rndToIO (frequency (head (runStrategy (strategy m state per .| wait))))

    -- increase the monster move time and set direction
    let nm = m { mtime = time + mspeed m, mdir = if nl == (0,0) then Nothing else Just nl }
    let (act, nms) = insertMonster nm ms
    let nlvl = updateMonsters (const nms) lvl
    moveOrAttack
      True True -- attacks allowed, auto-open
      per (AMonster act) nl
      session
      (displayLevel session per state)
      (\ s msg -> handleMonsters session s per (addMsg oldmsg msg))
      (handleMonsters session (updateLevel (const nlvl) state) per oldmsg)
      (updateLevel (const nlvl) state)


-- | Display current status and handle the turn of the player.
handle :: Session -> State -> Perception -> Message -> IO ()
handle session (state@(State { splayer = player@(Monster { mhp = php, mdir = pdir, mloc = ploc, mitems = pinv, mtime = ptime }),
                               stime   = time,
                               slevel  = lvl@(Level nm sz ms smap lmap lmeta) }))
               per oldmsg =
    -- check for player death
    if php <= 0
      then do
             displayCurrent (addMsg oldmsg more) Nothing
             getConfirm session
             displayCurrent ("You die." ++ more) Nothing
             getConfirm session
             let total = calculateTotal player
             handleScores True True False total session displayCurrent (\ _ _ -> shutdown session) (shutdown session) nstate
      else -- check if the player can make another move yet
           if ptime > time then
             do
               -- do not make intermediate redraws while running
               maybe (displayLevel session per state "" Nothing) (const $ return True) pdir
               handleMonsters session state per oldmsg
           -- NOTE: It's important to call handleMonsters here, not loop,
           -- because loop does all sorts of calculations that are only
           -- really necessary after the player has moved.
      else do
             displayCurrent oldmsg Nothing
             let h = nextCommand session >>= h'
                 h' e =
                       handleDirection e (\ d -> wrapHandler (move d) h) $
                         handleDirection (L.map toLower e) run $
                         case e of
                           "o"       -> wrapHandler (openclose True)  h
                           "c"       -> wrapHandler (openclose False) h
                           "s"       -> wrapHandler search            h

                           "less"    -> wrapHandler (lvlchange Up)    h
                           "greater" -> wrapHandler (lvlchange Down)  h

                           -- items
                           "comma"   -> wrapHandler pickupItem  h
                           "d"       -> wrapHandler dropItem    h
                           "i"       -> wrapHandler inventory   h
                           "q"       -> wrapHandler drinkPotion h

                           -- saving or ending the game
                           "S"       -> saveGame mstate >>
                                        let total = calculateTotal player
                                        in  handleScores False False False total session displayCurrent (\ _ _ -> shutdown session) h nstate
                           "Q"       -> shutdown session
                           "Escape"  -> displayCurrent "Press Q to quit." Nothing >> h

                           -- wait
                           "space"   -> loop session nstate ""
                           "period"  -> loop session nstate ""

                           -- look
                           "colon"   -> wrapHandler lookAround h

                           -- display modes
                           "V"       -> handle session (toggleVision     ustate) per oldmsg
                           "R"       -> handle session (toggleSmell      ustate) per oldmsg
                           "O"       -> handle session (toggleOmniscient ustate) per oldmsg
                           "T"       -> handle session (toggleTerrain    ustate) per oldmsg

                           -- meta information
                           "M"       -> displayCurrent "" (Just $ unlines (shistory mstate) ++ more) >>= \ b ->
                                        if b then getOptionalConfirm session
                                                    (const (displayCurrent "" Nothing >> h)) h'
                                             else displayCurrent "" Nothing >> h
                           "I"       -> displayCurrent lmeta   Nothing >> h
                           "v"       -> displayCurrent version Nothing >> h

                           s         -> displayCurrent ("unknown command (" ++ s ++ ")") Nothing >> h
             maybe h continueRun pdir

 where

  -- we record the oldmsg in the history
  mstate = if L.null oldmsg then state else updateHistory (take 500 . ((oldmsg ++ " "):)) state
    -- TODO: make history max configurable

  reachable = preachable per
  visible   = pvisible per

  displayCurrent :: Message -> Maybe String -> IO Bool
  displayCurrent  = displayLevel session per ustate

  -- update player memory
  nlmap = foldr (\ x m -> M.update (\ (t,_) -> Just (t,t)) x m) lmap (S.toList visible)
  nlvl = updateLMap (const nlmap) lvl

  -- state with updated player memory, but without any passed time
  ustate  = updateLevel (const nlvl) state

  -- update player action time, and regenerate hitpoints
  -- player HP regeneration, TODO: remove hardcoded max and time interval
  nplayer = player { mtime = time + mspeed player,
                     mhp   = if time `mod` 1500 == 0 then (php + 1) `min` playerHP else php }
  nstate  = updateLevel (const nlvl) (updatePlayer (const nplayer) mstate)

  -- uniform wrapper function for action handlers
  wrapHandler :: Handler () -> IO () -> IO ()
  wrapHandler h abort = h session displayCurrent (loop session) abort nstate

  -- run into a direction
  run dir =
    do
      let mplayer = nplayer { mdir = Just dir }
          abort   = handle session (updatePlayer (const $ player { mdir = Nothing }) ustate) per ""
      moveOrAttack
        False False -- attacks and opening doors disallowed while running
        per APlayer dir
        session displayCurrent
        (loop session)
        abort
        (updatePlayer (const mplayer) nstate)
  continueRun dir =
    let abort = handle session (updatePlayer (const $ player { mdir = Nothing }) ustate) per oldmsg
        dloc  = shift ploc dir
        mslocs = S.fromList $ L.map mloc ms
    in  case (oldmsg, nlmap `at` ploc) of
          (_:_, _)                   -> abort
          (_, Tile (Opening {}) _)   -> abort
          (_, Tile (Door {}) _)      -> abort
          (_, Tile (Stairs {}) _)    -> abort
          _
            | not $ S.null $ mslocs `S.intersection` pvisible per
                                     -> abort  -- monsters visible
          _
            | accessible nlmap ploc dloc ->
                moveOrAttack
                  False False -- attacks and opening doors disallowed while running
                  per APlayer dir
                  session displayCurrent
                  (loop session)
                  abort
                  nstate
          (_, Tile Corridor _)  -- direction change restricted to corridors
            | otherwise ->
                let ns  = L.filter (\ x -> distance (neg dir,x) > 1
                                        && accessible nlmap ploc (ploc `shift` x)) moves
                    sns = L.filter (\ x -> distance (dir,x) <= 1) ns
                in  case ns of
                      [newdir] -> run newdir
                      _        -> case sns of
                                    [newdir] -> run newdir
                                    _        -> abort
          _ -> abort

  -- perform a player move
  move dir = moveOrAttack
               True True -- attacks and opening doors is allowed
               per APlayer dir

type Handler a =  Session ->                                    -- session
                  (Message -> Maybe String -> IO Bool) ->       -- display
                  (State -> Message -> IO a) ->                 -- success continuation
                  IO a ->                                       -- failure continuation
                  State -> IO a

-- | Open and close doors.
openclose :: Bool -> Handler a
openclose o session displayCurrent continue abort
          nstate@(State { slevel  = nlvl@(Level { lmonsters = ms, lmap = nlmap }),
                          splayer = Monster { mloc = ploc } }) =
  do
    displayCurrent "direction?" Nothing
    e <- nextCommand session
    handleDirection e openclose'
                      (displayCurrent "never mind" Nothing >> abort)
  where
    openclose' dir =
      let txt  = if o then "open" else "closed"
          dloc = shift ploc dir
      in
        case nlmap `at` dloc of
          Tile d@(Door hv o') is
                   | secret o'   -> displayCurrent "never mind" Nothing >> abort
                   | toOpen (not o) /= o'
                                 -> displayCurrent ("already " ++ txt) Nothing >> abort
                   | not (unoccupied ms nlmap dloc)
                                 -> displayCurrent "blocked" Nothing >> abort
                   | otherwise   -> -- ok, we can open/close the door
                                    let nt = Tile (Door hv (toOpen o)) is
                                        clmap = M.insert (shift ploc dir) (nt, nt) nlmap
                                    in continue (updateLevel (const (updateLMap (const clmap) nlvl)) nstate) ""
          _ -> displayCurrent "never mind" Nothing >> abort


-- | Perform a level change -- will quit the game if the player leaves
-- the dungeon.
lvlchange :: VDir -> Handler ()
lvlchange vdir session displayCurrent continue abort
          nstate@(State { slevel  = lvl@(Level { lmap = nlmap }),
                          splayer = player@(Monster { mloc = ploc }) }) =
  case nlmap `at` ploc of
    Tile (Stairs _ vdir' next) is
     | vdir == vdir' -> -- ok
        case next of
          Nothing ->
            -- we are at the top (or bottom or lift)
            fleeDungeon
          Just (nln, nloc) ->
            -- perform level change
            do
              -- put back current level
              -- (first put back, then get, in case we change to the same level!)
              let full = putDungeonLevel lvl (sdungeon nstate)
              -- get new level
                  (new, ndng) = getDungeonLevel nln full
                  lstate = nstate { sdungeon = ndng, slevel = new }
              continue (updatePlayer (const (player { mloc = nloc })) lstate) ""
    _ -> -- no stairs
         let txt = if vdir == Up then "up" else "down" in
         displayCurrent ("no stairs " ++ txt) Nothing >> abort
  where
    fleeDungeon =
      let items   = mitems player
          total   = calculateTotal player
          winMsg  = "Congratulations, you won! Your loot, worth "
                    ++ show total ++ " gold, is:"
      in
       if total == 0
           then do
                  displayCurrent ("Chicken!" ++ more) Nothing
                  getConfirm session
                  displayCurrent
                    ("Next time try to grab some loot before you flee!" ++ more)
                    Nothing
                  getConfirm session
                  shutdown session
           else do
                  displayItems displayCurrent nstate winMsg True items
                  getConfirm session
                  handleScores True False True total session displayCurrent (\ _ _ -> shutdown session) abort nstate

-- | Calculate loot's worth.
calculateTotal :: Player -> Int
calculateTotal player = L.sum $ L.map price $ mitems player
  where
    price i = if iletter i == Just '$' then icount i else 10 * icount i

-- | Handle current score and display it with the high scores.
handleScores :: Bool -> Bool -> Bool -> Int -> Handler () 
handleScores write killed victor total session displayCurrent continue abort
             nstate@(State { stime = time }) =
  let -- TODO: this should be refactored into a dedicated function
      moreM msg s =
        displayCurrent msg (Just (s ++ more)) >> getConfirm session
      points = if killed then (total + 1) `div` 2 else total
  in  do
        unless (total == 0) $ do
          curDate <- getClockTime
          let score = HighScores.ScoreRecord points killed victor curDate time
          (placeMsg, slideshow) <- HighScores.register write score
          mapM_ (moreM placeMsg) slideshow
        continue nstate ""

-- | Search for secret doors
search :: Handler a
search session displayCurrent continue abort
       nstate@(State { slevel  = Level { lmap = nlmap },
                       splayer = Monster { mloc = ploc } }) =
  let searchTile (Tile (Door hv (Just n)) x,t') = Just (Tile (Door hv (Just (max (n - 1) 0))) x, t')
      searchTile t                              = Just t
      slmap = foldl (\ l m -> update searchTile (shift ploc m) l) nlmap moves
  in  continue (updateLevel (updateLMap (const slmap)) nstate) ""

-- | Look around at current location
lookAround :: Handler a
lookAround session displayCurrent continue abort
           nstate@(State { slevel  = Level { lmap = nlmap },
                           splayer = Monster { mloc = ploc } }) =
  do
    -- check if something is here to pick up
    let t = nlmap `at` ploc
    if length (titems t) <= 2
      then displayCurrent (lookAt True nstate nlmap ploc) Nothing >> abort
      else
        do
           displayItems displayCurrent nstate
                        (lookAt True nstate nlmap ploc) False (titems t)
           getConfirm session
           displayCurrent "" Nothing
           abort  -- looking around doesn't take any time

-- | Display inventory
inventory :: Handler a
inventory session displayCurrent continue abort
          nstate@(State { splayer = player })
  | L.null (mitems player) =
    displayCurrent "You are not carrying anything." Nothing >> abort
  | otherwise =
  do
    displayItems displayCurrent nstate
                 "This is what you are carrying:" True (mitems player)
    getConfirm session
    displayCurrent "" Nothing
    abort  -- looking at inventory doesn't take any time

drinkPotion :: Handler a
drinkPotion session displayCurrent continue abort
            state@(State { slevel  = nlvl@(Level { lmap = nlmap }),
                           splayer = nplayer@(Monster { mloc = ploc }) })
    | L.null (mitems nplayer) =
      displayCurrent "You are not carrying anything." Nothing >> abort
    | otherwise =
    do
      i <- getPotions session displayCurrent state
                      "What to drink?" (mitems nplayer)
      case i of
        Just i'@(Item { itype = Potion ptype }) ->
                   let iplayer = nplayer { mitems = deleteBy ((==) `on` iletter) i' (mitems nplayer) }
                       t = nlmap `at` ploc
                       msg = subjectMonster (mtype nplayer) ++ " " ++
                             verbMonster (mtype nplayer) "drink" ++ " " ++
                             objectItem state (icount i') (itype i') ++ ". " ++
                             pmsg ptype
                       pmsg PotionWater   = "Tastes like water."
                       pmsg PotionHealing = "You feel better."
                       fplayer PotionWater   = iplayer
                       fplayer PotionHealing = iplayer { mhp = 20 }
                   in  continue (updateLevel       (const nlvl) $
                                 updatePlayer      (const (fplayer ptype)) $
                                 updateDiscoveries (S.insert (itype i')) $
                                 state) msg
        Just _  -> displayCurrent "you cannot drink that" Nothing >> abort
        Nothing -> displayCurrent "never mind" Nothing >> abort

dropItem :: Handler a
dropItem session displayCurrent continue abort
         state@(State { slevel  = nlvl@(Level { lmap = nlmap }),
                        splayer = nplayer@(Monster { mloc = ploc }) })
    | L.null (mitems nplayer) =
      displayCurrent "You are not carrying anything." Nothing >> abort
    | otherwise =
    do
      i <- getAnyItem session displayCurrent state
                      "What to drop?" (mitems nplayer)
      case i of
        Just i' -> let iplayer = nplayer { mitems = deleteBy ((==) `on` iletter) i' (mitems nplayer) }
                       t = nlmap `at` ploc
                       nt = t { titems = snd (joinItem i' (titems t)) }
                       plmap = M.insert ploc (nt, nt) nlmap
                       msg = subjectMonster (mtype nplayer) ++ " " ++
                             verbMonster (mtype nplayer) "drop" ++ " " ++
                             objectItem state (icount i') (itype i') ++ "."
                   in  continue (updateLevel  (const (updateLMap (const plmap) nlvl)) $
                                 updatePlayer (const iplayer) $
                                 state) msg
        Nothing -> displayCurrent "never mind" Nothing >> abort

pickupItem :: Handler a
pickupItem _ displayCurrent continue abort
           state@(State { slevel  = nlvl@(Level { lmap = nlmap }),
                          splayer = nplayer@(Monster { mloc = ploc }) }) =
    do
      -- check if something is here to pick up
      let t = nlmap `at` ploc
      case titems t of
        []      ->  displayCurrent "nothing here" Nothing >> abort
        (i:rs)  ->
          case assignLetter (iletter i) (mletter nplayer) (mitems nplayer) of
            Just l  ->
              let msg = -- (complete sentence, more adequate for monsters)
                        {-
                        subjectMonster (mtype player) ++ " " ++
                        compoundVerbMonster (mtype player) "pick" "up" ++ " " ++
                        objectItem (icount i) (itype i) ++ "."
                        -}
                        letterLabel (iletter ni) ++ objectItem state (icount ni) (itype ni)
                  nt = t { titems = rs }
                  plmap = M.insert ploc (nt, nt) nlmap
                  (ni,nitems) = joinItem (i { iletter = Just l }) (mitems nplayer)
                  iplayer = nplayer { mitems  = nitems,
                                      mletter = maxLetter l (mletter nplayer) }
              in  continue (updateLevel  (const (updateLMap (const plmap) nlvl)) $
                            updatePlayer (const iplayer) $
                            state) msg
            Nothing -> displayCurrent "cannot carry anymore" Nothing >> abort

getPotions :: Session ->
              (Message -> Maybe String -> IO Bool) ->
              State ->
              String ->
              [Item] ->
              IO (Maybe Item)
getPotions session displayCurrent state prompt is =
  getItem session displayCurrent  state
          prompt (\ i -> case itype i of Potion {} -> True; _ -> False)
          "Potions in your inventory:" is

getAnyItem :: Session ->
              (Message -> Maybe String -> IO Bool) ->
              State ->
              String ->
              [Item] ->
              IO (Maybe Item)
getAnyItem session displayCurrent state prompt is =
  getItem session displayCurrent state
          prompt (const True) "Objects in your inventory:" is

getItem :: Session ->
           (Message -> Maybe String -> IO Bool) ->
           State ->
           String ->
           (Item -> Bool) ->
           String ->
           [Item] ->
           IO (Maybe Item)
getItem session displayCurrent state prompt p ptext is0 =
  let is = L.filter p is0
      choice | L.null is = "[*]"
             | otherwise = "[" ++ letterRange (concatMap (maybeToList . iletter) is) ++ " or ?*]"
      r = do
            displayCurrent (prompt ++ " " ++ choice) Nothing
            let h = nextCommand session >>= h'
                h' e =
                      case e of
                        "question" -> do
                                        b <- displayItems displayCurrent state
                                                          ptext True is
                                        if b then getOptionalConfirm session (const r) h'
                                             else r
                        "asterisk" -> do
                                        b <- displayItems displayCurrent state
                                                          "Objects in your inventory:" True is0
                                        if b then getOptionalConfirm session (const r) h'
                                             else r
                        [l]        -> return (find (\ i -> maybe False (== l) (iletter i)) is0)
                        _          -> return Nothing
            h
  in r

displayItems :: (Message -> Maybe String -> IO Bool) ->
                State ->
                Message ->
                Bool ->
                [Item] ->
                IO Bool
displayItems displayCurrent state msg sorted is =
    do
      let inv = unlines $
                L.map (\ (Item { icount = c, iletter = l, itype = t }) ->
                         letterLabel l ++ objectItem state c t ++ " ")
                      ((if sorted then sortBy (cmpLetter' `on` iletter) else id) is)
      let ovl = inv ++ more
      displayCurrent msg (Just ovl)


-- | This function performs a move (or attack) by any actor, i.e., it can handle
-- both monsters and the player. It is currently written such that it conforms
-- (with extensions) to the action handler interface. However, it should not actually
-- cause any interaction (at least not when we're performing a move of a monster),
-- so it may make sense to change the type once again.
moveOrAttack :: Bool ->                                     -- allow attacks?
                Bool ->                                     -- auto-open doors on move
                Perception ->                               -- ... of the player
                Actor ->                                    -- who's moving?
                Dir ->
                Handler a
moveOrAttack allowAttacks autoOpen
             per actor dir
             session displayCurrent continue abort
             state@(State { slevel  = nlvl@(Level { lmap = nlmap }),
                            splayer = player })
      -- to prevent monsters from hitting themselves
    | dir == (0,0) = continue state ""
      -- At the moment, we check whether there is a monster before checking accessibility
      -- i.e., we can attack a monster on a blocked location. For instance,
      -- a monster on an open door can be attacked diagonally, and a
      -- monster capable of moving through walls can be attacked from an
      -- adjacent position.
    | not (L.null attacked) =
        if allowAttacks then
          do
            let damage m = case mhp m of
                             1  ->  m { mhp = 0, mtime = 0 }  -- grant an immediate move to die
                             h  ->  m { mhp = h - 1 }
            let combatVerb m
                  | mhp m > 0 = "hit"
                  | otherwise = "kill"
            let combatMsg m  = subjectMonster (mtype am) ++ " " ++
                               verbMonster (mtype am) (combatVerb m) ++ " " ++
                               objectMonster (mtype m) ++ "."
            let perceivedMsg m
                  | mloc m `S.member` pvisible per = combatMsg m
                  | otherwise                      = "You hear some noises."
            let sortmtime = sortBy (\ x y -> compare (mtime x) (mtime y))
            let updateVictims s msg (a:r) =
                  updateActor damage (\ m s -> updateVictims s
                                                   (addMsg msg (perceivedMsg m)) r)
                              a s
                updateVictims s msg [] = continue s {- (updateMonsters sortmtime l) -} msg
            updateVictims state "" attacked
        else
          abort
      -- Perform a move.
    | accessible nlmap aloc naloc =
        updateActor (\ m -> m { mloc = naloc })
                    (\ _ s -> continue s (if actor == APlayer
                                          then lookAt False state nlmap naloc else ""))
                    actor state
      -- Bump into a door/wall, that is try to open it/examine it
    | autoOpen =
      case nlmap `at` naloc of
        Tile d@(Door hv o') is
          | secret o' -> abort  -- nothing interesting spotted on the wall
          | toOpen False == o' ->  -- closed door
            let nt = Tile (Door hv (toOpen True)) is
                clmap = M.insert naloc (nt, nt) nlmap
                clvl  = updateLMap (const clmap) nlvl
            in
             continue (updateLevel (const clvl) state) ""
          | otherwise -> abort  -- already open (bumping diagonally)
        _ -> abort  -- nothing interesting spotted on the wall
    | otherwise = abort
    where am :: Monster
          am     = getActor state actor
          aloc :: Loc
          aloc   = mloc am
          source = nlmap `at` aloc
          naloc  = shift aloc dir
          target = nlmap `at` naloc
          attackedPlayer   = [ APlayer | mloc player == naloc ]
          attackedMonsters = L.map AMonster $
                             findIndices (\ m -> mloc m == naloc) (lmonsters nlvl)
          attacked :: [Actor]
          attacked = attackedPlayer ++ attackedMonsters
