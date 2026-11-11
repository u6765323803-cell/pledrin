# Pledrin — read-side data model

Status: normative for Phase 2. This document specifies the interface between the
Ponder indexer and the Next.js application. Both are built against the frozen
ABIs in `contracts/abi/`, and this document is the only place where their shared
vocabulary is defined.

`docs/SPEC.md` is the protocol. This is the read side built on top of it. Where
the two disagree about protocol behaviour, `docs/SPEC.md` wins and this document
is wrong. Where this document names an entity, a field, a query or an
application rule, it is normative and `docs/SPEC.md` is silent by design: its
section 18 puts the indexer and the frontend out of its scope.

Audience: the indexer engineer and the frontend engineer. They build in
parallel. Every name in sections 3, 4 and 5 is a name both halves must use.

Authority, in order:

1. `contracts/abi/*.json` for every event, field, type and function signature.
2. `docs/SPEC.md` for protocol behaviour, formulas and revert reasons.
3. `docs/CHAIN_FACTS.md` for every chain property and every external address.
4. This document for entities, derived values, the API shape, and the rules
   that bind both halves.

No event name, field name or function signature in this document was written
from memory. Everything marked **derived** exists only in the read side and has
no on-chain counterpart. Nothing here introduces an external address, an RPC
URL or an explorer URL; deployments are referred to by name and every address is
configuration (section 1.4).

---

## 1. Scope and the interface contract

### 1.1 What this document decides and what it does not

It decides: the entity set, each entity's fields and their provenance, the
derived values and their formulas, the query surface, the page list with its
reads and writes, the indexing rules that correctness depends on, and the
application rules that user safety depends on.

It does not decide: the Postgres schema, the Ponder handler layout, the API
transport syntax, the React component tree, or any visual design. The indexer
engineer chooses how to express the entities of section 3 in Ponder. The
frontend engineer chooses how to render the shapes of section 5. Neither may
rename a field, add a field the chain cannot support, or drop a field a page
needs without the change landing here first.

### 1.2 Encoding conventions

These bind the wire format. A mismatch here is the cheapest possible way for the
two halves to fail to meet, so it is specified before anything else.

| Convention | Type | Rule |
|---|---|---|
| `Address` | string | 20-byte hex, `0x`-prefixed, **lowercase**, exactly 42 characters. Lowercase is canonical for keys, equality and URLs. The application may render EIP-55 checksummed form; it must not send it as a query argument. |
| `Hash32` | string | 32-byte hex, `0x`-prefixed, lowercase, exactly 66 characters. Used for transaction hashes and for `poolId`. |
| `Uint` | string | Unsigned decimal integer, no sign, no exponent, no separators, no leading zeros except for `"0"`. Every `uint128` and `uint256` value crosses the API this way. |
| `Int` | string | Signed decimal integer, optional leading `-`. Used only for tick values. |
| `Bps` | number | Integer 0 to 10000 inclusive. Safe as a JSON number. |
| `Timestamp` | number | Unix seconds, integer. Safe as a JSON number. Always `block.timestamp`, never derived from a block number. |
| `BlockNumber` | number | Integer. Safe as a JSON number on this chain. Used only for ordering and for staleness, never as a clock. |
| `Enum` | string | The identifier from the contract enum, spelled exactly as in section 1.5. |

**IDX/APP-shared rule.** No quantity denominated in wei or in token base units
may cross the API as a JSON number. `TOTAL_SUPPLY` is `1e27` base units, which
exceeds `Number.MAX_SAFE_INTEGER` by eleven orders of magnitude; a single
`number` anywhere in that path silently truncates. `Uint` strings are parsed to
`bigint` on both sides.

Prices are the one derived family that is not a raw chain quantity. They are
carried as `Uint` in the unit defined in section 4.2 and are display-only: no
price computed by the indexer may ever become an argument of a transaction
(APP-4).

### 1.3 Identifiers and ordering

| Thing | Identifier |
|---|---|
| A launch | its `BondingCurve` address, from `LaunchCreated.launch`. Never its token address, never its symbol, never a sequential index. |
| A launch's token | `LaunchCreated.token`. One-to-one with the launch, but not the launch's identity. |
| A log-derived row (trade, fee accrual, payout, donation) | `"<transactionHash>:<logIndex>"`, lowercase, `logIndex` in decimal without padding. |
| A locked position | `PositionLocked.positionId`, as `Uint`. |
| A creator | the creator address. `createLaunch` has no creator parameter in `contracts/abi/LaunchFactory.json`, so a launch's creator is always the sender of its creation transaction. |
| A vesting schedule | the launch address it is keyed by, which is `CreatorVesting`'s own key. |
| A candle | `(launch, interval, bucketStart)`. |

**The total order over logs is `(blockNumber, logIndex)` ascending, and nothing
else.** Two blocks may carry the same `block.timestamp`, so a timestamp is not a
total order and must never be a pagination cursor. Every paginated query in
section 5 uses an opaque cursor that encodes `(blockNumber, logIndex)`.

### 1.4 Configuration, not constants

No Pledrin contract address exists yet, and `docs/CHAIN_FACTS.md` holds no
Pledrin address. Every one of the following is deployment configuration supplied
to the indexer and to the application, named here and never written as a
literal in either codebase or in this document:

| Configuration value | Used for |
|---|---|
| `LaunchFactory` address | the root of all child-address discovery; `isLaunch` checks |
| `LaunchFactory` deployment block | the indexer's start block for every factory-anchored source |
| `CreatorVesting` address | the vesting singleton's event source |
| `LiquidityLock` address | the lock singleton's event source |
| `Timelock` address | governance events, subject to decision 18 |
| `CurveDeployer`, `TokenDeployer` addresses | integrity cross-checks only (IDX-8) |
| chain id and RPC endpoint | from `docs/CHAIN_FACTS.md`, selected by environment |
| Uniswap v4 `PoolManager`, `PositionManager`, `Quoter`, `StateView`, `UniversalRouter` addresses | post-graduation reads and links, from `docs/CHAIN_FACTS.md` |
| explorer base URL | transaction and address links, from `docs/CHAIN_FACTS.md` |

The indexer must refuse to start if a configured address has no code at the
configured start block, rather than indexing an empty address set and reporting
a healthy but empty database.

### 1.5 Enum values

The ABIs type these fields `uint8`. The numeric values below are from the
interface sources the frozen ABIs were generated from and are load-bearing for
decoding. The string spellings are the only form that crosses the API.

| Enum | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| `State` (`BondingCurve.state`, `WrongState.current`) | `Live` | `Graduating` | `Graduated` | `Expired` | `Stalled` |
| `BondState` (`BondStateChanged.oldState`/`newState`) | `None` | `Bonded` | `Returned` | `Forfeited` | — |
| `FeeKind` (`FeesClaimed.kind`) | `Creator` | `Protocol` | `Bounty` | `Bond` | — |
| `PositionKind` (`PositionLocked.kind`) | `Core` | `Floor` | — | — | — |

`Counter` (`ReputationUpdated.counter`) has ten values, in this order:
`Launches`, `Graduations`, `Stalls`, `Expiries`, `BondsPosted`, `BondsReturned`,
`BondsForfeited`, `BondWeiPosted`, `BondWeiForfeited`, `EthRaisedGraduated`.
They correspond one-to-one with the fields of `reputationOf`'s return tuple in
`contracts/abi/LaunchFactory.json`, in the same order.

The read side adds two **derived** state vocabularies that have no on-chain
counterpart, defined in section 4.5: `EffectiveState` and `BondOutcome`.

### 1.6 Protocol constants the read side needs

Taken from `docs/SPEC.md` section 15.1. They are compile-time constants in both
codebases, not configuration, because they are global constants in the
contracts and are re-asserted by every curve's constructor.

| Name | Value | Used by |
|---|---|---|
| `TOTAL_SUPPLY` | `1000000000 * 10**18` | valuation, circulating supply |
| `CURVE_SUPPLY` | `900000000 * 10**18` | cap progress |
| `LP_SUPPLY` | `100000000 * 10**18` | graduation display |
| `VIRTUAL_TOKEN_RESERVE` | `1012500000 * 10**18` | every price formula |
| `VIRTUAL_TOKEN_TAIL` | `112500000 * 10**18` | terminal price |
| `CREATOR_FIRST_BUY_MAX` | `18000000 * 10**18` | the creation form's first-buy bound |
| `MIN_BUY_WEI` | `10**12` | the buy form's lower bound |
| `ALT_DELAY` | `3600` seconds | `graduateAlt` availability |
| `GRAD_GRACE` | `604800` seconds | `abortGraduation` availability |
| `TIMELOCK_DELAY` | `172800` seconds | governance display |

`TOTAL_SUPPLY` is never read per launch. Every launch's token asserts it in the
curve's constructor (`docs/SPEC.md` section 3), there is no mint and no burn, so
it is a constant for every Pledrin token for all time.

### 1.7 Read-side parameters

Every parameter the read side introduces, with type, units, bounds and default.

| Parameter | Type | Units | Default | Bounds | Owner |
|---|---|---|---|---|---|
| `CANDLE_INTERVALS` | set of integers | seconds | `{60, 300, 3600, 86400}` | each a divisor of 86400 | indexer |
| `METADATA_MAX_BYTES` | integer | bytes | `4096` | `512` to `65536` | indexer |
| `PAGE_LIMIT_DEFAULT` | integer | rows | `25` | `1` to `PAGE_LIMIT_MAX` | both |
| `PAGE_LIMIT_MAX` | integer | rows | `100` | `25` to `500` | both |
| `TOP_HOLDERS_N` | integer | addresses | `10` | `5` to `50` | indexer |
| `STALENESS_WARN_SECONDS` | integer | seconds | `30` | `5` to `600` | application |
| `STALENESS_BLOCK_WARN` | integer | blocks | `50` | `5` to `10000` | application |
| `QUOTE_TTL_SECONDS` | integer | seconds | `15` | `3` to `60` | application |

`METADATA_MAX_BYTES` is a defence, not a preference: `createLaunch` applies no
length bound and no validation to `params.metadata`, and `LaunchMetadata` emits
it verbatim (IDX-20).

---

## 2. Event inventory and its consumers

Every event in `contracts/abi/`, what it is the authority for, and which entity
consumes it. "None" is a real answer and is stated where it applies.

