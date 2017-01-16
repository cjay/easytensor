{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilyDependencies     #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UnboxedTuples              #-}
{-# LANGUAGE UndecidableInstances       #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Numeric.Array
-- Copyright   :  (c) Artem Chirkin
-- License     :  MIT
--
-- Maintainer  :  chirkin@arch.ethz.ch
--
--
-----------------------------------------------------------------------------

module Numeric.Array
  ( Array
  ) where

import           GHC.TypeLits              (KnownNat, Nat)
import           Numeric.Array.Base.ArrayF ()
import           Numeric.Array.Family
import           Numeric.Commons
import           Numeric.Dimensions

-- | A wrapper on top of ArrayType type family
--   to eliminate any possible ambiguity.
newtype Array t (ds :: [Nat]) = Array {_unArray :: ArrayType t ds }

instance Show t => Show (Array t '[]) where
  show (Array t) = show t
instance KnownNat d => Show (Array Float '[d]) where
  show (Array t) = show t
instance ( Dimensions (n :+ m :+ ds)
         ) => Show (Array Float ((n :+ m :+ ds) :: [Nat])) where
  show (Array t) = show t


deriving instance Bounded (ArrayType t ds) => Bounded (Array t ds)
deriving instance Enum (ArrayType t ds) => Enum (Array t ds)

deriving instance {-# OVERLAPPABLE #-} Eq (ArrayType t ds) => Eq (Array t ds)
deriving instance {-# OVERLAPPING #-} Eq t => Eq (Array t '[])
deriving instance {-# OVERLAPPING #-} Eq (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} Integral (ArrayType t ds) => Integral (Array t ds)


deriving instance {-# OVERLAPPABLE #-} Num (ArrayType t ds)
                                    => Num (Array t ds)
deriving instance {-# OVERLAPPING #-} Num t => Num (Array t '[])
deriving instance {-# OVERLAPPING #-} Num (Array Float (d ': ds))

deriving instance {-# OVERLAPPABLE #-} Fractional (ArrayType t ds)
                                    => Fractional (Array t ds)
deriving instance {-# OVERLAPPING #-} Fractional t => Fractional (Array t '[])
deriving instance {-# OVERLAPPING #-} Fractional (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} Floating (ArrayType t ds)
                                    => Floating (Array t ds)
deriving instance {-# OVERLAPPING #-} Floating t => Floating (Array t '[])
deriving instance {-# OVERLAPPING #-} Floating (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} Ord (ArrayType t ds)
                                    => Ord (Array t ds)
deriving instance {-# OVERLAPPING #-} Ord t => Ord (Array t '[])
deriving instance {-# OVERLAPPING #-} Ord (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} Read (ArrayType t ds)
                                    => Read (Array t ds)
deriving instance {-# OVERLAPPING #-} Read t => Read (Array t '[])


deriving instance {-# OVERLAPPABLE #-} Real (ArrayType t ds)
                                    => Real (Array t ds)
deriving instance {-# OVERLAPPING #-} Real t => Real (Array t '[])


deriving instance {-# OVERLAPPABLE #-} RealFrac (ArrayType t ds)
                                    => RealFrac (Array t ds)
deriving instance {-# OVERLAPPING #-} RealFrac t => RealFrac (Array t '[])


deriving instance {-# OVERLAPPABLE #-} RealFloat (ArrayType t ds)
                                    => RealFloat (Array t ds)
deriving instance {-# OVERLAPPING #-} RealFloat t => RealFloat (Array t '[])


deriving instance {-# OVERLAPPABLE #-} PrimBytes (ArrayType t ds)
                                    => PrimBytes (Array t ds)
deriving instance {-# OVERLAPPING #-} PrimBytes t => PrimBytes (Array t '[])
deriving instance {-# OVERLAPPING #-} Dimensions (d ': ds)
                                    => PrimBytes (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} FloatBytes (ArrayType t ds)
                                    => FloatBytes (Array t ds)
deriving instance {-# OVERLAPPING #-} FloatBytes t => FloatBytes (Array t '[])
deriving instance {-# OVERLAPPING #-} FloatBytes (Array Float (d ': ds))


deriving instance {-# OVERLAPPABLE #-} DoubleBytes (ArrayType t ds)
                                    => DoubleBytes (Array t ds)
deriving instance {-# OVERLAPPING #-} DoubleBytes t => DoubleBytes (Array t '[])


deriving instance {-# OVERLAPPABLE #-} IntBytes (ArrayType t ds)
                                    => IntBytes (Array t ds)
deriving instance {-# OVERLAPPING #-} IntBytes t => IntBytes (Array t '[])


deriving instance {-# OVERLAPPABLE #-} WordBytes (ArrayType t ds)
                                    => WordBytes (Array t ds)
deriving instance {-# OVERLAPPING #-} WordBytes t => WordBytes (Array t '[])

-- deriving instance Dimensions (d ': ds)
--     => ElementWise (Idx (d ': ds)) Float (Array Float (d ': ds))
