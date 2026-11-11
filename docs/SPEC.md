# Pledrin — normative specification

Status: reconciled against the Phase 1 contracts under `contracts/src` on
2026-11-11, and against the Phase 1 test suite later the same day. This document
is normative: where it conflicts with code, the code is wrong, and every
disagreement found during those reconciliations was resolved by correcting
whichever side was wrong rather than by leaving both. Two corrections from that
second pass changed the contracts rather than the document and are verified
against them here: the fee destinations of section 6.3 with Invariant 59, and
`ALT_TICK_SPACING_MAX = 199` in section 15.1. One later contract change is
carried here as well: `FeeAccrued` gained a fifth amount, `reserveCut`
(sections 6.3, 16 and 16.1, and Invariant 59). So is a later round of
revert-reason changes, verified against `contracts/src` on 2026-11-11: the
refusals of `CreatorVesting.release` and `BondingCurve.claimBond`, the order in
which `buy` gives its own, and the standard that governs every refusal in this
protocol (sections 5.4, 11.3, 12 and 16.2, and Invariants 32, 62 and 63).
Decisions 14 and 15 of `docs/OPEN_DECISIONS.md` were resolved into that round,
and were the only two refusals this document had recorded as unsettled. Nothing
in the round changed a condition under which a trade, a claim or a release
succeeds. Where this document is silent, `docs/OPEN_DECISIONS.md` records the
gap.

All external addresses come from `docs/CHAIN_FACTS.md` and nowhere else. No
address appears in this document that is not in that file.

Notation: `floor(x)` and `ceil(x)` are integer division rounded down and up.
`mulDiv(a, b, c)` is `floor(a * b / c)` computed on a 512-bit intermediate.
`mulDivUp` is the same rounded up. All token quantities are in base units
(18 decimals) unless written "whole tokens". All ETH quantities are in wei.

---

## 1. Chain and external dependencies

Robinhood Chain, Arbitrum Nitro. Mainnet chain ID 4663, testnet 46630. ETH is
the gas token and the only quote currency used by the protocol.

Consequences that bind the design:

- All time logic uses `block.timestamp`. `block.number` is never read.
- Calldata size dominates transaction cost, not opcode count. Function
  signatures are kept narrow; per-launch metadata beyond `name` and `symbol` is
  emitted in an event and never written to storage. The calldata cost of that
  metadata is paid once at launch and is unavoidable; what is avoided is the
  storage cost and all subsequent reads.
- No logic may depend on precise gas accounting or on `gasleft()`.

External contracts used, all verified present on both networks with identical
code size:

| Role | Address |
|---|---|
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Those three are the whole external surface. No Pledrin contract references
Uniswap v4's StateView: pool state is read with `StateLibrary`'s `extsload` path
directly against PoolManager, which needs no second address.

Every external address reaches the contracts as a constructor argument. No
external address is a literal in any source file, which makes the rule at the
top of this document checkable mechanically rather than by review.

### 1.1 Graduation venue: Uniswap v4, decided

Uniswap v4 is the graduation venue. This is a settled trade-off, not an open
question.

v2 and v3 exist only on mainnet 4663. None of the v3 addresses in
`docs/CHAIN_FACTS.md` have code on testnet 46630, and the mainnet
`NonfungiblePositionManager.WETH9()` address has no code on testnet either. A v3
design would make graduation — the single most consequential and least
reversible transaction in the protocol — impossible to test end to end on the
public testnet, and would additionally require a wrapped-native address that is
not known on testnet. That is disqualifying.

The full v4 stack is deployed at identical addresses on both networks, so every
graduation path is testable against the real contracts before it runs on
mainnet. Two further v4 properties are load-bearing:

1. Native ETH is usable directly as a pool currency (`currency0 = address(0)`),
   so graduation performs no wrapping step and needs no WETH address at all.
   Because `address(0)` sorts below every token address, ETH is always
   `currency0` and the launch token is always `currency1`. There is no ordering
   branch anywhere in the code.
2. Positions minted through PositionManager are ERC-721 (`symbol()` is
   `UNI-V4-POSM`, `supportsInterface(0x80ac58cd)` is true on both networks), so
   a position can be transferred to a contract with no outbound transfer path
   and thereby made permanent.

The cost of this choice: v4 liquidity on Robinhood Chain is younger than v2
liquidity, and routing to a v4 pool depends on UniversalRouter
(`0x8876789976dEcBfCbBbe364623C63652db8C0904`) rather than the better-known v2
routers. That is accepted.

---

## 2. Contract set

One contract per responsibility. No contract is upgradeable. No proxy. No
contract holds a power over user funds.

| Contract | Instances | Holds | Owner |
|---|---|---|---|
| `PledrinToken` | one per launch | nothing | none |
| `BondingCurve` | one per launch | curve ETH reserve, fee buckets, bond ETH, unsold tokens | none |
| `LaunchFactory` | singleton | global launch config, reputation counters | `Timelock` |
| `CreatorVesting` | singleton | vested creator token allocations | none |
| `LiquidityLock` | singleton | graduated position NFTs, retained compounding residuals | none |
| `Timelock` | singleton | nothing | protocol governance |
| `CurveDeployer` | singleton | nothing | none |
| `TokenDeployer` | singleton | nothing | none |

Eight contracts, two of which are plumbing: `CurveDeployer` and `TokenDeployer`
carry creation code and nothing else, for the reason in section 2.1.

`BondingCurve` is one instance per launch rather than a singleton with a
`launchId` argument. Reasons: a per-launch instance makes `address(curve).balance`
the single number that must cover that launch's obligations, which makes
Invariant 3 a one-read assertion; it removes a 32-byte `launchId` from every
trade's calldata on a chain where calldata dominates cost; and it removes any
possibility of cross-launch accounting confusion.

The deployment mechanism is no longer purely an open decision: decision 5 of
`docs/OPEN_DECISIONS.md` chose option A, a full deployment per launch, and that
is what is implemented. Section 2.1 is the cost of that choice.

Fee splitting is performed inside `BondingCurve`, not in a separate splitter.
A separate splitter would move value across a contract boundary on every trade
for no gain.

### 2.1 Why there are two deployer contracts

`BondingCurve`'s creation code plus `LaunchFactory`'s own code exceeds EIP-170's
24,576-byte runtime limit, so the factory cannot carry it. Measured with the
build settings in `contracts/foundry.toml`:

| Contract | Runtime | Creation code | Free of 24,576 |
|---|---|---|---|
| `CurveDeployer` | 23,952 bytes | 23,978 bytes | 624 bytes |
| `BondingCurve` | 19,374 bytes | 23,099 bytes | 5,202 bytes |
| `LaunchFactory` | 7,232 bytes | 8,645 bytes | 17,344 bytes |
| `TokenDeployer` | 2,979 bytes | 3,005 bytes | 21,597 bytes |
| `PledrinToken` | 1,488 bytes | 2,602 bytes | 23,088 bytes |

Every figure is the landed tree, read from the build artifacts. The two
combinations EIP-170 rules out follow from those parts, because a contract that
embeds another contract's creation code cannot be smaller than the code it
embeds:

- **A factory carrying `BondingCurve`'s creation code.** The creation code alone
  is 23,099 bytes, which leaves 1,477 bytes of the limit for the entire factory,
  and the factory is 7,232 bytes. Carrying both is at least 30,331 bytes, 5,755
  over the limit. Nothing recoverable from dropping the external call into a
  deployer closes a gap of that size.
- **One deployer carrying both `BondingCurve`'s and `PledrinToken`'s creation
  code.** At least 23,099 + 2,602 = 25,701 bytes, 1,125 over the limit before any
  dispatch code of its own. This is why there are two deployers and not one.

The limit is therefore the reason for two deployers rather than one, and for any
deployer at all:

- **`CurveDeployer`** carries `BondingCurve`'s creation code.
  `deploy(CurveConfig)` is payable, forwards `msg.value` to the curve it creates
  as that launch's bond, and passes `msg.sender` to the curve as its `factory`.
  A curve deployed by anyone else is therefore absent from the factory's
  `isLaunch` mapping and can write no reputation counter; a curve that names the
  real factory cannot even finish a lifecycle, because `recordGraduation`,
  `recordStall` and `recordExpiry` all revert `NotLaunch` for a caller the
  factory did not deploy.
- **`TokenDeployer`** carries `PledrinToken`'s creation code and mints the whole
  supply to `msg.sender`. `BondingCurve`'s constructor calls it, so the supply is
  still minted in one constructor directly to the curve as section 3 requires,
  and the curve then asserts
  `totalSupply() == TOTAL_SUPPLY && balanceOf(address(this)) == TOTAL_SUPPLY`
  before it accepts the token at all.

Both deployers are stateless, ownerless and permissionless, hold nothing, and
have no function other than `deploy`. Anyone may call either one; what a caller
gets is a contract of its own with no standing in the factory and no relation to
any launch (`docs/THREAT_MODEL.md` section 8.2).

What this construction preserves is the property that matters: every launch is a
full `CREATE` deployment whose immutables are set in a real constructor. There is
no clone, no immutable-args offset, no proxy, no initialiser and no
`delegatecall`, so Invariant 54 is intact.

The margin is a standing constraint on future work. `BondingCurve`'s creation
code is 23,099 bytes of `CurveDeployer`'s 23,952 runtime bytes, leaving
**624 bytes** — 2.5% of the limit — before the deployer itself becomes
undeployable. `CurveDeployer`'s own code above the creation code it carries is
853 bytes and has not changed, so every byte added to the curve is a byte off
that margin, and fewer than 624 bytes of new curve code exhausts it.

All 421 bytes of margin lost since the previous measurement are the
post-terminal fee redirect of section 6.3. The other changes in the same pass
were free or better than free: overriding `transferOwnership` to revert made
`LaunchFactory` 92 bytes smaller, because the revert replaces `Ownable`'s body;
adding `FeeAccrued`'s `reserveCut` field made the curve 29 bytes smaller; and the
`SafeCast` binding change is byte-identical, verified by building the tree twice
with only those directives differing and comparing the deployed bytecode of
every affected contract.

The levers for reclaiming margin are the two this section already names:
decision 5 option B, which is a clone with immutable args, or splitting the
curve. Neither
is a change that can be made late. Narrowing the fee function is not a lever —
branching its two bucket writes costs more code at `optimizer_runs = 200` than
the writes it would skip — so a future change that needs room must take one of
the two structural options rather than trimming section 6.3.

### 2.2 Deployment order

The order below has no cycles, so no address prediction, no CREATE2 salt and no
post-deployment wiring step is needed.

| Order | Contract | Constructor arguments |
|---|---|---|
| 1 | `Timelock` | the initial admin |
| 2 | `CreatorVesting` | none |
| 3 | `LiquidityLock` | PositionManager; PoolManager is read off it so the two cannot be mismatched |
| 4 | `CurveDeployer` | none |
| 5 | `TokenDeployer` | none |
| 6 | `LaunchFactory` | the timelock as owner, both deployers, `CreatorVesting`, `LiquidityLock`, PoolManager, PositionManager, Permit2, the treasury, the initial fee config |

`CreatorVesting` can precede the factory because it holds no factory address at
all: every mutating function is keyed by its caller (section 12). That is what
removes the factory-vesting cycle, which would otherwise be the one place in the
system that needed a predicted address or a setter.

---

## 3. Token

`PledrinToken` is a plain ERC-20 fixed at deployment:

- `totalSupply()` is exactly `1_000_000_000 * 10**18` = `1e27` base units,
  minted once in the constructor and never changed.
- `decimals()` is `18`.
- No `mint`, no `burn`, no `owner`, no pause, no blacklist, no transfer hook, no
  fee on transfer, no rebase, no upgrade path, no privileged role of any kind.
  The constructor is the only code that ever moves supply other than ERC-20
  `transfer` / `transferFrom`.
- `name` and `symbol` are set at construction from launch parameters and are
  immutable.

The protocol never takes a fee in tokens. Every protocol fee is denominated in
ETH. This is what allows the token to be a plain ERC-20 with no hook: nothing in
the protocol needs to observe or intercept a transfer.

The entire supply is minted to the launch's `BondingCurve`, in one constructor.
`BondingCurve`'s constructor calls `TokenDeployer.deploy(name, symbol)`, which
deploys the token and mints `TOTAL_SUPPLY` to `msg.sender` — the curve — inside
the token's own constructor. The curve then requires
`totalSupply() == TOTAL_SUPPLY` and `balanceOf(curve) == TOTAL_SUPPLY` exactly,
and reverts `InvalidToken` otherwise: a launch owns its whole supply at
construction or it does not exist. Why the mint goes through a separate deployer
contract at all is section 2.1.

---

## 4. Supply allocation

The allocation is a global constant, identical for every launch. It is not
configurable.

| Bucket | Whole tokens | Base units | Share |
|---|---|---|---|
| Curve sale supply `C` | 900,000,000 | `9e26` | 90% |
| Graduation liquidity `S_LP` | 100,000,000 | `1e26` | 10% |
| Free creator allocation | 0 | `0` | 0% |
| Total | 1,000,000,000 | `1e27` | 100% |

### 4.1 There is no free creator carve-out

A creator receives no tokens for free. The only creator token allocation is a
**priced, vested first buy**: in the launch transaction the creator may spend
their own ETH on the curve at the opening price, and the tokens that purchase
yields are delivered to `CreatorVesting`, not to the creator's wallet.

Reasoning, stated because this is the design's most contested choice:

- A fixed split with no carve-out means the curve constants in section 5 are
  global constants rather than per-launch values. One audited curve, one set of
  numbers, no per-launch parameter that can be mis-set, less calldata.
- The creator pays the same price as the first public buyer for the same tokens.
  No buyer is diluted by a gift.
- The allocation is in a contract that physically cannot release it early. This
  is prevention. It is strictly stronger than any rule that detects a creator
  sale and punishes it afterwards, because by the time such a rule fires the
  tokens are already sold.
- A creator who wants an early position will take one with or without the
  protocol's permission. Making the honest path cheap, visible, bounded and
  locked is better than making it invisible. `docs/THREAT_MODEL.md` states
  plainly what this does not achieve.

The first buy is capped at `CREATOR_FIRST_BUY_MAX = 18,000,000 * 10**18` base
units, 1.8% of total supply. At the default parameters that costs 0.00905 ETH,
which is 0.23% of the target raise — early curve tokens are cheap by
construction, which is exactly why the cap is on tokens and not on ETH.

---

## 5. Bonding curve

### 5.1 Form

A constant-product market maker over virtual reserves. Chosen over a
linear-price or exponential curve because:

- Both directions are closed form with only `mulDiv`. No square root, no
  logarithm, no iteration, no loop.
- Solvency reduces to a single multiplication (section 5.6), which makes the
  protocol's most important invariant a one-line assertion rather than an
  argument about an integral.
- There are no LP shares, so the first-depositor and share-inflation attacks
  that affect pool-share designs are structurally absent.
- The price is finite and non-zero over the whole sale range.

### 5.2 State

Per launch, in storage:

| Name | Type | Units | Meaning |
|---|---|---|---|
| `tokensSold` (`s`) | `uint128` | base units | tokens transferred out by buys, minus tokens returned by sells |
| `ethReserve` (`r`) | `uint128` | wei | ETH backing the curve |

The rest of the curve's storage is accounting rather than pricing. It is listed
here in one place because Invariant 3 is stated over all of it:

