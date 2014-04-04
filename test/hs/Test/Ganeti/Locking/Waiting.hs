{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{-| Tests for lock waiting structure.

-}

{-

Copyright (C) 2014 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Test.Ganeti.Locking.Waiting (testLocking_Waiting) where

import Control.Applicative ((<$>), (<*>), liftA2)
import qualified Data.Map as M
import qualified Data.Set as S

import Test.QuickCheck

import Test.Ganeti.TestHelper
import Test.Ganeti.Locking.Allocation (TestLock, TestOwner)

import Ganeti.BasicTypes (isBad, genericResult)
import Ganeti.Locking.Allocation (LockRequest, listLocks)
import Ganeti.Locking.Types (Lock)
import Ganeti.Locking.Waiting

{-

Ganeti.Locking.Waiting is polymorphic in the types of locks, lock owners,
and priorities. So we can use much simpler types here than Ganeti's
real locks and lock owners, knowning that polymorphic functions cannot
exploit the simplicity of the types they're deling with. To avoid code
duplication, we use the test structure from Test.Ganeti.Locking.Allocation.

-}

{-

All states of a LockWaiting ever available outside the module can be
obtained from @emptyWaiting@ applying one of the update operations.

-}

data UpdateRequest a b c = Update b [LockRequest a]
                         | UpdateWaiting c b [LockRequest a]
                         | RemovePending b
                         deriving Show

instance (Arbitrary a, Arbitrary b, Arbitrary c)
         => Arbitrary (UpdateRequest a b c) where
  arbitrary =
    frequency [ (2, Update <$> arbitrary <*> (choose (1, 4) >>= vector))
              , (4, UpdateWaiting <$> arbitrary <*> arbitrary
                                  <*> (choose (1, 4) >>= vector))
              , (1, RemovePending <$> arbitrary)
              ]

-- | Transform an UpdateRequest into the corresponding state transformer.
asWaitingTrans :: (Lock a, Ord b, Ord c)
               => LockWaiting a b c -> UpdateRequest a b c -> LockWaiting a b c
asWaitingTrans state (Update owner req) = fst $ updateLocks owner req state
asWaitingTrans state (UpdateWaiting prio owner req) =
  fst $ updateLocksWaiting prio owner req state
asWaitingTrans state (RemovePending owner) = removePendingRequest owner state


-- | Fold a sequence of requests to transform a waiting strucutre onto the
-- empty waiting. As we consider all exported transformations, any waiting
-- structure can be obtained this way.
foldUpdates :: (Lock a, Ord b, Ord c)
            => [UpdateRequest a b c] -> LockWaiting a b c
foldUpdates = foldl asWaitingTrans emptyWaiting

instance (Arbitrary a, Lock a, Arbitrary b, Ord b, Arbitrary c, Ord c)
         => Arbitrary (LockWaiting a b c) where
  arbitrary = foldUpdates <$> (choose (0, 8) >>= vector)

-- | Verify that an owner with a pending request cannot make any
-- changes to the lock structure.
prop_NoActionWithPendingRequests :: Property
prop_NoActionWithPendingRequests =
  forAll (arbitrary :: Gen TestOwner) $ \a ->
  forAll ((arbitrary :: Gen (LockWaiting TestLock TestOwner Integer))
          `suchThat` (S.member a . getPendingOwners)) $ \state ->
  forAll (arbitrary :: Gen [LockRequest TestLock]) $ \req ->
  forAll arbitrary $ \prio ->
  printTestCase "Owners with pending requests may not update locks"
  . all (isBad . fst . snd)
  $ [updateLocks, updateLocksWaiting prio] <*> [a] <*> [req] <*> [state]

-- | Quantifier for blocked requests. Quantifies over the generic situation
-- that there is a state, an owner, and a request that is blocked for that
-- owner. To obtain such a situation, we use the fact that there must be a
-- different owner having at least one lock.
forAllBlocked :: (Testable prop)
              => (LockWaiting TestLock TestOwner Integer -- State
                  -> TestOwner -- The owner of the blocked request
                  -> Integer -- The priority
                  -> [LockRequest TestLock] -- Request
                  -> prop)
              -> Property
forAllBlocked predicate =
  forAll (arbitrary :: Gen TestOwner) $ \a ->
  forAll (arbitrary :: Gen Integer) $ \prio ->
  forAll (arbitrary `suchThat` (/=) a) $ \b ->
  forAll ((arbitrary :: Gen (LockWaiting TestLock TestOwner Integer))
          `suchThat` foldl (liftA2 (&&)) (const True)
              [ not . S.member a . getPendingOwners
              , M.null . listLocks a . getAllocation
              , not . M.null . listLocks b . getAllocation]) $ \state ->
  forAll ((arbitrary :: Gen [LockRequest TestLock])
          `suchThat` (genericResult (const False) (not . S.null)
                      . fst . snd . flip (updateLocksWaiting prio a) state))
          $ \req ->
  predicate state a prio req

-- | Verify that an owner has a pending request after a waiting request
-- not fullfilled immediately.
prop_WaitingRequestsGetPending :: Property
prop_WaitingRequestsGetPending =
  forAllBlocked $ \state owner prio req ->
  printTestCase "After a not immediately fulfilled waiting request, owner\
                \ must have a pending request"
  . S.member owner . getPendingOwners . fst
  $ updateLocksWaiting prio owner req state


testSuite "Locking/Waiting"
 [ 'prop_NoActionWithPendingRequests
 , 'prop_WaitingRequestsGetPending
 ]
