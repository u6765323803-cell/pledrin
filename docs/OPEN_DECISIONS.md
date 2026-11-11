# Pledrin — open decisions

Genuinely unresolved questions only. Anything that `docs/SPEC.md` decides is not
here, including choices that were contested: the graduation venue (Uniswap v4),
the 90/10 supply split, the virtual-reserve CPMM, the absence of a free creator
carve-out, and the holder-protection pool buying locked depth instead of paying
holders pro rata. Those are settled with their reasoning in the spec.

Each entry states the question, the options, the trade-offs, a recommendation,
and whether it blocks Phase 1 (the Solidity implementation).

---

## 1. Trading fees accruing to the permanently locked positions

**Blocks Phase 1.**

### Question

A locked Uniswap v4 position earns swap fees forever. `LiquidityLock` as
specified has no path to collect them, so they accrue inside PoolManager and are
never realised by anyone. Should the lock ship with a collect-and-recompound
path, and if so, from day one?

This cannot be deferred. `LiquidityLock` is not upgradeable and holds the
position forever. A compounding path added later would require a new lock, and
moving a position to a new lock requires a transfer path, which is exactly the
thing the lock must not have.

### Options

**A. No collection, ever.** The lock holds the NFT and has no outbound call of
any kind. Strongest possible claim and the smallest possible contract. Cost: the
fees are permanently stranded. Over a long-lived pool this is the larger share of
the position's economic value.

**B. Permissionless compound-only.** One function, callable by anyone, that in a
single `modifyLiquidities` call collects the accrued fees and increases liquidity
on the same `tokenId`, with any ratio residual left in the lock and re-used on the
next call. The lock still has no transfer, decrease or burn path, and no address
can receive value from it. Cost: real contract surface — the lock now encodes v4
action sequences, holds transient balances within a transaction, and holds a
permanent residual it cannot spend. Each of those is a line of attack that option
A does not have.

**C. Collect to a fixed, non-configurable address.** Rejected. It gives the
locked position a payee, which contradicts the claim that nothing ever leaves it,
and it makes that address a target.

### Trade-offs

A is auditable in one sitting and is impossible to get wrong. B is worth real
money over the life of a successful token and keeps every wei inside the lock,
but the compounding logic is the only non-trivial code in a contract whose entire
value is being trivially correct. A bug in B could lock the position in a state
where even compounding reverts, which is harmless, or — in the worst case — could
mis-encode a v4 action and decrease liquidity, which is not.

### Recommendation

**B, with the compounding path written and reviewed as if it were the riskiest
code in the repository**, because the stranded value in A is large and permanent
and the claim "fees stay in the position" is strictly stronger than "fees are
stranded". Conditional on the Phase 1 fork test demonstrating that collect plus
increase on the same `tokenId` can be expressed as one `modifyLiquidities` call
with no intermediate recipient. If that is not achievable, fall back to A rather
than building a two-step version that holds funds across calls.

---

## 2. Fallback if the free v4 price reset is not achievable

**Blocks Phase 1.**

### Question

Section 8.2 of the spec requires `graduate()` to restore a manipulated
zero-liquidity pool to `sqrtPriceTerminal` with a swap whose net deltas in both
currencies are zero, and to revert otherwise. The design assumes v4 permits such
a swap. This must be confirmed by fork test against
`0x8366a39cc670b4001a1121b8f6a443a643e40951`. If it reverts, or if it cannot be
made to produce exactly zero deltas, the specified anti-grief path does not work
and section 8.4 needs a different primary answer.

### Options

**A. As specified.** Free reset on the primary key; `graduateAlt` with a
caller-chosen tick spacing as the escape; `abortGraduation` after seven days as
the last resort. Depends on the zero-delta reset working.

**B. Skip the reset; go straight to an unused key.** If `slot0` is not at
`sqrtPriceTerminal`, `graduate()` reverts immediately and the launch graduates via
`graduateAlt` on a fresh spacing, which is initialised at the right price by
definition. Removes the reset entirely and removes the swap code from the curve.
Cost: a one-hour `ALT_DELAY` becomes the common path whenever anyone pays gas to
nudge the price, and the canonical pool ends up on a non-standard tick spacing,
which fragments routing and frontend expectations.

**C. Bounded reset budget.** Permit the reset to consume up to a fixed small
amount of ETH, e.g. `R_target / 1000`. Makes the reset robust to small amounts of
hostile liquidity. Cost: it breaks the clean statement that curve reserves fund
only sells and the core position, and the budget becomes a number an attacker
optimises against.