| Name | Type | Units | Meaning | Section |
|---|---|---|---|---|
| `creatorFeeEth` | `uint128` | wei | accrued creator fee | 6 |
| `protocolFeeEth` | `uint128` | wei | accrued protocol fee | 6 |
| `protectionEth` | `uint128` | wei | accrued holder-protection fee | 6, 10 |
| `bondHeldWei` | `uint128` | wei | bond ETH still on the bond account | 11 |
| `pendingBondWei` | `uint128` | wei | bond credited to the creator, awaiting `claimBond` | 11 |
| `pendingBountyWei` | `mapping(address => uint256)` | wei | graduation bounty credited per earner | 8.3 |
| `pendingBountyTotalWei` | `uint128` | wei | sum of every unclaimed bounty | 8.3 |
| `state` | `State` | — | lifecycle state | 7 |
| `bondState` | `BondState` | — | bond state | 11.3 |
| `capReachedAt` | `uint64` | unix seconds | time the cap was reached, zero before | 7, 8 |
| `graduatedAt` | `uint64` | unix seconds | time the launch graduated, zero before | 8 |

Per launch, immutable:

| Name | Type | Units | Meaning |
|---|---|---|---|
| `virtualEthReserve` (`vE0`) | `uint128` | wei | the curve's only free scalar |
| `ethTarget` (`R_target`) | `uint128` | wei | `ETH_TARGET_MULTIPLE * vE0`, computed once in the constructor |
| `sqrtPriceTerminal` | `uint160` | Q64.96 | the pool's opening price, computed once in the constructor (section 8.1) |
| `bondWei` | `uint128` | wei | the dev bond posted at launch, possibly zero (section 11.1) |
| `gradDeadline` | `uint64` | unix seconds | `block.timestamp + gradWindow`, fixed at construction |
| `totalFeeBps` | `uint16` | bps | the launch's total trading fee (section 6) |
| `creatorShareBps`, `protocolShareBps`, `protectionShareBps` | `uint16` | bps of the fee | the launch's fee split (section 6) |
| `factory`, `token`, `creator`, `protocolTreasury`, `vesting`, `liquidityLock`, `poolManager`, `positionManager`, `permit2` | `address` | — | the launch's fixed counterparties |

`gradWindow` itself is not stored: only the deadline it implies is. There is no
`launchedAt` field anywhere in the curve, which is why the bond condition of
section 11.1 is a comparison against `gradDeadline`.

Global constants:

| Name | Value |
|---|---|
| `VIRTUAL_TOKEN_RESERVE` (`vT0`) | `1_012_500_000 * 10**18` = `1.0125e27` |
| `CURVE_SUPPLY` (`C`) | `900_000_000 * 10**18` = `9e26` |
| `LP_SUPPLY` (`S_LP`) | `100_000_000 * 10**18` = `1e26` |
| `VIRTUAL_TOKEN_TAIL` (`tau`) | `vT0 - C` = `112_500_000 * 10**18` = `1.125e26` |

Live reserves are derived, never stored and never read from balances:

```
vE = vE0 + r
vT = vT0 - s
K  = vE0 * vT0            (immutable per launch)
```

**The curve prices from storage only.** `r` is a storage variable, not
`address(this).balance`. `s` is a storage variable, not
`token.totalSupply() - token.balanceOf(this)`. Forcing ETH or tokens into the
contract by any means cannot change any price. This single rule removes the
entire class of balance-manipulation and donation-manipulation attacks against
pricing. Value genuinely intended as a donation goes through `donate()`
(section 5.7), which updates `r` explicitly.

### 5.3 Why these constants

The constants satisfy `C * tau == vT0 * S_LP` exactly in base units
(`1.0125e53` on both sides, verified). Three exact identities follow, with zero
division remainder at any step:

```
R_target  = vE0 * C / tau        = 8 * vE0          ETH raised at the cap
vE(s = C) = K / tau              = 9 * vE0          terminal virtual ETH
P_term    = vE0 * vT0 / tau^2    = R_target / S_LP  terminal marginal price
```

The third identity is the reason for this exact choice of constants: **the
curve's final marginal price is exactly the price of a full-range pool holding
`R_target` wei against `S_LP` base units.** Graduation therefore opens the
Uniswap pool at precisely the price the last curve buyer paid. There is no
step down into the pool for holders and no step up for an arbitrageur to
harvest. Any other split of the supply leaves a gap: an 80/20 split, for
example, opens the pool 20% below the curve's last price.

Two further derived facts, both exact:

- The price range from the first base unit to the cap is `(vT0 / tau)^2 = 81`.
  Every Pledrin launch is an 81-fold price range, always.
- At the default `vE0 = 0.5 ether`: opening fully-diluted valuation 0.4938 ETH,
  graduation FDV 40 ETH, `R_target` 4 ETH.

### 5.4 Buy

`buy(uint256 minTokensOut, uint256 deadline)`, payable. Requires
`state == Live`, `block.timestamp < gradDeadline`,
`block.timestamp <= deadline`, and `msg.value >= MIN_BUY_WEI`, checked in that
order. The window is checked before the caller's own deadline because a closed
window is permanent while a passed deadline is cleared by resubmitting, so the
order decides which refusal a caller sees when both are true and it names the one
that cannot be cleared (section 16.2, Invariant 32).

Let `v = msg.value`.

```
1.  feeMax   = ceil(v * totalFeeBps / 10000)
2.  netMax   = v - feeMax
3.  dT       = mulDiv(vT, netMax, vE + netMax)                 // round down
4.  if dT <= C - s:
        net    = netMax
        fee    = feeMax
        refund = 0
    else:
        dT     = C - s
        net    = mulDivUp(vE, dT, vT - dT)                     // round up
        fee    = ceil(net * totalFeeBps / (10000 - totalFeeBps))
        require(net + fee <= v)                                // else revert
        refund = v - net - fee
5.  require(dT >= 1 && dT >= minTokensOut)
6.  r += net
7.  s += dT
8.  split fee per section 6; `buy` runs only in `Live`, so section 6.3 redirects
    nothing and the three buckets are the whole destination
9.  if s == C: state = Graduating, capReachedAt = block.timestamp
10. token.transfer(msg.sender, dT)
11. if refund > 0: send refund to msg.sender
```

Steps 6 to 9 are every storage write the trade performs, including the
`Live -> Graduating` transition, and all of them complete before either transfer
in steps 10 and 11. The transition is not an epilogue after the transfers:
ordering it last would leave a window, inside a single call, in which the cap is
reached and the state does not say so.

Step 4's second branch is the final buy, clipped exactly to the cap. The buyer
pays only for the tokens they receive and the fee is recomputed on the ETH
actually consumed, so the clipped buyer is not charged a fee on the refunded
portion.

**The clipped buy never costs more than the value sent, so step 4's
`require(net + fee <= v)` cannot fail for any input.** The rounding overshoot it
was previously described as covering is zero, not two wei. Proof:
`feeMax = ceil(v * f / 10000)` gives
`netMax = v - feeMax = floor(v * (10000 - f) / 10000)`; the token output of
step 3 is non-decreasing in `netMax` and `net` is the least ETH that buys `dT`
tokens, so the clip's own precondition — that the unclipped quote exceeded
`C - s` — forces `netMax >= net`; that gives `v * (10000 - f) / 10000 >= net`,
and since `v` is an integer, `v >= net + ceil(net * f / (10000 - f))`, which is
exactly `net + fee`. The `require` is therefore a defensive assertion and not a
reachable branch. It stays, and must not be deleted as dead code: if a future
change to the fee rounding ever makes it reachable, the buy has to revert rather
than underflow the refund subtraction on the next line.

Step 5's `dT >= 1` is defensive in the same sense. A quote yields zero tokens
only when the curve has nothing left to sell, and the buy that takes the last
base unit moves the launch to `Graduating` in the same transaction, where
step 1's state check fires first; the only other arithmetic route to a zero
quote needs
`ethReserve` above roughly `1e38` wei, which is about `1e20` ETH and cannot
exist. Neither guard is reachable through the protocol and both are specified,
kept and tested: the reachable surface of this function is narrowed by the state
machine, not by the arithmetic, and that is a property worth asserting rather
than assuming.

### 5.5 Sell

`sell(uint256 dT, uint256 minEthOut, uint256 deadline)`. Requires
`state in {Live, Expired, Stalled}`, `block.timestamp <= deadline`, and
`dT >= 1`. The caller must have approved the curve for at least `dT`, because
step 10 pulls the tokens with `transferFrom`.

```
1.  require(dT <= s)
2.  gross = mulDiv(vE, dT, vT + dT)                            // round down
3.  require(gross >= 1)
4.  fee   = ceil(gross * totalFeeBps / 10000)
5.  out   = gross - fee
6.  require(out >= 1 && out >= minEthOut)
7.  r -= gross, then r += feeToReserve
8.  s -= dT
9.  split fee per sections 6 and 6.3, which yields feeToReserve: the part of the
    fee that has no payout path in this state and goes to r instead of to a
    bucket. It is zero in `Live` and can be non-zero only in `Expired` and
    `Stalled`.
10. token.transferFrom(msg.sender, address(this), dT)
11. send out to msg.sender
```

Steps 7 and 9 are one atomic group: the split determines the `feeToReserve` that
step 7 adds back, so it is evaluated first, and the order in which the two reach
storage is immaterial. `r -= gross` cannot underflow by Invariant 2 and the
add-back only raises `r`, so the sequence is safe in either order. The seller
still pays the whole fee; what the redirect changes is where part of it lands.

Steps 7 to 9 are every storage write the trade performs and they complete before
the seller's tokens are pulled in step 10. Pulling first and writing afterwards
would be observationally identical — any revert in the pull rolls the writes
back, the launch token is the protocol's own hookless ERC-20 with no callback,
and `sell` holds a reentrancy guard — but strict checks-effects-interactions is
the project's standard and Invariant 55 points the same way, so the order above
is the normative one.

There is no minimum on sells beyond `out >= 1`. A holder with a dust balance
must always be able to exit; a minimum sell size would trap them.

### 5.6 Solvency

The sell formula can pay out at most `r` for any input the contract will accept
if and only if `vE * vT >= K`. Derivation: a seller may present at most
`dT = s = vT0 - vT`, and

```
gross <= r
<=> vE * dT / (vT + dT) <= vE - vE0
<=> vE0 * dT <= vT * (vE - vE0)
<=> vE0 * (vT0 - vT) <= vT * r
<=> vE0 * vT0 <= vT * (vE0 + r)
<=> K <= vE * vT
```

The rounding directions in 5.4 and 5.5 make `vE * vT` monotonically
non-decreasing: a buy adds `net` to `vE` exactly while removing at most the
exact token amount from `vT`; a sell adds `dT` to `vT` exactly while removing at
most the exact ETH amount from `vE`. Therefore `vE * vT >= K` holds from
initialisation forever, and full solvency follows. This is Invariant 1 and
Invariant 2.

The same inequality evaluated at `s = C` gives `vE >= K / tau = 9 * vE0`, hence
`r >= 8 * vE0 = R_target`. **The solvency invariant proves that the graduation
ETH target is always met or exceeded.** Simulation over 4,000-trade random
sequences at the extremes of the `vE0` range confirms both results, with the
product drifting upward and `r` at the cap exceeding `R_target` by a few
thousand wei of accumulated rounding.

### 5.7 Donate

`donate()`, payable. Requires `state in {Live, Graduating, Expired, Stalled}`
and `msg.value >= 1`. Effect: `r += msg.value`. It does not change `s`, `vT`,
any fee bucket, or any lifecycle state, and it never mints tokens.

A donation raises `vE` without raising `s`, which raises the sell price for
every current holder and lowers the token count every future buyer receives.
It is a one-way transfer of value from the donor to current holders, costs
nothing to distribute, and requires no snapshot and no claim mechanism. It is
the mechanism by which forfeited bonds and stranded protection ETH reach
holders (sections 11 and 12).

Because a donation moves the price, it can be used to front-run a pending buy
so that the buyer receives fewer tokens than quoted. `minTokensOut` on `buy` is
mandatory and is the mitigation.

`donate()` is the only way to add ETH to `r`. A plain ETH transfer to the curve
reverts: the curve's `receive` function accepts value from PositionManager alone,
which is the sweep of unspent `currency0` from a graduation mint, and reverts
`DirectEthNotAccepted` for every other sender. That is not a pricing measure —
pricing reads storage either way (section 5.2) — but a usability one: a user
cannot silently lose ETH by sending it to the curve instead of calling `donate`.

### 5.8 Rounding, summarised

Every rounding step rounds against the user and in favour of curve solvency.

| Step | Direction | Effect on user |
|---|---|---|
| Buy fee from `msg.value` | up | less ETH reaches the curve, fewer tokens out |
| Buy tokens out | down | fewer tokens |
| Clipped-buy ETH required | up | pays more |
| Clipped-buy fee | up | pays more |
| Sell gross ETH out | down | less ETH |
| Sell fee from gross | up | less ETH |
| Fee share floors, remainder to holders | down for creator and protocol | dust goes to holders |
| `sqrtPriceX96` at pool init | down | pool opens at most 1 part in 1e32 below terminal |

---

## 6. Fees

`totalFeeBps` is set from factory config at launch and copied immutably into the
curve. Default 100 (1%). Hard maximum `MAX_TOTAL_FEE_BPS = 200` enforced in
code, not only in config.

Every fee is in ETH. The fee is split three ways by shares expressed in
hundredths of a percent of the fee, which must sum to exactly 10000.

| Share | Unpledged default | Pledged default |
|---|---|---|
| `creatorShareBps` | 3000 | 5000 |
| `protocolShareBps` | 4000 | 3000 |
| `protectionShareBps` | 3000 | 2000 |

"Pledged" means `bondWei > 0` at launch. A bonded launch gives the creator a
larger share of the same total fee; the total the trader pays is identical
either way. The share set is fixed at launch from the bond decision and never
changes afterwards, so a launch's fee economics cannot shift under its holders.

### 6.1 Split arithmetic and the remainder

```
creatorCut    = floor(fee * creatorShareBps    / 10000)
protocolCut   = floor(fee * protocolShareBps   / 10000)
protectionCut = fee - creatorCut - protocolCut
```

The third share is computed as the residual, never as a product. Therefore
`creatorCut + protocolCut + protectionCut == fee` holds by construction for
every possible `fee`, with no wei created and none lost. This is Invariant 14.

**The rounding remainder goes to the holder-protection pool**, and from there
into permanently locked liquidity (section 10), or into the curve reserve if the
launch never graduates (sections 6.3 and 10.3). The dust therefore flows to
holders, which is the party that should receive it when a rounding direction is
ambiguous. No other destination is permitted.

### 6.2 Accrual and claiming

Three per-launch ETH buckets: `creatorFeeEth`, `protocolFeeEth`,
`protectionEth`. All three are accrued in storage and paid out later, never
pushed during a trade. A trade never makes an outbound call to the creator or
the treasury.

| Function | Caller | Precondition | Destination |
|---|---|---|---|
| `claimCreatorFees()` | anyone | `state in {Graduated, Stalled}` and `creatorFeeEth > 0` | `creator` |
| `claimProtocolFees()` | anyone | any state, and `protocolFeeEth > 0` | `protocolTreasury` |
| `claimBond()` | anyone | `bondState == Returned` and `pendingBondWei > 0` | `creator` |
| `claimBounty(address earner)` | anyone | `pendingBountyWei[earner] > 0` | `earner` |

The precondition column is the whole condition for success, so a call that fails
any part of it reverts. Which error it reverts with is not interchangeable: one
error is deliberately not reused across reasons of unequal finality.
`claimBond`'s four refusals are in section 11.3, and the standard the whole
protocol applies, together with the shared errors kept in spite of it, is in
section 16.2.

