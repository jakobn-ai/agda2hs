module Fail.RuntimeCheckGo where

open import Haskell.Prelude

conflict : ((go0 : Nat) ⦃@0 _ : IsTrue (go0 > 0)⦄ → Nat) → Nat
conflict _ = 0
{-# COMPILE AGDA2HS conflict #-}
