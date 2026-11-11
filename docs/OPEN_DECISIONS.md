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

**RESOLVED 2026-11-11 by the founder: permissionless compound-only.
CONFIRMED BY FORK TEST 2026-11-11: the condition below is met, the fallback is
not needed, and the implementation facts are recorded at the end of this
entry.**

`LiquidityLock` gets a single permissionless function that collects the
position's accrued fees and reinvests them into that same position. No
recipient parameter, no withdrawal path, no transfer path. Every wei stays
inside the lock and the position can only grow.

This was conditional on the fork test named in the appendix proving that
collect and increase execute as one `modifyLiquidities` call with no
intermediate recipient. They do, in two different encodings, so the fallback —
**no collection at all**, never a two-step version that holds funds between
calls — is not taken. Which encoding ships is decision 12.

Because the lock is not upgradeable, this function must be written and
reviewed as the riskiest code in the repository: it is the only code with a
reason to touch a position that must otherwise never move.

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
on the same `tokenId`, with any ratio residual left in the lock, where it
accumulates permanently and is never reinvested (fact 3 below; the phrase
"re-used on the next call" that stood here was wrong). The lock still has no
transfer path, no burn path and no liquidity-decreasing path — subject to the one
qualification in decision 12 — and no address can receive value from it. Cost: real contract surface — the lock now encodes v4
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
than building a two-step version that holds funds across calls. That test has
since been run: the condition is met, so the conditional is discharged and the
facts below replace it.

### Implementation facts measured on the fork

Measured 2026-11-11 against the deployed PoolManager and PositionManager on
chain 4663. These are the facts the lock's author needs and must not re-derive
from memory.

1. **Collect and increase are one call.** `INCREASE_LIQUIDITY` with a non-zero
   liquidity issues a single `PoolManager.modifyLiquidity`, and its returned
   delta already nets the collected fees against the cost of the new liquidity;
   two `CLOSE_CURRENCY` actions then settle both sides. No recipient parameter
   names any address at any point: `CLOSE_CURRENCY` pays to `msgSender()`, which
   for a call the lock makes is the lock, which is also the position's owner.
2. **The one call collects every wei.** The position's accrued fees are zero in
   both currencies immediately afterwards, so nothing is left in PoolManager for
   a later caller to find or race for.
3. **The ratio residual is retained, not reinvested.** Both
   `INCREASE_LIQUIDITY_FROM_DELTAS` and `CLOSE_CURRENCY` work off the
   PoolManager delta of the current call, not off the lock's own balance, so a
   residual left by an earlier compounding is invisible to a later one. It
   accumulates in the lock. Folding it back in would require the lock to forward
   ETH as `msg.value` and to hold a Permit2 approval for its own token, which is
   exactly the lock surface this decision is trying not to add. Compounding is
   nonetheless repeatable: a second round after further trading grew the position
   again and left the first round's residual untouched.
4. **No third party can collect or redirect the fees.** `PositionManager` reverts
   `NotApproved` when a non-owner submits a collect for the locked `tokenId`, and
   the only recipient the compounding encoding can name is the lock itself.

---

## 2. Fallback if the free v4 price reset is not achievable

**RESOLVED 2026-11-11 by the tech lead: ship as specified if the fork test
passes, otherwise the committed fallback. CONFIRMED BY FORK TEST 2026-11-11: the
zero-net-delta reset holds in both directions and at any nominal size, so the
specification ships and the fallback is not taken. The one wording change the
test forced — a swap of literally zero is not executable — is recorded in the
appendix and corrected in spec 8.2 step 2.**

The first fork test Phase 1 writes answers this. If a zero-net-delta swap
restores the price of a zero-liquidity v4 pool, the specification ships
unchanged. If it does not, the committed fallback ships: `graduate()` reverts
immediately on a wrong pool price, graduation proceeds through
`graduateAlt`, and `ALT_DELAY` drops to zero.

Explicitly not on the table: a bounded reset budget, or a tolerance band
around the terminal price. Both trade away properties the specification
currently states cleanly, and neither is worth the trade.