| Event | Contract | Read-side authority for | Consumer |
|---|---|---|---|
| `LaunchCreated` | `LaunchFactory` | the existence of a launch, and every immutable it fixes | `Launch` (create) |
| `LaunchMetadata` | `LaunchFactory` | `name`, `symbol`, the opaque metadata blob | `Launch` (mutate) |
| `FeeConfigSet` | `LaunchFactory` | the fee defaults future launches receive | `ProtocolConfig` |
| `TreasurySet` | `LaunchFactory` | the treasury future launches receive | `ProtocolConfig` |
| `LaunchesPausedSet` | `LaunchFactory` | whether `createLaunch` is open | `ProtocolConfig` |
| `ReputationUpdated` | `LaunchFactory` | every reputation counter, as an absolute value | `Creator` |
| `OwnershipTransferred` | `LaunchFactory` | ownership renunciation | none in the page list; decision 18 |
| `Bought` | `BondingCurve` | a buy, and the resulting `tokensSold` and `ethReserve` | `Trade`, `Launch`, `Candle` |
| `Sold` | `BondingCurve` | a sell, and the resulting `tokensSold` and `ethReserve` | `Trade`, `Launch`, `Candle` |
| `FeeAccrued` | `BondingCurve` | the four-way destination of one trade's fee | `FeeAccrual`, `Launch` |
| `Donated` | `BondingCurve` | a donation and the resulting `ethReserve` | `Donation`, `Launch`, `Candle` |
| `CapReached` | `BondingCurve` | the `Live -> Graduating` transition | `Launch` (state and `capReachedAt` only; IDX-4) |
| `Graduated` | `BondingCurve` | the graduation outcome, including the pool actually used | `Launch`, `LockedPosition`, `Payout` basis |
| `GraduationStalled` | `BondingCurve` | the `Graduating -> Stalled` transition | `Launch` |
| `Expired` | `BondingCurve` | the `Live -> Expired` transition and all three forfeited amounts | `Launch` |
| `BondStateChanged` | `BondingCurve` | every bond transition, with its destination | `Launch` (bond fields) |
| `FeesClaimed` | `BondingCurve` | every ETH payout, by kind | `Payout`, `Launch` |
| `VestingCreated` | `CreatorVesting` | a schedule's allocation, cliff and duration | `VestingSchedule` |
| `VestingStarted` | `CreatorVesting` | the vesting clock's start | `VestingSchedule` |
| `VestingReleased` | `CreatorVesting` | a release and the cumulative released | `VestingSchedule`, `Payout` |
| `VestingVoided` | `CreatorVesting` | a schedule becoming irrecoverable | `VestingSchedule` |
| `PositionLocked` | `LiquidityLock` | a position's id, launch and kind | `LockedPosition` |
| `PositionCompounded` | `LiquidityLock` | liquidity added to a locked position | `LockedPosition` |
| `Transfer` | `PledrinToken` | token balances, hence holders | `TokenBalance` |
| `Approval` | `PledrinToken` | nothing the read side needs | **none.** The application reads `allowance` by RPC when it needs it. Indexing this event is pure cost. |
| `CurveDeployed` | `CurveDeployer` | nothing, by itself | **none.** Permissionless; see IDX-8. |
| `TokenDeployed` | `TokenDeployer` | nothing, by itself | **none.** Permissionless; see IDX-8. |
| `OperationProposed` | `Timelock` | a pending governance operation and its `readyAt` | decision 18 |
| `OperationExecuted` | `Timelock` | an executed governance operation | decision 18 |
| `OperationCancelled` | `Timelock` | a dropped operation | decision 18 |
| `AdminTransferred` | `Timelock` | the timelock admin | decision 18 |

Three observations about this table that matter more than the table.

**Nothing in the page list requires an event that the protocol does not emit.**
Every number sections 3 and 4 define is derivable from the events above, from
the constants of section 1.6, and from `block.timestamp`. No contract change is
needed for Phase 2.

**Two protocol facts are deliberately unobservable from events** and are
limitations rather than gaps: the fees a locked position has earned
(`PositionCompounded` carries `liquidityAdded`, not the amounts collected), and
post-graduation trading (Pledrin emits nothing after `Graduated`). Section 9
states both.

**Four events are emitted and consumed by nothing in Phase 2.** `Approval`,
`CurveDeployed`, `TokenDeployed` and `OwnershipTransferred` have no page that
needs them. The first should not be indexed at all. The middle two should be
indexed only if decision 18's integrity check is adopted. `Timelock`'s four are
behind the same decision.

---

## 3. Entities

For each entity: which events create it, which mutate it, and for every field
whether it comes from an event, from a constant, or is derived.

A note on what is *not* here. There is no `Bond` entity: a launch has exactly
one bond, its amount is immutable from `LaunchCreated.bondWei`, and its state
leaves `Bonded` at most once (`docs/SPEC.md` Invariant 25). A separate entity
would buy a join and nothing else, so the bond is five fields on `Launch` and
one derived outcome. There is no `Graduation` entity for the same reason. There
is no entity for the launch token: it is one field on `Launch` plus the
`TokenBalance` set.

### 3.1 `Launch`

Created by `LaunchCreated`. Mutated by `LaunchMetadata`, `Bought`, `Sold`,
`Donated`, `FeeAccrued`, `CapReached`, `Graduated`, `GraduationStalled`,
`Expired`, `BondStateChanged`, `FeesClaimed`.

| Field | Type | Source |
|---|---|---|
| `address` | `Address` | `LaunchCreated.launch` |
| `token` | `Address` | `LaunchCreated.token` |
| `creator` | `Address` | `LaunchCreated.creator` |
| `virtualEthReserve` | `Uint` (wei) | `LaunchCreated.virtualEthReserve` |
| `ethTarget` | `Uint` (wei) | `LaunchCreated.ethTarget` |
| `totalFeeBps` | `Bps` | `LaunchCreated.totalFeeBps` |
| `creatorShareBps` | `Bps` | `LaunchCreated.creatorShareBps` |
| `protocolShareBps` | `Bps` | `LaunchCreated.protocolShareBps` |
| `protectionShareBps` | `Bps` | `LaunchCreated.protectionShareBps` |
| `bondWei` | `Uint` (wei) | `LaunchCreated.bondWei` |
| `gradDeadline` | `Timestamp` | `LaunchCreated.gradDeadline` |
| `initialPoolId` | `Hash32` | `LaunchCreated.poolId` |
| `createdAt` | `Timestamp` | block timestamp of `LaunchCreated` |
| `createdAtBlock` | `BlockNumber` | block number of `LaunchCreated` |
| `createdTx` | `Hash32` | transaction hash of `LaunchCreated` |
| `name` | string | `LaunchMetadata.name` |
| `symbol` | string | `LaunchMetadata.symbol` |
| `metadataRaw` | string or null | `LaunchMetadata.metadata` as hex, or null when longer than `METADATA_MAX_BYTES` |
| `metadataBytes` | number | byte length of `LaunchMetadata.metadata` |
| `metadataDecoded` | object or null | **derived**, decision 17; null when absent, oversize or undecodable |
| `pledged` | boolean | **derived**: `bondWei > 0`. Matches the curve's `pledged()` view, which `docs/SPEC.md` Invariant 29 fixes to the immutable `bondWei` and not to `bondState` |
| `onChainState` | `State` | **derived from transitions**: `Live` at creation, `Graduating` on `CapReached`, `Graduated` on `Graduated`, `Stalled` on `GraduationStalled`, `Expired` on `Expired` |
| `tokensSold` | `Uint` (base units) | assigned from `Bought.tokensSold` / `Sold.tokensSold`; zero at creation |
| `ethReserve` | `Uint` (wei) | assigned from `Bought.ethReserve` / `Sold.ethReserve` / `Donated.ethReserve` / `Expired.ethReserve`; set to `0` on `Graduated` (IDX-3, IDX-5) |
| `capReachedAt` | `Timestamp` or null | block timestamp of `CapReached`; `CapReached.timestamp` carries the same value |
| `graduatedAt` | `Timestamp` or null | block timestamp of `Graduated` |
| `stalledAt` | `Timestamp` or null | block timestamp of `GraduationStalled` |
| `expiredAt` | `Timestamp` or null | block timestamp of `Expired` |
| `settledAt` | `Timestamp` or null | **derived**: whichever of the three above is set |
| `graduationPoolId` | `Hash32` or null | `Graduated.poolId` (IDX-18) |
| `graduationCaller` | `Address` or null | `Graduated.caller` |
| `positionIdCore` | `Uint` or null | `Graduated.positionIdCore` |
| `positionIdFloor` | `Uint` or null | `Graduated.positionIdFloor`, **null when the event carries `0`** (IDX-17) |
| `ethToCore` | `Uint` (wei) or null | `Graduated.ethToCore` |
| `ethToFloor` | `Uint` (wei) or null | `Graduated.ethToFloor` |
| `tokensToCore` | `Uint` (base units) or null | `Graduated.tokensToCore` |
| `graduationBounty` | `Uint` (wei) or null | `Graduated.bounty` |
| `bondState` | `BondState` | **derived**: `Bonded` when `bondWei > 0` at creation, else `None`; then `BondStateChanged.newState` (IDX-7) |
| `bondSettledAt` | `Timestamp` or null | block timestamp of the `BondStateChanged` that left `Bonded` |
| `bondDestination` | `Address` or null | `BondStateChanged.destination` of that transition |
| `bondClaimedAt` | `Timestamp` or null | block timestamp of `FeesClaimed` with `kind = Bond` |
| `bondForfeitedWei` | `Uint` (wei) | `Expired.bondForfeited` |
| `creatorFeesForfeitedWei` | `Uint` (wei) | `Expired.creatorFeesForfeited` |
| `protectionForfeitedWei` | `Uint` (wei) | `Expired.protectionForfeited` |
| `creatorFeeAccruedWei` | `Uint` (wei) | **derived**: running sum of `FeeAccrued.creatorCut` |
| `protocolFeeAccruedWei` | `Uint` (wei) | **derived**: running sum of `FeeAccrued.protocolCut` |
| `protectionAccruedWei` | `Uint` (wei) | **derived**: running sum of `FeeAccrued.protectionCut` |
| `reserveCutWei` | `Uint` (wei) | **derived**: running sum of `FeeAccrued.reserveCut` |
| `feeChargedTotalWei` | `Uint` (wei) | **derived**: sum of all four `FeeAccrued` amounts (section 4.6) |
| `creatorFeesClaimedWei` | `Uint` (wei) | **derived**: sum of `FeesClaimed.amount` with `kind = Creator` |
| `protocolFeesClaimedWei` | `Uint` (wei) | **derived**: sum of `FeesClaimed.amount` with `kind = Protocol` |
| `bountyClaimedWei` | `Uint` (wei) | **derived**: sum of `FeesClaimed.amount` with `kind = Bounty` |
| `creatorFeeBalanceWei` | `Uint` (wei) | **derived**, section 4.6 |
| `protocolFeeBalanceWei` | `Uint` (wei) | **derived**, section 4.6 |
| `protectionBalanceWei` | `Uint` (wei) | **derived**, section 4.6 |
| `buyCount`, `sellCount` | number | **derived**: counts of `Bought` and `Sold` |
| `uniqueTraderCount` | number | **derived**: distinct addresses over `Bought.buyer` and `Sold.seller`, excluding the creator's launch-transaction buy (IDX-22) |
| `volumeEthWei` | `Uint` (wei) | **derived**, section 4.9 |
| `donationCount`, `donatedEthWei` | number, `Uint` | **derived**: user donations only, excluding `Donated` with `donor == launch` (IDX-26) |
| `holderCount` | number | **derived**, section 3.9 |
| `lastTradeAt` | `Timestamp` or null | **derived** |
| `lastActivityAt` | `Timestamp` | **derived**: the latest timestamp of any event attributed to this launch |

`tokensSold` and `ethReserve` are assigned from the event field and never
computed as a delta. Section 4.1 states the rule and IDX-1 through IDX-6 state
why each alternative is wrong.

### 3.2 `Trade`

Created by `Bought` and `Sold`. Never mutated. One entity for both sides so
that the trade-history page is a single ordered list and the candle pipeline has
a single input.