`claimBounty` takes the earner as an argument rather than reading `msg.sender`.
Graduation credits the bounty to a mapping keyed by the address that graduated
the launch (section 8.2 step 6), and the claim is a permissionless push to the
address that mapping names, so an earner needs neither a transaction of its own
nor a live key to be paid. `pendingBountyTotalWei` tracks the sum of the mapping
so that Invariant 3 stays a one-read assertion.

`claimCreatorFees` reverting before graduation is load-bearing: **the creator
cannot withdraw a single wei from a launch until that launch has delivered.**
This is Invariant 20 and is the strongest deterministic creator constraint the
design has.

`protocolTreasury` is copied immutably into the curve at launch, so a later
change to factory config cannot redirect an existing launch's accrued fees.

All four claim functions are permissionless pushes, so that no privileged action
is ever needed to move accrued value, and all four use a checked low-level call.
A recipient that reverts on receipt blocks only its own bucket.

Sells stay open in `Expired` and `Stalled` (section 7), so fees continue to be
charged and split in those states. Where each of the three shares goes then is
section 6.3.

### 6.3 Fees charged after a terminal transition

A sell in `Expired` or `Stalled` charges and splits its fee exactly as any other
sell does. The split arithmetic of section 6.1 is unchanged, the three parts
still sum to the fee, and the holder-protection share is still the residual, so
Invariants 14 and 17 hold in every state. What depends on the state is the
**destination** of two of the three shares, because two of the three buckets have
no payout path once a launch is terminal: `claimCreatorFees` requires `Graduated`
or `Stalled`, so a creator share accrued in `Expired` could never be claimed by
anyone, and the holder-protection bucket has no claim function at all — it is
distributed only by a transition, which in a terminal state has already
happened.

| Share | `Live` | `Expired` | `Stalled` |
|---|---|---|---|
| creator | `creatorFeeEth` | `ethReserve` | `creatorFeeEth` |
| protocol | `protocolFeeEth` | `protocolFeeEth` | `protocolFeeEth` |
| holder protection | `protectionEth` | `ethReserve` | `ethReserve` |

`Graduating` and `Graduated` are absent from the table because no trade executes
in either (section 7), so no fee is charged in them. The protocol share is
unchanged in every column because `claimProtocolFees` has no state gate and
always had a path.

The destination of a redirected share is `ethReserve` and nothing else. Holder
protection exists for holders, and in a terminal state the reserve is the only
thing holders sell against, so paying it into the reserve is the same mechanism
the protocol already uses for the protection balance standing at the transition
(section 10.3) and for a forfeited bond (section 11.4). A redirect only ever adds
to `ethReserve` without changing `tokensSold`, so it raises the solvency product
and Invariant 1 is unaffected; it raises every remaining holder's exit price,
which is the point.

Three consequences for the rest of this document:

- `ethReserve` falls by less than `ethGross` on a sell in a terminal state
  whenever the redirected share is non-zero, which is why Invariant 4 is stated
  the way it is.
- `Sold` carries the reserve **after** the redirect, so an indexer following
  `ethReserve` through events stays exact and no second log is needed
  (section 16.1).
- `FeeAccrued` carries the redirected amount as a field of its own. Its four
  amounts are `creatorCut`, `protocolCut`, `protectionCut` and `reserveCut`,
  where `reserveCut` is exactly the wei this trade added to `ethReserve` in place
  of a bucket, and the four sum to the trade's `fee` in every state. On a `Live`
  trade `reserveCut` is zero and the three buckets are the whole destination, and
  the same sum still holds. The event therefore reconciles on its own: the total
  a launch has ever charged is the sum of all four amounts over its `FeeAccrued`
  logs, with no state-dependent reconstruction and no second log, and that total
  equals the sum of the `fee` field over its `Bought` and `Sold` logs. This is
  Invariant 59.

This section corrects the behaviour of the first implementation written in
Phase 1. The contracts were changed to match the specification before that phase
closed, and the superseded behaviour was never deployed to any network. The
behaviour it replaces left a creator share accrued in `Expired`, and a
holder-protection share accrued in either terminal state, permanently stranded
in a contract with no withdrawal path: nobody could take
that ETH, but nobody could reach it either. The project's rule is to be honest
about what cannot be prevented, not resigned about what can. This can be
prevented, in one branch of one internal function, with no new external surface,
no new admin power and no new trust assumption, so it is prevented rather than
documented. Decision 13 of `docs/OPEN_DECISIONS.md` records the options, the
resolution and why the earlier recommendation was reversed.

---

## 7. Lifecycle

```
                  createLaunch
                       |
                       v
                   +--------+
          +------->|  Live  |--------+
          |        +--------+        |
          | sell                     | s == C, before gradDeadline
          | donate                   v
          |                   +-------------+
          |                   | Graduating  |
          |                   +-------------+
          |                     |         |
          |     graduate /      |         | abortGraduation
          |     graduateAlt     v         v  (>= GRAD_GRACE after cap)
          |                 +-----------+ +---------+
          |                 | Graduated | | Stalled |
          |                 +-----------+ +---------+
          |
          |  now >= gradDeadline && s < C
          |        +---------+
          +--------| Expired |
                   +---------+
```

| State | `buy` | `sell` | `donate` | `graduate` | Terminal |
|---|---|---|---|---|---|
| `Live` | yes, until `gradDeadline` | yes | yes | no | no |
| `Graduating` | no | no | yes | yes | no |
| `Graduated` | no | no | no | no | yes |
| `Expired` | no | yes, forever | yes | no | yes |
| `Stalled` | no | yes, forever | yes | no | yes |

The deadline is enforced inside `buy` and inside the `Live -> Graduating`
transition, not by a keeper calling `expire()`. A launch whose deadline passes
is therefore closed to buyers and incapable of graduating whether or not anyone
calls `expire()`. `expire()` only finalises the ETH accounting.

`Graduating` freezes `s` and `r` against trades. This is what makes graduation
un-reversible: with sells enabled at the cap, anyone could sell one base unit
repeatedly to push `s` below `C` and hold a launch at the threshold forever.
Freezing removes that vector entirely.

`Expired` and `Stalled` keep sells open permanently with no deadline. Holders
are never forced to sell and the exit never closes. Buys are closed, so the
`1e27 - s` tokens still held by the curve can never leave it: they are
permanently immobilised without any burn and without `totalSupply()` changing.

---

## 8. Graduation

### 8.1 The pool is initialised at launch, not at graduation

The launch transaction initialises the pool with zero liquidity.
`BondingCurve`'s constructor makes the call —
`PoolManager.initialize(poolKey, sqrtPriceTerminal)` — because the constructor is
the first moment the token address exists, and `createLaunch` cannot return
before it has run.

The pool key is:

| Field | Value |
|---|---|
| `currency0` | `address(0)` (native ETH) |
| `currency1` | the launch token |
| `fee` | `POOL_FEE = 10000` (1%) |
| `tickSpacing` | `POOL_TICK_SPACING = 200` |
| `hooks` | `address(0)` |

```
sqrtPriceTerminal = sqrt( mulDiv(S_LP, 2**192, R_target) )      // round down
```

The multiplication must use a 512-bit intermediate; `S_LP * 2**192` overflows
256 bits. At the default `vE0 = 0.5 ether` this evaluates to exactly
`5000 * 2**96` with no remainder, tick 170352. Over the permitted `vE0` range
the tick runs from 115135 to 207243, comfortably inside v4's `+/-887272`, and
`sqrtPriceTerminal` is always above `MIN_SQRT_PRICE`. All three ticks are
confirmed against the deployed PoolManager.

**Pool orientation. Sections 8.2, 8.5 and 10 depend on this and read as
contradictory without it.** `currency0` is native ETH and `currency1` is the
launch token, so the pool's price is token per ETH and the tick axis runs
opposite to the token's ETH price: **the token getting cheaper in ETH moves the
tick up.** Two consequences are normative. A range lying entirely above the
current tick is funded in `currency0`, that is in ETH alone; a range lying
entirely below it is funded in `currency1`, that is in the token alone. A
standing ETH bid under the token's price is therefore a tick range *above* the
current tick, and the token-denominated side of the book is below it. Every tick
comparison in this document is in tick terms unless it says "in price terms".

Wherever graduation needs the pool's current tick it reads `slot0.tick` and must
not derive it from `slot0.sqrtPriceX96`. `Pool.swap` can leave `slot0.tick` one
tick below `TickMath.getTickAtSqrtPrice(slot0.sqrtPriceX96)` when a `zeroForOne`
swap ends exactly on an initialised tick boundary, and the two values then
disagree by one tick.

Initialising at launch is the primary anti-grief measure. The token address does
not exist before the launch transaction, so no attacker can reach the pool key
first, and therefore **no attacker can ever choose the pool's initial price.**
The cost is one `initialize` call per launch including launches that never
graduate. That is accepted: the alternative leaves the single most important
transaction in the protocol exposed to a cheap, permanent grief.

`IBondingCurve` exposes `poolId()` and `gradDeadline()`. It exposes no
`poolKey()` and no `launchedAt()`; both were dropped against the size budget of
section 2.1. The key is reconstructible from `token()` and the three constants in
the table above, since `currency0` is always `address(0)`, and the launch time is
in the `LaunchCreated` log.

`hooks` is `address(0)`. A hook could take a post-graduation fee, but it would
put protocol code in the swap path of every future trade forever. The claim
this design makes is that a graduated Pledrin pool is an ordinary, unowned,
hookless v4 pool.

### 8.2 `graduate()`

Permissionless. Requires `state == Graduating`. One transaction, no window.

```
1.  state = Graduated; graduatedAt = block.timestamp      // before any call out
2.  if slot0(poolKey).sqrtPriceX96 != sqrtPriceTerminal:
        zeroForOne = slot0(poolKey).sqrtPriceX96 > sqrtPriceTerminal
        swap(zeroForOne, amountSpecified = -1, sqrtPriceLimitX96 = sqrtPriceTerminal)
        require the swap's net currency0 and currency1 deltas are both zero
3.  require slot0(poolKey).sqrtPriceX96 == sqrtPriceTerminal
4.  mint position A (core):
        token.approve(PERMIT2, S_LP)
        PERMIT2.approve(token, POSITION_MANAGER, S_LP, type(uint48).max)
        tickLower = alignUp(MIN_TICK, tickSpacing)
        tickUpper = alignDown(MAX_TICK, tickSpacing)       // -887200 / 887200
        liquidity:    the largest value whose currency1 requirement is <= S_LP
        token amount: at most S_LP; require S_LP - consumed <= LP_DUST_MAX
        ETH amount:   amount0Max = R_target exactly
        recipient:    LiquidityLock
        coreEth    = the ETH the mint consumed, read from this contract's balance
        token.approve(PERMIT2, 0)                          // before position B
        LiquidityLock.registerPosition(positionIdCore, Core)
5.  floorEth = protectionEth + (r - R_target) + (R_target - coreEth)
    bounty   = floor(protocolFeeEth * GRAD_BOUNTY_BPS / 10000)
6.  protectionEth = 0; r = 0
    protocolFeeEth -= bounty
    pendingBountyWei[msg.sender] += bounty                 // credited, not pushed
    pendingBountyTotalWei += bounty
7.  if bondHeldWei > 0:
        bondState = Returned
        pendingBondWei = bondHeldWei; bondHeldWei = 0       // credited, not pushed
8.  mint position B (floor), which internally:
        if floorEth < MIN_FLOOR_WEI: no mint, positionIdFloor = 0, ethToFloor = 0
        otherwise, with currentTick read from slot0.tick:
            tickLower = alignDown(currentTick, tickSpacing) + tickSpacing
            tickUpper = tickLower + alignDown(FLOOR_RANGE_TICKS, tickSpacing)
            require tickLower > currentTick
            require tickUpper <= alignDown(MAX_TICK, tickSpacing)
            ETH amount:   floorEth, single-sided (currency0 only)
            recipient:    LiquidityLock
            LiquidityLock.registerPosition(positionIdFloor, Floor)
9.  CreatorVesting.start()                                 // keyed by msg.sender
10. factory.recordGraduation(creator, R_target, bondReturned)
11. emit Graduated
```

The order of steps 4 to 8 is forced, and it is the reason Invariant 55's
strongest form does not hold in this function. `floorEth` is a function of the
ETH the core mint actually consumed, which is knowable only after that mint has
returned, so a storage write necessarily follows an external call here. What
holds instead is the property the anti-grief argument in section 8.4 and
`docs/THREAT_MODEL.md` section 7 actually rely on: `graduate` holds a reentrancy
guard; `state` is written to its terminal value in step 1, before any call leaves
the contract, so a reentrant attempt fails the state check; and every remaining
storage write is complete before the function's last external calls, which are
the floor mint and the two protocol-internal notifications of steps 9 and 10,
with only the event after them.

Step 2's restoring swap nominates a non-zero `amountSpecified`.
`PoolManager.swap` rejects `amountSpecified == 0` with
`SwapAmountCannotBeZero()`, so "zero cost" describes what the swap settles, not
the size it names: in a pool with no liquidity the net deltas are zero in both
currencies at any nominal size, measured in both directions and at sizes from
one unit to `1e18`, and step 2 nominates one unit of exact input. The `if` guard
is equally load-bearing, because a swap whose `sqrtPriceLimitX96` equals the
pool's current price reverts with `PriceLimitAlreadyExceeded`: a launch whose
pool price was never moved must skip the swap rather than perform a no-op one.
The direction is decided by the comparison and follows the orientation of
section 8.1 — a pool price above `sqrtPriceTerminal` is restored by a
`zeroForOne` swap, a pool price below it by the other direction.

Position A is sized by liquidity, not by amounts. `MINT_POSITION` is
parameterised by a liquidity value and the `currency1` owed for a given
liquidity is a step function of it, so no liquidity value lands on `S_LP`
exactly. Position A therefore consumes **at most** `S_LP` base units and at most
`R_target` wei, and the liquidity minted is the largest value that fits: one more
unit of liquidity would require more than `S_LP`. Measured against the deployed
PositionManager the token shortfall is 28,428 base units at `vE0 = 1.25e16`,
1,088 at the default `vE0 = 5e17`, and 240 at `vE0 = 1.25e20`. It is irreducible,
and Invariant 39 bounds it by `LP_DUST_MAX` as an explicit assertion rather than
assuming exactness.

**Both quantities step 4 measures are deltas across the mint call, and the dust
comparison is `S_LP` minus the token delta. Neither is ever an absolute balance
read after the call.** `coreEth` is this contract's ETH balance before the call
minus its balance after it, and the token consumption is the same difference in
`token.balanceOf(address(this))`. This is normative and not an implementation
choice. Any address may transfer launch tokens to the curve at any time and
ERC-20 gives the curve no way to refuse, so an absolute post-call balance would
fold a third party's donation into the dust comparison and let a donation of
just over `LP_DUST_MAX` base units revert `graduate()` on demand; measured as a
delta, a donation of any size raises both readings by the same amount and
cancels.
Invariant 60 asserts the consequence and `docs/THREAT_MODEL.md` section 6.6
states the grief it closes.

That remainder is immobilised. The unspent token never leaves the curve, and
after graduation the curve has no withdrawal path of any kind, so a few hundred
base units — on the order of `10**-15` whole tokens — stay there permanently. The
amount is harmless, but it is not zero: the earlier claim that no token dust is
immobilised was false and is withdrawn.

