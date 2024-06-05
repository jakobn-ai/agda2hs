{-# OPTIONS --sized-types #-}
module RuntimeCheckFeatures where

open import Haskell.Prelude
open import Haskell.Extra.Delay
open import Haskell.Extra.Dec.Instances

noneErasedFun : Nat → Nat
noneErasedFun _ = 1
{-# COMPILE AGDA2HS noneErasedFun #-}

noDecInstance : ⦃ x : Nat ⦄ ⦃@0 _ : HasResult x (now x)⦄ → Nat
noDecInstance = 0
{-# COMPILE AGDA2HS noDecInstance #-}

simpleFun : (x : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ → Nat
simpleFun _ = 0
{-# COMPILE AGDA2HS simpleFun #-}

simpleFunCaller : Nat
simpleFunCaller = simpleFun 1
{-# COMPILE AGDA2HS simpleFunCaller #-}

fun : (x : Nat) → ((y : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ ⦃@0 _ : IsFalse (x < y)⦄ → Nat) → Nat
fun _ _ = 0
{-# COMPILE AGDA2HS fun #-}

fun' : ((x : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ → ((y : Nat) ⦃@0 _ : IsFalse (x < y)⦄ → Nat) → Nat) → Nat
fun' _ = 0
{-# COMPILE AGDA2HS fun' #-}

-- If you want to deconstruct in Haskell, you have to write deconstructors in Agda.
-- Making the constructor available would enable bypassing the smart constructor.
data Dat : Set where
  Con : (((x : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ → Nat) → Nat) → Dat
  NoneErasedCon : Nat → Dat
{-# COMPILE AGDA2HS Dat #-}

-- Term variables in type parameter not supported, so not showcased here
record Rec : Set where
  field
    recFst : Nat
    recSnd : (⦃@0 _ : IsTrue (recFst > 0)⦄ → Nat) → (⦃@0 _ : IsTrue (recFst < 5)⦄ → Nat) → Nat
open Rec public
{-# COMPILE AGDA2HS Rec #-}

zeroLtSuc : (a : Nat) → IsTrue (0 < (a + 1))
zeroLtSuc zero = IsTrue.itsTrue
zeroLtSuc (suc _) = IsTrue.itsTrue

record Newt : Set where
  field
    theField : (f : ((x : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ → Nat)) → (y : Nat) → ⦃@0 _ : IsTrue (f (y + 1) ⦃ zeroLtSuc y ⦄ > 0)⦄ → Nat
open Newt public
{-# COMPILE AGDA2HS Newt newtype #-}

record NoneErasedNewt : Set where
  field
    noneErasedField : Nat
open NoneErasedNewt public
{-# COMPILE AGDA2HS NoneErasedNewt newtype #-}