| Field | Type | Source |
|---|---|---|
| `id` | string | section 1.3 |
| `launch` | `Address` | `Bought.launch` / `Sold.launch` |
| `side` | `"Buy"` or `"Sell"` | **derived** from which event produced the row |
| `trader` | `Address` | `Bought.buyer` / `Sold.seller` |
| `blockNumber` | `BlockNumber` | log |
| `logIndex` | number | log |
| `timestamp` | `Timestamp` | block |
| `txHash` | `Hash32` | log |
| `tokenAmount` | `Uint` (base units) | `Bought.tokensOut` / `Sold.tokensIn` |
| `ethIn` | `Uint` (wei) | `Bought.ethIn`; `0` for a sell |
| `ethToCurve` | `Uint` (wei) | `Bought.ethToCurve`; `0` for a sell |
| `refund` | `Uint` (wei) | `Bought.refund`; `0` for a sell |
| `ethGross` | `Uint` (wei) | `Sold.ethGross`; `0` for a buy |
| `ethOut` | `Uint` (wei) | `Sold.ethOut`; `0` for a buy |
| `feeWei` | `Uint` (wei) | `Bought.fee` / `Sold.fee` |
| `ethVolumeWei` | `Uint` (wei) | **derived**, section 4.9. For a buy, `ethIn - refund`; for a sell, `ethGross` |
| `tokensSoldAfter` | `Uint` (base units) | `Bought.tokensSold` / `Sold.tokensSold` |
| `ethReserveAfter` | `Uint` (wei) | `Bought.ethReserve` / `Sold.ethReserve` |
| `priceExecuted` | `Uint` | **derived**, section 4.2 |
| `priceSpotAfter` | `Uint` | **derived**, section 4.2 |
| `isClipped` | boolean | **derived**: `side == "Buy" && refund > 0`. The final buy of a launch, clipped at the cap (`docs/SPEC.md` section 5.4 step 4) |
| `isCreatorFirstBuy` | boolean | **derived**: the buy in the same transaction as this launch's `LaunchCreated` (IDX-22) |

`Trade` carries no fee split. The split is `FeeAccrual`'s business and the two
are never joined (IDX-2).

### 3.3 `FeeAccrual`

Created by `FeeAccrued`. Never mutated.

| Field | Type | Source |
|---|---|---|
| `id` | string | section 1.3 |
| `launch` | `Address` | `FeeAccrued.launch` |
| `blockNumber`, `logIndex`, `timestamp`, `txHash` | | log and block |
| `creatorCut` | `Uint` (wei) | `FeeAccrued.creatorCut` |
| `protocolCut` | `Uint` (wei) | `FeeAccrued.protocolCut` |
| `protectionCut` | `Uint` (wei) | `FeeAccrued.protectionCut` |
| `reserveCut` | `Uint` (wei) | `FeeAccrued.reserveCut` |
| `total` | `Uint` (wei) | **derived**: the sum of all four |

### 3.4 `Donation`

Created by `Donated`. Never mutated. Kept separate from `Trade` because a
donation moves the price without being a trade, and the price pipeline must see
it (IDX-23).

| Field | Type | Source |
|---|---|---|
| `id` | string | section 1.3 |
| `launch` | `Address` | `Donated.launch` |
| `donor` | `Address` | `Donated.donor` |
| `amount` | `Uint` (wei) | `Donated.amount` |
| `ethReserveAfter` | `Uint` (wei) | `Donated.ethReserve` |
| `isProtocolInternal` | boolean | **derived**: `donor == launch`. True for the stranded-protection donation `abortGraduation` emits (`docs/SPEC.md` section 16.1) |
| `blockNumber`, `logIndex`, `timestamp`, `txHash` | | log and block |

### 3.5 `Payout`

One entity for every value that has left the protocol to a named recipient.
Created by `FeesClaimed` (four kinds) and `VestingReleased` (one kind). Never
mutated. It exists because the claim page needs one history feed per address
across launches and across two contracts.

| Field | Type | Source |
|---|---|---|
| `id` | string | section 1.3 |
| `launch` | `Address` | `FeesClaimed.launch` / `VestingReleased.launch` |
| `recipient` | `Address` | `FeesClaimed.recipient` / `VestingReleased.creator` |
| `kind` | `"CreatorFees"`, `"ProtocolFees"`, `"Bounty"`, `"Bond"`, `"VestingRelease"` | **derived** from `FeesClaimed.kind` (section 1.5) or from the event being `VestingReleased` |
| `asset` | `"ETH"` or `"TOKEN"` | **derived**: `TOKEN` for `VestingRelease`, `ETH` otherwise |
| `amount` | `Uint` | `FeesClaimed.amount` (wei) / `VestingReleased.amount` (base units) |
| `cumulative` | `Uint` or null | `VestingReleased.cumulative`; null for the four ETH kinds |
| `caller` | `Address` | **derived**: the transaction sender. All four claim functions and `release` are permissionless pushes, so the caller and the recipient differ routinely |
| `blockNumber`, `logIndex`, `timestamp`, `txHash` | | log and block |

### 3.6 `Creator`

Created by the first `ReputationUpdated` or the first `LaunchCreated` for an
address, whichever the indexer sees first. Mutated by `ReputationUpdated`.

| Field | Type | Source |
|---|---|---|
| `address` | `Address` | `ReputationUpdated.creator` / `LaunchCreated.creator` |
| `launches` | number | `ReputationUpdated.newValue` where `counter = Launches` |
| `graduations` | number | the same, `counter = Graduations` |
| `stalls` | number | `counter = Stalls` |
| `expiries` | number | `counter = Expiries` |
| `bondsPosted` | number | `counter = BondsPosted` |
| `bondsReturned` | number | `counter = BondsReturned` |
| `bondsForfeited` | number | `counter = BondsForfeited` |
| `bondWeiPosted` | `Uint` (wei) | `counter = BondWeiPosted` |
| `bondWeiForfeited` | `Uint` (wei) | `counter = BondWeiForfeited` |
| `ethRaisedGraduated` | `Uint` (wei) | `counter = EthRaisedGraduated` |
| `firstLaunchAt` | `Timestamp` | **derived**: earliest `LaunchCreated` timestamp |
| `lastLaunchAt` | `Timestamp` | **derived**: latest `LaunchCreated` timestamp |
| `settledLaunches` | number | **derived**, section 4.10 |
| `openLaunches` | number | **derived**, section 4.10 |

Every counter is assigned from `newValue` and never incremented locally
(IDX-9). The seven count fields are `uint32` on chain and safe as JSON numbers;
the three wei fields are `uint128` and are `Uint` strings.

This entity stores no score. `docs/SPEC.md` section 13 is explicit that any
score is off-chain policy; section 4.10 defines the ratios the API exposes and
the conditions under which they are undefined.

### 3.7 `VestingSchedule`

Created by `VestingCreated`. Mutated by `VestingStarted`, `VestingReleased`,
`VestingVoided`. Keyed by the launch address, which is `CreatorVesting`'s own
key.

| Field | Type | Source |
|---|---|---|
| `launch` | `Address` | `VestingCreated.launch` |
| `creator` | `Address` | `VestingCreated.creator` |
| `allocation` | `Uint` (base units) | `VestingCreated.allocation` |
| `cliff` | number (seconds) | `VestingCreated.cliff` |
| `duration` | number (seconds) | `VestingCreated.duration` |
| `createdAt` | `Timestamp` | block timestamp of `VestingCreated` |
| `start` | `Timestamp` or null | `VestingStarted.start` |
| `released` | `Uint` (base units) | `VestingReleased.cumulative`, assigned not accumulated |
| `voided` | boolean | true on `VestingVoided` |
| `voidedAt` | `Timestamp` or null | block timestamp of `VestingVoided` |
| `isPledrinLaunch` | boolean | **derived**: a `Launch` row exists for this key (IDX-8) |
| `cliffEndsAt`, `fullyVestedAt`, `vestedAt`, `releasableAt` | | **derived**, section 4.8 |

`createSchedule` is permissionless and keyed by `msg.sender`, so any contract
can emit all four of these events for itself with an arbitrary `creator` and an
arbitrary `allocation`. `isPledrinLaunch` is not a convenience field; the API
must never return a schedule with `isPledrinLaunch = false` (IDX-8).

### 3.8 `LockedPosition`

Created by `PositionLocked`. Mutated by `PositionCompounded`.

| Field | Type | Source |
|---|---|---|
| `positionId` | `Uint` | `PositionLocked.positionId` |
| `launch` | `Address` | `PositionLocked.launch` |
| `kind` | `PositionKind` | `PositionLocked.kind` |
| `lockedAt` | `Timestamp` | block timestamp of `PositionLocked` |
| `compoundCount` | number | **derived**: count of `PositionCompounded` |
| `liquidityAddedTotal` | `Uint` | **derived**: sum of `PositionCompounded.liquidityAdded` |
| `lastCompoundedAt` | `Timestamp` or null | **derived** |
| `isPledrinLaunch` | boolean | **derived**: a `Launch` row exists for `launch` (IDX-8) |

`registerPosition` is permissionless and records `launch = msg.sender`, and the
lock holds no factory address (`docs/SPEC.md` section 9 and section 16.1). The
same filter rule applies as for vesting.

The lock's principal, its accrued fees and its retained residual are not
derivable from these two events. Section 9 states that limitation.

### 3.9 `TokenBalance` and the holder set

Created and mutated by the launch token's `Transfer`. One row per
`(token, holder)`.

| Field | Type | Source |
|---|---|---|
| `token` | `Address` | the emitting token address |
| `launch` | `Address` | **derived**: the `Launch` whose `token` this is |
| `holder` | `Address` | `Transfer.from` / `Transfer.to` |
| `balance` | `Uint` (base units) | **derived**: running sum of credits minus debits |
| `firstHeldAt` | `Timestamp` | **derived** |
| `lastChangedAt` | `Timestamp` | **derived** |
| `isExcluded` | boolean | **derived**: the address is in the exclusion set below |

The exclusion set, which is not optional and is the difference between a holder
count that means something and one that does not:

| Excluded address | Why |
|---|---|
| the zero address | the mint source |
| the launch's own curve | holds all unsold supply, and after a terminal transition holds supply nobody can ever buy (`docs/SPEC.md` section 7) |
| `CreatorVesting` | holds the creator's unreleased allocation |
| `LiquidityLock` | holds position NFTs, not tokens, but is excluded for safety |
| Uniswap v4 `PoolManager` | holds every pool's token balance after graduation, including the locked `LP_SUPPLY` |

`holderCount` on `Launch` is the number of non-excluded addresses with
`balance > 0`. Section 4.3 defines circulating supply over the same exclusion
set, and section 9 is explicit that `holderCount` is inflatable by anyone
willing to pay gas.

### 3.10 `Candle`

Derived aggregation. Keyed `(launch, interval, bucketStart)`. Written by every
event that moves the curve price: `Bought`, `Sold`, `Donated`, `Expired`
(IDX-23).

| Field | Type | Source |
|---|---|---|
| `launch` | `Address` | |
| `interval` | number (seconds) | one of `CANDLE_INTERVALS` |
| `bucketStart` | `Timestamp` | `floor(timestamp / interval) * interval` |
| `open`, `high`, `low`, `close` | `Uint` | **derived**: `priceSpotAfter` over the bucket's events, in log order |
| `volumeEthWei` | `Uint` (wei) | **derived**: sum of `Trade.ethVolumeWei` in the bucket |
| `volumeTokens` | `Uint` (base units) | **derived**: sum of `Trade.tokenAmount` in the bucket |
| `tradeCount` | number | **derived** |
| `tokensSoldClose`, `ethReserveClose` | `Uint` | **derived**: the cursor values at the bucket's last event |

A bucket with no event has no row. The application carries the previous
`close` forward and must not treat a missing bucket as a zero price (APP-14).
A candle's `open` is the `priceSpotAfter` of its own first event, not the
previous bucket's `close`; the two differ and the application must not assume
they are continuous.

### 3.11 `ProtocolConfig`

A single row, created at the indexer's start block and mutated by
`FeeConfigSet`, `TreasurySet` and `LaunchesPausedSet`.

