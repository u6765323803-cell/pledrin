# Pledrin — normative specification

Status: Phase 0. This document is normative. Where it conflicts with code, the
code is wrong. Where it is silent, `docs/OPEN_DECISIONS.md` records the gap.

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
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Uniswap v4 StateView (reads only) | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |

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
(`0x8876789976decbfcbbbe364623c63652db8c0904`) rather than the better-known v2
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
| `LiquidityLock` | singleton | graduated position NFTs | none |
| `Timelock` | singleton | nothing | protocol governance |

`BondingCurve` is one instance per launch rather than a singleton with a
`launchId` argument. Reasons: a per-launch instance makes `address(curve).balance`
the single number that must cover that launch's obligations, which makes
Invariant 3 a one-read assertion; it removes a 32-byte `launchId` from every
trade's calldata on a chain where calldata dominates cost; and it removes any
possibility of cross-launch accounting confusion. The deployment mechanism
(full deploy versus clone with immutable args) is an open decision; it does not
affect semantics.

Fee splitting is performed inside `BondingCurve`, not in a separate splitter.
A separate splitter would move value across a contract boundary on every trade
for no gain.

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

The entire supply is minted to the launch's `BondingCurve`.

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
units, 2% of total supply. At the default parameters that costs 0.00905 ETH,
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

Per launch, immutable:

| Name | Type | Units | Meaning |
|---|---|---|---|
| `virtualEthReserve` (`vE0`) | `uint128` | wei | the curve's only free scalar |

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
(section 5.5), which updates `r` explicitly.

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
`state == Live`, `block.timestamp <= deadline`,
`block.timestamp < gradDeadline`, and `msg.value >= MIN_BUY_WEI`.

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
8.  split fee per section 6
9.  token.transfer(msg.sender, dT)
10. if refund > 0: send refund to msg.sender
11. if s == C: state = Graduating, capReachedAt = block.timestamp
```

Step 4's second branch is the final buy, clipped exactly to the cap. The buyer
pays only for the tokens they receive and the fee is recomputed on the ETH
actually consumed, so the clipped buyer is not charged a fee on the refunded
portion. The `require` in that branch covers the at-most-two-wei rounding
overshoot that `mulDivUp` and `ceil` can introduce; it reverts rather than
silently charging more.

### 5.5 Sell

`sell(uint256 dT, uint256 minEthOut, uint256 deadline)`. Requires
`state in {Live, Expired, Stalled}`, `block.timestamp <= deadline`, and
`dT >= 1`. The caller must have approved or the contract must pull via
`transferFrom`.

```
1.  require(dT <= s)
2.  gross = mulDiv(vE, dT, vT + dT)                            // round down
3.  require(gross >= 1)
4.  fee   = ceil(gross * totalFeeBps / 10000)
5.  out   = gross - fee
6.  require(out >= 1 && out >= minEthOut)
7.  token.transferFrom(msg.sender, address(this), dT)
8.  r -= gross
9.  s -= dT
10. split fee per section 6
11. send out to msg.sender
```

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
every possible `fee`, with no wei created and none lost. This is Invariant 4.

**The rounding remainder goes to the holder-protection pool**, and from there
into permanently locked liquidity (section 11). The dust therefore flows to
holders, which is the party that should receive it when a rounding direction is
ambiguous. No other destination is permitted.

### 6.2 Accrual and claiming

Three per-launch ETH buckets: `creatorFeeEth`, `protocolFeeEth`,
`protectionEth`. All three are accrued in storage and paid out later, never
pushed during a trade. A trade never makes an outbound call to the creator or
the treasury.

| Function | Caller | Precondition | Destination |
|---|---|---|---|
| `claimCreatorFees()` | anyone | `state in {Graduated, Stalled}` | `creator` |
| `claimProtocolFees()` | anyone | any state | `protocolTreasury` |
| `claimBond()` | anyone | `bondState == Returned` | `creator` |
| `claimBounty()` | anyone | `pendingBountyWei > 0` | the recorded bounty earner |

`claimCreatorFees` reverting before graduation is load-bearing: **the creator
cannot withdraw a single wei from a launch until that launch has delivered.**
This is Invariant 20 and is the strongest deterministic creator constraint the
design has.

`protocolTreasury` is copied immutably into the curve at launch, so a later
change to factory config cannot redirect an existing launch's accrued fees.

Both claim functions are permissionless pushes so that no privileged action is
ever needed to move accrued value, and both use a checked low-level call. A
recipient that reverts on receipt blocks only its own bucket.

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

`createLaunch` calls `PoolManager.initialize(poolKey, sqrtPriceTerminal)` in
the launch transaction, with zero liquidity.

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
`sqrtPriceTerminal` is always above `MIN_SQRT_PRICE`.

Initialising at launch is the primary anti-grief measure. The token address does
not exist before the launch transaction, so no attacker can reach the pool key
first, and therefore **no attacker can ever choose the pool's initial price.**
The cost is one `initialize` call per launch including launches that never
graduate. That is accepted: the alternative leaves the single most important
transaction in the protocol exposed to a cheap, permanent grief.

`hooks` is `address(0)`. A hook could take a post-graduation fee, but it would
put protocol code in the swap path of every future trade forever. The claim
this design makes is that a graduated Pledrin pool is an ordinary, unowned,
hookless v4 pool.

### 8.2 `graduate()`

Permissionless. Requires `state == Graduating`. One transaction, no window.

```
1.  state = Graduated; graduatedAt = block.timestamp      // before any call out
2.  if slot0(poolKey).sqrtPriceX96 != sqrtPriceTerminal:
        perform a zero-input swap with sqrtPriceLimitX96 = sqrtPriceTerminal
        require the swap's net currency0 and currency1 deltas are both zero
        require slot0(poolKey).sqrtPriceX96 == sqrtPriceTerminal