`amount0Max` for position A is exactly `R_target` and must not be tightened. An
`amount0Max` one wei below the amount the mint actually requires is rejected with
`MaximumAmountExceeded`, `amount0Max = R_target` is accepted, and the ETH
headroom between the two is **not monotone** in `virtualEthReserve`, so no
tighter closed-form bound is safe across the permitted range. Any unused ETH is
counted into `floorEth` in step 5 and funds position B in step 8, so no ETH is
stranded. Because the pool opens at exactly the curve's terminal price, the ETH
consumed equals `R_target` to within the `sqrtPriceTerminal` rounding-down
error.

The Permit2 allowance is revoked inside step 4, before position B is minted, so
position B's funding in `currency0` alone is structural rather than a property of
its parameters: with no token allowance in place, a token-funded mint would
revert.

That revocation is the ERC-20 leg only, and it is the only leg this
specification requires to be revoked. The Permit2 registration made earlier in
the same step — spender PositionManager, `expiration = type(uint48).max` —
survives graduation holding whatever the core mint did not spend, which is the
few hundred base units Invariant 39 bounds. It is inert, because a Permit2 pull
requires both legs and the ERC-20 leg is zero. **Normative: no function of the
curve other than the core mint may grant the curve's ERC-20 allowance to
Permit2.** That prohibition, not the registration's own parameters, is what keeps
the surviving registration unusable (Invariant 61, and
`docs/THREAT_MODEL.md` section 7).

Step 5's two subtractions are checked arithmetic and neither can underflow.
`r - R_target` cannot, because Invariant 13 gives `r >= R_target` at the cap and
`Graduating` freezes `r` against trades while `donate` can only raise it;
`R_target - coreEth` cannot, because `amount0Max` for the core mint was
`R_target`.

Steps 6 and 7 **credit** rather than send. A creator or bounty earner whose
address reverts on receiving ETH would otherwise be able to make `graduate()`
revert forever, which would strand every holder. Nothing in `graduate()` makes
an ETH transfer to an address the caller does not control.

Step 8's `tickUpper <= alignDown(MAX_TICK, tickSpacing)` requirement cannot fire
at any permitted parameter set: step 3 has asserted the price is
`sqrtPriceTerminal`, whose tick is at most 207243 across the permitted
`virtualEthReserve` range (section 8.1), and 207243 plus `FLOOR_RANGE_TICKS` is
far inside the aligned maximum tick at every permitted spacing. It is an
assertion, not a branch: a graduation that could not place the floor position
would be a bug rather than a case to handle.

`MIN_FLOOR_WEI` is checked inside the floor mint, which returns zeroes rather
than reverting. A graduation below the threshold is therefore an ordinary
graduation whose `Graduated` event carries `positionIdFloor = 0` and
`ethToFloor = 0` (section 16.1).

Step 9 calls `CreatorVesting.start()` with no arguments: the schedule it starts
is the one keyed by the caller, which is this curve (section 12). A launch with
no schedule reaches a no-op rather than a revert, so a creator who skipped the
first buy cannot make graduation fail.

Step 10 passes three arguments, not one.
`recordGraduation(address creator, uint128 ethRaised, bool bondReturned)` carries
the bond outcome because the factory cannot ask a curve that is still
mid-graduation what happened to its bond, and calling back into the curve to find
out is exactly the reentrancy that step 1 and the write ordering exist to avoid.
Without that argument the factory could not increment `bondsReturned` at all.
`ethRaised` is `R_target`, not the curve's final `r` (section 13).

### 8.3 Who pays the gas, and why it is always worth paying

The caller of `graduate()` pays its gas and is credited
`GRAD_BOUNTY_BPS = 1000` (10%) of the launch's accrued `protocolFeeEth`. The
bounty comes from the protocol's own fee bucket and never from `r`,
`protectionEth`, `creatorFeeEth` or `bondWei`. Curve reserves fund only sells
and the graduation liquidity. The rounding remainder of the bounty division
stays in `protocolFeeEth` for the treasury.

Sizing: at graduation, cumulative trade volume is at least `R_target`, so at the
default 1% fee and 40% protocol share, `protocolFeeEth >= 0.004 * R_target`, and
the bounty is at least `0.0004 * R_target`. At the default `R_target = 4 ETH`
that is 0.0016 ETH. Observed gas price on these networks is 0.01 to 0.02 gwei,
so a two-million-gas graduation costs around 0.00004 ETH. The bounty exceeds
the gas cost by more than an order of magnitude and scales with the raise, so
there is always an economic actor willing to call it.

### 8.4 Anti-grief, completely

| Vector | Why it fails |
|---|---|
| Pre-initialise the pool at a wrong price | Impossible. The pool is initialised in the launch transaction, before the token address is public. |
| Move the price of the zero-liquidity pool before graduation | `graduate()` restores it with a limit swap that nominates one unit of input, settles for nothing in a pool with no liquidity, and asserts both zero net deltas and the restored price. |
| Add liquidity to the pool so the price reset is not free | The reset is required to have zero net cost, so `graduate()` reverts rather than spending curve ETH. State stays frozen and `graduate()` is retryable forever. |
| Block the primary pool key permanently | After `ALT_DELAY = 1 hour` in `Graduating`, `graduateAlt(uint24 tickSpacing)` runs the identical procedure on a caller-chosen `tickSpacing` in `[10, 199]`, requiring that pool to be uninitialised so it is initialised at `sqrtPriceTerminal` with no prior liquidity. An attacker would have to pre-block every permitted spacing and keep doing so. |
| Sell at the cap to prevent graduation | `Graduating` freezes `s`. |
| Donate launch tokens to the curve before `graduate()` | The core mint's token consumption is a delta across the mint call and the dust comparison is `S_LP` minus that delta, so a donation of any size cancels and cannot reach `LP_DUST_MAX` (step 4, Invariant 60). |
| Revert on ETH receipt to make `graduate()` fail | `graduate()` sends ETH to nobody; bond and bounty are credited. |
| Starve graduation of a caller | Permissionless and bounty-paid, section 8.3. |
| Everything above at once | After `GRAD_GRACE = 7 days` in `Graduating`, `abortGraduation()` moves the launch to `Stalled`: sells reopen permanently, the bond is **returned** to the creator because the cap was delivered, creator fees become claimable, and `protectionEth` is donated into `r`. Holders get a permanent exit against the deepest reserve the curve ever held. |

`graduateAlt` takes the spacing as a `uint24` and narrows it to `int24` through
`SafeCast`, so a value above `int24`'s maximum reverts in the cast and everything
else is caught by the range check. The permitted range is a range of integers and
not a menu of canonical tiers: every value from `ALT_TICK_SPACING_MIN = 10` to
`ALT_TICK_SPACING_MAX = 199` is available, which is 190 distinct pool keys.

`ALT_TICK_SPACING_MAX` is 199 and not 200 **because 200 is
`POOL_TICK_SPACING`**. At 200 the "alternative" pool key is the canonical pool
key, and `graduateAlt` would be a second entry point into the pool the launch
transaction already initialised — a function whose whole purpose is to reach a
*different* key would be able to name the one key `graduate` exists for.
Excluding it by the bound makes `graduateAlt(200)` revert `InvalidTickSpacing`,
which is the accurate error, instead of `AltPoolInitialized`, which is a
pool-state error that only happens to fire because that pool exists. The two
paths are therefore disjoint by construction and `graduate` is the only function
that can reach the canonical key (Invariant 38).

`ALT_DELAY` exists so that the honest primary key wins when it is available and
a caller cannot fragment the canonical pool onto an odd tick spacing for no
reason.

`graduateAlt`'s requirement that the alternate pool be **uninitialised**
(Invariant 38) is load-bearing and must not be relaxed, in particular not to
"uninitialised, or initialised at `sqrtPriceTerminal`" and not to any variant in
which `graduateAlt` restores a price. Restoring a griefed price costs nothing in
either currency, but it costs gas in proportion to the tick distance divided by
the tick spacing, because the swap walks the tick bitmap one word at a time.
Measured against the deployed PoolManager, restoring from the extreme tick costs
173k gas of EVM execution at `POOL_TICK_SPACING = 200` and 2.33M at
`ALT_TICK_SPACING_MIN = 10` — on its own more than the two-million-gas
graduation that section 8.3 sizes the bounty against. The alt path stays clear of
that cost only because it opens the pool itself, at `sqrtPriceTerminal`, with
nothing to restore. Those figures are EVM execution gas under a forked EVM; per
`docs/CHAIN_FACTS.md` Nitro's `gasleft()` and L1 data costs differ, so treat them
as the relative cost of the loop and not as a chain gas quote.

`abortGraduation()` emits `GraduationStalled` and, whenever `protectionEth` was
non-zero, also a `Donated` log naming the launch as both launch and donor, which
is how an indexer learns the new `ethReserve` (section 16.1).

`abortGraduation()` returns rather than forfeits the bond because the creator
met the only condition the bond encodes — reaching the cap before the deadline —
and a third party's grief must not cost them. A creator who griefs their own
graduation to reach `Stalled` gains nothing: they receive exactly the bond and
fees they would have received from `graduate()`, and they pay for the grief.

### 8.5 Sandwiching the migration

Three structural mitigations, and one honest admission.

1. Pool initialisation, price assertion, and both mints are one transaction.
   There is no window between seeding and tradeability.
2. The pool opens at exactly the curve's terminal price (section 5.3), so at
   the first post-graduation block there is no price gap to arbitrage. A
   mis-sized pool price is the usual source of migration sandwich profit and it
   is removed arithmetically, not by a slippage parameter.
3. The floor position lies entirely on one side of spot — strictly above the
   current tick, which by the orientation of section 8.1 is the direction of a
   falling token price — so it holds no token when minted, cannot move the price
   or the tick, and cannot create a gap.

What remains: the first swap in the new pool is ordinary MEV and is not
prevented. Whoever wins it captures ordinary price impact, not a protocol
subsidy. `docs/THREAT_MODEL.md` says so.

---

## 9. Liquidity lock

`LiquidityLock` is the recipient named by both graduation mints, so a position is
owned by the lock from the moment it exists: PositionManager mints it to the lock
with `_mint`, which invokes no receiver hook, so delivery involves no transfer and
no callback. The lock's `onERC721Received` is not on that path; it exists for the
unrelated case of an unsolicited position NFT sent to the lock with
`safeTransferFrom`, and it accepts only from PositionManager and can change
nothing (Invariant 57). The lock has no function that calls `transferFrom`,
`safeTransferFrom`,
`approve`, `setApprovalForAll` or `permit`, no `BURN_POSITION` action, and no
liquidity-decreasing action with a non-zero liquidity argument. There is no
owner, no rescue function, no sweep, no timelock, no escape hatch. `ownerOf` for
a locked position is the lock, forever.

Two functions, and nothing else that writes:

| Function | Caller | Effect |
|---|---|---|
| `registerPosition(uint256 positionId, PositionKind kind)` | anyone; in practice the graduating curve | records `launch = msg.sender` and the kind for a position the lock already owns; reverts `NotOwned` otherwise, and `AlreadyLocked` on a second attempt for the same id |
| `compound(uint256 positionId)` | anyone | collects that registered position's accrued fees and reinvests them into the same position; returns the liquidity gained |

`registerPosition` is permissionless by design and not by omission. The only
position it can register is one the lock already owns, the only consequence of
registering one is that its fees become compoundable, it cannot overwrite an
existing record, and it names no recipient and moves nothing.

Fee compounding is decision 1 of `docs/OPEN_DECISIONS.md`, resolved to a
permissionless compound-only function; its encoding is decision 12, resolved to
option B and implemented. One `modifyLiquidities` batch of four actions:
`DECREASE_LIQUIDITY` with a hard-coded zero liquidity, which credits the accrued
fees without touching the principal; `INCREASE_LIQUIDITY_FROM_DELTAS` with
`type(uint128).max` on both amounts, which spends exactly that credit; then two
`CLOSE_CURRENCY`. No caller-supplied number reaches the call: the amount
compounded is the position's own fee delta and nothing else. The zero is a
literal in the encoding, not a parameter (Invariant 46).

Two guards in `compound` are load-bearing and must not be relaxed:

1. `NothingToCompound`, which reverts when the position's liquidity did not
   change. With fees accrued on one side only this is the normal case rather than
   an edge case: the liquidity a pair of amounts buys is the minimum over both
   sides, so a one-sided fee delta buys zero. Without the guard, `CLOSE_CURRENCY`
   would credit those fees out of the position and into the lock's retained
   residual, which nothing can ever spend. Reverting leaves them accrued inside
   the pool until the other side accumulates, where a later call can still
   compound them.
2. `LiquidityNotIncreased`, which reverts if the position's liquidity fell. It is
   a backstop against a mis-encoded batch rather than a case expected to arise.

The ratio residual of each compounding is **retained** by the lock and
accumulates there. It is not reinvested by a later call and the lock cannot spend
it, because the v4 actions involved work off the PoolManager delta of the current
call and not off the lock's own balance. The lock's `receive` accepts ETH from
PoolManager and PositionManager only, so nobody can add to that residual by
accident either. No path exists by which a locked position's principal, its fees
or the residual reach any address.

`compound` emits `PositionCompounded(positionId, caller, liquidityAdded)`. That
event is the only observable proof a compounding did anything: the position's
liquidity is otherwise visible only by reading PositionManager.

One cost of this encoding is recorded here because an auditor will meet it in the
dependency rather than in Pledrin's own source.
`INCREASE_LIQUIDITY_FROM_DELTAS` is marked
`DEPRECATED - vulnerable to sandwich attacks` in the vendored v4-periphery,
because it carries no minimum-liquidity check: an attacker who moves the pool
price before the call makes the fee delta buy less liquidity. The exposure here
is value destruction and not theft — the batch names no recipient but the lock,
so the liquidity not bought becomes retained residual rather than anyone's profit
— and the attack costs two legs of the pool's own fee on a notional large enough
to move a pool that holds the whole ETH target, paid into the position being
griefed. Decision 12 of `docs/OPEN_DECISIONS.md` records the full comparison
against the alternative, whose grief costs only gas.

---

## 10. Holder protection pool

### 10.1 What it does

The holder-protection share of every trading fee accrues as `protectionEth` and
is deposited at graduation as **position B: a single-sided, ETH-only, permanently
locked Uniswap v4 position occupying the band immediately below the opening
price in price terms, which by the orientation of section 8.1 is the tick range
immediately above the current tick.**

That is a standing bid. If the token's ETH price falls into the band, the
position buys tokens from sellers with the protection pool's ETH, which is
exactly the support a floor is supposed to be. The tokens it acquires become
sell-side depth on the way back up. The position is locked, so neither the ETH
nor the tokens nor the fees ever leave it.

The range is `FLOOR_RANGE_TICKS = 13800` ticks wide, which is a price factor of
`1.0001^13800 = 3.97`. The bid therefore spans from just below the opening price
down to about 25% of it — the token falling to `1/3.97` of its opening ETH price
— concentrating the protection across the drawdown band where it matters rather
than spreading it thinly to zero. Those 13800 ticks are counted *upward* in tick
terms, which is downward in price terms; the next paragraph gives the range
explicitly, because the two vocabularies read as contradictory otherwise.

The tick direction is the part that is easy to get wrong, so it is stated in both
vocabularies. `tickLower` is `alignDown(currentTick, tickSpacing) + tickSpacing`,
which is **strictly greater** than `currentTick`; `tickUpper` is
`tickLower + alignDown(FLOOR_RANGE_TICKS, tickSpacing)`, which is at most
`alignDown(MAX_TICK, tickSpacing)`. In price terms that is the band from just
below the token's opening ETH price down to `1/3.97` of it. A range strictly
above the current tick is the range v4 funds in `currency0` alone, so position B
is mintable with ETH and no token approval, holds no token at the moment it is
minted, and cannot move the opening price. A range below the current tick is
funded in `currency1`: specifying the floor on that side would make the
protection pool mint **a sell wall out of the token** instead of a standing ETH
bid, which is the opposite of this section's purpose.