| Field | Type | Source |
|---|---|---|
| `totalFeeBps` | `Bps` | `FeeConfigSet.totalFeeBps` |
| `creatorShareBps`, `protocolShareBps`, `protectionShareBps` | `Bps` | the unpledged trio of `FeeConfigSet` |
| `pledgedCreatorShareBps`, `pledgedProtocolShareBps`, `pledgedProtectionShareBps` | `Bps` | the pledged trio of `FeeConfigSet` |
| `treasury` | `Address` | `TreasurySet.treasury` |
| `launchesPaused` | boolean | `LaunchesPausedSet.paused` |
| `updatedAt` | `Timestamp` | **derived** |

The factory emits `FeeConfigSet` and `TreasurySet` at construction, so this row
is complete from the start block without an RPC read. The creation page still
re-reads `feeConfig()` and `launchesPaused()` by RPC before signing (APP-3),
because a timelocked change can land between the page load and the signature.

### 3.12 `GovernanceOperation`

Behind decision 18. If adopted: created by `OperationProposed`, mutated by
`OperationExecuted` and `OperationCancelled`, with fields `id`, `target`,
`data`, `salt`, `readyAt`, `proposedAt`, `executedAt`, `cancelledAt`, and a
derived `status` of `Pending`, `Ready`, `Executed` or `Cancelled`.

### 3.13 `IndexerStatus`

Derived, not event-sourced. One row.

| Field | Type | Meaning |
|---|---|---|
| `chainId` | number | from configuration |
| `headBlock` | `BlockNumber` | the highest block fully indexed |
| `headTimestamp` | `Timestamp` | its `block.timestamp` |
| `chainHeadBlock` | `BlockNumber` | the chain's head as the indexer last observed it |
| `blocksBehind` | number | **derived** |
| `secondsBehind` | number | **derived**: server time minus `headTimestamp` |
| `backfillComplete` | boolean | whether the historical range is finished |

Every page reads this. The application shows a staleness warning when
`secondsBehind > STALENESS_WARN_SECONDS` or `blocksBehind >
STALENESS_BLOCK_WARN`, and must not present a backfilling index as complete
data (APP-13).

---

## 4. Derived values

Every formula below reads named stored fields. Where `docs/SPEC.md` already has
the formula, this section cites it rather than restating it.

### 4.1 The reserve and sold cursor

Everything in sections 4.2 to 4.4 reads two numbers. They are maintained by one
rule, and the rule is the reason sections 7's first six items exist.

```
live virtual reserves, per docs/SPEC.md section 5.2:
  vE = virtualEthReserve + ethReserve        (wei)
  vT = VIRTUAL_TOKEN_RESERVE - tokensSold    (base units)
```

| Event | `tokensSold` | `ethReserve` |
|---|---|---|
| `LaunchCreated` | `0` | `0` |
| `Bought` | assign `tokensSold` | assign `ethReserve` |
| `Sold` | assign `tokensSold` | assign `ethReserve` |
| `Donated` | unchanged | assign `ethReserve` |
| `CapReached` | unchanged | **unchanged** — the field repeats the `Bought` in the same transaction (IDX-4) |
| `Expired` | unchanged | assign `ethReserve` |
| `GraduationStalled` | unchanged | unchanged — the accompanying `Donated` carries the move |
| `Graduated` | unchanged | assign `0` (IDX-5) |

No delta is ever computed. Every one of these events except `Graduated` carries
the resulting reserve as a field, and `Graduated` is covered by
`docs/SPEC.md` Invariant 43.

### 4.2 Prices

Three different prices, three different uses. Confusing them is the most likely
way for the chart and the trade list to disagree.

**Unit.** `Uint`, wei per whole token, that is per `10**18` base units. At the
default parameters the opening price is about `4.9e8` and the terminal price is
exactly `4e10`, so an integer in this unit has ample precision over the whole
81-fold range of every launch (`docs/SPEC.md` section 5.3).

```
priceSpot        = floor( vE * 10**18 / vT )
```

This is the CPMM marginal price of the curve in `docs/SPEC.md` section 5.1. It
reads `virtualEthReserve`, `ethReserve` and `tokensSold`.

At `tokensSold == CURVE_SUPPLY` and `ethReserve == ethTarget` it equals
`ethTarget * 10**18 / LP_SUPPLY` exactly, which is `docs/SPEC.md` section 5.3's
`P_term`. That is a testable assertion on this formula and on the constants of
section 1.6 together. In practice `ethReserve` at the cap exceeds `ethTarget`
by the accumulated rounding `docs/SPEC.md` section 5.6 measures at a few
thousand wei, and by anything donated, so `priceSpot` at the cap is at or just
above `priceTerminal` and never below it. The application must not present them
as necessarily identical.

```
priceTerminal    = floor( ethTarget * 10**18 / LP_SUPPLY )
```

The price the last curve buyer pays and the price the Uniswap pool opens at.
Constant per launch. Reads `ethTarget` only.

```
priceExecuted    = floor( ethVolumeWei * 10**18 / tokenAmount )      per trade
```

The volume-weighted average price the trader actually got, including the fee,
which is why it reads `ethVolumeWei` (section 4.9) and not `ethToCurve` or
`ethOut`. It is strictly worse than `priceSpot` on both sides, which is
`docs/SPEC.md` Invariant 8 and is a property the trade list should not appear to
contradict.

```
priceSpotAfter   = priceSpot evaluated at (ethReserveAfter, tokensSoldAfter)
```

The chart series. It is stored per trade and per donation so the candle
pipeline never recomputes history.

`priceSpot` is floored, so it is display-only. The exact rational is always
recoverable from `(virtualEthReserve + ethReserve, VIRTUAL_TOKEN_RESERVE -
tokensSold)`, and a transaction's numbers come from `quoteBuy` or `quoteSell`
and nowhere else (APP-4).

### 4.3 Valuation

```
fdvWei           = floor( vE * TOTAL_SUPPLY / vT )
marketCapWei     = floor( vE * circulatingBaseUnits / vT )
circulatingBaseUnits = TOTAL_SUPPLY - sum of balances over the exclusion set of section 3.9
```

`fdvWei` reads the cursor and nothing else. At the default
`virtualEthReserve = 5e17` it is `4.938e17` wei at launch and `4e19` wei at the
cap, which are the two figures `docs/SPEC.md` section 5.3 states, so the formula
is checkable against the specification rather than against an implementation.

`marketCapWei` additionally reads the `TokenBalance` set, so it is available
only when `Transfer` indexing is in place (decision 20). Where it is not, the
API omits the field rather than substituting `fdvWei`, and the application
labels whichever it shows. They differ by at least the unsold curve supply,
which before the cap is most of the supply.

Pre-graduation, the honest headline is `fdvWei` with the curve-held supply shown
alongside it. Post-graduation, neither number is derivable from Pledrin events
at all, because the price is the Uniswap pool's (section 9).

### 4.4 Progress toward the cap

```
capProgressBps   = min(10000, floor( tokensSold * 10000 / CURVE_SUPPLY ))
ethRaisedWei     = ethReserve
ethTargetWei     = ethTarget
```

**`capProgressBps` is the only progress figure the application may present as
progress toward graduation, and it is token-denominated because the cap
condition is `tokensSold == CURVE_SUPPLY` and nothing else** (`docs/SPEC.md`
sections 5.4 step 9 and 7).

A ratio of `ethReserve` to `ethTarget` must not be presented as progress, for a
reason that is arithmetic rather than stylistic: `donate()` raises `ethReserve`
without raising `tokensSold` (`docs/SPEC.md` section 5.7), so that ratio can
reach and exceed 10000 on a launch that will never graduate. Donations into a
nearly-full curve are cheap, which makes a false 100% cheap.

The two measures are also far apart in the middle of the curve, which the
application must not hide by showing only one. From the constants of section
1.6: at `tokensSold = CURVE_SUPPLY / 2` the reserve is exactly one tenth of
`ethTarget`, and at 90% of `CURVE_SUPPLY` it is exactly one half. So the honest
presentation is `capProgressBps` as the bar, and `ethRaisedWei` against
`ethTargetWei` as two absolute amounts beside it. Both are exact and neither is
a percentage of the other.

### 4.5 Effective state, windows and available actions

The on-chain `state` enum and the state a user is in are not the same thing,
because two transitions depend on the clock and the clock emits no event. A
launch whose `gradDeadline` has passed is still `Live` in storage until somebody
calls `expire()`, while `buy` has already been refusing with `BuyWindowClosed`
(`docs/SPEC.md` Invariant 32).

`EffectiveState`, **derived**, evaluated at a query time `now`:

| `EffectiveState` | Condition | Buys | Sells |
|---|---|---|---|
| `Live` | `onChainState == Live && now < gradDeadline` | yes | yes |
| `ExpiryPending` | `onChainState == Live && now >= gradDeadline` | no | yes |
| `Graduating` | `onChainState == Graduating` | no | no |
| `Graduated` | `onChainState == Graduated` | no | no |
| `Expired` | `onChainState == Expired` | no | yes |
| `Stalled` | `onChainState == Stalled` | no | yes |

Windows, all in seconds, all clamped at zero, all read `block.timestamp`:

| Derived field | Formula | Reads |
|---|---|---|
| `secondsUntilDeadline` | `max(0, gradDeadline - now)` | `gradDeadline` |
| `altGraduateAt` | `capReachedAt + ALT_DELAY` | `capReachedAt` |
| `abortAvailableAt` | `capReachedAt + GRAD_GRACE` | `capReachedAt` |
| `secondsUntilAltGraduate` | `max(0, altGraduateAt - now)` | above |
| `secondsUntilAbort` | `max(0, abortAvailableAt - now)` | above |

`availableActions`, **derived**, is the list of permissionless calls that would
not revert on state or time grounds at `now`. It exists because three of the
protocol's transitions are callable by anyone and one of them pays, and because
the launch page has to show which one is live without the user discovering it by
a failed simulation.

| Action | Available when | Pays the caller |
|---|---|---|
| `buy` | `EffectiveState == Live` | no |
| `sell` | `EffectiveState` in `{Live, ExpiryPending, Expired, Stalled}` | no |
| `donate` | `EffectiveState` in `{Live, ExpiryPending, Graduating, Expired, Stalled}` | no, it is a gift (`docs/SPEC.md` section 5.7) |
| `expire` | `EffectiveState == ExpiryPending` | nothing |
| `graduate` | `EffectiveState == Graduating` | the bounty of `docs/SPEC.md` section 8.3, credited not sent |
| `graduateAlt` | `EffectiveState == Graduating && now >= altGraduateAt` | the same bounty |
| `abortGraduation` | `EffectiveState == Graduating && now >= abortAvailableAt` | nothing |
| `claimCreatorFees` | `onChainState` in `{Graduated, Stalled}` and `creatorFeeBalanceWei > 0` | nothing to the caller; pays `creator` |
| `claimProtocolFees` | `protocolFeeBalanceWei > 0` | nothing to the caller; pays the treasury |
| `claimBond` | `bondState == Returned && bondClaimedAt == null` | nothing to the caller; pays `creator` |
| `claimBounty` | a bounty credit exists and is unclaimed (section 4.6) | nothing to the caller; pays the earner |
| `release` | section 4.8's `releasableNow > 0` | nothing to the caller; pays the recorded creator |
| `compound` | a `LockedPosition` exists for the launch | nothing, ever |

`availableActions` is advisory. It is computed from indexed state that is at
least one block old, so it decides what to offer, never what to sign: the
application still simulates (APP-1).

### 4.6 Fee buckets, and what is actually claimable

