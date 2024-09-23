module Fail.RuntimeCheckArg where

open import Haskell.Prelude

conflict : (Nat → (a0 : Nat) ⦃@0 _ : IsTrue (a0 > 0)⦄ → Nat) → Nat
conflict _ = 0
{-# COMPILE AGDA2HS conflict #-}
