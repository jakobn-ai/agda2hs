module Fail.RuntimeCheckUnboxed where

open import Haskell.Prelude

record Unboxable : Set where
  field unboxField : Nat
{-# COMPILE AGDA2HS Unboxable unboxed #-}

record NotUnboxable : Set where
  field noUnboxField : (@0 _ : IsTrue Bool.true) → Nat
{-# COMPILE AGDA2HS NotUnboxable unboxed #-}