Three ETH buckets accrue and are paid out later. The read side reconstructs each
from the events that add to it and every event that removes from it. Missing a
single remover leaves a bucket permanently overstated, and an overstated bucket
is a claim button whose transaction reverts `NothingToClaim`.

```
feeChargedTotalWei   = sum over FeeAccrued of (creatorCut + protocolCut + protectionCut + reserveCut)

creatorFeeBalanceWei = sum(FeeAccrued.creatorCut)
                     - sum(FeesClaimed.amount where kind = Creator)
                     - Expired.creatorFeesForfeited

protocolFeeBalanceWei = sum(FeeAccrued.protocolCut)
                      - sum(FeesClaimed.amount where kind = Protocol)
                      - Graduated.bounty

protectionBalanceWei = sum(FeeAccrued.protectionCut)
                     - Expired.protectionForfeited
                     - (the Donated.amount emitted by abortGraduation, where donor == launch)
                     - (at Graduated: the whole remaining balance, which goes to the floor position)
```

Four notes, each of which is a way to be wrong by a little.

The four-amount sum is the whole of the fee in every state, `reserveCut`
included. Summing only the three bucket amounts under-counts every trade
accepted in `Expired` or `Stalled` by exactly the redirected share
(`docs/SPEC.md` section 6.3 and Invariant 59). This is IDX-1.

`feeChargedTotalWei` also equals the sum of the `fee` field over the launch's
`Bought` and `Sold` logs. The two totals agreeing is the reconciliation test
`docs/SPEC.md` Invariant 59 states, and the indexer should assert it rather than
assume it.

`protocolFeeBalanceWei` must subtract `Graduated.bounty`: graduation moves that
amount out of the protocol bucket and into the bounty credit (`docs/SPEC.md`
section 8.2 steps 5 and 6). An indexer that does not shows the treasury a
balance it cannot claim.

`protectionBalanceWei` is zero in every terminal state, by three different
routes, and in `Graduated` the amount that left is not separately logged — it is
folded into `Graduated.ethToFloor` together with the excess reserve and the
core mint's unspent ETH. The balance is therefore assigned to zero at each
terminal transition rather than reduced by a logged amount.

The bounty credit, which has no bucket of its own:

```
bountyCredit(launch, earner)   = Graduated.bounty  if Graduated.caller == earner, else 0
bountyClaimable(launch, earner) = bountyCredit > 0
                                  && no FeesClaimed(kind = Bounty, recipient = earner) for that launch
```

One launch graduates once, so there is at most one credit per launch and the
pair `(launch, earner)` is unique. A `bounty` of zero is possible when the
protocol share is zero, and `claimBounty` then reverts `NothingToClaim`, so the
zero case must not be offered.

### 4.7 Bond outcome

`BondOutcome`, **derived**, is the four-valued answer the launch page and the
badge need. It reads `bondWei`, `bondState` and `bondClaimedAt`.

| `BondOutcome` | Condition | Meaning |
|---|---|---|
| `NotBonded` | `bondWei == 0` | the launch is not Pledged |
| `Held` | `bondState == Bonded` | the bond is still committed; the launch has not settled |
| `Returned` | `bondState == Returned` | the launch delivered; the bond is the creator's, claimed or not |
| `ForfeitedToHolders` | `bondState == Forfeited` | the launch expired; `expire()` added the bond to the reserve |

`pledged` is `bondWei > 0` and is independent of `BondOutcome`: the badge
records that a bond was posted, not that it is still held (`docs/SPEC.md`
section 11.1 and Invariant 29). The application must show both, because a
`Pledged` badge next to a `ForfeitedToHolders` outcome is the single most
informative pair of fields on the page, and showing only the badge is
misleading.

`bondClaimable` is `bondState == Returned && bondClaimedAt == null`. The
distinction between an unclaimed and an already-claimed return is exactly what
`claimBond`'s `BondAlreadyClaimed` refusal exists for (`docs/SPEC.md` section
11.3).

### 4.8 Vesting

The release schedule itself is `docs/SPEC.md` section 12's `releasable(t)`
formula and is not restated here. The read side adds the fields a page needs,
all reading `start`, `cliff`, `duration`, `allocation`, `released` and `voided`:

| Derived field | Formula |
|---|---|
| `cliffEndsAt` | `start + cliff`, null while `start` is null |
| `fullyVestedAt` | `start + cliff + duration`, null while `start` is null |
| `vestedNow` | `docs/SPEC.md` section 12's formula at `now`, plus `released` |
| `releasableNow` | `docs/SPEC.md` section 12's `releasable(now)` |
| `unreleased` | `allocation - released` |
| `percentReleasedBps` | `floor(released * 10000 / allocation)` |

`releasableNow` is zero for a voided schedule, zero before the cliff and zero
for a finished one, and the `releasable(launch)` view cannot tell those apart
(`docs/SPEC.md` section 12). The read side can, because it holds `voided`,
`start` and `released`, so the API returns a `vestingStatus` of `NotStarted`,
`Cliff`, `Vesting`, `Complete` or `Voided`, and the application's copy comes
from that rather than from a zero.

A schedule's clock starts at graduation or at a stall, never at launch, so
`start` is null for every launch still on its curve.

### 4.9 Volume and counts

```
Trade.ethVolumeWei = ethIn - refund      for a buy
                   = ethGross            for a sell
Launch.volumeEthWei = sum of Trade.ethVolumeWei
```

For a buy, `ethIn` is `msg.value` and **includes the refund of a clipped buy**
(`docs/SPEC.md` section 5.4 step 4). Summing `ethIn` over-counts, and it
over-counts specifically on the last and largest buy of every launch that
reaches the cap. `ethIn - refund` equals `ethToCurve + fee` exactly, which is
the arithmetic of section 5.4 step 4, and either expression is correct. This is
IDX-3.

For a sell, `ethGross` is the ETH the curve gave up before the fee, which is the
figure comparable to a buy's `ethToCurve + fee`. `ethOut` is what the seller
received and is the right number for the seller's own row, not for volume.

`tokensSold` is not cumulative volume. It falls on every sell, and sells stay
open forever in `Expired` and `Stalled` (`docs/SPEC.md` Invariant 31), so a
cumulative token volume must be a separate running sum of `Trade.tokenAmount`
(IDX-13).

### 4.10 Reputation, as the API exposes it

`docs/SPEC.md` section 13 stores raw counters and no score, because a score is
policy and a policy in a non-upgradeable contract cannot be corrected. The read
side keeps that discipline: it exposes the counters, a small set of ratios with
explicit denominators, and an explicit undefined case.

```
settledLaunches    = graduations + stalls + expiries
openLaunches       = launches - settledLaunches
graduationRateBps  = floor(graduations * 10000 / settledLaunches)   undefined when settledLaunches == 0
expiryRateBps      = floor(expiries    * 10000 / settledLaunches)   undefined when settledLaunches == 0
bondForfeitRateBps = floor(bondsForfeited * 10000 / bondsPosted)    undefined when bondsPosted == 0
```

`openLaunches` is non-negative by `docs/SPEC.md` Invariant 49. An undefined
ratio is `null` on the wire, never `0`, and the application renders it as "no
settled launches yet" and not as "0%" (APP-11).

The three wei-denominated counters are the part of a reputation that costs
something to produce. `docs/SPEC.md` section 13 says so, and the API orders the
`CreatorProfile` shape accordingly: `bondWeiForfeited`, `bondWeiPosted` and
`ethRaisedGraduated` before any count. A fresh address can manufacture
`launches` for the price of gas; it cannot manufacture `bondWeiForfeited`
without having lost that ETH to holders.

No score, no composite, no decay, no weighting is computed by the indexer or the
API. If the product later wants one, it belongs in the application where it can
be changed, it must be labelled as the application's own opinion, and it must
show the counters it was computed from.

### 4.11 Graduation outcome

```
ethMigratedWei   = ethToCore + ethToFloor
ethStrandedWei   = (ethReserve before Graduated) + (protectionBalanceWei before Graduated)
                   - ethToCore - ethToFloor
tokenDustBaseUnits = LP_SUPPLY - tokensToCore
hasFloorPosition = positionIdFloor != null
```

`ethStrandedWei` is exact and is usually a few wei, bounded above by
`MIN_FLOOR_WEI` when the floor position is skipped entirely (`docs/SPEC.md`
section 10.1). It is the ETH permanently immobilised in the curve, which has no
withdrawal path after graduation. `tokenDustBaseUnits` is the irreducible mint
remainder bounded by `LP_DUST_MAX` (`docs/SPEC.md` Invariant 39).

Both are small and both are real. The application may omit them from the main
view, but it must not display `LP_SUPPLY` as the amount of token migrated when
`tokensToCore` is the amount that was.

---

## 5. The API surface

Read-only. **The API has no mutations and no write endpoints of any kind.**
Every state change in Pledrin is a wallet transaction signed by the user
against the frozen ABIs. An API that could write would be an admin path by
another name.

The transport is decision 21. Every query and every field below must exist
whatever that decision is, under exactly these names.

### 5.1 Rules that bind the API itself

1. Every paginated query takes `limit` (default `PAGE_LIMIT_DEFAULT`, maximum
   `PAGE_LIMIT_MAX`) and `after` (an opaque cursor encoding
   `(blockNumber, logIndex)`), and returns `items`, `nextCursor` and
   `hasMore`. Offset pagination is not used: rows can be rolled back by a reorg
   and an offset silently skips or repeats rows when they are.
2. Every response carries the `IndexerStatus` fields `headBlock` and
   `headTimestamp`, so the application can date every number it renders without
   a second request.
3. `launch(address)` returns null for an address that is not a known launch,
   including an address that is a `CurveDeployed` curve but not a
   `LaunchCreated` launch. It never errors on a well-formed address.
4. Derived time-dependent fields — `EffectiveState`, every `secondsUntil*`,
   `availableActions`, `releasableNow` — are evaluated against the server's
   clock at request time, and the response states the `evaluatedAt` timestamp it
   used. The application recomputes them locally from `gradDeadline`,
   `capReachedAt` and `start` for a live countdown rather than polling.
5. No query returns a row whose `isPledrinLaunch` is false (IDX-8).
6. No query returns raw metadata bytes longer than `METADATA_MAX_BYTES`.
7. Integer encoding is section 1.2's, everywhere, with no exceptions for
   "small" values.

### 5.2 Shapes

`LaunchListItem` — the launch list and every list of launches elsewhere.

`address`, `token`, `name`, `symbol`, `creator`, `pledged`, `bondWei`,
`effectiveState`, `capProgressBps`, `ethRaisedWei`, `ethTargetWei`,
`priceSpot`, `fdvWei`, `holderCount`, `volumeEthWei`, `buyCount`, `sellCount`,
`createdAt`, `gradDeadline`, `secondsUntilDeadline`, `lastTradeAt`,
`bondOutcome`, `metadataDecoded`.

`LaunchDetail` — `LaunchListItem` plus:

every immutable of section 3.1 (`virtualEthReserve`, `ethTarget`, the four fee
fields, `initialPoolId`, `createdTx`), the cursor (`tokensSold`, `ethReserve`),
`priceTerminal`, `marketCapWei`, `circulatingBaseUnits`, `onChainState`,
`capReachedAt`, `graduatedAt`, `stalledAt`, `expiredAt`, `settledAt`,
`secondsUntilAltGraduate`, `secondsUntilAbort`, `availableActions`, the fee
block (`feeChargedTotalWei`, `creatorFeeBalanceWei`, `protocolFeeBalanceWei`,
`protectionBalanceWei`, and the claimed and forfeited totals), the bond block
(`bondState`, `bondOutcome`, `bondSettledAt`, `bondClaimedAt`,
`bondForfeitedWei`, `bondClaimable`), the graduation block
(`graduationPoolId`, `graduationCaller`, `positionIdCore`, `positionIdFloor`,
`ethToCore`, `ethToFloor`, `tokensToCore`, `graduationBounty`,
`ethMigratedWei`, `ethStrandedWei`, `tokenDustBaseUnits`), `vesting` as a
`VestingSummary` or null, `lockedPositions` as a list of `LockedPositionSummary`,
`creatorProfile` as a `CreatorProfile`, `uniqueTraderCount`, `donationCount`,
`donatedEthWei`, `metadataBytes`.

`TradeRow` — `id`, `side`, `trader`, `timestamp`, `blockNumber`, `txHash`,
`tokenAmount`, `ethVolumeWei`, `feeWei`, `priceExecuted`, `priceSpotAfter`,
`isClipped`, `isCreatorFirstBuy`, and for a sell `ethOut`, for a buy `refund`.

`CandleRow` — `bucketStart`, `open`, `high`, `low`, `close`, `volumeEthWei`,
`volumeTokens`, `tradeCount`.

`HolderRow` — `holder`, `balance`, `shareBps` (**derived**:
`floor(balance * 10000 / circulatingBaseUnits)`), `firstHeldAt`.

`CreatorProfile` — `address`, `bondWeiForfeited`, `bondWeiPosted`,
`ethRaisedGraduated`, `launches`, `graduations`, `stalls`, `expiries`,
`bondsPosted`, `bondsReturned`, `bondsForfeited`, `settledLaunches`,
`openLaunches`, `graduationRateBps`, `expiryRateBps`, `bondForfeitRateBps`,
`firstLaunchAt`, `lastLaunchAt`.

`VestingSummary` — `launch`, `creator`, `allocation`, `cliff`, `duration`,
`start`, `released`, `unreleased`, `voided`, `vestingStatus`, `cliffEndsAt`,
`fullyVestedAt`, `releasableNow`, `percentReleasedBps`.

`LockedPositionSummary` — `positionId`, `kind`, `lockedAt`, `compoundCount`,
`liquidityAddedTotal`, `lastCompoundedAt`.

`ClaimableItem` — `launch`, `launchName`, `launchSymbol`, `kind` (the five
`Payout` kinds), `asset`, `amount`, `contract` (`"BondingCurve"` or
`"CreatorVesting"`), `functionName` (`claimCreatorFees`, `claimBond`,
`claimBounty`, `claimProtocolFees`, `release`), `recipient`, `blockedReason`
(null when claimable; otherwise the SPEC-defined refusal that currently
applies), `nextEligibleAt` (for a vesting item inside its cliff).

`PayoutRow` — `id`, `launch`, `kind`, `asset`, `amount`, `recipient`, `caller`,
`timestamp`, `txHash`.

`ProtocolConfigShape` — every field of section 3.11, plus the constants of
section 1.6 so the creation form has its bounds from one place.

### 5.3 Queries

Each exists because a page needs it. The page is named.

| Query | Arguments | Returns | Needed by |
|---|---|---|---|
| `launches` | `sort`, `filter`, `search`, `limit`, `after` | page of `LaunchListItem` | launch list |
| `launch` | `address` | `LaunchDetail` or null | launch detail |
| `launchTrades` | `address`, `side?`, `trader?`, `limit`, `after` | page of `TradeRow` | launch detail |
| `launchCandles` | `address`, `interval`, `from?`, `to?`, `limit` | list of `CandleRow` | launch detail chart |
| `launchHolders` | `address`, `limit`, `after` | page of `HolderRow` | launch detail |
| `creator` | `address` | `CreatorProfile` or null | creator profile, launch detail |
| `creatorLaunches` | `address`, `sort`, `limit`, `after` | page of `LaunchListItem` | creator profile |
| `creatorPayouts` | `address`, `limit`, `after` | page of `PayoutRow` | creator profile, claims |
| `claimable` | `address` | list of `ClaimableItem` | claims |
| `protocolConfig` | — | `ProtocolConfigShape` | creation flow, launch detail |
| `indexerStatus` | — | `IndexerStatus` | every page |

`sort` for `launches`, each with an explicit secondary key of
`(createdAtBlock, address)` so the order is total: `newest`, `oldest`,
`capProgress`, `ethRaised`, `volume`, `lastTrade`, `holders`, `fdv`,
`deadlineSoonest`.

`filter` for `launches`: `effectiveState` (one or more of section 4.5's six
values), `pledged` (boolean), `bondOutcome`, `creator`, `minHolderCount`,
`minVolumeEthWei`, `createdAfter`, `createdBefore`. Filtering on
`effectiveState` is evaluated against the server clock, which is why
`ExpiryPending` is a filterable value and the raw `onChainState` is not
(IDX-11).

`search` matches a case-folded substring of `name` or `symbol`, and an exact
match on `address` or `token`. It must never be the thing that identifies a
launch: names and symbols are unvalidated and not unique (IDX-21).

`claimable(address)` is the query that cannot be replaced by an RPC read,
because it is the only way to find out *which* launches owe an address
anything without enumerating every launch. It aggregates, for the given
address: creator fees on launches where it is the creator and `onChainState` is
`Graduated` or `Stalled`; a returned, unclaimed bond on launches where it is the
creator; a bounty credit on launches it graduated; `releasableNow` on vesting
schedules where it is the recorded creator; and protocol fees **only when the
address equals the configured treasury**. Each item carries the exact function
to call and on which contract, and a `blockedReason` naming the SPEC refusal
when an item is visible but not yet claimable.

Two things are deliberately absent. There is no cross-launch holdings query,
because no page in section 6 needs one: the sell form reads the user's balance
by RPC. There is no governance query, pending decision 18. If a portfolio page
or a governance page is added, the query is added with it.

---

## 6. Pages

The minimum set. For each: what it reads, and what it writes on chain. Visual
design is the frontend engineer's and is not specified here.

### 6.1 Launch list

Reads: `launches` with `sort`, `filter`, `search`; `indexerStatus`.

Writes: nothing.

Behaviour that is data, not design: the default sort is `newest`; the default
filter excludes nothing, because hiding `Expired` launches by default would
hide the outcome a reader most needs to see when judging a creator. Every row
shows `capProgressBps` as the bar and `ethRaisedWei` against `ethTargetWei` as
amounts (section 4.4). Every row shows `pledged` and `bondOutcome` together
(section 4.7). A row whose `effectiveState` is `ExpiryPending` is labelled as
closed to buyers, not as live.

### 6.2 Launch detail

Reads: `launch`, `launchCandles`, `launchTrades`, `launchHolders`,
`indexerStatus`. Live RPC reads before any signature: `state()`,
`tokensSold()`, `ethReserve()`, `gradDeadline()`, `capReachedAt()`,
`quoteBuy(ethIn)` or `quoteSell(tokensIn)`, `balanceOf(user)`,
`allowance(user, curve)`.

Writes, all against `BondingCurve` at the launch's own address:

| Write | Preconditions the page must check first |
|---|---|
| `buy(minTokensOut, deadline)` payable | `effectiveState == Live`; `msg.value >= MIN_BUY_WEI`; `minTokensOut` set from a fresh `quoteBuy` |
| `sell(tokensIn, minEthOut, deadline)` | `effectiveState` allows sells; allowance covers `tokensIn` |
| `PledrinToken.approve(curve, tokensIn)` | only when the allowance is short; exact amount (APP-8) |
| `donate()` payable | `effectiveState` allows donations |
| `graduate()` / `graduateAlt(tickSpacing)` | section 4.5's windows |
| `abortGraduation()` | `now >= abortAvailableAt` |
| `expire()` | `effectiveState == ExpiryPending` |
| the four claim functions | section 4.5 |
| `CreatorVesting.release(launch)` | `releasableNow > 0` |
| `LiquidityLock.compound(positionId)` | a locked position exists |

The chart shows the curve-phase series from `launchCandles` and stops at
`graduatedAt`. After graduation it shows the last curve price, labels it as the
price at graduation, and links to the pool identified by `graduationPoolId` —
not `initialPoolId` (IDX-18). It does not draw a flat line forward from the
last candle (APP-14).

### 6.3 Launch creation

Reads: `protocolConfig` for the fee split, the pause flag and the bounds;
`creator` for the signing address, so a returning creator sees their own
record. Live RPC reads before signing: `launchesPaused()` and `feeConfig()`.

Writes: `LaunchFactory.createLaunch(params)` payable, with
`msg.value == bondWei + creatorFirstBuyWei` exactly, which the factory enforces
with `ValueMismatch`.

The form's fields are `docs/SPEC.md` section 15.2's table and its bounds are
that table's bounds. Three things the page must compute rather than guess:

`ethTarget = 8 * virtualEthReserve`, so the form shows the raise the chosen
`virtualEthReserve` implies, in ETH, as the primary number. The user is
choosing a target, not a virtual reserve.

The bond floor is `max(MIN_BOND_WEI, ethTarget / 10)`, so it moves when the
target moves. A bond is zero or at least that floor; there is no value in
between.

The first buy's token yield has no on-chain quote before the launch exists, and
`FirstBuyTooLarge` reverts the entire launch transaction. The page must
therefore compute the yield itself, in integer arithmetic, from
`docs/SPEC.md` section 5.4 evaluated at `tokensSold == 0`, which reduces to
`netMax = floor(v * (10000 - totalFeeBps) / 10000)` and
`tokensOut = floor(VIRTUAL_TOKEN_RESERVE * netMax / (virtualEthReserve +
netMax))`. The largest permitted first buy follows from
`CREATOR_FIRST_BUY_MAX`: `netMaxLimit = floor(virtualEthReserve *
CREATOR_FIRST_BUY_MAX / (VIRTUAL_TOKEN_RESERVE - CREATOR_FIRST_BUY_MAX))`, and
the form's cap on `creatorFirstBuyWei` is
`floor(netMaxLimit * 10000 / (10000 - totalFeeBps))`.

That closed form is a safe lower bound and not the exact maximum — integer
flooring leaves it a few wei short — so it is a starting point and the forward
evaluation of `tokensOut` against `CREATOR_FIRST_BUY_MAX` is what makes the
bound exact. The forward check is sound because `tokensOut` is non-decreasing
in `v`.

The two figures are different numbers and the form must not confuse them. At
the default parameters `netMaxLimit` is `9049773755656108` wei, which is the
0.00905 ETH `docs/SPEC.md` section 4.1 states as the cost of a maximum first
buy — that is the ETH reaching the curve, fee excluded. The cap on
`creatorFirstBuyWei`, which is `msg.value` and includes the fee, is
`9141185611773846` wei, about 0.00914 ETH. Agreement with section 4.1 on the
first figure is a checkable test of the form's arithmetic.

**The launch's address is not knowable before the transaction lands.** The curve
is deployed with plain `CREATE` from `CurveDeployer` (`docs/SPEC.md` section
2.1), so its address is a function of that deployer's nonce and of nothing in
the parameters. A simulation of `createLaunch` returns an address that another
launch landing first invalidates. The page takes the address from the receipt's
`LaunchCreated` log and from nowhere else (APP-5).

### 6.4 Creator profile

Reads: `creator`, `creatorLaunches`, `creatorPayouts`, `indexerStatus`.

Writes: nothing.

