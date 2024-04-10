module RuntimeCheckFeatures.PostRtc where

import Haskell.Extra.Dec.Instances (decIsFalse, decIsTrue)
import Numeric.Natural (Natural)

noneErasedFun :: Natural -> Natural
noneErasedFun _ = 1

noDecInstance :: Natural -> Natural
noDecInstance x = 0

simpleFun :: Natural -> Natural
simpleFun _ = 0

simpleFunCaller :: Natural
simpleFunCaller = simpleFun 1

fun :: Natural -> (Natural -> Natural) -> Natural
fun _ _ = 0

fun' :: (Natural -> (Natural -> Natural) -> Natural) -> Natural
fun' _ = 0

data Dat = Con ((Natural -> Natural) -> Natural)
         | NoneErasedCon Natural

data Rec = Rec{recFst :: Natural,
               recSnd :: Natural -> Natural -> Natural}

newtype Newt = Newt{theField ::
                    (Natural -> Natural) -> Natural -> Natural}

newtype NoneErasedNewt = NoneErasedNewt{noneErasedField :: Natural}