3.  token.approve(PERMIT2, S_LP)
    PERMIT2.approve(token, POSITION_MANAGER, S_LP, type(uint48).max)
4.  mint position A (core):
        tickLower = alignUp(MIN_TICK, tickSpacing)
        tickUpper = alignDown(MAX_TICK, tickSpacing)       // -887200 / 887200
        token amount: exactly S_LP
        ETH amount:   at most R_target
        recipient:    LiquidityLock
5.  floorEth = protectionEth + (r - R_target) + (R_target - ETH used by A)
    protectionEth = 0
6.  if floorEth >= MIN_FLOOR_WEI:
        mint position B (floor):
            tickUpper = alignDown(currentTick, tickSpacing) - tickSpacing
            tickLower = tickUpper - alignDown(FLOOR_RANGE_TICKS, tickSpacing)
            require tickLower >= alignUp(MIN_TICK, tickSpacing)
            ETH amount:   floorEth, single-sided (currency0 only)
            recipient:    LiquidityLock
7.  r = 0
8.  bounty = floor(protocolFeeEth * GRAD_BOUNTY_BPS / 10000)
    protocolFeeEth -= bounty
    pendingBountyWei[msg.sender] += bounty                  // credited, not pushed
9.  if bondHeldWei > 0:
        bondState = Returned
        pendingBondWei = bondHeldWei; bondHeldWei = 0        // credited, not pushed