Measured against the deployed PoolManager and PositionManager at the default
parameters (`currentTick = 170352`, `tickSpacing = 200`), with a 1 ETH probe in
place of `floorEth`: the range `[170400, 184200]` consumed exactly
`1_000_000_000_000_000_000` wei and zero base units of the token, with no token
approval present at all, and a seller crossing the whole range received
`999_999_999_999_999_999` wei while the position accumulated
`50_079_062_227_699_919_545_122_979` base units. The mirrored range
`[156200, 170000]` requires zero `currency0` and
`12_105_670_708_310_857_288_856_074` base units of `currency1` for the same
liquidity, and an ETH-only mint of it reverts with `MaximumAmountExceeded`.

If `floorEth < MIN_FLOOR_WEI = 1e12` the position is not minted. The threshold
is checked inside the floor mint, which returns zeroes rather than reverting, so
the launch graduates normally and its `Graduated` event carries
`positionIdFloor = 0` and `ethToFloor = 0`. The reason is
de-minimis and not arithmetic: over a range this wide one wei of `floorEth`
already yields non-zero liquidity and mints successfully, so the earlier
justification — that v4 would round the liquidity to zero — is false and is
withdrawn. The constant exists so that graduation does not spend a mint's gas and
a permanent position NFT on a bid worth less than a millionth of an ETH. The
skipped ETH stays in the curve contract, which after graduation has no withdrawal
path of any kind: it is permanently removed from circulation. The amount is
bounded above by `1e12` wei, 0.000001 ETH.

### 10.2 Why not snapshot and claim

The rejected alternative is to snapshot holders at graduation and let them claim
a pro-rata share of `protectionEth`. It is worse on every axis:

- A snapshot requires either an on-chain holder set, which a plain ERC-20 with no
  transfer hook does not have and which would force a hook into the token, or an
  off-chain Merkle root, which needs a trusted publisher — and the design
  constraints forbid both an admin and an oracle.
- A claim mechanism has gas cost per claimant, an unclaimed-funds tail, and a
  decision about where unclaimed funds go, each of which is a new attack surface.
- A snapshot is the single most sybil-rewarding construct available: it pays per
  address, so splitting one balance across a thousand wallets before the snapshot
  costs only gas.
- A pro-rata payment pays holders who already sold their exposure and pays
  nothing to anyone who buys after graduation.
- Locked depth helps every holder, including every future one, needs no list, has
  no claim deadline, and cannot be gamed by address count.

Donating into the locked position is therefore the specified behaviour.

### 10.3 Before graduation, and if graduation never happens

`protectionEth` cannot be deposited into a pool that does not exist yet, so
before graduation it simply accrues and no party can touch it. On `Expired` or
`Stalled` it is donated into `r` (section 5.7), which raises every current
holder's exit price. Same principle, same absence of a snapshot, applied to the
only market that exists in those states.

Only the balance standing at the moment of the transition is donated in that one
step. Both terminal states keep sells open, so later sells charge a fresh
holder-protection share, and that share goes straight into `r` on each trade
rather than into `protectionEth`, with the exact destinations and the reasoning
in section 6.3. The outcome is the same either way: in a terminal state the
holder-protection share reaches holders through the reserve they sell against,
and never sits in a bucket with no claim function.

### 10.4 What it is not

It is not insurance. It does not compensate an individual for a loss, does not
track anyone's cost basis, and pays nothing to anyone directly. It buys depth
below the opening price. `docs/THREAT_MODEL.md` states this plainly so the
mechanism is not read as something it is not.

---

## 11. Dev Bond

### 11.1 What the bond is

`bondWei` of the creator's own ETH, posted in the launch transaction, held by
that launch's `BondingCurve`, and committed against **exactly one
deterministic, on-chain-observable condition**:

> The launch reaches `tokensSold == CURVE_SUPPLY` before `gradDeadline`.

`gradDeadline` is `block.timestamp + gradWindow` evaluated once in the curve's
constructor and stored as an immutable; the curve has no `launchedAt` field, so
the condition is one comparison against one immutable (section 5.2).

That is the whole of it. The bond is a **delivery bond**, not an honesty bond
and not an anti-rug bond. It makes one promise that a contract can check without
an oracle, without an admin and without judgement, and it makes no other promise.
`docs/THREAT_MODEL.md` states this in those words.

If `bondWei > 0` the launch is Pledged: the `pledged()` view returns true and the
Pledged fee shares of section 6 apply. Pledged status is derived from the
immutable `bondWei > 0` alone — never from a settable flag, and deliberately not
from the mutable `bondState` (Invariant 29). The badge therefore records that a
bond was posted, not that it is still held: a reader who wants the outcome reads
`bondState`, where `Forfeited` is the interesting value.

Bounds: `bondWei` is 0, or at least `max(MIN_BOND_WEI, R_target / 10)` and at
most `MAX_BOND_WEI`. The proportional floor means a bond is always meaningful
relative to the raise it backs; a flat minimum would be trivial on a large launch.

Two fields, deliberately distinct: `bondWei` is the immutable amount posted at
launch and is what `pledged()`, the fee-share selection and the reputation
counters read. `bondHeldWei` is the mutable ETH balance still held on the bond
account. Exactly one transition moves `bondHeldWei` to zero, and it is the same
transition that moves `bondState` out of `Bonded`.

### 11.2 Prevention first

Three constraints do the actual work, and none of them is a punishment:

1. **The creator cannot withdraw any ETH from a launch before it graduates.**
   `claimCreatorFees` reverts outside `Graduated` and `Stalled` (Invariant 20).
   There is nothing to claw back because nothing has left.
2. **The creator's token allocation physically cannot be sold early.** It is in
   `CreatorVesting`, which has no release path before graduation and no release
   path at all if the launch expires (section 12). A vesting contract that cannot
   release beats a slashing rule that fires after the tokens are already sold,
   because the slashing rule operates on a loss that has already happened.
3. **Liquidity permanence is structural, not bonded.** Nothing can withdraw the
   graduated liquidity, so no rule is needed to forbid it and no bond is needed
   to deter it.

### 11.3 The bond state machine and `claimBond`'s refusals

`bondState` is one of `None`, `Bonded`, `Returned`, `Forfeited`. It leaves
`Bonded` at most once, and every exit is a single write guarded by the state
check. This is what makes Invariant 25 — a bond is never paid twice — a
one-enum assertion rather than a balance argument.

| Transition | Condition | Effect |
|---|---|---|
| `Bonded -> Returned` | `graduate()`, `graduateAlt()` or `abortGraduation()` | `pendingBondWei = bondHeldWei`; `bondHeldWei = 0`; `bondsReturned++` |
| `Bonded -> Forfeited` | `expire()`: `state == Live && block.timestamp >= gradDeadline && s < C` | `ethReserve += bondHeldWei`; `bondHeldWei = 0`; `bondsForfeited++`; `bondWeiForfeited += bondWei` |

`claimBond()` names which of those states refused it. The refusal is a function
of `bondState` alone in three of the four states, where the credit is zero and is
not read; in `Returned` the credit decides:

| `bondState` | `pendingBondWei` | Refusal | Permanent |
|---|---|---|---|
| `Bonded` | `0` | `BondNotReturned()` | No. The launch has not settled yet: `graduate()`, `graduateAlt()` or `abortGraduation()` turns the identical call into a payment, and `expire()` turns it into `BondForfeitedToHolders()`. |
| `None` | `0` | `NoBondPosted()` | Yes. `bondWei` was zero at launch and no path creates a bond afterwards. |
| `Forfeited` | `0` | `BondForfeitedToHolders()` | Yes. `expire()` added the bond to `ethReserve` (section 11.4). It will never be paid to the creator. |
| `Returned` | `0` | `BondAlreadyClaimed()` | Yes. The bond has been paid. |
| `Returned` | `> 0` | none; the call pays the credit to the creator | |

`Returned` with an empty credit can only mean a completed claim, which is what
makes the fourth refusal exact rather than an inference. The only write that sets
`bondState = Returned` runs solely when `bondHeldWei` is non-zero and sets
`pendingBondWei` to that amount in the same statement, nothing else ever adds to
the credit, and `claimBond` is the only function that empties it. Invariant 63
states this as an assertion, and Invariant 25 is the same fact counted in wei.

An indexer reads the same distinction from `BondStateChanged`, whose
`destination` is the creator on a return and the launch itself on a forfeit, and
from the `FeesClaimed` log with `kind = Bond` that a successful claim emits.

### 11.4 Automatic payout to holders

The only trigger is expiry: the cap was not reached before the deadline.
`expire()` is permissionless and does, atomically:

```
state = Expired                                      // before any call out
bond = bondHeldWei; creatorFees = creatorFeeEth; protection = protectionEth
r += bond + creatorFees + protection
creatorFeeEth = 0; protectionEth = 0
if bond > 0:
    bondHeldWei = 0; bondState = Forfeited
    emit BondStateChanged(launch, creator, Bonded, Forfeited, bond, launch)
CreatorVesting.void()                                // keyed by msg.sender
factory.recordExpiry(creator, bond > 0 ? bondWei : 0)
emit Expired(launch, bond, creatorFees, protection, r)
```

`recordExpiry(address creator, uint128 bondForfeited)` takes the forfeited amount
rather than a flag, because the factory tracks both a count and a wei total
(section 13). The amount passed is `bondWei`, which while `Live` is identical to
`bondHeldWei`: the only exit from `Bonded` before a terminal state is this one.

`expire()`'s three preconditions are not equally reachable. `state == Live` and
`block.timestamp >= gradDeadline` are the real gate. The third, `s < C`, is a
defensive assertion: the buy that reaches the cap moves the launch to
`Graduating` in the same transaction (section 5.4 step 9), so a `Live` launch
sitting at the cap does not exist and the `CapAlreadyReached` error it raises is
unreachable through the protocol. It is specified, kept and tested — a test
reaches it by writing the packed state byte directly — because it is what makes
"a launch that delivered cannot expire" a property of this function rather than
one inherited from `buy`. It is not dead code and must not be removed.

`expire()` emits no `Donated`. `Expired` already carries all three forfeited
amounts and the resulting `ethReserve`, so a `Donated` log as well would make an
indexer count the same wei twice (section 16.1). `abortGraduation()` is the
opposite case and does emit one, because `GraduationStalled` carries no amounts.

The forfeited ETH is donated into the curve reserve, which raises the exit price
for every holder immediately, with no snapshot, no claim, no list and no gas
cost per holder. Nothing is sent to the creator: the bond, the accrued creator
fee share, and the creator's entire token allocation are all lost in the same
transaction.

Note that both the bond **and** the creator's accrued fee share are forfeited.
A creator who launches, collects fees from early buyers, and lets the launch die
receives nothing.

### 11.5 Conditions deliberately not bonded

Each of these was considered and rejected because it cannot be evaluated
deterministically on-chain:

- "The creator must not sell." The creator's only identified tokens are in
  vesting and cannot be sold early. Any other tokens they hold were bought
  through addresses the protocol cannot link to them. Unenforceable.
- "The creator must not hold a majority." Trivially defeated by splitting
  across addresses. Unenforceable.
- "The project must ship what it promised." Requires off-chain judgement.
  Not a rule.
- "Liquidity must stay locked." Already structural; a bond would add nothing.

---

## 12. Creator allocation and vesting

`CreatorVesting` is a singleton holding one schedule per launch, keyed by the
launch's own address.

| Field | Source |
|---|---|
| `allocation` | base units delivered by the creator's first buy at launch |
| `start` | set by `graduate` / `graduateAlt` / `abortGraduation` to `block.timestamp` |
| `cliff` | `creatorVestCliff`, immutable from launch |
| `duration` | `creatorVestDuration`, immutable from launch |
| `released` | cumulative released |
| `voided` | set by `expire()` |

```
releasable(t) =
    0                                                   if start == 0 or voided
    0                                                   if t < start + cliff
    allocation - released                               if t >= start + cliff + duration
    floor(allocation * (t - start - cliff) / duration) - released   otherwise
```

The interface:

| Function | Caller | Effect |
|---|---|---|
| `createSchedule(address creator, address token, uint128 allocation, uint32 cliff, uint32 duration)` | anyone; in practice the launch, inside its launch transaction | creates the schedule keyed by `msg.sender` and **pulls** `allocation` from `msg.sender` with `transferFrom`; reverts `ScheduleExists` on a second call |
| `start()` | anyone; in practice the launch | starts the schedule keyed by `msg.sender` at `block.timestamp`; a caller with no schedule is a no-op |
| `void()` | anyone; in practice the launch | voids the schedule keyed by `msg.sender`; a caller with no schedule is a no-op |
| `release(address launch)` | anyone | sends everything vested so far to that schedule's recorded `creator` |
| `releasable(address launch)`, `scheduleOf(address launch)` | anyone | views |

`start()` reverts `AlreadyStarted` on a second call and `ScheduleVoided` on a
voided schedule; `void()` reverts `ScheduleVoided` on an already-voided one.
Neither can fire from a launch, because a launch calls each at most once and only
from a terminal transition.

`release(address launch)` refuses with one of four errors, chosen so that a
caller is never told to wait for tokens that are not coming:

| Condition | Refusal | Permanent |
|---|---|---|
| `allocation == 0` | `NoSchedule()` | Yes for every Pledrin launch: a launch's schedule is created inside its launch transaction or never, because `creatorFirstBuy` is callable only by the factory and only while `tokensSold == 0` (section 15.3). For an address that is not a launch it says only that this address has no schedule yet, since `createSchedule` is permissionless. |
| `voided` is set | `ScheduleVoided()` | Yes. `expire()` set it, nothing clears it, and no release of this schedule will ever succeed. |
| `released == allocation` | `ScheduleFullyReleased()` | Yes. The schedule has paid the allocation in full and has nothing left to pay. |
| `start == 0` | `NothingToRelease()` | No. The clock starts when the launch graduates or stalls; if the launch expires instead, this refusal becomes `ScheduleVoided()`. |
| `block.timestamp < start + cliff` | `NothingToRelease()` | No. |
| started, past the cliff, no further base unit accrued since the last release | `NothingToRelease()` | No. |

The checks run in that order, and both terminal conditions are rejected
**before** the releasable amount is computed. That ordering is the point of them:
`releasable` returns zero for a voided schedule and zero for a finished one
(Invariants 21 and 22), so computing first and reporting `NothingToRelease` would
answer a creator whose allocation is irrecoverable, and a creator who has already
been paid all of it, with the same word it uses for a creator who is one second
short of their cliff.

`NothingToRelease` therefore carries the narrow meaning stated in the table, and
nothing terminal hides behind it any more: the schedule exists, is not voided, is
not finished, and has nothing releasable at this block time. A schedule in that
condition can still pay, either when its clock advances or when its launch
settles.

The `releasable(address launch)` view cannot make any of these distinctions and
is not changed to: it returns zero for a voided schedule, for a schedule before
its cliff and for a finished one alike. A caller that needs the reason reads
`scheduleOf(launch)`, which returns `voided`, `start`, `released` and
`allocation`, and decides from those.

Every mutating function is keyed by `msg.sender` and takes no launch argument,
and `createSchedule` funds itself by pulling the allocation out of its caller.
That is load-bearing twice over and is worth stating rather than only recording.

First, it is why `CreatorVesting` needs no privileged caller and no factory
address, which is what breaks the factory-vesting deployment cycle (section 2.2).
A vesting contract that checked `msg.sender` against a factory would have to know
the factory's address, while the factory has to know the vesting address: a cycle
that can only be broken by address prediction or by a setter, and a setter on
this contract is a power over user funds.