The wei-denominated counters lead, the counts follow, and an undefined ratio
reads as "no settled launches yet" (section 4.10). An address with no record is
presented as unknown, not as safe: a creator can use a fresh address for every
launch and `docs/THREAT_MODEL.md` says that is not preventable. A high
`launches` with zero `graduations` is the signal worth surfacing, and
`bondWeiForfeited` is the only figure on the page that cost the creator
anything to earn.

### 6.5 Claims

Reads: `claimable(address)`, `creatorPayouts(address)`, `indexerStatus`. Live
RPC reads before signing, per item: `creatorFeeEth()`, `protocolFeeEth()`,
`pendingBondWei()`, `pendingBountyWei(earner)`, `releasable(launch)`,
`scheduleOf(launch)`.

Writes: `claimCreatorFees()`, `claimProtocolFees()`, `claimBond()`,
`claimBounty(earner)`, `CreatorVesting.release(launch)`.

Every one of these is a permissionless push to a fixed recipient. The page must
say so: the connected wallet pays gas and the protocol pays the recorded
recipient, which may be a different address. A user claiming on behalf of
someone else is a supported and useful action, and presenting it as "claim your
rewards" when the recipient is another address is wrong.

An item with a `blockedReason` is shown with that reason and no button. The
reason text comes from `docs/SPEC.md` sections 11.3, 12 and 16.2 (APP-10).

---

## 7. What the indexer must get right or be wrong silently

Numbered so tests can be written from them. Each is a way to produce a number
that looks plausible and is wrong, which is worse than a failure because nobody
notices.

**IDX-1. Total a trade's fee from all four `FeeAccrued` amounts.**
`creatorCut + protocolCut + protectionCut + reserveCut` equals the trade's fee
in every state. Summing only the three bucket amounts under-counts every trade
accepted in `Expired` or `Stalled` by the redirected share (`docs/SPEC.md`
sections 6.3 and 16.1, Invariant 59). Test: a launch that expires, then a sell,
then assert `feeChargedTotalWei` equals the sum of `Bought.fee` and `Sold.fee`.

**IDX-2. Never join `FeeAccrued` to a trade.** It is emitted immediately before
its `Bought` or `Sold` in the same transaction and carries no trade identifier.
A single transaction may contain more than one trade on the same launch, so any
pairing rests on log-index adjacency. The per-trade fee is already in
`Bought.fee` and `Sold.fee`, so no pairing is needed: `FeeAccrual` is its own
entity and reconciles at the launch level.

**IDX-3. Volume is `ethIn - refund`, never `ethIn`.** `Bought.ethIn` is
`msg.value` and includes the refund of a clipped buy. The error appears on
exactly one trade per graduating launch — the last and largest one
(section 4.9).

**IDX-4. `CapReached` adds no value to the reserve.** Its `ethReserve` repeats
the `Bought` emitted immediately before it in the same transaction. Treating it
as a reserve-changing event doubles the final buy's contribution. It is the
authority for the `Graduating` transition and for `capReachedAt`, and for
nothing else.

**IDX-5. `Graduated` sets `ethReserve` to zero, and the zero is not derivable
from the event's own fields.** `Graduated` is the one lifecycle event that does
not carry the resulting reserve. `ethToCore + ethToFloor` is less than the
reserve plus the protection balance by the stranded residual (section 4.11), so
subtracting them leaves a small positive reserve forever. `docs/SPEC.md`
Invariant 43 is the authority: after graduation `ethReserve == 0`.

**IDX-6. `Expired` moves the reserve and emits no `Donated`; `abortGraduation`
moves it and does emit one.** `expire()` adds the bond, the accrued creator fee
and the protection balance to the reserve and reports the result in
`Expired.ethReserve` only. An indexer that follows only trades and donations
loses that jump, which on a bonded launch is a large upward price move. An
indexer that synthesises a donation for it as well double-counts the stall case,
where the `Donated` log is real (`docs/SPEC.md` sections 11.4 and 16.1).

**IDX-7. A launch's first logs arrive before the launch does, and some of them
come from an address nothing has announced yet.** In the launch transaction the
log order is: the token's mint `Transfer`, `TokenDeployed`, the curve
constructor's `BondStateChanged` (when bonded), the pool's initialisation,
`CurveDeployed`, then — when there is a first buy — `FeeAccrued`, `Bought`, the
token transfer into vesting and `VestingCreated`, then one to three
`ReputationUpdated`, and only then `LaunchCreated` and `LaunchMetadata`.

Two consequences. No handler may assume a `Launch` row exists when it runs; each
writes only its own fields and upserts. And the curve's constructor-emitted
`BondStateChanged` precedes, in the same transaction, the very log from which
the curve's address becomes discoverable, so a child-address mechanism may not
deliver it at all.

**Normative, so that correctness does not depend on the indexing framework's
within-transaction child resolution: the launch's initial bond state is derived
from `LaunchCreated.bondWei` — `Bonded` when non-zero, `None` otherwise — and
never from the constructor's `BondStateChanged`.** That event remains useful as
a cross-check and must not be the only source of anything. The creator's
first-buy allocation likewise comes from `VestingCreated`, which is emitted by
the always-indexed `CreatorVesting` singleton and needs no child resolution.

**IDX-8. Resolve addresses and attributions only from the factory, never from a
permissionless entry point.** `CurveDeployer`, `TokenDeployer`,
`CreatorVesting.createSchedule` and `LiquidityLock.registerPosition` are all
permissionless, and the last two record `msg.sender` as the "launch".
Therefore:

- The set of curve addresses to index comes from `LaunchCreated.launch`. Never
  from `CurveDeployed.curve`: anyone may deploy a curve and emit fabricated
  trades, states and bond transitions from it.
- The set of token addresses comes from `LaunchCreated.token`. Never from
  `TokenDeployed.token`.
- Every `VestingCreated`, `VestingStarted`, `VestingReleased`, `VestingVoided`,
  `PositionLocked` and `PositionCompounded` is filtered on its `launch` field
  being a known launch before it is attributed or returned by any query. A
  fabricated `VestingCreated` can name any address as `creator` and any
  allocation, so an unfiltered join puts a fake allocation on a real creator's
  profile.
- Where a definitive answer is wanted, `LaunchFactory.isLaunch(address)` is the
  on-chain authority (`docs/SPEC.md` section 16.1).

**IDX-9. `ReputationUpdated.newValue` is absolute: assign it, never increment.**
A handler that increments its own copy double-counts on any replay and drifts
permanently after a rollback. Assignment is idempotent and reorg-safe by
construction. A bonded `createLaunch` emits three of these events in one
transaction, each for a different counter.

**IDX-10. The total order over logs is `(blockNumber, logIndex)`.** Two blocks
may share a `block.timestamp`, so ordering or paginating by timestamp drops and
repeats rows. Row ids include `logIndex` because one transaction can contain
several trades on one launch.

**IDX-11. The state a user is in is time-dependent and emits no event.** A
launch past `gradDeadline` is still `Live` in storage, and `buy` is already
refusing. Any list or filter built on the stored state shows dead launches as
live and offers a buy that always reverts. `EffectiveState` (section 4.5) is the
field the API exposes for filtering; `onChainState` is available on the detail
shape for completeness. The same applies to the `Graduating` sub-windows:
`graduateAlt` becomes available at `capReachedAt + ALT_DELAY` and
`abortGraduation` at `capReachedAt + GRAD_GRACE`, and nothing is emitted at
either moment.

**IDX-12. Every stored row must be a pure function of the canonical log set.**
No handler may call the chain and store the result: an `eth_call` is evaluated
against a head that a reorg can replace and is not reproducible on replay
without an archive node. All time logic uses `block.timestamp` from the log's
block, never the server clock and never `block.number` as a clock
(`docs/CHAIN_FACTS.md`). Where a value genuinely needs a live read, the
application reads it, not the indexer.

**IDX-13. `tokensSold` is not cumulative and is not circulating supply.** It
falls on every sell, and sells never close in `Expired` and `Stalled`
(`docs/SPEC.md` Invariant 31), so cumulative token volume is a separate running
sum. It is also not circulating supply: the creator's first buy is included in
it but the tokens are in `CreatorVesting` (section 4.3).

**IDX-14. Reorg behaviour is a correctness requirement, not an operational
one.** Every entity in section 3 is either assigned from an event field or is a
running aggregate over events, so a correct rollback restores every row exactly.
The requirements: handlers must be idempotent; aggregates must be reconstructible
by replaying the canonical logs from the launch's creation; and no row may
depend on data outside the log set (IDX-12). The confirmation depth or finality
tag to trust on this chain is decision 19 and is configuration until it is
answered — `docs/CHAIN_FACTS.md` records that this is an Arbitrum Nitro chain
but records nothing about its finality, and this document will not guess.

**IDX-15. Fee buckets need every remover, or they overstate forever.** Section
4.6 lists them. The visible symptom is a claim button whose transaction reverts
`NothingToClaim`, which is the exact failure the simulation rule exists to
catch — but by then the user has already been told they have money waiting.

**IDX-16. A returned bond and an unclaimed bond are different things.**
`bondState == Returned` means the launch delivered; it does not mean the ETH is
still there. `bondClaimable` requires that no `FeesClaimed` with `kind = Bond`
has been seen for the launch (section 4.7).

**IDX-17. `positionIdFloor == 0` means there is no floor position.** Zero is not
a position id (`docs/SPEC.md` section 16.1). A handler that creates a
`LockedPosition` row for every id in `Graduated` invents a position `0`, and the
lock emits no `PositionLocked` for it. The authority for locked positions is
`PositionLocked`; `Graduated`'s two id fields are for display and for the null
check.

**IDX-18. A graduated launch's pool is `Graduated.poolId`, which may not be
`LaunchCreated.poolId`.** `graduateAlt` runs the whole procedure on a
caller-chosen `tickSpacing` in `[10, 199]`, which is a different pool key and a
different `poolId` (`docs/SPEC.md` section 8.4 and Invariant 38). Both must be
stored. A link or a post-graduation read built on `initialPoolId` points at an
empty, zero-liquidity pool after an alternative graduation. It also follows that
one token can have several pools, only one of which is the launch's.

**IDX-19. The creator is the launch transaction's sender, and reputation is
per address.** `createLaunch` has no creator parameter. There is no way to
launch on behalf of another address, and no way to link two addresses belonging
to one person. A creator using a fresh address per launch has an empty record
and this is not detectable (`docs/THREAT_MODEL.md`).

**IDX-20. `LaunchMetadata.metadata` is unbounded, unvalidated and attacker
controlled.** `createLaunch` applies no length check and no structure check to
it; the only validated strings are `name` and `symbol`, bounded at 64 and 16
bytes. The indexer stores at most `METADATA_MAX_BYTES` and records the true
length; a longer or undecodable blob yields `metadataDecoded = null` and
`metadataRaw = null`, and must never fail a block or stall the index. The
encoding itself is decision 17.

**IDX-21. `name` and `symbol` are arbitrary and not unique.** They are
length-bounded UTF-8 and nothing else: two launches may share both, and either
may contain control characters, bidirectional overrides or homoglyphs of a
well-known symbol. Nothing may be keyed on them, search must treat them as
untrusted text, and the application must render them as text (APP-9).

**IDX-22. The creator's first buy is a real `Bought` with `buyer = creator`, and
the tokens went to `CreatorVesting`.** An indexer that derives balances from
trades misattributes exactly that one buy (`docs/SPEC.md` section 16.1).
Balances come from `Transfer` and from nowhere else. `isCreatorFirstBuy` is
determined by the trade being in the same transaction as the launch's
`LaunchCreated`, and that trade is excluded from `uniqueTraderCount` and from
any "the creator bought their own launch" signal — which in any case cannot be
complete, because a creator buying through other addresses is not detectable.