10. CreatorVesting.start(launch, block.timestamp)
11. factory.recordGraduation(creator, R_target)
12. emit Graduated
```

Position A is minted **token-exact**: it consumes exactly `S_LP` base units and
at most `R_target` wei. Any unused ETH flows into the floor position in step 5,
so nothing is stranded and no token dust is immobilised. Because the pool opens
at exactly the curve's terminal price, the ETH consumed equals `R_target` to
within the `sqrtPriceTerminal` rounding-down error.

Steps 8 and 9 **credit** rather than send. A creator or bounty earner whose
address reverts on receiving ETH would otherwise be able to make `graduate()`
revert forever, which would strand every holder. Nothing in `graduate()` makes
an ETH transfer to an address the caller does not control.

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
| Move the price of the zero-liquidity pool before graduation | `graduate()` restores it with a zero-input limit swap, which costs nothing in a pool with no liquidity, and asserts the restored price. |
| Add liquidity to the pool so the price reset is not free | The reset is required to have zero net cost, so `graduate()` reverts rather than spending curve ETH. State stays frozen and `graduate()` is retryable forever. |
| Block the primary pool key permanently | After `ALT_DELAY = 1 hour` in `Graduating`, `graduateAlt(uint24 tickSpacing)` runs the identical procedure on a caller-chosen `tickSpacing` in `[10, 200]`, requiring that pool to be uninitialised so it is initialised at `sqrtPriceTerminal` with no prior liquidity. An attacker would have to pre-block the whole permitted spacing range and keep doing so. |
| Sell at the cap to prevent graduation | `Graduating` freezes `s`. |
| Revert on ETH receipt to make `graduate()` fail | `graduate()` sends ETH to nobody; bond and bounty are credited. |
| Starve graduation of a caller | Permissionless and bounty-paid, section 8.3. |
| Everything above at once | After `GRAD_GRACE = 7 days` in `Graduating`, `abortGraduation()` moves the launch to `Stalled`: sells reopen permanently, the bond is **returned** to the creator because the cap was delivered, creator fees become claimable, and `protectionEth` is donated into `r`. Holders get a permanent exit against the deepest reserve the curve ever held. |

`ALT_DELAY` exists so that the honest primary key wins when it is available and
a caller cannot fragment the canonical pool onto an odd tick spacing for no
reason.

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
3. The floor position is entirely below spot, so adding it cannot move the
   price up and cannot create a gap.

What remains: the first swap in the new pool is ordinary MEV and is not
prevented. Whoever wins it captures ordinary price impact, not a protocol
subsidy. `docs/THREAT_MODEL.md` says so.

---

## 9. Liquidity lock

`LiquidityLock` receives the position NFTs via `safeTransferFrom` and holds
them. It has no function that calls `transferFrom`, `safeTransferFrom`,
`approve`, `setApprovalForAll`, `permit`, or any PositionManager action that
decreases liquidity or burns a position. There is no owner, no rescue function,
no sweep, no timelock, no escape hatch. `ownerOf` for a locked position is the
lock, forever.

Trading fees accruing to a locked position are an open decision (whether the
lock ships with a permissionless compound-only path from day one, since it
cannot be added later without weakening the lock). `docs/OPEN_DECISIONS.md`
records it as blocking Phase 1. Either way, no path exists by which a locked
position's principal or fees reach any address.

---

## 10. Holder protection pool

### 10.1 What it does

The holder-protection share of every trading fee accrues as `protectionEth` and
is deposited at graduation as **position B: a single-sided, ETH-only, permanently
locked Uniswap v4 position occupying the tick range immediately below the
opening price.**

That is a standing bid. If the price falls into the range, the position buys
tokens from sellers with the protection pool's ETH, which is exactly the
support a floor is supposed to be. The tokens it acquires become sell-side
depth on the way back up. The position is locked, so neither the ETH nor the
tokens nor the fees ever leave it.

The range is `FLOOR_RANGE_TICKS = 13800` ticks wide, which is a price factor of
`1.0001^13800 = 3.97`. The bid therefore spans from just below the opening
price down to about 25% of it, concentrating the protection across the drawdown
band where it matters rather than spreading it thinly to zero.

`tickUpper` is `alignDown(currentTick, tickSpacing) - tickSpacing`, which is
strictly below the current tick's aligned boundary. This guarantees the position
is single-sided in `currency0` and therefore mintable with ETH alone and
incapable of moving the opening price.

If `floorEth < MIN_FLOOR_WEI = 1e12` the position is not minted, because v4
would round the liquidity to zero. That ETH stays in the curve contract, which
after graduation has no withdrawal path of any kind: it is permanently removed
from circulation. The amount is bounded above by `1e12` wei, 0.000001 ETH.

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

> The launch reaches `tokensSold == CURVE_SUPPLY` before
> `launchedAt + gradWindow`.

That is the whole of it. The bond is a **delivery bond**, not an honesty bond
and not an anti-rug bond. It makes one promise that a contract can check without
an oracle, without an admin and without judgement, and it makes no other promise.
`docs/THREAT_MODEL.md` states this in those words.

If `bondWei > 0` the launch is Pledged: the `pledged()` view returns true and the
Pledged fee shares of section 6 apply. Pledged status is derived from
`bondWei > 0` and `bondState`, never from a settable flag.

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

### 11.3 The three terminal bond states

`bondState` is one of `None`, `Bonded`, `Returned`, `Forfeited`. It leaves
`Bonded` at most once, and every exit is a single write guarded by the state
check. This is what makes Invariant 7 — a bond is never paid twice — a
one-enum assertion rather than a balance argument.

| Transition | Condition | Effect |
|---|---|---|
| `Bonded -> Returned` | `graduate()`, `graduateAlt()` or `abortGraduation()` | `pendingBondWei = bondHeldWei`; `bondHeldWei = 0`; `bondsReturned++` |
| `Bonded -> Forfeited` | `expire()`: `state == Live && block.timestamp >= gradDeadline && s < C` | `ethReserve += bondHeldWei`; `bondHeldWei = 0`; `bondsForfeited++`; `bondWeiForfeited += bondWei` |

### 11.4 Automatic payout to holders

The only trigger is expiry: the cap was not reached before the deadline.
`expire()` is permissionless and does, atomically:

```
state = Expired
forfeited = bondHeldWei + creatorFeeEth + protectionEth
if bondHeldWei > 0: bondState = Forfeited
r += forfeited
bondHeldWei = 0; creatorFeeEth = 0; protectionEth = 0
CreatorVesting.void(launch)
factory.recordExpiry(creator, bondWei)
emit Expired(...)
```

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

`CreatorVesting` is a singleton holding one schedule per launch.

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

`release()` is callable by anyone and always sends to the recorded `creator`.
There is no early-release path, no owner, no acceleration, no transfer of the
schedule, and no function that can change `allocation`, `cliff` or `duration`
after launch. `void()` is callable only by that launch's curve and only on
expiry; once voided the allocation is irrecoverable by anyone, which removes
2% of supply from circulation without burning it and without changing
`totalSupply()`.

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

That is the whole list. There is no function on any deployed contract by which
the owner, the timelock, the treasury or any other address can move curve
reserves, bond ETH, protection ETH, accrued fees, vested tokens or a locked
position. A pause stops new launches only: trading, selling, donating,
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
| `ALT_TICK_SPACING_MIN` / `MAX` | `10` / `200` | ticks |
| `FLOOR_RANGE_TICKS` | `13800` | ticks |
| `MIN_FLOOR_WEI` | `10**12` | wei |
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
| `creatorFirstBuyWei` | `uint128` | wei | `0` | `0` to whatever yields at most `CREATOR_FIRST_BUY_MAX` base units |
| `gradWindow` | `uint32` | seconds | `2592000` (30 d) | `86400` to `31536000` |
| `creatorVestCliff` | `uint32` | seconds | `604800` (7 d) | `0` to `7776000` |
| `creatorVestDuration` | `uint32` | seconds | `15552000` (180 d) | `2592000` to `126144000` |
| `totalFeeBps` | `uint16` | bps | `100` | from factory config, at most `MAX_TOTAL_FEE_BPS` |
| `creator` | `address` | — | `msg.sender` | non-zero |
| `protocolTreasury` | `address` | — | from factory config | non-zero |

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
2.  deploy PledrinToken, minting TOTAL_SUPPLY to the new BondingCurve
3.  deploy BondingCurve with all immutables
4.  PoolManager.initialize(poolKey, sqrtPriceTerminal)
5.  if bondWei > 0: bondHeldWei = bondWei; bondState = Bonded
6.  if creatorFirstBuyWei > 0:
        execute buy(creatorFirstBuyWei) on the curve
        require tokens out <= CREATOR_FIRST_BUY_MAX
        deliver tokens to CreatorVesting with start = 0
7.  launches++, bondsPosted++, bondWeiPosted += bondWei
8.  emit LaunchCreated and LaunchMetadata
```

