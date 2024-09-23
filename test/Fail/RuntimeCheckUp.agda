module Fail.RuntimeCheckUp where

open import Haskell.Prelude

conflict : ((up : Nat) ⦃@0 _ : IsTrue (up > 0)⦄ → Nat) → Nat
conflict _ = 0
{-# COMPILE AGDA2HS conflict #-}
