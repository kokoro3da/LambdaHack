-- | Atomic monads.
module Game.LambdaHack.Atomic
  ( -- * MonadAtomic
    MonadAtomic(..)
  , broadcastUpdAtomic,  broadcastSfxAtomic
    -- * CmdAtomic
  , CmdAtomic(..), UpdAtomic(..), SfxAtomic(..), HitAtomic(..)
    -- * PosAtomicRead
  , PosAtomic(..), posUpdAtomic, posSfxAtomic, seenAtomicCli, generalMoveItem
  ) where

import Game.LambdaHack.Atomic.CmdAtomic
import Game.LambdaHack.Atomic.MonadAtomic
import Game.LambdaHack.Atomic.PosAtomicRead