---

## 16. Events

Indexed fields are chosen for the indexer's access patterns: by launch, by
creator, by trader.

| Event | Fields (indexed marked `*`) |
|---|---|
| `LaunchCreated` | `launch*`, `token*`, `creator*`, `virtualEthReserve`, `ethTarget`, `totalFeeBps`, `creatorShareBps`, `protocolShareBps`, `protectionShareBps`, `bondWei`, `gradDeadline`, `poolId` |
| `LaunchMetadata` | `launch*`, `name`, `symbol`, `metadata` (opaque bytes, never stored) |
| `Bought` | `launch*`, `buyer*`, `ethIn`, `ethToCurve`, `tokensOut`, `fee`, `refund`, `tokensSold`, `ethReserve` |
| `Sold` | `launch*`, `seller*`, `tokensIn`, `ethGross`, `ethOut`, `fee`, `tokensSold`, `ethReserve` |
| `FeeAccrued` | `launch*`, `creatorCut`, `protocolCut`, `protectionCut` |
| `Donated` | `launch*`, `donor*`, `amount`, `ethReserve` |
| `CapReached` | `launch*`, `ethReserve`, `timestamp` |
| `Graduated` | `launch*`, `poolId*`, `positionIdCore`, `positionIdFloor`, `ethToCore`, `ethToFloor`, `tokensToCore`, `bounty`, `caller*` |
| `GraduationStalled` | `launch*`, `caller*` |
| `Expired` | `launch*`, `bondForfeited`, `creatorFeesForfeited`, `protectionForfeited`, `ethReserve` |
| `BondStateChanged` | `launch*`, `creator*`, `oldState`, `newState`, `amount`, `destination` |
| `FeesClaimed` | `launch*`, `recipient*`, `kind`, `amount` |
| `VestingStarted` | `launch*`, `creator*`, `allocation`, `start`, `cliff`, `duration` |
| `VestingReleased` | `launch*`, `creator*`, `amount`, `cumulative` |
| `VestingVoided` | `launch*`, `creator*`, `allocation` |
| `PositionLocked` | `positionId*`, `launch*`, `kind` |
| `ReputationUpdated` | `creator*`, `counter`, `newValue` |
| `LaunchesPausedSet` | `paused` |
| `FeeConfigSet` | `totalFeeBps`, `creatorShareBps`, `protocolShareBps`, `protectionShareBps`, `pledgedCreatorShareBps`, `pledgedProtocolShareBps`, `pledgedProtectionShareBps` |
| `TreasurySet` | `treasury*` |