**D. Tolerance band.** Accept any `slot0` within a few ticks of
`sqrtPriceTerminal` and mint at that price. Cost: it reintroduces the opening-price
gap that section 5.3 was designed to eliminate, and the band is a parameter an
attacker will sit exactly at the edge of.

### Trade-offs

A is best if the reset works, because it keeps the canonical pool on the standard
spacing in every case. B is strictly simpler and strictly more robust but makes
the common case worse. C and D both trade away a property the spec currently
states cleanly.

### Recommendation

**A, with B as the committed fallback**, decided by a fork test that must be the
first thing Phase 1 writes: initialise a pool with zero liquidity, move its price
with a swap, and attempt to restore it with a zero-amount limit swap, asserting
the deltas. If the reset works, ship A. If it does not, ship B and drop
`ALT_DELAY` to zero so the alternate key is available immediately. Do not ship C
or D.

---

## 3. Who holds the timelock's proposer role

Blocks mainnet deployment, not Phase 1.

### Question

`Timelock` has three powers (pause new launches, change future-launch defaults,
change the future treasury) and a 48-hour delay. Who may propose?

### Options

**A. A single EOA.** Simplest. A compromised key can, after 48 hours, pause new
launches and set hostile-but-bounded defaults for launches created afterwards. It
cannot touch any existing launch or any user's funds (spec Invariant 52).

**B. A multisig.** Removes the single key. Requires signer selection, a
deployment, and a documented recovery path for lost signers.

**C. No owner at all.** Deploy the factory with the owner set to the zero address
and no pause. Maximal credible neutrality. Cost: no ability to stop new launches
if a defect in `createLaunch` is found, and no way to correct a bad default.

### Trade-offs

The powers are deliberately small, so the blast radius of A is small — but it is
not zero, and "the launchpad's config key is one EOA" is a reasonable thing for a
user to decline. C is defensible precisely because the powers are so narrow, and
it makes section 8 of the threat model trivial.

### Recommendation

**B** for mainnet, with the signer set published before the first launch and the
timelock's address in the deployment record. A single EOA is acceptable on
testnet. Revisit C once `createLaunch` has been audited: if the pause is never
used in the first months, giving it up is a real improvement to the trust story.

---

## 4. Testnet faucet

Blocks testnet verification of Phase 1, not the Phase 1 code.

### Question

`docs/CHAIN_FACTS.md` lists the testnet faucet endpoint as unknown. Fork tests
against testnet 46630 need funded accounts, and the Phase 1 bar includes an
end-to-end graduation against the real Uniswap v4 contracts.

### Options

**A. Find and record the official faucet** in `docs/CHAIN_FACTS.md`, verified by
actually receiving testnet ETH.

**B. Run graduation fork tests only, with `forge` cheatcodes supplying balances.**
Exercises the real v4 contracts at a real block without needing funds. Does not
exercise a real transaction submitted through the real sequencer.

### Trade-offs

B covers almost everything that matters: the v4 contracts are the dependency, and
a fork test at a pinned block is reproducible in CI, which a faucet-funded live
test is not. What B misses is sequencer behaviour, real gas and real
`block.timestamp` progression.

### Recommendation

**B for CI, A additionally before mainnet.** Do not block Phase 1 on the faucet.
Record the faucet in `docs/CHAIN_FACTS.md` when it is verified, and run one
live testnet launch-to-graduation before mainnet.

---

## 5. Per-launch curve deployment mechanism

Does not block Phase 1.

### Question

Each launch gets its own `BondingCurve` (spec section 2). Full contract
deployment, or a minimal clone with immutable args?

### Options

**A. Full deploy per launch.** Simple, no proxy, immutables are real immutables,
nothing to get wrong. Costs the full contract's deployment gas on every launch.

**B. Clone with immutable args.** One implementation, per-launch parameters
appended to the clone's code and read by offset. Much cheaper per launch. Costs:
the pattern is a form of delegation, the argument offsets are hand-maintained,
and a mistake reads the wrong parameter rather than failing loudly.

### Trade-offs

Deployment gas is paid once per launch and on this chain is dominated by the L1
data cost of the launch transaction's calldata, not by the code size, which
narrows B's advantage relative to a Layer 1. Against that, launches are the
protocol's highest-frequency write and a creator pays for it.

### Recommendation

**A for Phase 1.** Measure `createLaunch` gas with `forge test --gas-report`,
then decide. B is a localised optimisation that can be made later without
changing any interface or any invariant, so there is no reason to take its risk
before the numbers justify it.

---

## 6. Pool fee tier and tick spacing

Does not block Phase 1. A default must still be chosen, and the spec chooses
`fee = 10000`, `tickSpacing = 200`.

### Question

Should the graduated pool be 1% / 200, or 0.3% / 60, or creator-selectable?

