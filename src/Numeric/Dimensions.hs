{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE Rank2Types, FlexibleContexts #-}
{-# LANGUAGE GADTs, TypeInType #-}
{-# LANGUAGE TypeFamilies, TypeFamilyDependencies #-}
{-# LANGUAGE MultiParamTypeClasses, MagicHash #-}
{-# LANGUAGE KindSignatures, DataKinds #-}
{-# LANGUAGE TypeOperators, FlexibleInstances, ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications, FunctionalDependencies     #-}
{-# LANGUAGE ConstraintKinds      #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Numeric.Dimensions
-- Copyright   :  (c) Artem Chirkin
-- License     :  MIT
--
-- Maintainer  :  chirkin@arch.ethz.ch
--
-- Provides a data type Idx that enumerates through multiple dimensions.
-- Lower indices go first, i.e. assumed enumeration
--          is i = i1 + i2*n1 + i3*n1*n2 + ... + ik*n1*n2*...*n(k-1).
-- This is also to encourage column-first matrix enumeration and array layout.
--
-- Some of the type-level list operations are implemented using type families
--   and weirdly duplicated for kinds k,Nat,XNat:
--   This duplication is needed to workaround some GHC bugs (panic with "no skolem info")
-----------------------------------------------------------------------------

module Numeric.Dimensions
  ( -- * Data types
    Idx (..), Dim (..), XNat, XN, N
  , SomeDim (..), someDimVal
  , Slice (..)
  , Dimensional (..), runDimensional, withDim
    -- * Operations
  , Dimensions, Dimensions' (..), Dimensions'' (..)
  , XDimensions (..)
  , inSpaceOf, asSpaceOf, order, appendIdx, splitIdx
    -- * Type-level programming
  , FixedDim, FixedXDim, KnownOrder, ValidDims
  , type (++), Length
  , type (:<), type (>:), type (:+), type (+:), Head, Tail
  , Suffix, Prefix
  , List (..), Cons, Snoc, Reverse, Take, Drop
  , EvalList, EvalCons, ToList, SimplifyList
  ) where


import Control.Arrow (first)
import GHC.TypeLits
import GHC.Prim
import GHC.Types
import GHC.Exts
import Data.Proxy
import Data.Type.Equality
-- import Data.Type.Bool

import Unsafe.Coerce

-- | Type-level dimensional indexing with arbitrary Int values inside
data Idx (ds :: [Nat]) where
   -- | Zero-rank dimensionality - scalar
   Z :: Idx '[]
   -- | List-like concatenation of indices
   (:!) :: !Int -> !(Idx ds) -> Idx (d ': ds)
infixr 5 :!

-- | Type-level dimensionality
data Dim (ds :: k) where
  -- | Zero-rank dimensionality - scalar
  D   :: Dim '[]
  -- | List-like concatenation of known dimensionality
  (:*) :: KnownNat (KnownDim d)
       => !(Proxy (KnownDim d)) -> !(Dim ds) -> Dim (d ': ds)
  -- | List-like concatenation of unknown dimensionality
  (:?) :: !SomeNat -> !(Dim ds) -> Dim (XN ': ds)
infixr 5 :*
infixr 5 :?

-- | Select a number of element from a given dimension
data Slice (n::Nat) (m::Nat) where
   Get   :: !Int -> Slice n 1
   (:&)  :: !(Slice n m) -> !Int -> Slice n (m + 1)
   Every :: Slice n n
infixl 9 :&


-- | Either known or unknown at compile-time natural number
data XNat = XN | N Nat
-- | Unknown natural number
type XN = 'XN
-- | Known natural number
type N (n::Nat) = 'N n

-- | Similar to SomeNat, hide some dimensions under an existential constructor.
data SomeDim (xns :: [XNat])
  = forall ns . ( Dimensions ns
                , ValidDims ns
                , FixedDim xns ns ~ ns
                , FixedXDim xns ns ~ xns
                ) => SomeDim (Dim ns)

-- | Construct dimensionality at runtime
someDimVal :: Dim (xns :: [XNat]) -> Maybe (SomeDim xns)
someDimVal D = Just $ SomeDim D
someDimVal xxs@(p :* xs) = do
    Refl <- isGoodDim p
    SomeDim ps <- someDimVal xs
    return $ withSuccKnown (order ps) ps
          ( \Refl -> let pps = p :* ps
                     in case ( isFixed xxs pps
                             , isXFixed xxs pps ) of
                          (Refl, Refl) -> SomeDim pps
          )
  where
    -- I know for sure that the constraint (FixedDim xns ns ~ ns) holds,
    --   but I need to convince the compiler that this is the case
    isFixed :: Dim xns -> Dim ns -> FixedDim xns ns :~: ns
    isFixed _ _ = unsafeCoerce Refl
    isXFixed :: Dim xns -> Dim ns -> FixedXDim xns ns :~: xns
    isXFixed _ _ = unsafeCoerce Refl
someDimVal (SomeNat p :? xs) = do
  Refl <- isGoodDim p
  SomeDim ps <- someDimVal xs
  return $ withSuccKnown (order ps) ps
            (\Refl -> SomeDim (p :* ps)
            )

isGoodDim :: KnownNat d => p d -> Maybe ((2 <=? d) :~: 'True)
isGoodDim p = if 2 <= natVal p then unsafeCoerce (Just Refl)
                               else unsafeCoerce Nothing


withSuccKnown :: Int
              -> p xs
              -> ( forall n . KnownNat n => (1 + Length xs) :~: n -> a)
              -> a
withSuccKnown n p g = case someNatVal (fromIntegral n) of
    Just (SomeNat m) -> g (evidence p m)
    Nothing          -> error "Something is terribly wrong. Is the length negative?"
  where
    evidence:: KnownNat m => p xs -> q m -> (1 + Length xs) :~: m
    evidence _ _ = unsafeCoerce Refl


-- | Fix runtime-obtained dimensions for use in some function
withDim :: Dim (xns :: [XNat])
        -> (forall ns . ( Dimensions ns
                        , FixedDim xns ns ~ ns
                        , FixedXDim xns ns ~ xns
                        )  => Dim ns -> a)
        -> Either String a
withDim xds f = case someDimVal xds of
  Just (SomeDim ds) -> Right $ f ds
  Nothing -> Left "Could not extract runtime naturals to construct dimensions."

-- | Provide runtime-known dimensions and execute inside functions
--   that require compile-time-known dimensions.
newtype Dimensional (xns :: [XNat]) a = Dimensional
  { _runDimensional ::
      forall ns . ( Dimensions ns
                  , FixedDim xns ns ~ ns
                  , FixedXDim xns ns ~ xns
                  ) => Dim ns -> a
  }

-- | Run Dimension-enabled computation with dimensionality known at runtime
runDimensional :: Dim xns
               -> Dimensional xns a
               -> Either String a
runDimensional xds d = withDim xds $ _runDimensional d

--------------------------------------------------------------------------------
-- * Dimension-enabled operations
--------------------------------------------------------------------------------

-- -- | Data types that can be parametrized by dimenions
-- --    - either compile-time or run-time
-- class PreservingDim (xns :: [XNat])
--                     (a :: [Nat] -> Type)
--                     (xa :: [XNat] -> Type)
--                    | a -> xa, xa -> a where
--   -- | Apply a function that requires a dixed dimension
--   withShape :: xa xns
--             -> (forall ns . ( Dimensions ns
--                             , FixedDim xns ns ~ ns
--                             , FixedXDim xns ns ~ xns
--                             ) => a ns -> b)
--             -> b
--   -- | Put some of dimensions into existential data type
--   looseDims :: ( FixedXDim xns ns ~ xns
--                , FixedDim xns ns ~ ns
--                , XDimensions ns xns
--                , Dimensions ns
--                ) => a ns -> xa xns

-- | The main constraint type.
--   With this we are sure that all dimension values are known at compile time,
--   plus we have all handy functions for `Dim` and `Idx` types.
type Dimensions xs = ( KnownDims xs
                     , KnownOrder xs
                     , Dimensions' xs
                     , Dimensions'' xs)

-- | Length of a dimension list
order :: KnownOrder xs => t xs -> Int
order = fromInteger . natVal . f
  where
    f :: t xs -> Proxy (Length xs)
    f _ = Proxy
{-# INLINE order #-}

class Dimensions' (ds :: [Nat]) where
  -- | Dimensionality of our space
  dim :: Dim ds

class XDimensions (ds :: [Nat]) (xds :: [XNat]) where
  -- | Loose compile-time information about dimensionalities
  xdim :: FixedXDim xds ds ~ xds => p ds -> Dim xds

-- | Support for Idx GADT
class Dimensions' ds => Dimensions'' (ds :: [Nat]) where
  -- | Total number of elements - product of all dimension sizes (unboxed)
  totalDim :: t ds -> Int
  -- | Run a primitive loop over all dimensions (1..n)
  loopS  :: Idx  ds -> (Idx  ds -> State# s -> State# s) -> State# s -> State# s
  -- | Run a loop over all dimensions keeping a boxed accumulator (1..n)
  loopA  :: Idx  ds -> (Idx  ds -> a -> a) -> a -> a
  -- | Run a loop in a reverse order n..1
  loopReverse :: Idx ds -> (Idx  ds -> a -> a) -> a -> a
  -- | Get index offset: i1 + i2*n1 + i3*n1*n2 + ...
  ioffset   :: Idx ds -> Int
  -- | Drop a number of dimensions
  dropDims  :: KnownNat n => Proxy n -> Idx ds -> Idx (EvalList (Drop n ds))
  -- | Take a number of dimensions
  takeDims  :: KnownNat n => Proxy n -> Idx ds -> Idx (EvalList (Take n ds))
  -- | Maximum values of all dimensions
  dimMax    :: Idx ds
  -- | Minimum values -- ones
  dimMin    :: Idx ds
  -- | For Enum
  succIdx   :: Idx ds -> Idx ds
  -- | For Enum
  predIdx   :: Idx ds -> Idx ds
  -- | For Enum
  fromIdx   :: Idx ds -> Int
  -- | For Enum
  toIdx     :: Int -> Idx ds
  -- | For Enum -- step dimension index by an Integer offset
  stepIdx   :: Int -> Idx ds -> Idx ds
  -- | For Enum -- difference in offsets between two Indices
  --      (a `diffIdx` b) = a - b
  diffIdx   :: Idx ds -> Idx ds -> Int

-- | Similar to `const` or `asProxyTypeOf`;
--   to be used on such implicit functions as `dim`, `dimMax`, etc.
inSpaceOf :: a ds -> b ds -> a ds
inSpaceOf x _ = x
{-# INLINE inSpaceOf #-}

asSpaceOf :: a ds -> (b ds -> c) -> (b ds -> c)
asSpaceOf _ = id
{-# INLINE asSpaceOf #-}

--------------------------------------------------------------------------------
-- Some important instances
--------------------------------------------------------------------------------

instance Show (Idx ds) where
  show Z = "Idx Ø"
  show xs = "Idx" ++ foldr (\i s -> " " ++ show i ++ s) "" (idxToList xs)

instance Dimensions'' ds => Show (Dim ds) where
  show D = "Dim Ø"
  show xs = "Dim" ++ foldr (\i s -> " " ++ show i ++ s) ""
    (idxToList $ dimMax `inSpaceOf` xs)

instance Show (SomeDim xns) where
  show (SomeDim p) = show p

instance Show (Dim (xds :: [XNat])) where
  show d = case someDimVal d of
    Nothing -> "Unknown dim"
    Just sd -> show sd

instance Functor (Dimensional xns) where
  fmap f d = Dimensional (f . _runDimensional d)
  {-# INLINE fmap #-}
instance Applicative (Dimensional xns) where
  pure x = Dimensional $ const x
  {-# INLINE pure #-}
  f <*> v = Dimensional $ \d -> _runDimensional f d (_runDimensional v d)
  {-# INLINE (<*>) #-}
instance Monad (Dimensional xns) where
  return  = pure
  {-# INLINE return #-}
  m >>= k = Dimensional $ \d -> _runDimensional (k $ _runDimensional m d) d
  {-# INLINE (>>=) #-}


idxToList :: Idx ds -> [Int]
idxToList Z = []
idxToList (x :! xs) = x : idxToList xs

idxFromList :: [Int] -> Idx ds
idxFromList [] = unsafeCoerce Z
idxFromList (x:xs) = unsafeCoerce $ x :! unsafeCoerce (idxFromList xs)

instance Eq (Idx ds) where
  Z == Z = True
  (a:!as) == (b:!bs) = a == b && as == bs
  Z /= Z = False
  (a:!as) /= (b:!bs) = a /= b || as /= bs

instance Eq (Dim ds) where
  D == D = True
  (_:*as) == (_:*bs) = as == bs
  (a:?as) == (b:?bs) = a == b && as == bs
  (a:*as) == (b:?bs) = SomeNat a == b && as == bs
  (a:?as) == (b:*bs) = a == SomeNat b && as == bs

-- | With this instance we can slightly reduce indexing expressions
--   e.g. x ! (1 :! 2 :! 4) == x ! (1 :! 2 :! 4 :! Z)
instance Num (Idx '[n]) where
  (a:!Z) + (b:!Z) = (a+b) :! Z
  (a:!Z) - (b:!Z) = (a-b) :! Z
  (a:!Z) * (b:!Z) = (a*b) :! Z
  signum (a:!Z)   = signum a :! Z
  abs (a:!Z)      = abs a :! Z
  fromInteger i   = fromInteger i :! Z

-- Disable this because it causes Nat ambiguity when being used
-- instance Num (Slice n 1) where
--   Get a + Get b = Get (a+b)
--   _ + _ = Get 1
--   Get a - Get b = Get (a-b)
--   _ - _ = Get 1
--   Get a * Get b = Get (a*b)
--   _ * _ = Get 1
--   signum (Get a) = Get $ signum a
--   signum x       = x
--   abs (Get a)    = Get $ abs a
--   abs x          = x
--   fromInteger i  = Get $ fromInteger i


instance Ord (Idx ds) where
  compare Z Z = EQ
  compare (a:!as) (b:!bs) = compare as bs `mappend` compare a b

instance Ord (Dim ds) where
  compare D D = EQ
  compare (_:*as) (_:*bs) = compare as bs
  compare (a:?as) (b:?bs) = compare as bs `mappend` compare a b
  compare (a:?as) (b:*bs) = compare as bs `mappend` compare a (SomeNat b)
  compare (a:*as) (b:?bs) = compare as bs `mappend` compare (SomeNat a) b

instance Dimensions' ds => Bounded (Dim ds) where
  maxBound = dim
  {-# INLINE maxBound #-}
  minBound = dim
  {-# INLINE minBound #-}

instance Dimensions'' ds => Bounded (Idx ds) where
  maxBound = dimMax
  {-# INLINE maxBound #-}
  minBound = dimMin
  {-# INLINE minBound #-}

instance Dimensions'' ds => Enum (Idx ds) where
  succ = succIdx
  {-# INLINE succ #-}
  pred = predIdx
  {-# INLINE pred #-}
  toEnum = toIdx
  {-# INLINE toEnum #-}
  fromEnum = fromIdx
  {-# INLINE fromEnum #-}
  enumFrom x = take (diffIdx maxBound x + 1) $ iterate succ x
  {-# INLINE enumFrom #-}
  enumFromTo x y | x >= y    = take (diffIdx x y + 1) $ iterate pred x
                 | otherwise = take (diffIdx y x + 1) $ iterate succ x
  {-# INLINE enumFromTo #-}
  enumFromThen x x' = take n $ iterate (stepIdx dn) x
    where
      dn = diffIdx x' x
      n  = 1 + if dn == 0 then 0
                          else if dn > 0 then diffIdx maxBound x `div` dn
                                         else diffIdx x minBound `div` negate dn
  {-# INLINE enumFromThen #-}
  enumFromThenTo x x' y = take n $ iterate (stepIdx dn) x
    where
      dn = diffIdx x' x
      n  = 1 + if dn == 0 then 0
                          else diffIdx y x `div` dn
  {-# INLINE enumFromThenTo #-}


instance IsList (Idx ds) where
  type Item (Idx ds) = Int
  fromList = idxFromList
  toList = idxToList

-- | Get the first dimension
headDim :: t (d ': ds :: [k]) -> Proxy d
headDim _ = Proxy


instance Dimensions' ('[] :: [Nat]) where
  dim = D
  {-# INLINE dim #-}

instance ( KnownOrder (d ': ds)
         , KnownDims (d ': ds)
         , Dimensions' ds
         )  => Dimensions' ((d ': ds) :: [Nat]) where
  dim = Proxy :* dim
  {-# INLINE dim #-}

instance XDimensions ns '[] where
  xdim _ = D
  {-# INLINE xdim #-}

instance ( XDimensions ns xs
         , KnownNat n
         ) => XDimensions (n ': ns) (XN ': xs) where
  xdim _ = case someNatVal (natVal $ Proxy @n) of
    Just sv -> sv :? xdim (Proxy @ns)
    Nothing -> error "Impossible happend: someNatVal (natVal n) == Nothing!"
  {-# INLINE xdim #-}

instance ( XDimensions ns xs
         , KnownNat n
         ) => XDimensions (n ': ns) (N n ': xs) where
  xdim _ = Proxy @n :* xdim (Proxy @ns)
  {-# INLINE xdim #-}


instance Dimensions'' ('[] :: [Nat]) where
  totalDim _ = 1
  {-# INLINE totalDim #-}
  loopS _ f = f Z
  {-# INLINE loopS #-}
  loopA _ f = f Z
  {-# INLINE loopA #-}
  loopReverse _ f = f Z
  {-# INLINE loopReverse #-}
  ioffset _ = 0
  {-# INLINE ioffset #-}
  dropDims _ Z = unsafeCoerce Z
  {-# INLINE dropDims #-}
  takeDims _ Z = unsafeCoerce Z
  {-# INLINE takeDims #-}
  dimMax = Z
  {-# INLINE dimMax #-}
  dimMin = Z
  {-# INLINE dimMin #-}
  succIdx = id
  {-# INLINE succIdx #-}
  predIdx = id
  {-# INLINE predIdx #-}
  fromIdx _ = 0
  {-# INLINE fromIdx #-}
  toIdx _ = Z
  {-# INLINE toIdx #-}
  stepIdx _ = id
  {-# INLINE stepIdx #-}
  diffIdx _ _ = 0
  {-# INLINE diffIdx #-}

instance ( Dimensions'' ds
         , KnownDims (d ': ds)
         , KnownOrder (d ': ds)
         )
          => Dimensions'' (d ': ds) where
  totalDim _ = fromIntegral (natVal (Proxy @d))
             * totalDim (Proxy @ds)
  {-# INLINE totalDim #-}
  loopS (n:!Z) f = loop1 n (\i -> f (i:!Z))
  loopS (n:!ns) f = loopS ns (\js -> loop1 n (\i -> f (i:!js)))
  {-# INLINE loopS #-}
  loopA (n:!Z) f = loopA1 n (f . (:!Z))
  loopA (n:!ns) f = loopA ns (\js -> loopA1 n (f . (:!js)))
  {-# INLINE loopA #-}
  loopReverse (n:!Z) f = loopReverse1 n (f . (:!Z))
  loopReverse (n:!ns) f = loopReverse ns (\js -> loopReverse1 n (f . (:!js)))
  {-# INLINE loopReverse #-}
  ioffset (i:!Z) = i
  ioffset iis@(i:!is) = i + fromIntegral (natVal' (headDim# iis)) * ioffset is
  {-# INLINE ioffset #-}
  dropDims p ds = case (fromInteger (natVal p), order ds) of
          (0, _) -> unsafeCoerce ds
          (n, k) -> if n >= k then unsafeCoerce Z
                              else f n ds
    where
      f 0 ds' = unsafeCoerce ds'
      f i (_:!ds') = unsafeCoerce (f (i-1) $ unsafeCoerce ds')
      f _ Z = unsafeCoerce Z
  {-# INLINE dropDims #-}
  takeDims p ds = case (fromInteger (natVal p), order ds) of
          (0, _) -> unsafeCoerce Z
          (n, k) -> if n >= k then unsafeCoerce ds
                              else f n ds
    where
      f 0 _ = unsafeCoerce Z
      f i (d:!ds') = unsafeCoerce $ d :! unsafeCoerce (f (i-1) $ unsafeCoerce ds')
      f _ Z = unsafeCoerce Z
  {-# INLINE takeDims #-}
  dimMax = ds
    where
      ds = fromInteger (natVal $ headDim ds) :! dimMax
  {-# INLINE dimMax #-}
  dimMin = 1 :! dimMin
  {-# INLINE dimMin #-}
  succIdx ds@(i:!is) = case fromInteger (natVal' (headDim# ds)) of
                         n -> if i == n then 1 :! succIdx is
                                        else i+1 :! is
  {-# INLINE succIdx #-}
  predIdx ds@(i:!is) = if i == 1
                       then fromInteger (natVal' (headDim# ds)) :! predIdx is
                       else i-1 :! is
  {-# INLINE predIdx #-}
  fromIdx ds@(i:!is) = i-1 + fromInteger (natVal' (headDim# ds)) * fromIdx is
  {-# INLINE fromIdx #-}
  toIdx j = r
    where
      r = case divMod j $ fromInteger (natVal' (headDim# r)) of
            (j', i) -> i+1 :! toIdx j'
  {-# INLINE toIdx #-}
  stepIdx di ds@(i:!is)
        = case divMod (di + i - 1) $ fromInteger (natVal' (headDim# ds)) of
           (0  , i') -> i'+1 :! is
           (di', i') -> i'+1 :! stepIdx di' is
  {-# INLINE stepIdx #-}
  diffIdx ds@(i1:!is1) (i2:!is2) = i1 - i2
        + fromInteger (natVal' (headDim# ds)) * diffIdx is1 is2
  {-# INLINE diffIdx #-}


appendIdx :: Idx as -> Int -> Idx (as +: b)
appendIdx Z i = i :! Z
appendIdx jjs@(j :! js) i = case proofCons jjs js of
    Refl -> unsafeCoerce $ j :! appendIdx js i
  where
    proofCons :: Idx as -> Idx bs -> as :~: (b :+ bs)
    proofCons _ _ = unsafeCoerce Refl
{-# INLINE appendIdx #-}

splitIdx :: KnownOrder as => Idx (as ++ bs) -> (Idx as, Idx bs)
splitIdx idx = rez
  where
    getAs :: (Idx as, Idx bs) -> Proxy as
    getAs _ = Proxy
    rez = splitN (order $ getAs rez) idx
    splitN :: Int -> Idx (as ++ bs) -> (Idx as, Idx bs)
    splitN 0 js = unsafeCoerce (Z, js)
    splitN n (j :! js) = first (unsafeCoerce . (j :!))
                       $ splitN (n-1) (unsafeCoerce js)
    splitN _ Z  = unsafeCoerce (Z, Z)
{-# INLINE splitIdx #-}



-- | Primitive proxy for taking head dimension
headDim# :: t (d ': ds :: [k]) -> Proxy# d
headDim# _ = proxy#
{-# INLINE headDim# #-}


-- | Do something in a loop for int i from 1 to n
loop1 :: Int -> (Int -> State# s -> State# s) -> State# s -> State# s
loop1 n f = loop' 1
  where
    loop' i s | i > n = s
              | otherwise = case f i s of s1 -> loop' (i + 1) s1
{-# INLINE loop1 #-}

-- | Do something in a loop for int i from 1 to n
loopA1 :: Int -> (Int -> a -> a) -> a -> a
loopA1 n f = loop' 1
  where
    loop' i s | i > n = s
              | otherwise = case f i s of s1 -> loop' (i + 1) s1
{-# INLINE loopA1 #-}

-- | Do something in a loop for int i from n to 1
loopReverse1 :: Int -> (Int -> a -> a) -> a -> a
loopReverse1 n f = loop' n
  where
    loop' i s | i == 0 = s
              | otherwise = case f i s of s1 -> loop' (i - 1) s1
{-# INLINE loopReverse1 #-}



--------------------------------------------------------------------------------
-- * Type-level programming
--------------------------------------------------------------------------------

-- | It is better to know the length of a dimension list and avoid infinite types.
type KnownOrder (ns :: [k]) = KnownNat (Length ns)

-- | A constraint family that makes sure all subdimensions are known.
type family KnownDims (ns :: [Nat]) :: Constraint where
  KnownDims '[] = ()
  KnownDims (x ': xs) = ( KnownNat x
                        , KnownOrder xs
                        , Dimensions' xs
                        , Dimensions'' xs
                        , KnownDims xs)

-- | Make sure all dimensions are not degenerate
type family ValidDims (ns :: [Nat]) :: Constraint where
  ValidDims '[] = ()
  ValidDims (x ': xs) = (2 <= x, ValidDims xs)


-- | Unify usage of XNat and Nat.
--   This is useful in function and type definitions.
--   Assumes a given XNat to be known at type-level (N n constructor).
type family KnownDim (x::k) :: Nat where
  KnownDim n = n
  KnownDim (N n) = n


-- | FixedDim puts very tight constraints on what list of naturals can be.
--   This allows establishing strong relations between [XNat] and [Nat].
type family FixedDim (xns :: [XNat]) (ns :: [Nat]) :: [Nat] where
  FixedDim '[] ns = '[]
  FixedDim (N n ': xs) ns = n ': FixedDim xs (Tail ns)
  FixedDim (XN  ': xs) ns = Head ns ': FixedDim xs (Tail ns)

type family FixedXDim (xns :: [XNat]) (ns :: [Nat]) :: [XNat] where
  FixedXDim xs '[] = '[]
  FixedXDim xs (n ': ns) = WrapHead n xs ': FixedXDim (Tail xs) ns

type family WrapHead (n :: Nat) (xs :: [XNat]) :: XNat where
  WrapHead x (N _ ': _) = N x
  WrapHead _ (XN  ': _) = XN
  WrapHead x '[]         = N x

-- | Synonym for a type-level cons
--     (injective, since this is just a synonym for the list constructor)
type (a :: k) :+ (as :: [k]) = a ': as
infixr 5 :+
-- | Synonym for a type-level snoc (injective!)
type (ns :: [k]) +: (n :: k) = GetSinkList (SinkFirst (n ': ns))
-- type family (ns :: [k]) +: (n :: k) = (nsn :: [k]) | nsn -> ns n where
--   xs +: x = GetListCons (SinkSnoc xs x)
infixl 5 +:



-- | List concatenation
type (as :: [k]) ++ (bs :: [k]) = EvalList ('Concat (ToList as) (ToList bs))
infixr 5 ++
-- -- | Reverse a list (injective!)
-- type Reverse (xs :: [k]) = EvalReverse ('Reverse xs)
-- -- | Drop a number of elements
-- type Drop (n::Nat) (xs :: [k]) = EvalDrop ('Drop n xs)
-- -- | Take a number of elements
-- type Take (n::Nat) (xs :: [k]) = EvalTake ('Take n xs)

-- | Type-level list operations
data List k
  = Empty
  | Cons k (List k)
  | Snoc (List k) k
  | Concat (List k) (List k)
  | Reverse (List k)
  | Drop Nat (List k)
  | Take Nat (List k)
type ListNat = List Nat
type ListXNat = List XNat

-- | Transform haskell list into a type-level list operations type List
type family ToList (xs :: [k]) = (ys :: List k) | ys -> xs where
    ToList ('[] :: [Nat]) = ('Empty :: ListNat)
    ToList ('[] :: [XNat]) = ('Empty :: ListXNat)
    ToList ('[] :: [k]) = ('Empty :: List k)
    ToList (x ': xs :: [Nat]) = ('Cons x (ToListNat xs) :: ListNat)
    ToList (x ': xs :: [XNat]) = ('Cons x (ToListXNat xs) :: ListXNat)
    ToList (x ': xs) = 'Cons x (ToList xs)

type family ToListNat (xs :: [Nat]) = (ys :: ListNat) | ys -> xs where
    ToListNat ('[] :: [Nat]) = ('Empty :: ListNat)
    ToListNat (x ': xs :: [Nat]) = ('Cons x (ToListNat xs) :: ListNat)

type family ToListXNat (xs :: [XNat]) = (ys :: ListXNat) | ys -> xs where
    ToListXNat ('[] :: [XNat]) = ('Empty :: ListXNat)
    ToListXNat (x ': xs :: [XNat]) = ('Cons x (ToListXNat xs) :: ListXNat)


-- | Evaluate a type-level operations List type into a lifted haskell list
type EvalList xs = EvalCons (SimplifyList xs)

-- | Evaluate a List into haskel list with a strong assumption that
--   the list consist only of 'Cons constructors.
type family EvalCons (xs :: List k) = (ys :: [k]) |  ys -> xs where
    EvalCons ('Empty :: ListNat) = ('[] :: [Nat])
    EvalCons ('Empty :: ListXNat) = ('[] :: [XNat])
    EvalCons ('Empty :: List k) = ('[] :: [k])
    EvalCons ('Cons x xs :: ListNat) = x ': EvalConsNat xs
    EvalCons ('Cons x xs :: ListXNat) = x ': EvalConsXNat xs
    EvalCons ('Cons x xs) = x ': EvalCons xs

type family EvalConsNat (xs :: List k) = (ys :: [k]) |  ys -> xs where
    EvalConsNat ('Empty :: ListNat) = ('[] :: [Nat])
    EvalConsNat ('Cons x xs :: ListNat) = x ': EvalConsNat xs

type family EvalConsXNat (xs :: List k) = (ys :: [k]) |  ys -> xs where
    EvalConsXNat ('Empty :: ListNat) = ('[] :: [Nat])
    EvalConsXNat ('Cons x xs :: ListNat) = x ': EvalConsXNat xs


-- x :: Proxy (EvalList (Concat '[2,6] (Drop 1 (Reverse '[2,7,89,4]))))
-- x = _

-- | This function must guarantee that result of evaluation is
--   either 'Empty or 'Cons
type family SimplifyList (xs :: List k) :: List k where
    SimplifyList 'Empty       = 'Empty
    SimplifyList ('Cons x xs) = 'Cons x (SimplifyList xs)

    SimplifyList ('Snoc 'Empty x)       = 'Cons x 'Empty
    SimplifyList ('Snoc ('Cons x xs) y) = 'Cons x (SimplifyList ('Snoc xs y))
    SimplifyList ('Snoc xs y)           = SimplifyList ('Snoc (SimplifyList xs) y)

    SimplifyList ('Concat ('Take n xs) ('Drop n xs)) = SimplifyList xs
    SimplifyList ('Concat 'Empty xs)                 = SimplifyList xs
    SimplifyList ('Concat xs 'Empty)                 = SimplifyList xs
    SimplifyList ('Concat ('Cons x xs) ys)           = 'Cons x (SimplifyList ('Concat xs ys))
    SimplifyList ('Concat xs ys)                     = SimplifyList ('Concat (SimplifyList xs) ys)

    SimplifyList ('Reverse 'Empty)          = 'Empty
    SimplifyList ('Reverse ('Concat xs ys)) = SimplifyList ('Concat ('Reverse ys) ('Reverse xs))
    SimplifyList ('Reverse ('Reverse xs))   = SimplifyList xs
    SimplifyList ('Reverse ('Snoc xs x))    = 'Cons x (SimplifyList ('Reverse xs))
    SimplifyList ('Reverse ('Cons x xs))    = SimplifyList ('Snoc ('Reverse xs) x)
    SimplifyList ('Reverse xs)              = SimplifyList ('Reverse (SimplifyList xs))

    SimplifyList ('Drop 0 xs)           = SimplifyList xs
    SimplifyList ('Drop n 'Empty)       = 'Empty
    SimplifyList ('Drop n ('Cons x xs)) = SimplifyList ('Drop (n-1) xs)
    SimplifyList ('Drop n xs)           = SimplifyList ('Drop n (SimplifyList xs))

    SimplifyList ('Take 0 _)            = 'Empty
    SimplifyList ('Take n 'Empty)       = 'Empty
    SimplifyList ('Take n ('Cons x xs)) = 'Cons x (SimplifyList ('Take (n-1) xs))
    SimplifyList ('Take n xs)           = SimplifyList ('Take n (SimplifyList xs))


--------------------------------------------------------------------------------
-- Polymorphic type-level operations (work on [k] and on List k)
--------------------------------------------------------------------------------

type family Cons (x :: k) (xs :: l k) :: List k where
    Cons x (xs :: [k])    = 'Cons x (ToList xs)
    Cons x (xs :: List k) = 'Cons x xs
    Cons _ xs = TypeError (
      'Text "Cons supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs
     )

type family Snoc (xs :: l k) (x :: k) :: List k where
    Snoc (xs :: [k]) x    = 'Snoc (ToList xs) x
    Snoc (xs :: List k) x = 'Snoc xs x
    Snoc xs _ = TypeError (
      'Text "Snoc supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs
     )

type family Concat (xs :: l k) (ys :: m k) :: List k where
    Concat (xs :: List k) (ys :: List k) = 'Concat xs ys
    Concat (xs :: [k]) (ys :: [k])       = 'Concat (ToList xs) (ToList ys)
    Concat (xs :: List k) (ys :: [k])    = 'Concat xs (ToList ys)
    Concat (xs :: [k]) (ys :: List k)    = 'Concat (ToList xs) ys
    Concat xs ys = TypeError (
      'Text "Concat supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs ':<>: 'Text " and " ':<>: 'ShowType ys
     )

type family Reverse (xs :: l k) :: List k where
    Reverse (xs :: [k])    = 'Reverse (ToList xs)
    Reverse (xs :: List k) = 'Reverse xs
    Reverse xs = TypeError (
      'Text "Reverse supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs
     )

type family Drop (n::Nat) (xs :: l k) :: List k where
    Drop n (xs :: [k])    = 'Drop n (ToList xs)
    Drop n (xs :: List k) = 'Drop n xs
    Drop n xs = TypeError (
      'Text "Drop supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs
     )

type family Take (n::Nat) (xs :: l k) :: List k where
    Take n (xs :: [k])    = 'Take n (ToList xs)
    Take n (xs :: List k) = 'Take n xs
    Take n xs = TypeError (
      'Text "Take supports types [k] and List k only"
      ':$$: 'Text "But found: " ':<>: 'ShowType xs
     )

--------------------------------------------------------------------------------
-- Tricks to make some type-level operations injective
--------------------------------------------------------------------------------


-- data ListCons k = ListSingle k | ListCons k [k]
--
-- type family GetListCons (xs :: ListCons k) = (ys :: [k]) | ys -> xs where
--   GetListCons ('ListSingle x :: ListCons k) = ('[x] :: [k])
--   GetListCons ('ListCons (y :: k) (x ': xs :: [k]) :: ListCons k) = (y ': x ': xs :: [k])


data SinkList k = SLEmpty | SLSingle k | SLCons k [k]

type family SinkFirst (xs :: [k]) = (ys :: SinkList k) | ys -> xs where
  SinkFirst ('[] :: [Nat])  = ('SLEmpty :: SinkList Nat)
  SinkFirst ('[] :: [XNat]) = ('SLEmpty :: SinkList XNat)
  SinkFirst ('[] :: [k])    = ('SLEmpty :: SinkList k)
  SinkFirst ('[x] :: [Nat])  = ('SLSingle x :: SinkList Nat)
  SinkFirst ('[x] :: [XNat]) = ('SLSingle x :: SinkList XNat)
  SinkFirst ('[x] :: [k])    = ('SLSingle x :: SinkList k)
  SinkFirst (y ': x ': xs) = 'SLCons x (GetSinkListNat (SinkFirstNat xs y))
  SinkFirst (y ': x ': xs) = 'SLCons x (GetSinkListXNat (SinkFirstXNat xs y))
  SinkFirst (y ': x ': xs) = 'SLCons x (GetSinkList (SinkFirstK xs y))

type SinkFirstNat (ns :: [Nat]) (n :: Nat) = SinkFirst (n ': ns)
type family GetSinkListNat (xs :: SinkList Nat) = (ys :: [Nat]) | ys -> xs where
  GetSinkListNat 'SLEmpty = '[]
  GetSinkListNat ('SLSingle x) = '[x]
  GetSinkListNat ('SLCons y (x ': xs)) = y ': x ': xs

type SinkFirstXNat (ns :: [XNat]) (n :: XNat) = SinkFirst (n ': ns)
type family GetSinkListXNat (xs :: SinkList XNat) = (ys :: [XNat]) | ys -> xs where
  GetSinkListXNat 'SLEmpty = '[]
  GetSinkListXNat ('SLSingle x) = '[x]
  GetSinkListXNat ('SLCons y (x ': xs)) = y ': x ': xs

type SinkFirstK (ns :: [k]) (n :: k) = SinkFirst (n ': ns)
type family GetSinkList (xs :: SinkList k) = (ys :: [k]) | ys -> xs where
  GetSinkList 'SLEmpty = '[]
  GetSinkList ('SLSingle x) = '[x]
  GetSinkList ('SLCons y (x ': xs)) = y ': x ': xs


-- x :: Proxy (('[1,2,3] +: 4) ~ '[1,2,3,4])
-- x = _

-- type family EvalSnoc (xs :: l k) (x :: k) = (ys :: ListCons k) |  ys -> xs x where
--     EvalSnoc 'Empty y = 'ListCons y 'Empty
--     EvalSnoc ('ListCons x xs) y = 'ListCons x (EvalSnoc xs y)

-- type family SinkSnoc (xs :: List k) = (ys :: List k) |  ys -> xs where
--   SinkSnoc ('Snoc 'Empty x) = 'Cons x 'Empty
--   SinkSnoc ('Snoc ('Cons x xs) y) = 'Cons x (SinkSnoc ('Snoc xs y))

-- type family SnocToCons (xs :: List k) = (ys :: List k) |  ys -> xs where
--   SnocToCons 'Empty = 'Empty
--   SnocToCons ('Snoc 'Empty x) = ('Cons x 'Empty)
--   SnocToCons ('Snoc ('Snoc xs x) y) = ('Cons x 'Empty)

-- type family EvalSnoc (xs :: List k) = (ys :: [k]) |  ys -> xs where
--   EvalSnoc 'Empty = '[]
--   EvalSnoc ('Snoc xs x) = x ': EvalSnoc xs

-- | A weird data type used to make `(+:)` operation injective.
--   `List k [k]` must have at least two elements.
-- data List1 k = L1Single k | L1Head k [k]
-- type family Snoc1 (xs :: [k]) (x :: k) = (ys :: List1 k) | ys -> xs x where
--   Snoc1 '[] y        = 'L1Single y
--   Snoc1 (x ': xs :: [Nat]) y
--       = ('L1Head x (GetList1Nat (SnocNat xs y)) :: List1 Nat)
--   Snoc1 (x ': xs :: [XNat]) y
--       = ('L1Head x (GetList1XNat (SnocXNat xs y)) :: List1 XNat)
--   Snoc1 (x ': xs) y
--       = 'L1Head x (xs +: y)
-- type family GetList1 (ts :: List1 k) = (rs :: [k]) | rs -> ts where
--   GetList1 ('L1Single x) = '[x]
--   GetList1 ('L1Head y (x ':xs)) = y ': x ': xs
--
-- -- | Even more weird thing - specialization to kind Nat and XNat.
-- --   Otherwise, example below will not typecheck.
-- --   The problem, I guess, is in too many layers of type families nested.
-- --   Though, even if I fully annotate everything with kind signature
-- --            it still does not work without this weird specialization.
-- -- ff :: Proxy k -> Proxy (as +: k) -> Proxy (k :+ bs) -> Proxy (as ++ bs)
-- -- ff _ _ _ = Proxy
-- -- yy :: Proxy ('[3,7,2] :: [Nat])
-- -- yy = ff (Proxy @5) (Proxy @'[3,7,5]) (Proxy @'[5,2])
-- type SnocNat (ns :: [Nat]) (n :: Nat) = Snoc1 ('Snoc ns n)
-- type family GetList1Nat (ts :: List1 Nat) = (rs :: [Nat]) | rs -> ts where
--   GetList1Nat ('L1Single x) = '[x]
--   GetList1Nat ('L1Head y (x ':xs)) = y ': x ': xs
-- type SnocXNat (ns :: [XNat]) (n :: XNat) = Snoc1 ('Snoc ns n)
-- type family GetList1XNat (ts :: List1 XNat) = (rs :: [XNat]) | rs -> ts where
--   GetList1XNat ('L1Single x) = '[x]
--   GetList1XNat ('L1Head y (x ':xs)) = y ': x ': xs

--
-- type family Reversed (ts :: Reversing k) = (rs :: [k]) | rs -> ts where
--   Reversed 'REmpty = '[]
--   Reversed ('Reversing ('L1Single a)) = '[a]
--   Reversed ('Reversing ('L1Head y (x ':xs))) = y ': x ': xs
--
--
-- type family ReversedNat (ts :: Reversing Nat) = (rs :: [Nat]) | rs -> ts where
--   ReversedNat 'REmpty = '[]
--   ReversedNat ('Reversing ('L1Single a)) = '[a]
--   ReversedNat ('Reversing ('L1Head y (x ':xs))) = y ': x ': xs
-- type family ReversedXNat (ts :: Reversing XNat) = (rs :: [XNat]) | rs -> ts where
--   ReversedXNat 'REmpty = '[]
--   ReversedXNat ('Reversing ('L1Single a)) = '[a]
--   ReversedXNat ('Reversing ('L1Head y (x ':xs))) = y ': x ': xs
--

-- | Synonym for (:+) that ignores Nat values 0 and 1
type family (n :: Nat) :< (ns :: [Nat]) :: [Nat] where
  0 :< ns = ns
  1 :< ns = ns
  n :< ns = n :+ ns
infixr 6 :<

-- | Synonym for (+:) that ignores Nat values 0 and 1
type family (ns :: [Nat]) >: (n :: Nat) :: [Nat] where
  ns >: 0 = ns
  ns >: 1 = ns
  ns >: n = ns +: n
infixl 6 >:
--
type family Head (xs :: [k]) :: k where
  Head (x ': xs) = x
  Head '[]       = TypeError ( 'Text
    "Head -- empty type-level list."
   )

type family Tail (xs :: [k]) :: [k] where
  Tail (x ': xs) = xs
  Tail '[]       = TypeError ( 'Text
    "Tail -- empty type-level list."
   )
--
--
--
-- data Reversing k = REmpty | Reversing (List1 k)
-- type family Reverse' (as :: List k) = (rs :: Reversing k) | rs -> as where
--   Reverse' ('Reverse '[]) = 'REmpty
--   Reverse' ('Reverse (a ': as) :: List Nat) = 'Reversing
--     (SnocNat (ReversedNat (Reverse' ('Reverse as))) a)
--   Reverse' ('Reverse (a ': as) :: List XNat) = 'Reversing
--     (SnocXNat (ReversedXNat (Reverse' ('Reverse as))) a)
--   Reverse' ('Reverse (a ': as)) = 'Reversing
--     (Snoc1 ('Snoc (Reversed (Reverse' ('Reverse as))) a))
--
type family Length (as :: l) :: Nat where
  Length '[] = 0
  Length (a ': as) = 1 + Length as
  Length (xs :: List k) = Length (EvalList xs)




-- | Get a suffix part of a list, given its prefix
type family Suffix (as :: List k) (asbs :: List k) :: List k where
  -- Found suffix!
  Suffix 'Empty asbs = asbs
  -- Error!
  Suffix ('Cons _ _) 'Empty = TypeError (
    'Text "Lhs Suffix/Prefix parameter cannot have more elements than its rhs parameter"
   )
  -- SimplifyList guarantees to return 'Cons or 'Empty constructors.
  -- Therefore, suffix evaluation must finish

  -- Variations of Cons stripping
  Suffix ('Cons _ as) ('Cons _ asbs) = Suffix as asbs
  Suffix ('Reverse ('Snoc as _)) ('Cons _ asbs) = Suffix ('Reverse as) asbs
  Suffix ('Cons _ as) ('Reverse ('Snoc asbs _)) = Suffix as ('Reverse asbs)
  Suffix ('Reverse ('Snoc as _))  ('Reverse ('Snoc asbs _)) = Suffix ('Reverse as) ('Reverse asbs)
  -- Variations of Drop-Take
  Suffix ('Take n asbs) asbs = 'Drop n asbs
  Suffix ('Reverse ('Drop n asbs)) ('Reverse asbs) = 'Reverse ('Take n asbs)

  -- General case
  Suffix as asbs = Suffix (SimplifyList as) (SimplifyList asbs)


-- | Get a prefix part of a list, given its suffix.
--   I use Suffix+Reverse for it.
type family Prefix (bs :: List k) (asbs :: List k) :: List k where
  -- Found prefix!
  Prefix 'Empty asbs = asbs

  -- Variations of Snoc stripping
  Prefix ('Snoc as _) ('Snoc asbs _) = Prefix as asbs
  Prefix ('Reverse ('Cons _ as)) ('Snoc asbs _) = Prefix ('Reverse as) asbs
  Prefix ('Snoc as _) ('Reverse ('Cons _ asbs)) = Prefix as ('Reverse asbs)
  Prefix ('Reverse ('Cons _ as))  ('Reverse ('Cons _ asbs)) = Prefix ('Reverse as) ('Reverse asbs)
  -- Variations of Drop-Take
  Prefix ('Drop n asbs) asbs = 'Take n asbs
  Prefix ('Reverse ('Take n asbs)) ('Reverse asbs) = 'Reverse ('Drop n asbs)

  -- General case - compute via Suffix
  Prefix as asbs = 'Reverse (Suffix ('Reverse as) ('Reverse asbs))



-- data List k
--   = Empty
--   | Cons k (List k)
--   | Snoc (List k) k
--   | Concat (List k) (List k)
--   | Reverse (List k)
--   | Drop Nat (List k)
--   | Take Nat (List k)


-- -- | Get a prefix part of a list, given its suffix
-- type family Prefix (bs :: List k) (asbs :: List k) :: List k where
--   Prefix '[] asbs  = asbs
--   Prefix bs (a ': asbs) = If (SameLength bs (a ': asbs)) '[] (a ': Prefix bs asbs)
--   -- Prefix bs bs = '[]
--   -- Prefix bs (a ': asbs) = a ': Prefix bs asbs
--   -- Prefix bs asbs = TypeError (
--   --   'Text "Lhs Prefix parameter must be a suffix of its rhs parameter"
--   --   ':$$: 'Text "Assertion failed: " ':<>: 'ShowType bs ':<>: 'Text " == " ':<>: 'ShowType asbs
--   --  )


--
-- type family SameLength (as :: [k]) (bs :: [k]) :: Bool where
--   SameLength '[] '[] = 'True
--   SameLength (_ ': as) (_ ': bs) = SameLength as bs
--   SameLength _ _ = 'False
--
-- -- x :: Proxy (Prefix '[3] '[2,7,3])
-- -- x = _
--
--
-- -- | Get a suffix part of a list, given its prefix
-- --   This version is more permissive than Suffix type class:
-- --     we do not check whether lhs is indeed a prefix
-- type family Suffix (as :: [k]) (asbs :: [k]) :: [k] where
--   Suffix '[] asbs = asbs
--   Suffix (a ': as) (_ ': asbs) = Suffix as asbs
--   Suffix (_ ': _) '[] = TypeError (
--     'Text "Lhs Suffix parameter cannot have more elements than its rhs parameter"
--    )
--
-- -- | Get a prefix part of a list, given its suffix
-- type family Prefix (bs :: [k]) (asbs :: [k]) :: [k] where
--   Prefix '[] asbs  = asbs
--   Prefix bs (a ': asbs) = If (SameLength bs (a ': asbs)) '[] (a ': Prefix bs asbs)
--   -- Prefix bs bs = '[]
--   -- Prefix bs (a ': asbs) = a ': Prefix bs asbs
--   -- Prefix bs asbs = TypeError (
--   --   'Text "Lhs Prefix parameter must be a suffix of its rhs parameter"
--   --   ':$$: 'Text "Assertion failed: " ':<>: 'ShowType bs ':<>: 'Text " == " ':<>: 'ShowType asbs
--   --  )