---

## 17. Invariants

Numbered, individually testable assertions. Every one must have a test that
fails if it is violated. The three marked **mandatory** are the core of the
invariant suite.

### Curve solvency

1. **Mandatory.** For every launch in every state,
   `(vE0 + ethReserve) * (vT0 - tokensSold) >= vE0 * vT0`.
2. **Mandatory.** For every launch and every `dT` in `[1, tokensSold]`, the gross
   ETH the sell formula yields for `dT` is at most `ethReserve`. The curve can
   never become insolvent against any sell, including a single seller selling
   every token ever sold.
3. For every launch before graduation,
   `address(curve).balance >= ethReserve + protectionEth + creatorFeeEth + protocolFeeEth + bondHeldWei + pendingBountyWei + pendingBondWei`.
4. `ethReserve` decreases only in `sell` (by `gross`) and in
   `graduate`/`graduateAlt` (to zero). No other code path reduces it.
5. `token.balanceOf(curve) == TOTAL_SUPPLY - tokensSold` for every launch before
   graduation.
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
13. At `tokensSold == CURVE_SUPPLY`, `ethReserve >= 8 * vE0`. (Implied by 1; it
    is asserted separately because graduation depends on it.)

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
18. The sum of all ETH ever paid out of a launch's three fee buckets, plus their
    current balances, equals the sum of all `fee` values ever charged by that
    launch.
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
    `start` is writable exactly once, by that launch's curve.
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
31. `tokensSold` never changes once `state` leaves `Live`.
32. `buy` reverts unless `state == Live && block.timestamp < gradDeadline`.
33. `sell` succeeds in `Live`, `Expired` and `Stalled` and reverts in
    `Graduating` and `Graduated`.