### Options

**A. 1% / 200 (specified).** Matches memecoin convention, pays the locked
position more per unit of volume, and coarse ticks keep the floor position's
boundary arithmetic simple.

**B. 0.3% / 60.** Cheaper for traders, which attracts more volume, and finer
ticks make the floor position's range more precise. Pays the locked position
less per trade.

**C. Creator-selectable at launch.** Flexible. Cost: it fragments routing across
tiers, it is one more parameter a creator can set badly, and it adds calldata to
`createLaunch`.

### Trade-offs

All post-graduation fees accrue to a locked position, so a higher tier is not
protocol revenue — it is permanent depth, which argues for A. Against that, a 1%
tier is a real cost to traders and may lose volume to a competing pool someone
else opens on a cheaper tier, which would fragment the token's liquidity away from
the locked position.

### Recommendation

**A.** Reject C: a per-launch tier helps nobody and fragments liquidity. Revisit
A versus B once there is observed volume on graduated pools; the change affects
only `createLaunch` and `graduate` and does not touch any invariant.

---

## 7. Floor position range width

Does not block Phase 1.

### Question

The floor position spans `FLOOR_RANGE_TICKS = 13800` ticks below spot, a price
factor of 3.97. Is that the right width?

### Options

**A. 13800 ticks (about 4x, specified).** Concentrates the protection pool across
a 75% drawdown.

**B. Full range to the minimum tick.** Catches any decline, however deep.
Spreads the same ETH so thinly that it provides almost no support in the band
where most of the selling happens.

**C. Narrow, e.g. 6900 ticks (about 2x).** Twice the depth per tick immediately
below spot, where early sellers actually trade. Provides nothing below a 50%
decline.

### Trade-offs

The pool's size relative to the core position decides how much this matters. At
the default parameters the protection pool is roughly 0.3% of the raise at
graduation — small. Its concentration is therefore more important than its reach,
which argues toward C. Against that, the deeper the decline the more a holder
needs the bid to still be there, and a bid that stops at 50% is absent exactly
when it is most wanted.

### Recommendation

**A.** It is the compromise and nothing in the available data distinguishes
between these three. Revisit with real post-graduation price data. The value is a
single constant and changing it affects no interface and no invariant.

---

## 8. Should buys be permitted in `Expired`

Does not block Phase 1.

### Question

The spec closes buys permanently on expiry and leaves sells open forever. Should
buys stay open instead?

### Options

**A. Buys closed (specified).** No new buyer is onboarded into a launch that has
already failed. The unsold tokens are permanently immobilised in the curve, which
is a de facto supply reduction with no burn. Cost: the price in an expired curve
can only fall, so the last seller out gets the least, and nobody can arbitrage
that.

**B. Buys open.** Price discovery continues and a buyer who believes the token is
oversold can support it, which helps the remaining holders. Costs: it requires
deciding what happens if `tokensSold` reaches the cap after expiry — either
graduation from a terminal state, which contradicts `Expired` being terminal, or
a buy that reverts at the cap, which is a confusing dead end. It also onboards
new buyers into a launch the protocol has already declared failed.

### Trade-offs

B is better for the holders who are already in and worse for anyone who buys
afterwards. A is honest about the launch being over and keeps the state machine
total, which is what makes spec Invariant 35 provable.

### Recommendation

**A.** A failed launch should wind down, not reopen. The state machine's totality
is worth more than the marginal price support, and "buy into a launch that has
officially failed" is not a product surface worth building.

---

## 9. Should the creator's accrued fee share vest after graduation

Does not block Phase 1.

### Question

The spec makes the creator's accrued fee share claimable in full at graduation.
Should it release linearly instead, as the token allocation does?

### Options

**A. Claimable in full at graduation (specified).** Simple. The constraint that
does the work is that nothing is claimable *before* graduation.

**B. Linear release over 30 to 90 days after graduation.** Gives the creator a
reason to still be present a month later. Costs: it is withholding money the
creator has already earned from trades that already happened, it adds a second
vesting schedule, and it is trivially routed around — a creator who intends to
leave will simply leave and claim later.

### Trade-offs

B looks like alignment but buys very little: the amount is small (0.3% of the
raise at default parameters), the creator's real incentive is their vested token
allocation, which already runs 180 days, and B penalises an honest creator's cash
flow to deter a dishonest one who is not deterred.

### Recommendation

**A.** Put the time-locking on the tokens, where the rug risk actually is, not on
the fees.

---

## 10. Should `virtualEthReserve` be creator-chosen or a global constant

Does not block Phase 1.

### Question

