module RuntimeCheckFeatures (noneErasedFun, simpleFunCaller, Dat(NoneErasedCon), Rec(recFst, recSnd), Newt(theField), NoneErasedNewt(noneErasedField, NoneErasedNewt), RuntimeCheckFeatures.simpleFun, RuntimeCheckFeatures.fun, RuntimeCheckFeatures.fun', RuntimeCheckFeatures.scCon, RuntimeCheckFeatures.scRec, RuntimeCheckFeatures.scNewt) where

import Haskell.Extra.Dec.Instances (decIsFalse, decIsTrue)
import Numeric.Natural (Natural)

import RuntimeCheckFeatures.PostRtc

simpleFun :: Natural -> Natural
simpleFun x
  | decIsTrue (x > 0) = RuntimeCheckFeatures.PostRtc.simpleFun x
  | otherwise = error "Runtime check failed: decIsTrue (x > 0)"

fun :: Natural -> (Natural -> Natural) -> Natural
fun x a0 = RuntimeCheckFeatures.PostRtc.fun x (go0 a0)
  where
    go0 up y
      | decIsTrue (x > 0) && decIsFalse (x < y) = up y
      | not (decIsTrue (x > 0)) =
        error "Runtime check failed: decIsTrue (x > 0)"
      | otherwise = error "Runtime check failed: decIsFalse (x < y)"

fun' :: (Natural -> (Natural -> Natural) -> Natural) -> Natural
fun' a0 = RuntimeCheckFeatures.PostRtc.fun' (go1 a0)
  where
    go1 up x a1
      | decIsTrue (x > 0) = up x (go0 a1)
      | otherwise = error "Runtime check failed: decIsTrue (x > 0)"
      where
        go0 up y
          | decIsFalse (x < y) = up y
          | otherwise = error "Runtime check failed: decIsFalse (x < y)"

scCon :: ((Natural -> Natural) -> Natural) -> Dat
scCon a0 = Con (\ a1 -> a0 (go0 a1))
  where
    go0 up x
      | decIsTrue (x > 0) = up x
      | otherwise = error "Runtime check failed: decIsTrue (x > 0)"

scRec :: Natural -> (Natural -> Natural -> Natural) -> Rec
scRec recFst recSnd
  = Rec recFst (\ a0 a1 -> recSnd (go0 a0) (go1 a1))
  where
    go0 up
      | decIsTrue (recFst > 0) = up
      | otherwise = error "Runtime check failed: decIsTrue (recFst > 0)"
    go1 up
      | decIsTrue (recFst < 5) = up
      | otherwise = error "Runtime check failed: decIsTrue (recFst < 5)"

scNewt :: ((Natural -> Natural) -> Natural -> Natural) -> Newt
scNewt theField = Newt (go1 theField)
  where
    go1 up f y
      | decIsTrue (f (y + 1) > 0) = up (go0 f) y
      | otherwise =
        error "Runtime check failed: decIsTrue (f (y + 1) > 0)"
      where
        go0 up x
          | decIsTrue (x > 0) = up x
          | otherwise = error "Runtime check failed: decIsTrue (x > 0)"