34. `Expired` requires `block.timestamp >= gradDeadline && tokensSold < CURVE_SUPPLY`;
    `Graduating` requires `tokensSold == CURVE_SUPPLY && block.timestamp < gradDeadline`.
35. Exactly one of `Graduated`, `Expired` or `Stalled` is reachable from any
    `Live` launch, and every `Live` launch reaches one of them given the passage
    of time and at least one external call.
36. `graduate` and `graduateAlt` together succeed at most once per launch.
37. `graduateAlt` reverts before `capReachedAt + ALT_DELAY`;
    `abortGraduation` reverts before `capReachedAt + GRAD_GRACE`.
38. `graduateAlt` accepts only `tickSpacing` in
    `[ALT_TICK_SPACING_MIN, ALT_TICK_SPACING_MAX]` and only a pool that is not
    yet initialised.

### Graduation and liquidity

39. The core position consumes exactly `LP_SUPPLY` base units of the token and at
    most `8 * vE0` wei.
40. The pool's `sqrtPriceX96` equals `sqrtPriceTerminal` immediately before the
    core position is minted.
41. Any price-restoring swap performed by `graduate` has zero net currency0 and
    zero net currency1 delta. The curve never spends ETH or tokens on a swap.
42. The floor position, when minted, has
    `tickUpper < alignDown(currentTick, tickSpacing)` and is funded in
    `currency0` only.
43. After graduation, `ethReserve == 0` and the curve's remaining ETH balance is
    at most `MIN_FLOOR_WEI` plus the unclaimed fee, bounty and bond buckets.
44. The graduation bounty is at most `protocolFeeEth` at the time of graduation,
    and is never drawn from `ethReserve`, `protectionEth`, `creatorFeeEth` or
    `bondWei`.
45. `graduate` and `graduateAlt` make no ETH transfer to any address other than
    PoolManager and PositionManager. The bond and the bounty are credited, not
    pushed.
46. Every position NFT minted by graduation is owned by `LiquidityLock`
    immediately after the transaction, and `LiquidityLock` contains no code path
    that calls `transferFrom`, `safeTransferFrom`, `approve`, `setApprovalForAll`
    or any liquidity-decreasing or position-burning PositionManager action.
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
54. No contract in the system has a `selfdestruct`, a `delegatecall` to a
    non-constant target, a proxy, or an initialiser callable more than once.

### Reentrancy and call discipline

55. Every external function that moves ETH or tokens holds a reentrancy guard,
    and within each such function no storage write follows an external call.
56. `unlockCallback` on the curve reverts unless `msg.sender` is PoolManager and
    the curve is inside its own `unlock`.
57. `onERC721Received` on `LiquidityLock` reverts unless `msg.sender` is
    PositionManager.
58. A recipient that reverts on receiving ETH can block only its own claim, and
    can block no other party's claim, no trade, and no state transition.

---

## 18. Out of scope for this specification

- The indexer, the frontend and any off-chain scoring derived from section 13.
- Post-graduation routing and quoting, which use ordinary v4 tooling.
- Token metadata hosting. The protocol emits an opaque `metadata` blob in
  `LaunchMetadata` and interprets none of it.
- Any mechanism that would require an oracle, an admin decision, or off-chain
  judgement. Candidates are listed and rejected in section 11.5.