### Question

Section 8.2 of the spec requires `graduate()` to restore a manipulated
zero-liquidity pool to `sqrtPriceTerminal` with a swap whose net deltas in both
currencies are zero, and to revert otherwise. The design assumes v4 permits such
a swap. This must be confirmed by fork test against
`0x8366a39CC670B4001A1121B8F6A443A643e40951`. If it reverts, or if it cannot be
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

The floor position spans `FLOOR_RANGE_TICKS = 13800` ticks below spot in price
terms — which per spec 8.1 and 10.1 is the tick range *above* the current tick,
because `currency0` is ETH — a price factor of 3.97. Is that the right width?

### Options

**A. 13800 ticks (about 4x, specified).** Concentrates the protection pool across
a 75% drawdown.

**B. Full range to the deepest price, that is to the aligned maximum tick.**
Catches any decline, however deep.
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

## 12. Which v4 action pair the lock's compounding path uses

Does not block Phase 1. This is for the contracts engineer; decision 1 has
already settled *that* the lock compounds, and the fork test has shown both
candidate encodings work as one `modifyLiquidities` call with no intermediate
recipient.

### Question

Which action sequence does `LiquidityLock`'s single permissionless function
encode?

### Options

**A. `INCREASE_LIQUIDITY` + `CLOSE_CURRENCY` + `CLOSE_CURRENCY`.** The caller
passes the liquidity to add. One `PoolManager.modifyLiquidity` whose delta
already nets the collected fees against the cost of the new liquidity; the two
`CLOSE_CURRENCY` actions route the residual back to `msgSender()`, the lock
itself. The lock's bytecode then contains no liquidity-decreasing action id at
all, so Invariant 46 holds in its strongest literal form.

**B. `DECREASE_LIQUIDITY`(liquidity 0) + `INCREASE_LIQUIDITY_FROM_DELTAS` +
`CLOSE_CURRENCY` + `CLOSE_CURRENCY`.** A decrease of zero liquidity credits the
accrued fees, and `INCREASE_LIQUIDITY_FROM_DELTAS` with `type(uint128).max` for
both amounts spends exactly that credit. The caller passes no amount of any kind.

### Trade-offs

A takes a caller-supplied number into the riskiest function in the repository. An
overstated number cannot make the lock pay out of its retained residual — the
lock forwards no `msg.value` and holds no Permit2 approval for its own token, so
the settle leg reverts — but an understated one is a permanent griefing vector:
anyone may call with a liquidity of 1, which collects the entire accrued fee and
compounds almost none of it, pushing the rest into the residual that nobody,
including the lock, can ever spend. That destroys value rather than stealing it,
and the fees so diverted can never be collected again. Repeated cheaply after
every accrual, it reduces option B of decision 1 to option A of decision 1 at an
attacker's choice.

B removes the parameter and with it that grief: the amount is the position's own
fee delta and nothing else. The cost is that the lock's action list contains
`DECREASE_LIQUIDITY`, with a hard-coded zero. Nothing can make that zero
non-zero — it is a literal in the encoding, not an argument — but an auditor must
verify a constant rather than observe an absence, and Invariant 46's literal form
becomes "no liquidity-decreasing action with a non-zero liquidity argument".

### Recommendation

**B.** Removing the only caller-controlled input from the only function that ever
touches a position that must otherwise never move is worth more than the stronger
reading of Invariant 46, and the grief A permits is cheap, repeatable and
irreversible. `docs/SPEC.md` Invariant 46 already carries the qualified wording
conditioned on this choice, so picking B needs no further spec change and picking
A lets the qualification be deleted. A third variant — A, but with the lock
computing the liquidity on-chain from the position's own fee growth instead of
accepting it as an argument — closes the grief as well, and is rejected because
it puts more arithmetic in the lock than B's hard-coded zero does.

---

## Verification prerequisites for Phase 1