Second, it makes cross-schedule theft structurally impossible rather than merely
checked for. A contract that is not a Pledrin launch may call `createSchedule`,
but it can only create the schedule keyed by itself, and only by delivering the
allocation it declares out of its own balance in the same call. It cannot create,
start, void, redirect or drain anyone else's schedule, and the tokens any
schedule can release are tokens that same schedule delivered. There is no check
to get wrong because there is no cross-schedule operation to check.

The bounds on `cliff` and `duration` are enforced in `LaunchFactory`
(section 15.2). `CreatorVesting` itself requires only `duration != 0`,
`allocation != 0` and non-zero `creator` and `token`, because it is
permissionless and a schedule a stranger creates for itself is not the protocol's
business.

`release(address launch)` is callable by anyone and always sends to the recorded
`creator`. There is no early-release path, no owner, no acceleration, no transfer
of the schedule, and no function that can change `allocation`, `cliff` or
`duration` after launch. `void()` acts only on the caller's own schedule, and the
only caller with a schedule the protocol created is that launch's curve, which
calls it in `expire()` and nowhere else; once voided the allocation is
irrecoverable by anyone, which removes it — at most 1.8% of supply — from
circulation without burning it and without changing `totalSupply()`.

The clock starts at graduation, not at launch. Vesting that ran during the curve
phase would let a creator reach the cap on the last day of the window and
release immediately.

---

## 13. Creator reputation

Counters in `LaunchFactory`, keyed by creator address. Written only by the
factory and by curves the factory deployed. **There is no setter, no admin
write, no signed attestation, no oracle, and no off-chain input of any kind.
Every counter is a pure function of the protocol's own event history and can be
recomputed from logs by anyone.**

| Counter | Type | Incremented by |
|---|---|---|
| `launches` | `uint32` | `createLaunch` |
| `graduations` | `uint32` | `graduate`, `graduateAlt` |
| `stalls` | `uint32` | `abortGraduation` |
| `expiries` | `uint32` | `expire` |
| `bondsPosted` | `uint32` | `createLaunch` when `bondWei > 0` |
| `bondsReturned` | `uint32` | bond `Bonded -> Returned` |
| `bondsForfeited` | `uint32` | bond `Bonded -> Forfeited` |
| `bondWeiPosted` | `uint128` | `+= bondWei` at launch |
| `bondWeiForfeited` | `uint128` | `+= bondWei` on forfeiture |
| `ethRaisedGraduated` | `uint128` | `+= R_target` on graduation |

The three recorders are
`recordGraduation(address creator, uint128 ethRaised, bool bondReturned)`,
`recordStall(address creator, bool bondReturned)` and
`recordExpiry(address creator, uint128 bondForfeited)`, each callable only by a
curve the factory itself deployed, which it checks against its own `isLaunch`
mapping. Each carries the bond outcome as an argument because the alternative is
the factory reading it back out of a curve that is still mid-transition; as a
result the factory never reads a launch's storage at all. Every increment emits
one `ReputationUpdated` log, so a `createLaunch` with a bond emits three.

`ethRaisedGraduated` is incremented by `R_target` — the amount the curve was
built to raise, passed as `recordGraduation`'s `ethRaised` argument — and not by
the launch's final `ethReserve`, which is `R_target` plus accumulated rounding
plus anything donated. The counter is comparable across launches for that reason;
it is not a measure of a launch's peak reserve.

The wei-denominated counters exist because counts are cheap to fabricate and wei
is not. A fresh address can manufacture any number of `launches`; it cannot
manufacture `bondWeiForfeited` without having actually lost that ETH to holders.
Reputation measured in forfeited ETH is the only part of this that is expensive
to fake, and it is the part a reader should weight.

No score, no ratio, no decay, no weighting is stored on-chain. A score encodes a
policy, and a policy baked into a non-upgradeable contract cannot be corrected
when it turns out to be wrong. The contract stores raw counters; any score is
computed off-chain from them and from the event log, where it can be revised.

---

## 14. Governance, pause and timelock

`LaunchFactory` has an owner, which is `Timelock`. `Timelock` has a fixed
`TIMELOCK_DELAY = 172800` seconds (48 hours) between proposal and execution,
measured with `block.timestamp`.

The owner's complete set of powers:

| Function | Effect | Cannot |
|---|---|---|
| `setLaunchesPaused(bool)` | `createLaunch` reverts | affect any existing launch in any way |
| `setFeeConfig(...)` | changes defaults for future launches, bounded by `MAX_TOTAL_FEE_BPS` and a shares-sum check in code | change any existing launch's fees |
| `setProtocolTreasury(address)` | changes the treasury recorded into future launches | redirect any existing launch's accrued fees |
| `renounceOwnership()` | sets the owner to the zero address, after which none of the three functions above can ever be called again | be undone, or hand ownership to a named address |

Four powers, and that is the whole list. `LaunchFactory` inherits OpenZeppelin
`Ownable`, which also declares `transferOwnership(address)`;
**`transferOwnership` is overridden to revert `OwnershipTransferDisabled`, so
the factory's ownership can never move.** The reason is that a transfer executed
through the timelock could put ownership in an EOA, which removes the delay from
every subsequent
configuration change and quietly voids the guarantee this section exists to
make. Overriding it makes "the factory's owner is the timelock, permanently" a
property of the code rather than a promise.

`renounceOwnership` is kept, because it only ever reduces power. It is the exact
mechanism by which decision 3 option C of `docs/OPEN_DECISIONS.md` — no owner at
all — can be taken after deployment, through the timelock and its delay, and it
is irreversible once taken.

`Timelock` itself has four entry points:

| Function | Caller | Effect |
|---|---|---|
| `propose(address target, bytes data, bytes32 salt)` | `admin` | records `readyAt = block.timestamp + DELAY` against the operation's id |
| `cancel(bytes32 id)` | `admin` | drops a pending operation |
| `execute(address target, bytes data, bytes32 salt)` | `admin` | clears the pending record, then makes the call; reverts before `readyAt` |
| `setAdmin(address)` | the timelock itself | rotates the admin, so the admin's own rotation also waits out the delay |

`Timelock` is not payable, has no `receive` function, and executes every
operation as a zero-value call, so no path exists by which it can hold or move
value. Its authority is exactly the four `onlyOwner` functions of the first table
in this section. Who holds the `admin` role is decision 3 of
`docs/OPEN_DECISIONS.md`.

There is no function on any deployed contract by which the owner, the timelock,
the treasury or any other address can move curve reserves, bond ETH, protection
ETH, accrued fees, vested tokens or a locked position. A pause stops new
launches only: trading, selling, donating,
graduating, expiring, claiming and vesting all continue to work while paused.
Every launch-time configuration value is copied immutably into the launch at
creation, so a launch's rules are fixed the moment it exists.

---

## 15. Parameters

### 15.1 Global constants

| Name | Value | Units |
|---|---|---|
| `TOTAL_SUPPLY` | `1_000_000_000 * 10**18` | base units |
| `CURVE_SUPPLY` | `900_000_000 * 10**18` | base units |
| `LP_SUPPLY` | `100_000_000 * 10**18` | base units |
| `VIRTUAL_TOKEN_RESERVE` | `1_012_500_000 * 10**18` | base units |
| `VIRTUAL_TOKEN_TAIL` | `112_500_000 * 10**18` | base units |
| `ETH_TARGET_MULTIPLE` | `8` | — |
| `CREATOR_FIRST_BUY_MAX` | `18_000_000 * 10**18` | base units |
| `MIN_BUY_WEI` | `10**12` | wei |
| `MAX_TOTAL_FEE_BPS` | `200` | bps |
| `GRAD_BOUNTY_BPS` | `1000` | hundredths of a percent of `protocolFeeEth` |
| `POOL_FEE` | `10000` | pips (1%) |
| `POOL_TICK_SPACING` | `200` | ticks |
| `ALT_TICK_SPACING_MIN` / `MAX` | `10` / `199` | ticks |
| `FLOOR_RANGE_TICKS` | `13800` | ticks |
| `MIN_FLOOR_WEI` | `10**12` | wei |
| `LP_DUST_MAX` | `10**5` | base units |
| `MIN_BOND_WEI` | `10**16` | wei |
| `MAX_BOND_WEI` | `1000 * 10**18` | wei |
| `BOND_MIN_BPS_OF_TARGET` | `1000` | bps of `R_target` |
| `ALT_DELAY` | `3600` | seconds |
| `GRAD_GRACE` | `604800` | seconds |
| `TIMELOCK_DELAY` | `172800` | seconds |

### 15.2 Per-launch parameters, immutable after `createLaunch`

| Name | Type | Units | Default | Bounds |
|---|---|---|---|---|
| `name` | `string` | — | — | 1 to 64 bytes |
| `symbol` | `string` | — | — | 1 to 16 bytes |
| `virtualEthReserve` | `uint128` | wei | `5 * 10**17` | `1.25e16` to `1.25e20`, giving `R_target` from 0.1 to 1000 ETH |
| `bondWei` | `uint128` | wei | `0` | `0`, or `max(MIN_BOND_WEI, R_target/10)` to `MAX_BOND_WEI` |
| `creatorFirstBuyWei` | `uint128` | wei | `0` | `0`, or `MIN_BUY_WEI` to whatever yields at most `CREATOR_FIRST_BUY_MAX` base units |
| `gradWindow` | `uint32` | seconds | `2592000` (30 d) | `86400` to `31536000` |
| `creatorVestCliff` | `uint32` | seconds | `604800` (7 d) | `0` to `7776000` |
| `creatorVestDuration` | `uint32` | seconds | `15552000` (180 d) | `2592000` to `126144000` |
| `totalFeeBps` | `uint16` | bps | `100` | from factory config, at most `MAX_TOTAL_FEE_BPS` |
| `creator` | `address` | — | `msg.sender` | non-zero |
| `protocolTreasury` | `address` | — | from factory config | non-zero |

Where each bound is enforced: `LaunchFactory` checks every row of the table, with
one split. The `creatorFirstBuyWei` row's lower bound is the factory's; its upper
bound is the curve's, because the ceiling is on the base units the buy yields and
only the curve knows that number (section 15.3).
`BondingCurve`'s constructor independently re-checks `virtualEthReserve`,
`gradWindow`, `totalFeeBps`, the three shares summing to 10000, the bond bounds,
`msg.value == bondWei`, and that none of its counterparties is the zero address,
so those bounds hold for any curve however it was deployed. It does not re-check
`name`, `symbol`, `creatorVestCliff` or `creatorVestDuration`: those reach a
launch only through the factory, and a curve deployed directly through
`CurveDeployer` by a third party is not a Pledrin launch (section 2.1).

`virtualEthReserve` is the curve's only free scalar. It scales the entire curve
linearly in ETH and leaves every token-side quantity — `CURVE_SUPPLY`,
`LP_SUPPLY`, `VIRTUAL_TOKEN_RESERVE`, the 81-fold price range, the 90/10 split —
globally constant. Every Pledrin launch has the same shape and differs only in
how much ETH it raises.

### 15.3 `createLaunch`, one transaction

`createLaunch(params)` payable, requires
`msg.value == bondWei + creatorFirstBuyWei`:

```
1.  validate every parameter against section 15.2
2.  read the factory's fee config; select the Pledged or unpledged share set
    from bondWei != 0 (section 6)
3.  CurveDeployer.deploy{value: bondWei}(config), which deploys the launch's
    BondingCurve; in that one constructor:
        validate the config again (section 15.2)
        if bondWei > 0: bondHeldWei = bondWei; bondState = Bonded
        TokenDeployer.deploy(name, symbol), minting TOTAL_SUPPLY to the curve
        require totalSupply == TOTAL_SUPPLY and balanceOf(curve) == TOTAL_SUPPLY
        PoolManager.initialize(poolKey, sqrtPriceTerminal)
4.  isLaunch[launch] = true
5.  if creatorFirstBuyWei > 0:
        curve.creatorFirstBuy{value: creatorFirstBuyWei}(cliff, duration)
6.  launches++, bondsPosted++, bondWeiPosted += bondWei
7.  emit LaunchCreated and LaunchMetadata
```

Step 5 runs the creator's first buy **inside the curve**, not in the factory.
`creatorFirstBuy(uint32 cliff, uint32 duration)` is payable, callable only by the
curve's own `factory`, and callable only while `tokensSold == 0`, which is true
only in the launch transaction. It runs the ordinary buy body of section 5.4
against the curve's own state and charges the ordinary fee, then approves
`CreatorVesting` and calls `createSchedule`, which pulls the tokens out of the
curve. The tokens therefore travel from the curve to vesting and never touch the
creator's wallet or the factory's balance.

Routing it through the curve is what lets `CreatorVesting` be keyed by
`msg.sender` (section 12): the schedule's key is the launch because the launch is
both the caller and the funder. A factory-side first buy would have had to move
the tokens through the factory and would have forced vesting to trust a named
caller, which reintroduces the deployment cycle of section 2.2.

The call carries no slippage bound and `block.timestamp` as its deadline. That is
safe only because of the `tokensSold == 0` precondition: the price is the launch's
opening price by construction, fixed in the same transaction by the curve's own
constructor, and no third party can have traded against it in between. Were the
first buy reachable at any other time, both arguments would have to be real.

A clipped first buy cannot produce a refund, and the curve therefore has no
refund path here. Clipping happens only when a buy takes the whole remaining sale
supply, which at `tokensSold == 0` is all of `CURVE_SUPPLY`, and the
`CREATOR_FIRST_BUY_MAX` check rejects any first buy yielding more than
18,000,000 tokens. The ceiling is checked after the quote has been applied, so an
oversized first buy reverts the entire launch transaction rather than being
clipped to the cap. The clipped branch is unreachable in this path and `refund`
is always zero.

The first buy emits `Bought` with `buyer = creator`, which is the indexer caveat
in section 16.1.

---

## 16. Events and revert reasons

Indexed fields are chosen for the indexer's access patterns: by launch, by
creator, by trader.

Event data is sized for completeness rather than for minimality, which is the
opposite of the rule section 1 applies to function arguments. Log data is not
posted to L1 as calldata, so an extra word in an event costs L2 execution gas
only, while calldata size is what dominates transaction cost on this chain
(`docs/CHAIN_FACTS.md`). Where a reader would otherwise have to reconstruct a
quantity by combining two logs, the event carries the quantity.