`virtualEthReserve` is the curve's only free parameter and sets the raise target
from 0.1 to 1000 ETH. Should creators pick it, or should every launch raise the
same amount?

### Options

**A. Creator-chosen within bounds (specified).** A small project and a large one
can both use the protocol. The parameter scales the curve linearly in ETH and
changes no token-side geometry, so every launch still has the same shape and the
same 81-fold price range.

**B. One global constant.** Every launch is directly comparable, there is no
parameter to set badly, and `createLaunch` calldata shrinks. Cost: the single
value is wrong for most launches, and a target set too high means nothing
graduates.

### Trade-offs

B's uniformity is a real product benefit — comparable launches are easier to
reason about and harder to game with a deliberately trivial target. A's
flexibility is a real market benefit. The risk specific to A is a creator setting
`R_target` to the 0.1 ETH floor so that graduation is nearly free, which is
covered as self-funded graduation in threat model section 10.2.

### Recommendation

**A, with the bounds narrowed** once there is data on which targets actually
graduate. Consider raising the floor above 0.1 ETH: a target that cheap makes the
Pledged badge nearly meaningless, because the minimum bond is 10% of the target
and 0.01 ETH is not a bond. A floor around 1 ETH of target raise would be
defensible. This is a one-constant change.

---

## 11. The bond on `abortGraduation`

Does not block Phase 1.

### Question

`abortGraduation()` moves a launch stuck in `Graduating` for seven days to
`Stalled` and **returns** the bond to the creator. Should it forfeit it instead?

### Options

**A. Return (specified).** The creator met the only condition the bond encodes:
the cap was reached before the deadline. A third party's grief must not cost them.

**B. Forfeit.** Holders are left without a Uniswap pool, which is a worse outcome
than they were promised, so the bond should compensate them.

### Trade-offs

B punishes an honest creator for someone else's grief, and it creates an attack:
a griefer can destroy a creator's bond for the cost of blocking the pool for a
week. A creates the opposite concern — a creator griefing their own graduation to
reach `Stalled` — but the spec shows that gains them nothing, since they receive
exactly what `graduate()` would have given them, pay for the grief, and lose the
locked pool.

An option C would be to return the bond but not increment `graduations`, which is
what the spec already does by counting `stalls` separately.

### Recommendation

**A.** The asymmetry matters: under B a griefer with a week of gas money can
destroy an arbitrary creator's bond, which is a far worse property than the
hypothetical self-grief that A permits and that gains nobody anything.

---

## Verification prerequisites for Phase 1

Not decisions. These are v4 behaviours the spec assumes and that must be
confirmed by fork test against the addresses in `docs/CHAIN_FACTS.md` before the
corresponding part of the spec is treated as final. Each names the decision or
spec section it resolves.

| Assumption | Resolves |
|---|---|
| A zero-liquidity pool's price can be restored with a swap whose net deltas in both currencies are zero. | Decision 2; spec 8.2, Invariant 41 |
| `collect` and `increaseLiquidity` on the same `tokenId` can be expressed as one `modifyLiquidities` call with no intermediate recipient. | Decision 1 |
| A single-sided native-ETH position with `tickUpper` strictly below the current tick can be minted through PositionManager, funded in `currency0` only. | Spec 8.2 step 6, section 10.1, Invariant 42 |
| Minting with an exact `currency1` amount and a bounded `currency0` amount consumes exactly `LP_SUPPLY` and at most `R_target`, and the residual is recoverable to the curve. | Spec 8.2 step 4, Invariant 39 |
| The token approval path for PositionManager requires `token.approve(PERMIT2, ...)` followed by `PERMIT2.approve(token, POSITION_MANAGER, ...)`, and nothing else. | Spec 8.2 step 3 |
| `PoolManager.initialize` with `hooks = address(0)` succeeds and leaves the pool with zero liquidity. | Spec 8.1 |

### Addresses that belong in `docs/CHAIN_FACTS.md`

Two values were read from the chain while writing this specification and are
referenced, without their literals, in `docs/THREAT_MODEL.md` section 9. No
address may appear outside `docs/CHAIN_FACTS.md`, and the architect does not own
that file, so they are requested here rather than written there:

- `PoolManager.protocolFeeController()` on mainnet 4663 and on testnet 46630.
  The mainnet value is a non-zero address; the testnet value is the zero
  address. Whoever owns `docs/CHAIN_FACTS.md` should add both with the `cast`
  command used.
- `PoolManager.owner()` on mainnet 4663 and on testnet 46630. The two values
  differ and both are non-zero.

Neither address is referenced by any Pledrin contract. They are recorded only so
that the external governance exposure in `docs/THREAT_MODEL.md` section 9 is
auditable against a named source.
