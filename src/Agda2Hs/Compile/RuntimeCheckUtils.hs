{-# LANGUAGE OverloadedStrings #-}

module Agda2Hs.Compile.RuntimeCheckUtils (emitsRtc, importDec, checkNoneErased, smartConstructor, RtcResult (..), checkRtc) where

import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty (prettyShow)
import qualified Agda.Syntax.Concrete as AC
import Agda.Syntax.Concrete.Definitions (niceDeclarations)
import Agda.Syntax.Concrete.Definitions.Monad (NiceEnv (NiceEnv), runNice)
import qualified Agda.Syntax.Concrete.Name as AN
import Agda.Syntax.Internal
import Agda.Syntax.Position (noRange)
import Agda.Syntax.Translation.ConcreteToAbstract (ToAbstract (toAbstract))
import Agda.TypeChecking.InstanceArguments (findInstance)
import Agda.TypeChecking.MetaVars (newInstanceMeta, newLevelMeta)
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty (PrettyTCM (prettyTCM), (<+>))
import Agda.TypeChecking.Reduce (instantiate)
import Agda.TypeChecking.Substitute (telView', theTel)
import Agda.TypeChecking.Telescope (splitTelescopeAt)
import Agda.Utils.Impossible (__IMPOSSIBLE__)
import Agda.Utils.List (initLast)
import qualified Agda.Utils.List1 as List1
import Agda.Utils.Monad (unless)
import Agda.Utils.Tuple (mapSnd)
import Agda2Hs.Compile.Term (compileTerm)
import Agda2Hs.Compile.Types (C, rtc)
import Agda2Hs.Compile.Utils
import Agda2Hs.HsUtils
import Control.Monad.Except (catchError)
import Control.Monad.Reader (asks)
import Control.Monad.State (StateT (StateT), modify, put, runStateT)
import Data.Functor ((<&>))
import Data.List (intersect, partition, zip4)
import Data.Map (empty)
import Data.Maybe (catMaybes, fromJust, isJust)
import Data.Tuple (swap)
import qualified Language.Haskell.Exts as Hs

-- Import Haskell.Extra.Dec{,.Instances}
importDec :: TCM ()
importDec = do
  let haskellExtra = AN.Qual (AC.simpleName "Haskell") . AN.Qual (AC.simpleName "Extra")
      directives = ImportDirective noRange UseEverything [] [] Nothing
      importDecl q = [AC.Import noRange (haskellExtra q) Nothing AC.DontOpen directives]
      run ds = case fst $ runNice (NiceEnv True) $ niceDeclarations empty $ importDecl ds of
        Left _ -> __IMPOSSIBLE__
        Right ds -> toAbstract ds
  run $ AC.QName $ AC.simpleName "Dec"
  run $ AN.Qual (AC.simpleName "Dec") $ AC.QName $ AC.simpleName "Instances"
  return ()

-- Retrieve constructor name and generated smart constructor qname.
-- Takes extra argument whether one additional name should be stripped
smartConstructor :: QName -> Bool -> C QName
smartConstructor qname strip1 = do
  checkNameConflict smartString
  return smartQName
  where
    qnameList = qnameToList qname
    -- e.g. data types need the name of the data type itself stripped
    strip = if strip1 then 2 else 1
    qualifier = List1.take (length qnameList - strip) qnameList
    name = List1.last qnameList
    smartString = "sc" ++ prettyShow name
    smartName = mkName (nameBindingSite name) (nameId name) smartString
    smartQName = qnameFromList $ List1.prependList qualifier $ smartName List1.:| []

-- Runtime checks are not supported for certain pragmas. Check that none are erased.
checkNoneErased :: Telescope -> Bool
checkNoneErased tel = null topLevelErased && all (checkNoneErased . snd) other
  where
    doms = telToList tel
    (topLevelErased, other) = partition (checkTopLevelErased . fst) $ zip doms $ map telify doms

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
    errs =
      zip chks $
        map
          ( \chk ->
              let msg = "Runtime check failed: " ++ Hs.prettyPrint chk
               in Hs.App () (hsVar "error") $ Hs.Lit () $ Hs.String () msg msg
          )
          chks
    (nots, otherwise) = fromJust $ initLast errs
    notChks = map (\(chk, err) -> Hs.GuardedRhs () [Hs.Qualifier () $ Hs.App () (hsVar "not") chk] err) nots
    otherwiseChk = (\(_, err) -> Hs.GuardedRhs () [Hs.Qualifier () $ hsVar "otherwise"] err) otherwise

createRtc' :: Hs.Name () -> [Hs.Pat ()] -> Hs.Rhs () -> Maybe (Hs.Binds ()) -> Hs.Decl ()
createRtc' n args rhs binds = Hs.FunBind () [Hs.Match () n args rhs binds]

type NameIndices = (Int, Int)

-- Creates a runtime check if necessary and possible, informing C accordingly.
-- Takes telescope of type to check, name, and expression on success.
checkRtc :: Telescope -> QName -> Hs.Exp () -> C RtcResult
checkRtc tel name success =
  checkRtc' (0, 0) tel
    >>= \case
      NoneErased' -> return NoneErased
      Uncheckable' -> return Uncheckable
      Checkable' {..} -> do
        tellAllCheckable name
        let rhs = eApp success theirRhs
            chkName = hsName $ prettyShow $ qnameName name
            chk = createRtc chkName theirLhs theirChks rhs $ binds theirDecls
        return $ Checkable [chk]
      . snd

-- Recursively check for runtime checkability in nested types.
-- Accumulates on name indices for `go` function and `a` argument.
-- Takes telescope of type to check.
checkRtc' :: NameIndices -> Telescope -> C (NameIndices, RtcResult')
checkRtc' idcs tel = do
  ourChks <- mapM (uncurry createGuardExp) topLevelErased
  (belowIdcs, belowChks) <- mapAccumLM checkRtc'' idcs call
  (belowIdcs,)
    <$> if all isJust belowChks && all isJust ourChks
      then
        let (theirLhs, theirRhs, decls) = unzip3 $ catMaybes belowChks
            theirDecls = concat decls
            theirChks = catMaybes ourChks
         in if null theirDecls && null ourChks
              then return NoneErased'
              else return Checkable' {..}
      else return Uncheckable'
  where
    doms = telToList tel
    telsUpTo = map (\i -> fst $ splitTelescopeAt i tel) [0 ..]
    -- Partition out arguments that are erased and at top level (those we will attempt to check)
    (topLevelErased, call) = partition (checkTopLevelErased . fst) $ zip doms telsUpTo

-- Check a single type for runtime checkability.
-- Accumulates on name indices for `go` function and `a` argument.
-- Takes domain of type and telescope up to that point for context.
-- If checkable, returns lhs and rhs at that point plus declarations from checks below.
checkRtc'' :: NameIndices -> (Dom (ArgName, Type), Telescope) -> C (NameIndices, Maybe (Hs.Pat (), Hs.Exp (), [Hs.Decl ()]))
checkRtc'' (goIdx, argIdx) (d, tUpTo) = do
  ((theirGoIdx, theirArgIdx), chk) <- addContext tUpTo (checkRtc' (goIdx, ourArgIdx) tAt)
  case chk of
    NoneErased' -> return ((theirGoIdx, theirArgIdx), Just (ourLhs, hsVar arg, []))
    Uncheckable' -> return ((theirGoIdx, theirArgIdx), Nothing)
    Checkable' {..} -> do
      let go = "go" ++ show theirGoIdx
          conflicts = tAtNames `intersect` [go, arg, up]
      unless (null conflicts) $ errorNameConflict $ head conflicts
      let rhs = hsVar up `eApp` theirRhs
          maybeRtc = createRtc (hsName go) (hsPat up : theirLhs) theirChks rhs $ binds theirDecls
          (ourGoIdx, ourRhs, ourRtc) =
            if null theirChks
              then -- inline if nothing to check at this level (consumes no `goIdx`)
                (theirGoIdx, Hs.Lambda () theirLhs $ hsVar arg `eApp` theirRhs, theirDecls)
              else (succ theirGoIdx, hsVar go `eApp` [hsVar arg], [maybeRtc])
      return ((ourGoIdx, theirArgIdx), Just (ourLhs, ourRhs, ourRtc))
  where
    tAt = telify d
    tAtNames = map (fst . unDom) $ telToList tAt
    name = fst $ unDom d
    -- Use arg name if available, otherwise insert one (consumes one on `argIdx`)
    (arg, ourArgIdx) = if name == "_" then ("a" ++ show argIdx, succ argIdx) else (name, argIdx)
    ourLhs = hsPat arg
    up = "up"

---- Small single-mention convenience functions

-- Gather telescope from domain
telify :: Dom (a, Type) -> Telescope
telify = theTel . telView' . snd . unDom

-- Check a type is erased and at top level; in this case, it should be checked.
checkTopLevelErased :: Dom (a, Type) -> Bool
checkTopLevelErased dom = case getQuantity dom of
  Quantity0 _ -> null $ telToList $ telify dom
  _ -> False

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
findDecInstances :: Type -> C (Maybe Term)
findDecInstances t =
  liftTCM $
    do
      (m, v) <- newInstanceMeta "" t
      findInstance m Nothing
      Just <$> instantiate v
      `catchError` const (return Nothing)

-- Create expression to be put in the guard
createGuardExp :: Dom (a, Type) -> Telescope -> C (Maybe (Hs.Exp ()))
createGuardExp dom telUpTo =
  addContext (setHiding Hidden <$> telUpTo) $ do
    dec <- decify $ snd $ unDom dom
    findDecInstances dec >>= traverse (compileTerm dec)

-- from GHC.Utils.Monad
mapAccumLM :: (Monad m, Traversable t) => (acc -> x -> m (acc, y)) -> acc -> t x -> m (acc, t y)
mapAccumLM f s = fmap swap . flip runStateT s . traverse f'
  where
    f' = StateT . (fmap . fmap) swap . flip f