Not decisions. These were v4 behaviours the spec assumed. All six were tested on
2026-11-11 by `contracts/test/fork/V4Assumptions.t.sol` against the addresses in
`docs/CHAIN_FACTS.md`. Four held, two were refuted, and `docs/SPEC.md` and
`docs/THREAT_MODEL.md` have been corrected accordingly. Each row below states the
assumption in its **corrected** form, the part of the spec it resolves, and the
result.

| Assumption | Resolves | Result |
|---|---|---|
| A zero-liquidity pool's price can be restored with a swap whose net deltas in both currencies are zero, for any non-zero nominal `amountSpecified`. | Decision 2; spec 8.2, Invariant 41 | Holds, in both directions and at sizes from 1 to `1e18`. The *phrasing* "zero-input swap" was refuted: `amountSpecified == 0` reverts `SwapAmountCannotBeZero()`, and a limit equal to the current price reverts `PriceLimitAlreadyExceeded`, so spec 8.2 step 2 now nominates one unit of input, keeps its `if` guard and picks direction by comparison. Restoration stops being free as soon as anyone adds liquidity, which is the mitigation threat model 4.3 claims. |
| `collect` and `increaseLiquidity` on the same `tokenId` can be expressed as one `modifyLiquidities` call with no intermediate recipient. | Decision 1 | Holds, in two encodings. See decision 1's implementation facts and decision 12. |
| A single-sided native-ETH position with `tickLower` strictly **above** the current tick can be minted through PositionManager, funded in `currency0` only. | Spec 8.2 step 6, section 10.1, Invariant 42 | **Refuted as originally written.** The original read "`tickUpper` strictly below the current tick", which v4 funds in `currency1`: as specified, the holder-protection pool would have minted a token-funded sell wall instead of a standing ETH bid. The corrected direction holds and is now specified. |
| Minting with a bounded `currency1` amount and a bounded `currency0` amount consumes at most `LP_SUPPLY` with a remainder under `LP_DUST_MAX`, at most `R_target`, and the ETH residual is recoverable to the curve. | Spec 8.2 step 4, Invariant 39 | **Half refuted.** "At most `R_target`" holds and `R_target` is the exact bound; ETH headroom is not monotone in `virtualEthReserve`, so `amount0Max` must be `R_target`. "Exactly `LP_SUPPLY`" is unachievable: `MINT_POSITION` is parameterised by liquidity and the `currency1` owed is a step function of it, leaving an irreducible 28,428 / 1,088 / 240 base units across the permitted range. The ETH residual is recoverable; the token remainder is stranded in the curve. |
| The token approval path for PositionManager requires `token.approve(PERMIT2, ...)` followed by `PERMIT2.approve(token, POSITION_MANAGER, ...)`, and nothing else. | Spec 8.2 step 3 | Holds, and both legs are necessary. A direct `token.approve(POSITION_MANAGER, ...)` is not the path; either leg alone fails, on `AllowanceExpired` or inside the ERC-20 transfer. |
| `PoolManager.initialize` with `hooks = address(0)` succeeds and leaves the pool with zero liquidity. | Spec 8.1 | Holds. `sqrtPriceTerminal` is exactly `5000 * 2**96` at the default and ticks 170352, 115135 and 207243 were reproduced; a second `initialize` on the same key reverts `PoolAlreadyInitialized`, which is what makes initialising at launch an anti-grief measure. |

Two further measured facts, neither among the six, for whoever writes the
graduation path and the lock:

- `Pool.swap` can leave `slot0.tick` one tick below
  `TickMath.getTickAtSqrtPrice(slot0.sqrtPriceX96)` when a `zeroForOne` swap ends
  exactly on an initialised tick boundary. The floor range's `currentTick` must
  therefore be read from `slot0.tick` and never derived from the price. Now
  stated in spec 8.1 and asserted by Invariant 42.
- One wei of floor ETH mints non-zero liquidity over a 13800-tick range and the
  mint succeeds, so `MIN_FLOOR_WEI` is a de-minimis threshold and not a rounding
  guard. Spec 10.1's justification has been restated; the constant is kept.

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