| Event | Fields (indexed marked `*`) |
|---|---|
| `LaunchCreated` | `launch*`, `token*`, `creator*`, `virtualEthReserve`, `ethTarget`, `totalFeeBps`, `creatorShareBps`, `protocolShareBps`, `protectionShareBps`, `bondWei`, `gradDeadline`, `poolId` |
| `LaunchMetadata` | `launch*`, `name`, `symbol`, `metadata` (opaque bytes, never stored) |
| `CurveDeployed` | `curve*`, `factory*`, `creator*` |
| `TokenDeployed` | `token*`, `curve*` |
| `Bought` | `launch*`, `buyer*`, `ethIn`, `ethToCurve`, `tokensOut`, `fee`, `refund`, `tokensSold`, `ethReserve` |
| `Sold` | `launch*`, `seller*`, `tokensIn`, `ethGross`, `ethOut`, `fee`, `tokensSold`, `ethReserve` |
| `FeeAccrued` | `launch*`, `creatorCut`, `protocolCut`, `protectionCut`, `reserveCut` |
| `Donated` | `launch*`, `donor*`, `amount`, `ethReserve` |
| `CapReached` | `launch*`, `ethReserve`, `timestamp` |
| `Graduated` | `launch*`, `poolId*`, `positionIdCore`, `positionIdFloor`, `ethToCore`, `ethToFloor`, `tokensToCore`, `bounty`, `caller*` |
| `GraduationStalled` | `launch*`, `caller*` |
| `Expired` | `launch*`, `bondForfeited`, `creatorFeesForfeited`, `protectionForfeited`, `ethReserve` |
| `BondStateChanged` | `launch*`, `creator*`, `oldState`, `newState`, `amount`, `destination` |
| `FeesClaimed` | `launch*`, `recipient*`, `kind`, `amount` |
| `VestingCreated` | `launch*`, `creator*`, `allocation`, `cliff`, `duration` |
| `VestingStarted` | `launch*`, `creator*`, `allocation`, `start`, `cliff`, `duration` |
| `VestingReleased` | `launch*`, `creator*`, `amount`, `cumulative` |
| `VestingVoided` | `launch*`, `creator*`, `allocation` |
| `PositionLocked` | `positionId*`, `launch*`, `kind` |
| `PositionCompounded` | `positionId*`, `caller*`, `liquidityAdded` |
| `ReputationUpdated` | `creator*`, `counter`, `newValue` |
| `LaunchesPausedSet` | `paused` |
| `FeeConfigSet` | `totalFeeBps`, `creatorShareBps`, `protocolShareBps`, `protectionShareBps`, `pledgedCreatorShareBps`, `pledgedProtocolShareBps`, `pledgedProtectionShareBps` |
| `TreasurySet` | `treasury*` |
| `OperationProposed` | `id*`, `target*`, `data`, `salt`, `readyAt` |
| `OperationExecuted` | `id*`, `target*`, `data`, `salt` |
| `OperationCancelled` | `id*` |
| `AdminTransferred` | `previousAdmin*`, `newAdmin*` |

The last four are `Timelock`'s. `LaunchFactory` additionally emits OpenZeppelin
`Ownable`'s `OwnershipTransferred(previousOwner*, newOwner*)`, once at
construction and once more if ownership is ever renounced; it can never be
emitted for a transfer, because `transferOwnership` reverts (section 14).

### 16.1 Notes for an indexer

- `Bought` for the creator's first buy reports `buyer = creator`, although the
  tokens are delivered to `CreatorVesting` and never reach the creator. An
  indexer that derives balances from trade events rather than from ERC-20
  `Transfer` events will misattribute that one buy. `VestingCreated`, emitted in
  the same transaction with the same allocation, disambiguates it.
- `abortGraduation` emits `Donated(launch, launch, protectionEth, ethReserve)`
  in addition to `GraduationStalled`, whenever `protectionEth` was non-zero. The
  donor field is the launch itself. `GraduationStalled` carries no amounts, so
  without that log an indexer tracking `ethReserve` from events would lose it at
  the stall.
- `expire` emits only `Expired`, plus `BondStateChanged` when there was a bond.
  There is deliberately no `Donated`: `Expired` already carries the bond, the
  creator fees, the protection ETH and the resulting `ethReserve`, so a second
  log would double-count the same wei.
- `Graduated` carries `positionIdFloor = 0` and `ethToFloor = 0` when
  `floorEth < MIN_FLOOR_WEI` (section 8.2 step 8). Zero is not a position id.
- A sell in `Expired` or `Stalled` redirects part of its fee into `ethReserve`
  (section 6.3). Two notes follow. `Sold`'s `ethReserve` field is the reserve
  after that redirect, so the reserve is exact from events alone and there is
  deliberately no `Donated` log for a redirect, which would double-count it
  against the same `Sold`. And `FeeAccrued` carries the redirect as its fourth
  amount, `reserveCut`, so `creatorCut + protocolCut + protectionCut +
  reserveCut` equals that trade's `fee` in every state: summing those four fields
  over a launch's `FeeAccrued` logs totals every wei of fee the launch ever
  charged, and an indexer may rely on that without reading `Bought` and `Sold` at
  all. The property is in the event rather than in this paragraph on purpose.
  While the redirected share was reported as a zero, an indexer that summed the
  three bucket amounts under-counted every post-terminal trade by the redirected
  share and nothing but prose said so.
- A `CurveDeployed` or `TokenDeployed` log is not evidence of a Pledrin launch:
  both deployers are permissionless (section 2.1). Only `LaunchCreated` from the
  factory, and the factory's `isLaunch` mapping, identify a launch.
- `PositionLocked` and `PositionCompounded` carry whatever address registered the
  position. `LiquidityLock` does not check that address against the factory,
  because it has no factory address and needs none (section 9), so cross-check
  `launch` against `isLaunch` before attributing a locked position to a launch.
- Reputation is reported one counter per log, so the three counters a bonded
  `createLaunch` touches arrive as three `ReputationUpdated` events.

### 16.2 Revert reasons

A refusal is part of the external interface, and two consumers read it directly.
The web application has to explain a transaction in plain words before it is
signed. An indexer records whatever reason a failed call returned as that call's
cause. Both are wrong in the same way when the reason is wrong.

**The standard, for every function of every Pledrin contract: a refusal must not
name a condition that a later call can clear when the real blocker is permanent.**
A caller told `BondNotReturned` is told to come back. A caller told
`BondForfeitedToHolders` is told not to. Naming the first when the second is true
is a defect rather than an imprecision, and it is one that no compiler and no
invariant about balances will catch. Where one error served several conditions of
unequal finality, the error is split until every refusal a function can give is
as final as the condition that caused it. A split of this kind changes no
precondition, no storage write and no state transition; if it changes any of
those, it is not this kind of change.

Four parts of this document are that standard applied: `claimBond`'s four
refusals (section 11.3); `release`'s four (section 12); `buy`'s window check
ahead of its deadline check (section 5.4); and the graduation checks, where the
state check precedes the `ALT_DELAY` check so that a launch which has already
graduated answers `WrongState` instead of being told to wait out a delay that is
not what stands in its caller's way (Invariant 37).

The standard binds a function's refusals to each other. It does not require that
an error name exactly one condition across the whole protocol: a shared error is
acceptable when the caller can tell the cases apart from data it already holds.

#### Shared errors, and whether they are settled

| Function | Error | Status |
|---|---|---|
| `claimProtocolFees()` | `NothingToClaim()` | Settled. The bucket is empty. Clearable in `Live`, `Expired` and `Stalled`, where every sell accrues a protocol share (section 6.3), and permanent in `Graduated`, where no trade executes. In `Graduating` it is clearable only by way of `Stalled`. Any caller already holds `state`, so one error serves both meanings. |
| `claimCreatorFees()` | `NothingToClaim()` | Settled. Only `Graduated` and `Stalled` reach this error at all, because every other state answers `WrongState` first. Clearable in `Stalled`, where a sell still accrues the creator share; permanent in `Graduated`. Discriminated by `state`, as above. |
| `claimBounty(address earner)` | `NothingToClaim()` | Settled. It means either that this address never graduated this launch or that its bounty has already been paid, and both are permanent: the credit is written only to the address that graduated the launch and only in that transaction (section 8.2), so no passage of time credits an address that is not credited already. Nothing clearable is implied, and the distinction tells a caller nothing it can act on. An indexer that wants it reads `Graduated.caller` against `FeesClaimed` with `kind = Bounty`. |
| `release(address launch)` | `NothingToRelease()` | Settled, by splitting rather than by exception. It covers three conditions — not started, inside the cliff, nothing newly accrued — and a later call clears all three, so nothing terminal hides behind it. The terminal condition it used to cover, a schedule released in full, is `ScheduleFullyReleased()` as of Decision 15 of `docs/OPEN_DECISIONS.md`. That case was the only shared error inside a single function rather than across two, which is the shape this standard forbids rather than the shape it permits, and it was fixed instead of excused. |

`WrongState(State current)` is not in this family. It carries the state in its
payload, so the refusal discriminates itself: a caller learns which state refused
it and, by Invariant 30, whether that state can still change. An error that
discriminates itself needs no second error.

#### Deliberate check order

Where two refusals can both be true of one call, the order the checks run in
decides which one the caller sees. That order is specified, not incidental:

| Function | Order | Reason |
|---|---|---|
| `graduateAlt(uint24 tickSpacing)` | `InvalidTickSpacing`, then the state check, then `AltDelayNotElapsed` | The range check is a verdict about calldata alone and is true in every state, so `graduateAlt(200)` answers it rather than `AltPoolInitialized`, which is a pool-state error that only happens to fire (section 8.4, Invariant 38). The delay check follows the state check, because a launch that has already graduated is not waiting for a delay (Invariant 37). |
| `buy(uint256 minTokensOut, uint256 deadline)` | `WrongState`, `BuyWindowClosed`, `DeadlinePassed`, `BuyTooSmall` | The window closes permanently and a deadline is cleared by resubmitting, so the window is named first. A buy that merely sat in the mempool still answers `DeadlinePassed`, because the window check cannot fire while the window is open (section 5.4, Invariant 32). |
| `sell(uint256 tokensIn, uint256 minEthOut, uint256 deadline)` | `WrongState`, `DeadlinePassed`, `ZeroAmount`, `SellExceedsSupplySold`, then the quote's own `ZeroAmount` and `SlippageExceeded` | The state first, then the caller's own deadline. There is nothing behind the deadline here for the order to matter against: `sell` has no window and stays open in both terminal states (Invariant 33). |

The `buy` row was the other way round until Decision 14 of
`docs/OPEN_DECISIONS.md` reversed it. One input class made both checks true: a
transaction whose own deadline had passed, sent after `gradDeadline` to a launch
still `Live` because nobody had called `expire()` yet. It answered
`DeadlinePassed`, and a resubmission with a fresh deadline then answered
`BuyWindowClosed` — a condition a later call can clear, named while the real
blocker was permanent. Swapping the two checks costs nothing: while the window is
open the window check cannot fire, so a stale buy still answers
`DeadlinePassed`, and once the window has closed the caller is told the permanent
truth on the first attempt.

A `DeadlinePassed` from `buy` therefore now implies that the window was still
open in the block that refused it, which is the property Invariant 32 asserts. A
front end needs no second read to interpret it and must not present it as
anything other than what it is: resubmitting is the remedy. Reading
`gradDeadline` remains worth doing to show how much of the window is left, and is
no longer needed to decide what a refusal means.

---

## 17. Invariants

Numbered, individually testable assertions. Every one must have a test that
fails if it is violated. The four marked **mandatory** — 1, 2, 14 and 25 — are
the core of the invariant suite.

### Curve solvency

1. **Mandatory.** For every launch in every state in which the curve still
   trades — that is `Live`, `Graduating`, `Expired` and `Stalled`, every state
   but `Graduated` — `(vE0 + ethReserve) * (vT0 - tokensSold) >= vE0 * vT0`.
   The exclusion of `Graduated` is exact, is not a convenience, and must not be
   read as a bug: `graduate` sets `ethReserve` to zero (section 8.2 step 6,
   Invariant 43) while `tokensSold` stands at `C`, so in `Graduated` the product
   is `vE0 * tau`, one ninth of `vE0 * vT0`. It does not need to hold there.
   Graduation closes both sides of the book in the same transaction: the reserve
   leaves for the two permanently locked positions, `sell` reverts in `Graduated`
   (Invariant 33), and there is therefore no sell left for the curve to be
   solvent against. A test asserts this invariant in the four states named and
   skips `Graduated` for that reason.
2. **Mandatory.** For every launch in a state in which the curve still trades,
   and every `dT` in `[1, tokensSold]`, the gross ETH the sell formula yields for
   `dT` is at most `ethReserve`. The curve can never become insolvent against any
   sell it will accept, including a single seller selling every token ever sold.
   `Graduated` is excluded for the reason given in Invariant 1: `ethReserve` is
   zero there and the formula's output is a quote nobody can execute, because
   `sell` reverts.
3. For every launch before graduation,
   `address(curve).balance >= ethReserve + protectionEth + creatorFeeEth + protocolFeeEth + bondHeldWei + pendingBountyTotalWei + pendingBondWei`.
   `pendingBountyTotalWei` is the stored sum of the `pendingBountyWei` mapping,
   which is what keeps this a one-read assertion.
4. `ethReserve` decreases only in `sell` and in `graduate`/`graduateAlt` (to
   zero). No other code path reduces it. In `Live` a sell decreases it by exactly
   `gross`; in `Expired` and `Stalled` it decreases by `gross` less whatever that
   trade's fee redirects into it under section 6.3, which is at most `gross`.
5. `token.balanceOf(curve) >= TOTAL_SUPPLY - tokensSold` for every launch before
   graduation, with equality unless tokens reached the curve outside the
   protocol's own transfers. Tokens sent to the curve by a third party are inert
   and are never counted, because nothing reads `balanceOf` for pricing
   (Invariant 10), so the inequality is the testable form and the equality holds
   for every sequence of protocol operations.
6. `tokensSold <= CURVE_SUPPLY` always.
7. An immediate round trip never profits: for any `v` and any state, selling the
   tokens a buy of `v` produced yields at most `v`, even with `totalFeeBps == 0`.
8. No trade executes at a price better than spot for the user: for every buy,
   `ethToCurve * vT >= tokensOut * vE`; for every sell,
   `ethGross * vT <= tokensIn * vE`, evaluated at pre-trade reserves.
9. `donate` increases `ethReserve` by exactly `msg.value` and changes no other
   storage: not `tokensSold`, not any fee bucket, not any lifecycle field.
10. Pricing never reads a balance. `buy`, `sell` and every quote view are
    unaffected by ETH or tokens force-sent to the curve.
11. `buy` reverts if `tokensOut < minTokensOut`; `sell` reverts if
    `ethOut < minEthOut`.
12. The buy that reaches the cap sets `tokensSold == CURVE_SUPPLY` exactly, and
    refunds `msg.value - ethToCurve - fee` to the buyer.
13. At `tokensSold == CURVE_SUPPLY`, in every state in which the curve still
    trades, `ethReserve >= 8 * vE0`. (Implied by 1; it is asserted separately
    because graduation depends on it. `Graduated` is excluded for the same reason
    as in Invariant 1, and the exclusion is load-bearing there rather than
    incidental: graduation is reached by spending exactly that reserve into the
    two locked positions, so `tokensSold == CURVE_SUPPLY` holds in `Graduated`
    with `ethReserve == 0`.)

### Fees

14. **Mandatory.** For every trade,
    `creatorCut + protocolCut + protectionCut == fee` exactly. No wei is created
    and none is lost.
15. `creatorShareBps + protocolShareBps + protectionShareBps == 10000` for both
    the Pledged and unpledged share sets, enforced at config time and at launch
    time.
16. `totalFeeBps <= MAX_TOTAL_FEE_BPS` for every launch, enforced in the curve's
    constructor and not only in factory config.
17. `protectionCut` is computed as the residual and is therefore the sole
    destination of every rounding remainder of a fee split.
18. Fee conservation, in two forms, because the exact equality is a statement
    about a launch that has not yet left `Live` and the general statement has to
    name every destination a fee can legitimately reach afterwards.
    (a) **Pre-terminality.** For every launch that has not left `Live`, the sum of
    all `fee` values ever charged equals the sum of: the three buckets' current
    balances; the ETH paid out by `claimCreatorFees`, `claimProtocolFees` and
    `claimBounty`; and bounty credited but not yet claimed. Exact equality, no
    tolerance.
    (b) **Every launch, every state.** The sum of all `fee` values ever charged
    equals that same sum extended with the destinations a fee reaches when a
    launch leaves `Live`: `protectionEth` paid into the floor mint at graduation,
    including the part of it the mint did not consume and swept back into a curve
    that has no withdrawal path, and the whole of it when
    `floorEth < MIN_FLOOR_WEI` leaves the floor position unminted;
    `protectionEth` moved into `ethReserve` by `expire` or `abortGraduation`;
    creator fees moved into `ethReserve` by `expire`; and the shares a trade in
    `Expired` or `Stalled` redirects into `ethReserve` under section 6.3. No wei
    of a fee is created and none is lost, in any state. Fees do not only ever sit
    in their buckets, and a test written from form (a) alone will fail on any
    launch that left `Live`.