**IDX-23. The price moves on events that are not trades.** `Donated` raises
`ethReserve` with no token movement, and `Expired` raises it by the bond plus
the forfeited creator fees plus the protection balance. A candle pipeline driven
by trades alone shows a price gap at the next trade that no candle explains, and
on an expired bonded launch it shows the wrong price indefinitely. The candle
inputs are the four events of section 4.1 that change the cursor.

**IDX-24. Every protocol fee is in ETH.** There is no fee in tokens anywhere
(`docs/SPEC.md` section 3), so no fee is ever a percentage of a token amount,
and a token amount in an event is never net of a fee.

**IDX-25. After graduation the launch emits nothing further.** No trade, no fee,
no price. The series ends; it does not continue flat (`docs/SPEC.md` Invariant
47 and section 9 of this document).

**IDX-26. A `Donated` whose `donor` equals the launch is the protocol, not a
user.** `abortGraduation` emits one to move the stranded protection balance into
the reserve. It belongs in the reserve cursor and must be excluded from
`donationCount`, from `donatedEthWei` and from any list of donors.

**IDX-27. Backfill starts at the configured factory deployment block.** Not at
genesis, and not at a block number derived from a timestamp. Child sources start
at the block of the `LaunchCreated` that announced them.

---

## 8. What the application must never do

The founder's rule is that every transaction is simulated before signing and
explained in plain words. These are that rule made specific. Numbered for the
same reason as section 7.

**APP-1. Every transaction is simulated, and a failed simulation blocks
signing.** No exceptions, including for claims and for permissionless
maintenance calls. The decoded revert reason is shown.

**APP-2. The plain-words explanation must state, for every transaction:** what
leaves the wallet, in ETH and in tokens; what arrives, and at which address;
what the fee is; whether any part of it is unrecoverable; and what can still go
wrong between signing and inclusion. Section 8.1 adds per-call requirements.

**APP-3. Re-read the chain immediately before signing.** The indexer is at least
one block behind. Quotes come from `quoteBuy` or `quoteSell`; balances and
allowances from the token; bucket balances from the curve's own views;
releasable amounts from `releasable(launch)`; the pause flag and the fee config
from the factory. A quote older than `QUOTE_TTL_SECONDS` is stale and must be
refreshed before the signature.

**APP-4. No indexer-derived number may be a transaction argument.**
`minTokensOut`, `minEthOut`, `msg.value` and every vesting or claim amount come
from an on-chain read in the same session. Indexer prices are for display.

**APP-5. Never treat a simulated `createLaunch` return value as the launch
address.** It depends on `CurveDeployer`'s nonce and changes if any other launch
lands first. The address comes from the receipt's `LaunchCreated` log
(section 6.3).

**APP-6. `minTokensOut` on a buy is mandatory and never zero.** A donation can
be used to front-run a buy and reduce its yield, and `minTokensOut` is the
specified mitigation (`docs/SPEC.md` section 5.7). A user-visible slippage
tolerance is required; an unbounded buy must not be offerable.

**APP-7. Never show a "send ETH to this address" path for a curve.** A plain
transfer reverts `DirectEthNotAccepted`; the only ways in are `buy`, `donate`
and `createLaunch` (`docs/SPEC.md` section 5.7).

**APP-8. Approve the exact amount being sold, and never default to an unlimited
approval.** The curve's only pull of a user's tokens is inside `sell`, and
`sell` reverts in `Graduated`, so a leftover approval is inert — but an exact
approval is still the correct default and an unlimited one must not be
pre-selected.

**APP-9. Treat `name`, `symbol` and every metadata field as untrusted text.**
Never as markup, never as a URL the application follows without validation, and
never as an identifier. The canonical identity shown to the user is the launch
address (IDX-21).

**APP-10. Error copy comes from `docs/SPEC.md` and is not written twice.**
Section 16.2 of that document sets the standard — a refusal must not name a
condition a later call can clear when the real blocker is permanent — and
sections 11.3 and 12 give the per-refusal permanence. The application maps each
decoded error to its SPEC-defined meaning, presents "retry" only for a refusal
SPEC marks as clearable, and for an error it does not recognise shows the
decoded name verbatim and blocks signing rather than guessing. In particular:
`BuyWindowClosed` is permanent and `DeadlinePassed` from `buy` is always
clearable by resubmitting (`docs/SPEC.md` Invariant 32); `BondNotReturned` is
clearable while `NoBondPosted`, `BondForfeitedToHolders` and
`BondAlreadyClaimed` are permanent (section 11.3); `ScheduleVoided` and
`ScheduleFullyReleased` are permanent while `NothingToRelease` is not
(section 12); `WrongState` carries the state and is read with
`docs/SPEC.md` Invariant 30.

**APP-11. Never render an undefined ratio as zero.** A creator with no settled
launch has no graduation rate. "0%" is a verdict; `null` is the truth
(section 4.10).

**APP-12. Never present the Dev Bond as an anti-rug guarantee.** It is a
delivery bond committed against one condition: the launch reaches
`CURVE_SUPPLY` before `gradDeadline` (`docs/SPEC.md` section 11.1). The copy
says what it promises and `docs/THREAT_MODEL.md` says what it does not. A
`Pledged` badge is always shown together with `bondOutcome` (section 4.7).

**APP-13. Never present stale or partial index data as current.** A staleness
notice is shown when the thresholds of section 1.7 are exceeded, and a
backfilling index is labelled as incomplete.

**APP-14. Never extend a price series past its last data point.** A missing
candle bucket carries the previous close forward only as an explicitly flat
segment, and the series stops at `graduatedAt` with a label, not a flat line
(section 3.10, IDX-25).

**APP-15. Never present `expire()` as a reward.** It pays the caller nothing and
it permanently forfeits the creator's bond and accrued fees to holders.
`graduate()` is the one permissionless call that pays, and even that is credited
rather than sent, so claiming it is a second transaction (`docs/SPEC.md`
section 8.3).

**APP-16. Never offer an action `availableActions` excludes**, and never rely on
`availableActions` alone: it is computed from data at least one block old, so it
decides what to offer and the simulation decides what to sign.

### 8.1 The simulation and explanation requirements, per call

Every row requires a simulation. The column states what the explanation must
contain beyond APP-2's baseline. The three rows where the user commits capital
they cannot recover are marked.

| Call | The explanation must contain |
|---|---|
| `createLaunch` **(unrecoverable)** | the total ETH leaving the wallet, itemised into the bond and the first buy; that the bond is returned only if the launch reaches the cap before the deadline and is otherwise **paid to holders and lost**, with the deadline as an absolute date and time; that the first buy's tokens go to `CreatorVesting` and cannot be sold before the cliff, with the cliff and the end of vesting as absolute dates; that the creator can claim no fee from the launch until it graduates or stalls; that the fee split is fixed at this launch forever; that the token has no mint, no owner and no pause; that the creator address is the signing wallet and cannot be changed afterwards; and that the launch address will be known only once the transaction lands |
| `buy` | the tokens expected and the `minTokensOut` floor; the fee in ETH; that the price moves with every trade and with any donation. **When the quote is clipped at the cap** (`refund > 0`): the exact ETH that will be consumed, the exact refund, that the fee is charged only on the consumed part, and that this buy ends the curve phase — trading stops until somebody graduates the launch |
| `creatorFirstBuy` | not callable by the application. It is `factory`-only and reachable solely inside `createLaunch`. The application must not expose it |
| `sell` | the ETH expected net of fee and the `minEthOut` floor; in `Expired` or `Stalled`, that part of the fee goes into the reserve rather than to a bucket, which raises the exit price for the remaining holders |
| `approve` | the exact amount and the spender; that it grants only the ability to pull that amount when the user sells |
| `donate` **(unrecoverable)** | that this ETH is a gift to current holders, buys no tokens, cannot be refunded, raises the price for everyone including the donor's own future buys, and reduces the tokens every later buyer receives |
| `graduate` / `graduateAlt` | the bounty amount and that it is credited, not sent, so a second transaction is needed to claim it; that the migration is permanent and the resulting liquidity position can never be withdrawn by anyone; for `graduateAlt`, that it uses a different pool than the one the launch initialised |
| `abortGraduation` **(unrecoverable for the launch, not for the signer)** | that it is irreversible, that the launch becomes `Stalled` permanently, that buys never reopen, that sells reopen forever, and that the creator's bond is returned because the cap was delivered |
| `expire` | that it is irreversible; that it forfeits the creator's bond, the creator's accrued fees and the creator's entire token allocation to holders; and that the caller is paid nothing (APP-15) |
| the four claim functions | the amount, the recipient address, and that the recipient is fixed by the contract and is not the signer unless they happen to be the same address; that the signer pays gas either way |
| `release` | the amount releasable now, the next date at which more becomes releasable, and that it always pays the schedule's recorded creator regardless of who signs |
| `compound` | that it pays the caller nothing and that the gas is a contribution to the locked position; that `NothingToCompound` is the normal outcome when fees have accrued on one side only, and is not a fault |

---

## 9. Limitations of the read side

Stated here so that no page implies a completeness the data does not have.

1. **The locked positions' earnings are not observable from Pledrin events.**
   `PositionCompounded` carries `liquidityAdded` and no collected amounts, so
   cumulative fees earned by a locked position cannot be derived. Liquidity
   growth can. A current figure requires reading Uniswap state by RPC.
2. **Post-graduation price and volume are not in this data model.** Pledrin
   emits nothing after `Graduated`; the pool is an ordinary, unowned, hookless
   v4 pool and `docs/SPEC.md` section 18 puts its tooling out of scope.
   Decision 16 covers what, if anything, the application shows instead.
3. **`holderCount` is inflatable.** Splitting one balance across a thousand
   addresses costs gas and nothing else. Concentration — `TOP_HOLDERS_N` and
   their combined `shareBps` — is the figure that is not inflatable, and is the
   one worth showing.
4. **No address can be linked to another.** Reputation is per address; a creator
   using a fresh address per launch has an empty record; a creator buying their
   own launch through other addresses is indistinguishable from organic demand.
   `docs/THREAT_MODEL.md` states these plainly and the application must not
   imply otherwise.
5. **The indexer is always behind the chain.** Every number it serves is as of
   `headBlock`. This is why no indexer number may be a transaction argument
   (APP-4).
6. **A `FeeAccrued` cannot be attributed to a specific trade** (IDX-2), so there
   is no per-trade fee split, only a per-trade fee total and a per-launch split.
7. **The metadata blob is whatever a creator put there.** It is not validated on
   chain, not interpreted by the protocol, and not guaranteed to decode.

---

## 10. Open decisions this document raises

Recorded in `docs/OPEN_DECISIONS.md` as entries 16 to 21, each with options and
a recommendation. All six block Phase 2 rather than Phase 1, and the first two
block it at the start rather than at the end.

| # | Question |
|---|---|
| 16 | Post-graduation price history, and the Uniswap v4 `PoolManager` ABI that is not in `contracts/abi/` |
| 17 | The encoding of `LaunchMetadata.metadata`, which the protocol does not interpret and both halves must agree on |
| 18 | Whether the indexer indexes `Timelock` and exposes a governance query |
| 19 | The confirmation depth or finality tag to trust on this chain, which `docs/CHAIN_FACTS.md` does not record |
| 20 | Whether ERC-20 `Transfer` is indexed for every launch token, which is what `holderCount` and `marketCapWei` cost |
| 21 | The API transport, which must be chosen once before either half starts |
