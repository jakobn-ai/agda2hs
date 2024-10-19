{-# LANGUAGE OverloadedStrings #-}

module Agda2Hs.Compile.RuntimeCheckUtils (importDec, checkNoneErased, smartConstructor, RtcResult (..), checkRtc) where

import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty (prettyShow)
import qualified Agda.Syntax.Concrete as AC
import Agda.Syntax.Concrete.Definitions (NiceEnv (NiceEnv), niceDeclarations, runNice)
import qualified Agda.Syntax.Concrete.Name as AN
import Agda.Syntax.Internal
import Agda.Syntax.Position (noRange)
import Agda.Syntax.Translation.ConcreteToAbstract (ToAbstract (toAbstract))
import Agda.TypeChecking.InstanceArguments (findInstance)
import Agda.TypeChecking.MetaVars (newInstanceMeta, newLevelMeta)
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty (PrettyTCM (prettyTCM), text, (<+>))
import Agda.TypeChecking.Records (projectTyped)
import Agda.TypeChecking.Reduce (instantiate)
import Agda.TypeChecking.Substitute (telView', theTel)
import Agda.TypeChecking.Telescope (splitTelescopeAt)
import Agda.Utils.Impossible (__IMPOSSIBLE__)
import Agda.Utils.List (initLast)
import qualified Agda.Utils.List1 as List1
import Agda.Utils.Monad (allM, partitionM)
import Agda2Hs.Compile.Term (compileTerm)
import Agda2Hs.Compile.Type (DomOutput (DODropped), compileDom)
import Agda2Hs.Compile.Types (C)
import Agda2Hs.Compile.Utils
import Agda2Hs.HsUtils
import Control.Monad (ap, filterM, unless)
import Control.Monad.Except (catchError)
import Control.Monad.State (StateT (StateT, runStateT))
import Data.List (intersect)
import Data.Map (empty)
import Data.Maybe (catMaybes, fromJust, isJust)
import Data.Tuple (swap)
import qualified Language.Haskell.Exts as Hs

-- Import Haskell.Extra.Dec{,.Instances}
-- based on Agda.Syntax.Translation.ConcreteToAbstract.importPrimitives
importDec :: TCM ()
importDec = do
  let haskellExtra = AN.Qual (AC.simpleName "Haskell") . AN.Qual (AC.simpleName "Extra")
      dec = AC.simpleName "Dec"
      directives = ImportDirective noRange UseEverything [] [] Nothing
      importDecl q = [AC.Import noRange (haskellExtra q) Nothing AC.DontOpen directives]
      run ds = case fst $ runNice (NiceEnv True) $ niceDeclarations empty $ importDecl ds of
        Left _ -> __IMPOSSIBLE__
        Right ds -> toAbstract ds
  run $ AC.QName dec
  run $ AN.Qual dec $ AC.QName $ AC.simpleName "Instances"
  return ()

-- Retrieve constructor name and generated smart constructor qname.
-- Takes extra argument whether one additional name should be stripped
smartConstructor :: QName -> Bool -> C QName
smartConstructor qname strip1 = do
  checkNameConflict smartString
  return smartQName
  where
    qnameList = qnameToList qname
    -- data types need the name of the data type itself stripped
    strip = if strip1 then 2 else 1
    qualifier = List1.take (length qnameList - strip) qnameList
    name = List1.last qnameList
    smartString = "sc" ++ prettyShow name
    smartName = mkName (nameBindingSite name) (nameId name) smartString
    smartQName = qnameFromList $ List1.prependList qualifier $ smartName List1.:| []

-- Runtime checks are not supported for certain pragmas.
-- Check that the telescope has no erased types.
checkNoneErased :: Telescope -> C Bool
checkNoneErased tel = do
  let doms = telToList tel
  (topLevelErased, other) <- partitionM (checkTopLevelErased' . fst) $ zip doms $ map domToTel doms
  (null topLevelErased &&) <$> allM other (checkNoneErased . snd)

-- External runtime check result
data RtcResult
  = NoneErased
  | Uncheckable
  | Checkable [Hs.Decl ()]

-- Internal runtime check result
data RtcResult'
  = NoneErased'
  | Uncheckable'
  | -- The actual runtime check is assembled in the caller receiving an RtcResult',
    -- because the logic at the top level is different, e.g. the declarations are
    -- put in a `where` instead of being flattened.
    Checkable'
      { theirLhs :: [Hs.Pat ()],
        theirChks :: [Hs.Exp ()],
        theirRhs :: [Hs.Exp ()],
        theirDecls :: [Hs.Decl ()]
      }

-- Check name induces no conflict
checkNameConflict :: String -> C ()
checkNameConflict s =
  testResolveStringName s >>= \case
    Just _ -> errorNameConflict s
    Nothing -> return ()

errorNameConflict :: String -> C ()
errorNameConflict s =
  genericDocError
    =<< ("Illegal name" <+> prettyTCM s)
      <> ", conflicts with name generated for runtime checks."

-- Create runtime check.
-- Takes function name, lhs patterns, expressions for checks, expression on success, and optionally `where` binds
createRtc :: Hs.Name () -> [Hs.Pat ()] -> [Hs.Exp ()] -> Hs.Exp () -> Maybe (Hs.Binds ()) -> Hs.Decl ()
createRtc n args [] success = createRtc' n args $ Hs.UnGuardedRhs () success
createRtc n args chks success =
  createRtc' n args rhs
  where
    rhs = Hs.GuardedRhss () $ Hs.GuardedRhs () [Hs.Qualifier () andChks] success : notChks ++ [otherwiseChk]
    andChks = foldr1 (\c -> Hs.InfixApp () c $ Hs.QVarOp () $ Hs.UnQual () $ Hs.Symbol () "&&") chks
    chk2err chk =
      let msg = "Runtime check failed: " ++ Hs.prettyPrint chk
       in Hs.App () (hsVar "error") $ Hs.Lit () $ Hs.String () msg msg
    errs = zip chks $ map chk2err chks
    (nots, otherwise) = fromJust $ initLast errs
    notChks = map (\(chk, err) -> Hs.GuardedRhs () [Hs.Qualifier () $ Hs.App () (hsVar "not") chk] err) nots
    otherwiseChk = (\(_, err) -> Hs.GuardedRhs () [Hs.Qualifier () $ hsVar "otherwise"] err) otherwise

createRtc' :: Hs.Name () -> [Hs.Pat ()] -> Hs.Rhs () -> Maybe (Hs.Binds ()) -> Hs.Decl ()
createRtc' n args rhs binds = Hs.FunBind () [Hs.Match () n args rhs binds]

{- Suffixes for `go` functions in the `where` declaration for nested
erased arguments and `a` arguments for unnamed arguments.
Example to show all cases:

Turning

horrible : (((x : Nat) ⦃@0 _ : IsTrue (x > 0)⦄ → ((y : Nat) ⦃@0 _ : IsFalse (x < y)⦄ → Nat) → Nat) → Nat) → Nat

into

horrible a0 = PostRtc.horrible (\ a1 -> a0 (go1 a1))
  where
    go1 up x a2
      | decIsTrue (x > 0) = up x (go0 a2)
      | otherwise = error "Runtime check failed: decIsTrue (x > 0)"
      where
        go0 up y
          | decIsFalse (x < y) = up y
          | otherwise = error "Runtime check failed: decIsFalse (x < y)"

has a tree of
((x : Nat) ⦃…⦄ → ((y : Nat) ⦃…⦄ → Nat) → Nat) → Nat ~ (0, 0)
Reserve a0 for (Nat → (Nat → Nat) → Nat) → Nat:
  (x : Nat) ⦃…⦄ → ((y : Nat) ⦃…⦄ → Nat) → Nat ~ (0, 1)
Reserve a1 for Nat → (Nat → Nat) → Nat:
    (y : Nat) ⦃…⦄ → Nat ~ (0, 2)
Reserve a2 for Nat → Nat:
      (y : Nat) ~ (0, 3)
      ~ (0, 3)
Reserve go0 for (Nat → Nat) → Nat → Nat:
    ~ (1, 3)
Reserve go1 for (Nat → (Nat → Nat) → Nat) → Nat → (Nat → Nat) → Nat:
  ~ (2, 3)
Do not reserve a `go` function because we can inline:
~ (2, 3)
-}
type NameIndices = (Int, Int)

-- Creates a runtime check if necessary and possible, informing C accordingly.
-- Takes telescope of type to check, name, and expression on success.
checkRtc :: Telescope -> QName -> Hs.Exp () -> C RtcResult
checkRtc tel name success = do
  (_, chk) <- checkRtc' (0, 0) tel
  case chk of
    NoneErased' -> return NoneErased
    Uncheckable' -> return Uncheckable
    Checkable' {..} -> do
      tellAllCheckable name
      let rhs = eApp success theirRhs
          chkName = hsName $ prettyShow $ qnameName name
          chk = createRtc chkName theirLhs theirChks rhs $ binds theirDecls
      return $ Checkable [chk]

-- Recursively check for runtime checkability in nested types.
-- Accumulates on name indices for `go` function and `a` argument.
-- Takes telescope of type to check.
checkRtc' :: NameIndices -> Telescope -> C (NameIndices, RtcResult')
checkRtc' idcs tel = do
  -- Partition out arguments that are erased and at top level (those we will attempt to check)
  (topLevelErased, call) <- partitionM (checkTopLevelErased' . (\(d, _, _) -> d)) $ zip3 doms telsUpTo telsUpToIncluding

  -- slightly awkward extract of record types in arguments, their types,
  -- telescope up to and including (!) them, and their erased field QNames
  -- TODO consider zip instead
  let defTeTyTel = map (\(ty, _, tel) -> let te = snd $ unDom ty in (unEl te, te, tel)) call
      defTTTQNames = [(ttt, q) | ttt@(Def q _, _, _) <- defTeTyTel]
  defTermsDefs <- (\(ttt, q) -> (ttt,) . theDef <$> getConstInfo q) `mapM` defTTTQNames
  let recTTTFields = [(ttt, _recFields d) | (ttt, RecordDefn d) <- defTermsDefs]
  recTTTFieldsTypes <-
    (\(ttt, qs) -> (ttt,) <$> mapM (\q -> (unDom q,) . (defType <$>) <$> mapM getConstInfo q) qs)
      `mapM` recTTTFields
  recTTTErasedFields <-
    (\(ttt, qs) -> (ttt,) . map fst <$> filterM (checkTopLevelErased . snd) qs) `mapM` recTTTFieldsTypes

  applied <-
    (\((te, ty, tel), qs) -> (((,tel) <$>) . projectTyped te ty ProjPostfix) `mapM` qs)
    `mapM` recTTTErasedFields
  let erasedRecFields = [(t, tel) | (Just (_, _, t), tel) <- concat applied]
  reportSDoc "" 1 $ prettyTCM erasedRecFields

  recChks <- uncurry createGuardExp `mapM` erasedRecFields
  reportSDoc "" 1 $ text $ show recChks

  ourChks' <- (\(d, t, _) -> createGuardExp (snd $ unDom d) t) `mapM` topLevelErased
  let ourChks = ourChks' ++ recChks
  -- Recursively accumulate checks on arguments below top level
  (belowIdcs, belowChks) <- mapAccumLM checkRtc'' idcs $ map (\(d, t, _) -> (d, t)) call
  (belowIdcs,)
    <$> if not (all isJust belowChks && all isJust ourChks)
      then return Uncheckable'
      else -- all checkable or none erased
        let (theirLhs, theirRhs, decls) = unzip3 $ catMaybes belowChks
            theirDecls = concat decls
            -- all checks below found an instance
            theirChks = catMaybes ourChks
         in if null theirDecls && null ourChks
              then return NoneErased'
              else return Checkable' {..}
  where
    doms = telToList tel
    telSplit tele = map $ \i -> fst $ splitTelescopeAt i tele
    telsUpTo = telSplit tel [0 ..]
    telsUpToIncluding = telSplit tel [1 ..]

-- Check a single type for runtime checkability.
-- Accumulates on name indices for `go` function and `a` argument.
-- Takes domain of type and telescope up to that point for context.
-- If checkable, returns lhs and rhs at that point plus declarations from checks below.
checkRtc'' :: NameIndices -> (Dom (ArgName, Type), Telescope) -> C (NameIndices, Maybe (Hs.Pat (), Hs.Exp (), [Hs.Decl ()]))
checkRtc'' (goIdx, argIdx) (d, tUpTo) =
  -- Mutual recursion with checkRtc'
  addContext tUpTo (checkRtc' (goIdx, ourArgIdx) tAt) >>= \case
    (idcs, NoneErased') -> return (idcs, Just (ourLhs, argVar, []))
    (idcs, Uncheckable') -> return (idcs, Nothing)
    ((theirGoIdx, theirArgIdx), Checkable' {..}) -> do
      let go = "go" ++ show theirGoIdx
          conflicts = tAtNames `intersect` [go, arg, up]
      unless (null conflicts) $ errorNameConflict $ head conflicts
      let (ourGoIdx, ourRhs, ourRtc) =
            if null theirChks
              then -- inline if nothing to check at this level (consumes no `goIdx`)
              -- e.g. `\ a1 -> a0 (go1 a1)`, continuing the example above `NameIndices`
                (theirGoIdx, Hs.Lambda () theirLhs $ argVar `eApp` theirRhs, theirDecls)
              else
                let -- e.g. `up x a2`
                    lhs = hsPat up : theirLhs
                    -- e.g. `up x (go0 a2)`
                    rhs = hsVar up `eApp` theirRhs
                    rtc = createRtc (hsName go) lhs theirChks rhs $ binds theirDecls
                 in -- e.g. `go1 a1`
                    (succ theirGoIdx, hsVar go `eApp` [argVar], [rtc])
      return ((ourGoIdx, theirArgIdx), Just (ourLhs, ourRhs, ourRtc))
  where
    tAt = domToTel d
    tAtNames = map (fst . unDom) $ telToList tAt
    name = fst $ unDom d
    -- Use arg name if available, otherwise insert one (consumes one on `argIdx`)
    (arg, ourArgIdx) = if name == "_" then ("a" ++ show argIdx, succ argIdx) else (name, argIdx)
    ourLhs = hsPat arg
    argVar = hsVar arg
    up = "up"

---- Small convenience functions

-- Gather telescope from domain
domToTel :: Dom (a, Type) -> Telescope
domToTel = theTel . telView' . snd . unDom

-- Check a type is erased and at top level; in this case, it should be checked.
checkTopLevelErased :: Dom Type -> C Bool
checkTopLevelErased = ((DODropped ==) <$>) . compileDom

-- Convenience variant for Dom (a, Type)
checkTopLevelErased' :: Dom (a, Type) -> C Bool
checkTopLevelErased' = checkTopLevelErased . (snd <$>)

-- Create binds from declarations except when empty
binds :: [Hs.Decl ()] -> Maybe (Hs.Binds ())
binds [] = Nothing
binds decls = Just $ Hs.BDecls () decls

-- Turn a type into its Dec version
decify :: Type -> C Type
decify t = do
  dec <- resolveStringName "Haskell.Extra.Dec.Dec"
  level <- liftTCM newLevelMeta
  let vArg = defaultArg
      hArg = setHiding Hidden . vArg
  return $ t {unEl = Def dec $ map Apply [hArg $ Level level, vArg $ unEl t]}

-- Failably find instances for decidable terms
findDecInstances :: Type -> TCMT IO (Maybe Term)
findDecInstances t =
  do
    (m, v) <- newInstanceMeta "" t
    findInstance m Nothing
    Just <$> instantiate v
    `catchError` return (return Nothing)

-- Create expression to be put in the guard
createGuardExp :: Type -> Telescope -> C (Maybe (Hs.Exp ()))
createGuardExp ty telUpTo = addContext telUpTo $ do
  dec <- decify ty
  reportSDoc "" 1 $ prettyTCM dec
  res <- liftTCM $ findDecInstances dec
  reportSDoc "" 1 $ "have res?" <+> prettyTCM res
  compileTerm dec `mapM` res

-- from GHC.Utils.Monad
mapAccumLM :: (Monad m, Traversable t) => (acc -> x -> m (acc, y)) -> acc -> t x -> m (acc, t y)
mapAccumLM f s = fmap swap . flip runStateT s . traverse f'
  where
    f' = StateT . (fmap . fmap) swap . flip f