19. No protocol function transfers the launch token out of any user's balance.
    Fees are ETH-only.

### Creator constraints

20. For every launch in `Live` or `Graduating`, the total ETH ever sent by the
    protocol to `creator` on account of that launch is zero.
21. `CreatorVesting.releasable(launch)` is zero for all
    `t < start + cliff`, and zero forever once `voided` is set.
22. Cumulative released never exceeds `allocation`, and equals `allocation` for
    every `t >= start + cliff + duration` on a non-voided schedule.
23. `allocation`, `cliff` and `duration` are never writable after `createLaunch`;
    `start` is writable exactly once, and only by the launch itself, because
    `createSchedule`, `start` and `void` are all keyed by `msg.sender` and no
    function of `CreatorVesting` takes a launch argument it then writes to
    (section 12).
24. The tokens delivered to `CreatorVesting` at launch are at most
    `CREATOR_FIRST_BUY_MAX`.

### Bond

25. **Mandatory.** For every launch, `bondState` leaves `Bonded` at most once,
    and `bondHeldWei + pendingBondWei + (ETH ever paid out on the bond account)
    + (ETH ever moved from the bond account into `ethReserve`) == bondWei` at
    every point in time. A bond is never paid twice, and no wei of it is ever
    paid to both the creator and the reserve.
26. `bondState == Returned` implies `state in {Graduated, Stalled}`;
    `bondState == Forfeited` implies `state == Expired`.
27. On `expire()`, `bondHeldWei + creatorFeeEth + protectionEth` is added to
    `ethReserve` in full, those three fields become zero, and nothing is sent or
    credited to `creator`.
28. `bondWei > 0` implies `bondWei >= max(MIN_BOND_WEI, R_target / 10)` and
    `bondWei <= MAX_BOND_WEI`.
29. `pledged()` is a pure function of the immutable `bondWei` and has no setter,
    and is therefore unchanged by any bond transition.

### Lifecycle

30. Once `state` is `Graduated`, `Expired` or `Stalled`, it never changes again.
31. `tokensSold` never **increases** once `state` leaves `Live`, and does not
    change at all while `state` is `Graduating` or `Graduated`. In `Expired` and
    `Stalled` it decreases by exactly `dT` on every accepted `sell`
    (section 5.5 step 8), which is mandatory rather than incidental: the sell
    price is computed from `vT = vT0 - tokensSold`, so holding `tokensSold` fixed
    while `ethReserve` falls would make `vE * vT` decrease and break Invariants 1
    and 2. What this invariant forbids is what it was written to forbid: there
    is no buy after `Live`, so `tokensSold` can never rise again, and the cap is
    a one-way door because `Graduating` admits neither direction.
32. `buy` reverts unless `state == Live && block.timestamp < gradDeadline`, and
    its refusals are given in the order `WrongState`, `BuyWindowClosed`,
    `DeadlinePassed`, `BuyTooSmall`. A call made at or after `gradDeadline`
    therefore answers `BuyWindowClosed` whether or not its own deadline has also
    passed, and a `DeadlinePassed` from `buy` implies
    `block.timestamp < gradDeadline` in the block that refused it. No refusal of
    `buy` names a condition a later call can clear while a permanent condition
    also holds (section 16.2).
33. `sell` succeeds in `Live`, `Expired` and `Stalled` and reverts in
    `Graduating` and `Graduated`.
34. `Expired` requires `block.timestamp >= gradDeadline && tokensSold < CURVE_SUPPLY`;
    `Graduating` requires `tokensSold == CURVE_SUPPLY && block.timestamp < gradDeadline`.
35. Exactly one of `Graduated`, `Expired` or `Stalled` is reachable from any
    `Live` launch, and every `Live` launch reaches one of them given the passage
    of time and at least one external call.
36. `graduate` and `graduateAlt` together succeed at most once per launch.
37. `graduateAlt` reverts before `capReachedAt + ALT_DELAY`;
    `abortGraduation` reverts before `capReachedAt + GRAD_GRACE`. Both delay
    checks run after their function's state check, so a launch that is not
    `Graduating` answers `WrongState` and is never told to wait out a delay that
    is not what refused it (section 16.2).
38. `graduateAlt` accepts only `tickSpacing` in
    `[ALT_TICK_SPACING_MIN, ALT_TICK_SPACING_MAX] = [10, 199]`, narrowed from
    `uint24` to `int24` through `SafeCast`, and only a pool that is not yet
    initialised. `ALT_TICK_SPACING_MAX` is strictly below
    `POOL_TICK_SPACING = 200`, so `graduateAlt` can never name the canonical pool
    key: `graduateAlt(200)` reverts `InvalidTickSpacing` on the range check, not
    `AltPoolInitialized` on the pool-state check. The usable set is every spacing
    from 10 to 199, 190 distinct pool keys, and `graduate` is the only path to the
    canonical key.

### Graduation and liquidity

39. The core position consumes **at most** `LP_SUPPLY` base units of the token and
    at most `8 * vE0` wei. The token remainder, `LP_SUPPLY` minus the amount
    consumed, is at most `LP_DUST_MAX`, and graduation asserts that bound
    explicitly rather than assuming the amount is exact. The liquidity minted is
    the largest value whose `currency1` requirement does not exceed `LP_SUPPLY`:
    one more unit of liquidity would require more than `LP_SUPPLY`.
40. The pool's `sqrtPriceX96` equals `sqrtPriceTerminal` immediately before the
    core position is minted.
41. Any price-restoring swap performed by `graduate` or `graduateAlt` has zero net
    currency0 and zero net currency1 delta, whatever non-zero `amountSpecified`
    it nominates. The curve never spends ETH or tokens on a swap.
42. The floor position, when minted, has
    `tickLower == alignDown(currentTick, tickSpacing) + tickSpacing` and therefore
    `tickLower > currentTick`, with `currentTick` read from `slot0.tick` and not
    derived from `slot0.sqrtPriceX96`; it has
    `tickUpper == tickLower + alignDown(FLOOR_RANGE_TICKS, tickSpacing)` and
    `tickUpper <= alignDown(MAX_TICK, tickSpacing)`; and it is funded in
    `currency0` only, consuming zero base units of the token and requiring no
    token approval.
43. After graduation, `ethReserve == 0`; the curve's remaining ETH balance is at
    most `MIN_FLOOR_WEI`, plus whatever of `floorEth` the floor mint did not
    consume and swept back, plus the unclaimed fee, bounty and bond buckets, plus
    any ETH that reached the curve outside its own paths; and the curve's
    remaining token balance is at most `LP_DUST_MAX` plus any tokens force-sent
    to it. None of those amounts has a withdrawal path after graduation.
44. The graduation bounty is at most `protocolFeeEth` at the time of graduation,
    and is never drawn from `ethReserve`, `protectionEth`, `creatorFeeEth` or
    `bondWei`.
45. `graduate` and `graduateAlt` make no ETH transfer to any address other than
    PoolManager and PositionManager. The bond and the bounty are credited, not
    pushed.
46. Every position NFT minted by graduation is owned by `LiquidityLock`
    immediately after the transaction, and `LiquidityLock` contains no code path
    that calls `transferFrom`, `safeTransferFrom`, `approve`, `setApprovalForAll`
    or `permit`, no `BURN_POSITION` action, and no liquidity-decreasing action
    with a non-zero liquidity argument. Decision 12 of
    `docs/OPEN_DECISIONS.md` resolved to option B, so the lock's action list
    contains exactly one `DECREASE_LIQUIDITY`, whose liquidity argument is the
    literal zero in the encoding and not a parameter: no input to any function
    of the lock can make it non-zero.
47. After graduation the protocol charges no fee on any trade. All post-graduation
    trading fees accrue inside the locked positions.

### Governance

48. Every reputation counter is monotonically non-decreasing and has no external
    setter on any contract.
49. `graduations + stalls + expiries <= launches`;
    `bondsReturned + bondsForfeited <= bondsPosted`;
    `bondsPosted <= launches`; for every creator.
50. While `launchesPaused` is true, `createLaunch` reverts and `buy`, `sell`,
    `donate`, `graduate`, `graduateAlt`, `abortGraduation`, `expire`, every
    claim function and `release` all still succeed.
51. Every `LaunchFactory` config change requires at least `TIMELOCK_DELAY`
    seconds between proposal and execution, measured with `block.timestamp`.
52. No function on any deployed contract allows the factory owner, the timelock,
    the treasury or any other address to move curve reserves, bond ETH,
    protection ETH, accrued fees, vested tokens or a locked position.
53. A launch's `totalFeeBps`, fee shares, `protocolTreasury`, `creator`,
    `virtualEthReserve`, `gradDeadline`, `creatorVestCliff` and
    `creatorVestDuration` are never writable after `createLaunch`.
54. No contract in the system has a `selfdestruct`, a `delegatecall`, a proxy, or
    an initialiser of any kind. Every launch is a full `CREATE` deployment made
    by `CurveDeployer` with `new`, so its immutables are set in a real
    constructor; there is no clone, no immutable-args offset read by hand-
    maintained offsets, and no post-deployment initialisation step
    (sections 2.1 and 2.2).

### Reentrancy and call discipline

55. Call discipline, in three parts, because the strongest form is not true
    everywhere and the document must say which form is enforced:
    (a) every external function that moves ETH or tokens holds a reentrancy
    guard; (b) every function that moves `state` to a terminal value writes
    `state` first, before any external call, so that a reentrant entry fails the
    state check; (c) in `buy`, `sell`, `donate`, `creatorFirstBuy`,
    `claimCreatorFees`, `claimProtocolFees`, `claimBond`, `claimBounty`,
    `CreatorVesting.createSchedule`, `CreatorVesting.release` and
    `LiquidityLock.compound` — which writes no storage at all — no storage write
    follows any external call, and in `graduate`, `graduateAlt`, `expire`,
    `abortGraduation` and `createLaunch`, every storage write the function
    performs is complete before its final external call, so that what follows is
    only calls that write none of the calling contract's own state — the floor
    mint and its registration with the lock, `CreatorVesting.start` / `void`,
    `LaunchFactory.record*`, and the views the event arguments read — and the
    event itself. The stronger "no storage write after any external call" cannot
    hold in `graduate`, `graduateAlt` or `createLaunch`: graduation must read how
    much ETH the core mint consumed before it can compute `floorEth`
    (section 8.2 steps 4 to 8), and `createLaunch` cannot write `isLaunch` or a
    reputation counter before the curve those writes describe exists.
56. `unlockCallback` on the curve reverts unless `msg.sender` is PoolManager and
    the curve is inside its own `unlock`.
57. `onERC721Received` on `LiquidityLock` reverts unless `msg.sender` is
    PositionManager, and it is declared `external view`, so that its ABI state
    mutability is `view`. The second clause is asserted for the same reason the
    suite asserts the value of a constant. Anyone may `safeTransferFrom` a v4
    position NFT into the lock from anywhere, and that is the only path which
    reaches this callback: graduation does not, because PositionManager mints with
    `_mint` and invokes no receiver hook. `view` is what makes accepting such a
    transfer inert — the callback can register no position, write no storage and
    move no token, so an unsolicited NFT is dead weight in the lock rather than a
    lever on it (`docs/THREAT_MODEL.md` section 7). Removing `view` to make the
    callback do something useful would make that argument false with nothing else
    failing.
58. A recipient that reverts on receiving ETH can block only its own claim, and
    can block no other party's claim, no trade, and no state transition.

### Fees charged after a terminal transition

59. For every trade accepted in `Expired` or `Stalled`, with the split itself
    unchanged (Invariants 14 and 17) and with every share measured against the
    table in section 6.3: the protocol share accrues to `protocolFeeEth`; the
    holder-protection share is added to `ethReserve` and leaves `protectionEth`
    unchanged by that trade; in `Expired` the creator share is added to
    `ethReserve` and leaves `creatorFeeEth` unchanged by that trade; in `Stalled`
    the creator share accrues to `creatorFeeEth`, which is claimable in that
    state. No wei of a fee charged after a terminal transition is left in a bucket
    that has no reachable claim, the `ethReserve` field of that trade's event
    equals the launch's `ethReserve` immediately after the call, and the four
    amounts reported by its `FeeAccrued` satisfy
    `creatorCut + protocolCut + protectionCut + reserveCut == fee`, where
    `reserveCut` is the wei the trade added to `ethReserve` out of the fee. That
    equality holds for every trade in every state, including `Live`, where
    `reserveCut` is zero.

### Donated balances and the graduation mint

60. The token the core graduation mint consumes, the ETH it consumes, and the
    dust comparison against `LP_DUST_MAX` are each computed from the difference
    between a reading taken before the mint call and a reading taken after it,
    and never from an absolute balance read after that call. Therefore, for any
    amount `D` of launch token transferred to the curve by any address at any
    time before `graduate()` or `graduateAlt()` is called, that graduation's
    `tokensToCore`, `ethToCore`, `positionIdCore`, `ethToFloor` and success or
    failure are identical to the same graduation with `D = 0`, and `D` is still
    held by the curve afterwards with no path out of it.

### Approvals that outlive graduation

61. Immediately after `graduate()` or `graduateAlt()` returns,
    `token.allowance(curve, PERMIT2) == 0`, and the curve contains no code path
    that sets that allowance other than the core mint, which runs at most once
    per launch. The Permit2 registration naming PositionManager as spender still
    exists at that point and still carries the core mint's unspent remainder; it
    is unusable for exactly as long as those two clauses hold, and for no other
    reason.

### Revert reasons

62. `CreatorVesting.release(launch)` gives exactly the refusal section 12's table
    assigns to the schedule's condition, in that order: `NoSchedule` when
    `allocation == 0`; `ScheduleVoided` when `voided` is set, whatever the clock
    says and whatever `releasable` returns; `ScheduleFullyReleased` when
    `released == allocation`, which is checked before the releasable amount is
    computed; and `NothingToRelease` only on a schedule that exists, is not
    voided, is not finished, and has nothing releasable at this block time. No
    voided schedule and no finished schedule ever answers `NothingToRelease`, so
    for every schedule that does answer it there is a later block time, or a later
    transition of its launch, at which `release` pays.
63. `claimBond()` gives exactly the refusal section 11.3's table assigns to the
    launch's bond: `NoBondPosted` in `None`, `BondNotReturned` in `Bonded`,
    `BondForfeitedToHolders` in `Forfeited`, and `BondAlreadyClaimed` in
    `Returned` with `pendingBondWei == 0`. It succeeds only in `Returned` with a
    non-zero credit, and therefore at most once per launch, so
    `BondAlreadyClaimed` is reachable only after a claim that paid.

---

## 18. Out of scope for this specification

- The indexer, the frontend and any off-chain scoring derived from section 13.
- Post-graduation routing and quoting, which use ordinary v4 tooling.
- Token metadata hosting. The protocol emits an opaque `metadata` blob in
  `LaunchMetadata` and interprets none of it.
- Any mechanism that would require an oracle, an admin decision, or off-chain
  judgement. Candidates are listed and rejected in section 11.5.
