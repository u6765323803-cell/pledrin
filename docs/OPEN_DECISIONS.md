# Pledrin — open decisions

Genuinely unresolved questions only. Anything that `docs/SPEC.md` decides is not
here, including choices that were contested: the graduation venue (Uniswap v4),
the 90/10 supply split, the virtual-reserve CPMM, the absence of a free creator
carve-out, and the holder-protection pool buying locked depth instead of paying
holders pro rata. Those are settled with their reasoning in the spec.

Each entry states the question, the options, the trade-offs, a recommendation,
and whether it blocks Phase 1 (the Solidity implementation) or Phase 2 (the
Ponder indexer and the Next.js application). Entries 1 to 15 are Phase 1's;
entries 16 to 21 are Phase 2's and were raised by `docs/DATA_MODEL.md`; entries
22 and 23 are Phase 1's and were raised by the security review of 2026-11-11, and
entry 24 is Phase 2's.

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
calls — is not taken. Which encoding to use was decision 12, now resolved to
option B and implemented.

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

**Addendum, 2026-11-11: the bounded reset budget was re-raised and refused
again, on a stronger ground than the one recorded here.** The objection above is
that the budget becomes a number an attacker optimises against, which is true and
is not the worst of it. Every wei the curve would spend crossing hostile
liquidity is a wei the attacker collects as the liquidity provider on the other
side of that trade. A budget therefore does not convert the grief into a
quantified cost; it converts a grief with no payoff into a grief with a capped
payoff, while leaving the key blocked by any attacker who posts the liquidity that
requires the budget plus one wei to clear. Decision 22 records the argument in
full and takes a different route to the same goal: the restore is paid for by
whoever wants the graduation, out of their own funds, in a separate contract.

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

`Timelock` has four powers (pause new launches, change future-launch defaults,
change the future treasury, renounce the factory's ownership) and a 48-hour
delay. Who may propose?

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

Note added 2026-11-11, from the Phase 1 contracts: option C does not need a
different deployment. `LaunchFactory` keeps OpenZeppelin `Ownable`'s
`renounceOwnership`, so C can be taken after the fact by proposing and executing
that call through the timelock, which sets the owner to the zero address and
makes all three setters permanently uncallable. `transferOwnership` is overridden
to revert, so the only ownership move the factory permits is the one that reduces
power, and it is irreversible (`docs/SPEC.md` section 14).

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

**RESOLVED FOR PHASE 1 2026-11-11 by what was implemented: option A, a full
deployment per launch.** The cost was not the deployment gas the trade-off below
anticipated; it was EIP-170. `BondingCurve`'s creation code (22,678 bytes) plus
`LaunchFactory`'s own code does not fit in a 24,576-byte runtime, so the factory
cannot carry it. A factory that did measured 45,134 bytes at 1,000,000 optimizer
runs and 32,623 bytes at 200 runs with the IR pipeline, and one deployer carrying
both `BondingCurve`'s and `PledrinToken`'s creation code measured 25.0 KB.

What was implemented instead is two single-purpose deployers that carry creation
code and nothing else: `CurveDeployer` at 23,531 bytes, with **1,045 bytes of
margin**, and `TokenDeployer`. Both are stateless, ownerless and permissionless
and hold nothing. `docs/SPEC.md` sections 2.1 and 2.2 record the mechanism, the
deployment order and the consequences; `docs/THREAT_MODEL.md` section 8.2
records what a stranger can do with a permissionless deployer.

The margin is now a constraint on unrelated work: roughly a kilobyte of new
`BondingCurve` code makes `CurveDeployer` undeployable, at which point option B
below, or splitting the curve, stops being optional. Measure
`forge build --sizes` before adding to the curve, not after.

Did not block Phase 1.

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

### Addendum, 2026-11-11: the margin figures above are superseded

The sizes quoted in the resolution above were measured before the post-terminal
fee redirect of spec 6.3 landed. On the landed tree, read from the build
artifacts: `CurveDeployer` 23,952 bytes with **624 bytes of margin**,
`BondingCurve` 19,374, `LaunchFactory` 7,232, `TokenDeployer` 2,979, and
`BondingCurve`'s creation code 23,099 of the deployer's 23,952. All 421 bytes of
the margin lost are the redirect; the `transferOwnership` override and
`FeeAccrued`'s `reserveCut` field each made code smaller, and the `SafeCast`
binding change was byte-identical.

The constraint stated above therefore binds harder than it reads: fewer than 624
bytes of new `BondingCurve` code, not roughly a kilobyte, makes `CurveDeployer`
undeployable, at which point option B or splitting the curve stops being
optional. Spec 2.1 carries the current numbers and is the place to update; this
addendum exists so that the superseded ones are not read as current.

**Second addendum, later on 2026-11-11: 624 is now 527, across three changes and
not one.** `CurveDeployer` is 24,049 bytes and `BondingCurve`'s creation code
23,196 of them at commit `5b86188`. Of the 97 bytes lost since the figures above,
**69 are the security review's first finding** being fixed in `_mintCore`, and
the remaining **28 predate the review entirely**: `6421810` moved
`graduateAlt`'s delay check into `_settle` and saved 33, then `81b8d77` split
`claimBond` into four refusals and spent 61. Spec 2.1 carries the per-step ledger
and the margin at each step. Decision 22 adds to the curve as well and estimates
how much.

Two earlier revisions of this addendum got the attribution wrong in opposite
directions, and both are left visible because they are the evidence rather than
embarrassments. One recorded 448 free and charged 176 bytes to finding 1; it had
measured a variant of that fix that no longer exists, which computed the ETH cost
after the mint call rather than before it. The other recorded 527 correctly and
charged the whole 97 to finding 1, because 97 is what you get by subtracting this
document's own row from a current build.

**A size figure in a document is a measurement of a tree, not a property of the
design** — and the way the two numbers came to disagree is the proof of it rather
than an exception to it. The row above had been measured against a tree that
moved twice before anyone compared against it, so the difference anyone computed
from it was drift and not the cost of the change they were looking at. The cause
is procedural and spec 2.1 now states the rule it implies: a commit that changes
`BondingCurve` updates the size table in the same commit. The next change has to
be measured against the commit it lands on, and quoting a figure from a document
instead is how a contract becomes undeployable in CI rather than at review.

**Third addendum: 527 is now 886, and the budget this entry worries about is no
longer the binding one.** Decision 22's implementation took `CurveDeployer` to
23,690 bytes by removing a duplicated graduation body the compiler's inliner had
been producing, which is 359 bytes recovered by a change set that adds
functionality. Spec 2.1 has the measurement, the full ledger and the rule that
keeps it: `_settle` must not be given a literal-valued argument, because that is
what let the inliner duplicate the body. Option B and splitting the curve are
further off than they were this morning, and the reason is a compiler decision
rather than a design one — which is its own argument for measuring whole change
sets instead of reasoning about parts.

Nothing described in this entry has been deployed to any network.

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

**Addendum, 2026-11-11: A is unchanged for the canonical key and is no longer a
protocol-wide constant.** Decision 22 makes the `fee` field of the pool key a
range on the alternate graduation path, `[ALT_POOL_FEE_MIN, ALT_POOL_FEE_MAX] =
[3000, 10000]`, because the key space reachable at one fee tier is small enough to
be seized for gas. Every launch that graduates normally still graduates at
`POOL_FEE = 10000` and `POOL_TICK_SPACING = 200`, so this is not option C: the
tier is not creator-selectable, it is not a launch parameter, and it appears
nowhere in `createLaunch`. What changed is that a launch escaping a griefed key
may end up on a cheaper tier, never a dearer one, and `Graduated` now carries the
`fee` and `tickSpacing` it used so that the pool is identifiable from the log.

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

**RESOLVED 2026-11-11: option B implemented.** `LiquidityLock.compound` encodes
`DECREASE_LIQUIDITY` with a hard-coded zero liquidity, then
`INCREASE_LIQUIDITY_FROM_DELTAS` with `type(uint128).max` on both amounts, then
two `CLOSE_CURRENCY`. No caller-supplied number reaches the call. `docs/SPEC.md`
Invariant 46 has been flattened from a conditional into the unconditional
statement that option B implies, and spec section 9 records the encoding. The two
costs measured while implementing it are at the end of this entry; both are real
and neither changes the choice.

Does not block Phase 1. This was for the contracts engineer; decision 1 had
already settled *that* the lock compounds, and the fork test had shown both
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
irreversible. A third variant — A, but with the lock computing the liquidity
on-chain from the position's own fee growth instead of accepting it as an
argument — closes the grief as well, and is rejected because it puts more
arithmetic in the lock than B's hard-coded zero does.

### What option B cost, measured rather than assumed

**1. `INCREASE_LIQUIDITY_FROM_DELTAS` is marked deprecated in the vendored
v4-periphery.** The comment on the constant reads
`DEPRECATED: Vulnerable to sandwich attacks - do not use`, with the reason that
the delta-based path has no minimum-liquidity check, so an attacker who moves the
price can reduce the liquidity received. That warning is accurate and is accepted
here with its exposure stated exactly:

- The exposure is **value destruction, not theft.** There is no recipient
  parameter in the batch and the only address it can pay is the lock itself. An
  attacker who moves the pool price before the call makes the fee delta buy less
  liquidity and pushes the rest into the lock's retained residual, which nobody,
  including the lock, can ever spend. Nothing is transferred to the attacker.
- It is not cheap. Moving the price of a pool that holds the whole ETH target
  plus the floor position means paying the pool's 1% fee on a notional large
  enough to move it, twice, in and out — and paying it **into the very position
  being griefed**, where it is locked forever and is itself compoundable.
- Option A's grief costs only gas: anyone may call with a liquidity of 1 and
  divert the whole accrued fee into the unspendable residual. A grief that costs
  gas and one that costs two legs of a 1% fee on a position-sized notional are
  not comparable, which is why B remains the better choice after the deprecation
  was found rather than in spite of it.

**2. With one-sided fee accrual, nothing compounds — and that is now a revert.**
The liquidity a pair of amounts buys is the minimum over both sides, so a
position whose fees accrued in one currency only computes zero liquidity from its
delta. `compound` therefore reverts `NothingToCompound` rather than letting the
two `CLOSE_CURRENCY` actions credit those fees out of the position and into the
residual, where they could never be recovered. The fees stay accrued inside the
pool until the other side accumulates, and a later call compounds both. A second
guard, `LiquidityNotIncreased`, reverts if the position's liquidity fell at all.

Both guards are load-bearing. Without the first, ordinary one-sided accrual would
quietly convert collected fees into permanently dead ETH on every call; without
the second, a mis-encoded batch would have no backstop. Neither may be relaxed to
make a test pass.

---

## 13. Fees charged on sells after a terminal transition

**RESOLVED 2026-11-11: option B, narrowed to the shares that have no payout
path.** A trade in `Expired` or `Stalled` still charges the same fee and still
splits it three ways with the same unchanged arithmetic; what changed is the
destination of two of the three shares.

| Share | `Expired` | `Stalled` | Why |
|---|---|---|---|
| creator | `ethReserve` | `creatorFeeEth` | `claimCreatorFees` requires `Graduated` or `Stalled`, so a share accrued in `Expired` could never be claimed. `Stalled` keeps the claim open, so nothing needs to move there. |
| protocol | `protocolFeeEth` | `protocolFeeEth` | `claimProtocolFees` has no state gate and always had a path. Unchanged. |
| holder protection | `ethReserve` | `ethReserve` | The bucket has no claim function at all; it is distributed only by a transition, and in a terminal state that transition has already happened. |

`docs/SPEC.md` section 6.3 is the specification and Invariant 59 the testable
form. Sections 5.5, 6.1, 6.2, 10.3 and 16.1 and Invariants 4 and 18 were adjusted
to match.

Why option B rather than this entry's own recommendation of A, and why narrowed:
the destination is `ethReserve` because holder protection exists for holders and
the reserve is the only thing holders sell against in a terminal state, which is
already the destination the protocol chooses for the protection balance standing
at the transition and for a forfeited bond. Only the two shares with no reachable
claim move, because redirecting the protocol share as well would give up a fee
the protocol is still earning on a market it is still providing — that was option
C's cost, and it was never the problem. The redirect only adds to `ethReserve`
without changing `tokensSold`, so it raises the solvency product and Invariant 1
is unaffected; `ethReserve` therefore falls by less than `ethGross` on a
post-terminal sell, which Invariant 4 now states.

Why it was fixed rather than documented. The project's rule is to be honest about
what cannot be prevented on-chain, not to be resigned about what can. Sybil
wallets, a creator buying their own launch through fresh addresses and
social-engineering rugs are limitations and are written down as limitations,
because no deterministic on-chain rule closes them. A fee share accruing into a
bucket with no claim function is not that: it is prevented by one branch in one
internal function, with no new external surface, no new admin power, no oracle
and no new trust assumption. The earlier recommendation of A rested entirely on
not disturbing the fee path while the invariant suite was being written against
it. That suite is now written: it asserts fee conservation as an inequality that
holds either way and states the exact equality only pre-terminality, so the
reason to defer has expired.

Two things the implementation had to carry, both now in the spec. `Sold` must
report the reserve **after** the redirect, or an indexer following `ethReserve`
through events drifts by the redirected amount on every post-terminal sell.
And `FeeAccrued` reports what each bucket actually received, so a redirected
share reports zero there and the fee a terminal launch charged must be totalled
from the `fee` field of `Bought` and `Sold` instead.

Did not block Phase 1. Found while reconciling the specification against the
Phase 1 contracts and first recorded here as a property of what was implemented
rather than a defect. That classification was wrong: value that no address can
ever reach is a defect when one branch removes it.

### Question

`Expired` and `Stalled` keep sells open forever, and a sell in those states is an
ordinary sell: it charges `totalFeeBps` and splits it three ways. Two of the
three destinations have no payout path left at that point.

- The protocol share is claimable in every state, so it is fine.
- In `Stalled` the creator share is claimable, so it is fine.
- In `Expired` the creator share accrued after `expire()` is permanently
  unclaimable, because `claimCreatorFees` reverts in `Expired`.
- The holder-protection share accrued after either terminal transition is
  permanently undeliverable, because the one-time donation into `ethReserve` has
  already happened and there will be no pool.

Both of those accumulate in a contract with no withdrawal path, so they leave
circulation. Nobody can take them, and no invariant is violated: Invariant 3
still holds and Invariant 18 counts them as held. The amount is bounded by the
fee on post-terminal sell volume, which for a failed launch is the volume of
holders exiting.

Should a terminal launch keep splitting its fee this way?

### Options

**A. Keep it as implemented.** Simplest possible rule: a sell is a sell, the fee
arithmetic has no state-dependent branch, and the stranded wei raises nobody's
cost and lowers nobody's payout. Cost: a small, permanent, unexplained-looking
leak that an auditor will find and ask about, which is why it is written down
here.

**B. Route the whole fee into `ethReserve` after a terminal transition.** The fee
becomes a donation to the remaining holders, which is the destination the design
already chooses for ambiguous value (spec 6.1). Cost: a state-dependent branch in
the fee path, which is the most tested arithmetic in the protocol.

**C. Charge no fee on post-terminal sells.** Cheapest exit for holders of a
failed launch and arguably the fairest. Cost: the same branch as B, and it
removes the protocol's fee on volume it is still providing a market for.

### Trade-offs

The amounts are small and the current behaviour is safe, so this is a question of
honesty and tidiness rather than of risk. B is the most defensible of the three
on principle: every other rounding and remainder in the protocol flows to
holders, and this is the one place where value instead flows nowhere. Against
that, both B and C put a branch into `_accrueFee` or its caller, and that code is
covered by Invariants 14, 17 and 18 in every state.

### Recommendation

**A for Phase 1, with B as the change to make if this code is ever touched
again.** Do not add a branch to the fee path to recover an amount this small
while the invariant suite is being written against the current behaviour; do add
it if a future revision opens that function for another reason. Either way the
behaviour stays documented in spec 6.2 and 10.3 rather than being left for an
auditor to discover.

### Addendum, 2026-11-11, after this entry was resolved

Two notes that keep this record accurate without rewriting it.

`FeeAccrued` has since gained a fifth parameter, `reserveCut`, carrying the
redirected amount directly. The paragraph above that says a redirected share
"reports zero there" and that the fee a terminal launch charged "must be
totalled from the `fee` field of `Bought` and `Sold` instead" describes the
event's earlier shape and is superseded. The four amounts of a single
`FeeAccrued` now sum to that trade's fee in every state, so the event reconciles
on its own and no reconstruction is needed. The final form is in spec sections
6.3, 16 and 16.1 and in Invariant 59.

No Pledrin contract has been deployed to any network. `docs/OWNER_TODO.md`
records that mainnet deployment waits on an external audit, so every entry in
this document that speaks of what was implemented means code in the repository
and never code on a chain.

---

## 14. The order of `buy`'s deadline and window checks

**RESOLVED 2026-11-11: option B, and implemented in `contracts/src` the same
day.** `_buy` now checks `WrongState`, `BuyWindowClosed`, `DeadlinePassed`,
`BuyTooSmall` in that order. `docs/SPEC.md` section 5.4, the check-order table in
section 16.2 and Invariant 32 are the specification; Invariant 32 asserts the new
order explicitly, because it asserted the old one explicitly and would otherwise
have become the thing that failed.

Raised 2026-11-11 while writing the revert-reason standard of section 16.2. No
ETH, no token and no state was at stake either way; what changed is the sentence
a caller is shown.

**Which argument failed.** The brief that introduced this ordering defended it as
calldata validation whose verdict is true in every state, by analogy with the
`tickSpacing` range check that `graduateAlt` runs ahead of its state check. That
justification does not survive inspection, on two counts, and both are recorded
because the conclusion is worth less than the reason. The range check is a pure
function of its argument, while the deadline check compares the argument against
`block.timestamp`, so its verdict is a fact about the block rather than about the
calldata. And the range check runs *before* `graduateAlt`'s state check, while
the deadline check runs *after* `buy`'s, so `buy` was never applying a
calldata-first rule for the deadline check to be an instance of: its first
refusal was already `WrongState`.

**Why now rather than at the next edit.** The entry's own recommendation was B
"whenever `_buy` is next touched". That deferral was dropped once the
justification for A was gone: swapping strictly dominates, so waiting only kept a
misleading message in place for no gain. Section 16.2's instruction that a front
end read `gradDeadline` before echoing `DeadlinePassed` was a mitigation for this
defect and is no longer stated as one.

### Question

`buy` checked, in this order, `state == Live`, `block.timestamp <= deadline`,
`block.timestamp < gradDeadline`, and `msg.value >= MIN_BUY_WEI`. Exactly one
input class makes the middle two both true: a transaction whose own deadline has
passed, sent to a launch whose graduation window has also closed and which
nobody has yet moved out of `Live` by calling `expire()`. That call answers
`DeadlinePassed`. A resubmission with a fresh deadline then answers
`BuyWindowClosed`. Should the two checks be swapped?

### Options

**A. Keep the order.** The caller's own deadline is honoured before the launch's
window is consulted, so a transaction that sat in the mempool is refused for the
reason the caller themselves wrote into the calldata. The cost is the input class
above: the first refusal names a condition a later call can clear while the real
blocker, the closed window, is permanent. That is precisely what section 16.2
forbids everywhere else, and it costs the caller one wasted round trip and one
wasted gas payment.

**B. Check `BuyWindowClosed` before `DeadlinePassed`.** No input class is worse
off. While the window is open the window check cannot fire, so a stale
transaction still answers `DeadlinePassed`; once the window is closed the caller
is told the permanent truth on the first attempt. The cost is conceptual rather
than practical: a transaction the caller instructed not to execute after `T` is
refused for a reason other than `T`, and a reader who expects calldata to be
validated before chain state has to look at section 16.2 to see why.

### Trade-offs

The argument recorded for A is that the deadline check is calldata validation
whose verdict is true in every state, by analogy with the `tickSpacing` range
check that `graduateAlt` runs ahead of its state check. It fails on two counts,
both set out in the resolution above, and that failure is what decided this
entry.

Against that, A is already written, already tested and harmless to funds, and the
front end can compensate: `gradDeadline` is an immutable public getter, so an
application can read it once per launch and say "the launch's buy window closed"
rather than echoing "deadline passed".

B is a reordering of two adjacent `if` statements in `_buy`, with no new error, no
new storage read and no change to any precondition, which makes it the cheapest
change in this document.

### Recommendation

**B, taken whenever `_buy` is next touched for any other reason.** It costs
nothing by the standard section 16.2 states and it removes the only remaining
case where this protocol tells a caller to retry something that cannot succeed.
If A is kept, keep section 16.2's instruction that a front end reads
`gradDeadline` before it echoes `DeadlinePassed`, because that instruction is
then the only thing standing between the caller and a misleading message.

---

## 15. Whether `release` should name a schedule it has finished paying

**RESOLVED 2026-11-11: option B, and implemented in `contracts/src` the same
day.** `release` rejects a schedule with `released == allocation` as
`ScheduleFullyReleased()`, checked before the releasable amount is computed, and
`NothingToRelease` narrows to the three conditions a later call clears: not
started, inside the cliff, nothing newly accrued. `docs/SPEC.md` section 12's
table and Invariant 62 are the specification, and section 16.2's shared-error
table records the split rather than an exception.

Raised 2026-11-11, same source as decision 14.

**Which classification failed.** This case was handed over as one of four
deliberate exceptions to the standard, on the stated line that a shared error is
acceptable across functions when the caller can discriminate from data already in
hand. The other three exceptions — `claimProtocolFees`, `claimCreatorFees` and
`claimBounty` — are cross-function and clear that line: the caller holds the
launch state and can tell the clearable case from the permanent one. This one is
not cross-function. It was one function answering three clearable conditions and
one terminal condition with a single error, which is the intra-function shape the
standard forbids, and it sat one line below the `ScheduleVoided` check that the
same round of changes had just added for exactly that reason. The line drawn in
the brief condemned it; it was classified as permitted by it. Recording the
misclassification is the point of this paragraph: the standard is only worth
having if it decides cases against the person applying it.

### Question

`CreatorVesting.release` answered `NothingToRelease` for four conditions: the
schedule has not started, it is inside its cliff, no further base unit has
accrued since the last release, and the schedule has been released in full. The
first three are cleared by a later call. The fourth never is. Section 16.2's
standard is that within a single function the refusals must be as final as the
conditions that cause them, and this is the one place in the protocol that does
not hold. Should a fourth error be added?

### Options

**A. Keep one error.** `NothingToRelease` keeps covering all four. The caller
that wants the difference reads `scheduleOf(launch)` and compares `released`
against `allocation`.

**B. Add one error, checked before the releasable amount is computed.** One
comparison, `released == allocation`, and one new selector, on the same pattern
as the `voided` check that the same round of changes added immediately above it.
The error names the terminal case and `NothingToRelease` is then clearable in
every case it still covers.

### Trade-offs

The harm from A is the smallest in this family. The only party with a reason to
call `release` is the creator's payout path; a finished schedule has already paid
the allocation in full, so nobody is misinformed about where their tokens are;
and the ERC-20 `Transfer` and `VestingReleased` logs already show the schedule
paid out.

Against that, A is the exception a later reader is most likely to file as an
oversight, because it sits inside the one function this round of changes
corrected for exactly this reason, and because the rule it breaks is the
intra-function one rather than the cross-function one the three settled shared
errors rely on. A reader who accepts the reasoning for splitting `ScheduleVoided`
out of `NothingToRelease` has no way to see why the finished case was left in.

B costs one selector and one more branch in a function with no owner, no
acceleration path and nothing else to get wrong. `CreatorVesting` is a few
kilobytes of runtime code against the 24,576-byte limit that section 2.1 of the
specification sizes the deployers against, so there is no size argument against
it either.

### Recommendation

**B**, at the same priority as decision 14 and preferably in the same change,
since both are one-line edits to functions whose behaviour is otherwise settled.
If A is kept instead, section 16.2's table must keep saying that this one is
unsettled rather than reclassifying it as a deliberate exception, because the
other three exceptions are shared *across* functions and this one is not, and
collapsing the two kinds would weaken the standard to the point where it stops
deciding anything.

---

## 16. Post-graduation price history, and an ABI that is not in `contracts/abi/`

**Blocks Phase 2 at the start**, because the answer decides whether the read
side has one price formula or two, and whether it has a second event source.

After `Graduated` a launch emits nothing: no trade, no fee, no price
(`docs/SPEC.md` Invariant 47). Trading has moved to an ordinary v4 pool. The
launch page still has a chart, and the question is what that chart shows after
the curve phase ends.

Post-graduation trades are observable: Uniswap v4's `PoolManager` emits `Swap`
with the pool id indexed, so the launch's swaps can be filtered by the
`poolId` in `Graduated` — which, note, is not necessarily the `poolId` in
`LaunchCreated`, because `graduateAlt` uses a different pool key
(`docs/SPEC.md` Invariant 38).

The obstacle is the ABI. `contracts/abi/` holds the eight Pledrin ABIs and no
external one, `contracts/out/` is gitignored, and the only committed source for
the `Swap` signature is the vendored v4-core submodule at
`contracts/lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol`. The
project's rule is that the read side builds against frozen ABIs; an external ABI
pulled from a submodule's source at build time is not that.

### Question

Does the application show post-graduation price and volume, and if so where does
the data come from?

### Options

**A. Vendor a pinned `PoolManager` ABI and index `Swap`.** Full continuity: one
chart from the first curve buy to the present. The ABI is added as an external
artifact with its source commit recorded, kept separate from the ABIs our own
build produces. `docs/DATA_MODEL.md` gains a `PoolSwap` entity, and a second
price unit, because `Swap` reports `int128` currency deltas and a
`sqrtPriceX96`, not the wei-per-whole-token integer section 4.2 defines.

**B. No post-graduation history; current price only, read live.** The curve
chart ends at `graduatedAt` with a label. The current price comes from an RPC
read against the Quoter or StateView named in `docs/CHAIN_FACTS.md`, taken by
the application, not stored by the indexer.

**C. Nothing post-graduation.** The page states that trading has moved and links
out.

### Trade-offs

A is the only option that gives a continuous chart, and continuity is what a
reader of a graduated launch actually wants. Its costs are real but bounded: one
more event source on a singleton that every pool on the chain emits through, so
the filter is on an indexed topic and cheap, but the historical range runs from
each launch's graduation to the head and grows with the chain rather than with
Pledrin. The larger cost is conceptual: a second price formula, a second unit,
sign handling on `int128` deltas, and the `sqrtPriceX96` conversion — all of
which are new ways for the two halves to disagree about what a price is.

B keeps exactly one price formula and one unit, needs no new ABI, no new entity
and no new indexing surface, and matches what `docs/SPEC.md` section 18 already
says: post-graduation routing and quoting use ordinary v4 tooling. Its cost is
that a graduated launch's page has no history after graduation, which for a
successful launch is eventually most of its life.

C is B without the live price and saves nothing worth having.

### Recommendation

**B for the first release.** It is the option that ships the specified data
model unchanged and makes no claim the read side cannot keep.

Take A deliberately and separately if post-graduation history is wanted, and
when taking it: pin the ABI with its source commit, put it where it is obviously
external, filter on `Graduated.poolId` and not `LaunchCreated.poolId`, and add
the `PoolSwap` entity and the second price unit to `docs/DATA_MODEL.md` before
either half is built against it. Do not reach for the submodule's source at
build time as a shortcut; that is the version-drift failure the frozen-ABI rule
exists to prevent.

---

## 17. The encoding of `LaunchMetadata.metadata`

**Blocks Phase 2 at the start**: the creation form writes this blob and the
indexer reads it, so an unstated encoding is two halves writing and reading
different things.

`createLaunch` takes `bytes metadata`, emits it verbatim in `LaunchMetadata`,
never stores it, applies no length bound and no structure check, and
`docs/SPEC.md` section 18 is explicit that the protocol interprets none of it.
The only validated strings are `name` and `symbol`, bounded at 64 and 16 bytes.
That is correct for the protocol and leaves the read side to decide everything.

### Question

What goes in the blob, in what encoding, and bounded how?

### Options

**A. Inline, ABI-encoded tuple of bounded strings**, behind a leading version
byte: description, image URI, website, and a small fixed set of social handles.

**B. Inline UTF-8 JSON.**

**C. A short URI only**, pointing at off-chain JSON.

**D. Always empty**, with all metadata held in an application-side database
keyed by launch address.

### Trade-offs

Calldata dominates cost on this chain (`docs/CHAIN_FACTS.md`), so every inline
option is the expensive one — paid once, at launch, by the creator.

A is self-describing, cheapest and safest to decode, and bounds each field
explicitly. It cannot be extended without the version byte, which is why the
version byte is part of the option rather than a detail.

B is the easiest to write and the easiest to get wrong: no per-field bound,
duplicate keys, encoding ambiguity, and a parser that must be defensive against
a blob an attacker chose. It buys flexibility that nothing here needs.

C is about sixty bytes and is **mutable after launch**. That is the deciding
property: the creator can change the image and the description a buyer saw at
the moment they bought, in a protocol that otherwise fixes everything about a
launch at creation. It also makes the indexer depend on an off-chain fetch, with
its latency, its failure modes and its cache invalidation.

D has no on-chain record at all, so the application becomes a second source of
truth, with its own write path, its own authentication question and its own
moderation surface — the three things this project does not otherwise have.

### Recommendation

**A**, with a leading `uint8` version and explicit per-field byte bounds. The
immutability is the point: what a buyer saw cannot be changed afterwards, and
nothing has to be fetched for a page to render.

Whichever is chosen, two rules from `docs/DATA_MODEL.md` stand unchanged:
IDX-20's `METADATA_MAX_BYTES` cap, because the on-chain bound is the block gas
limit and nothing else; and the rule that an oversize or undecodable blob yields
a null field and never fails a block or stalls the index.

---

## 18. Whether the read side indexes `Timelock`

**Blocks Phase 2, but not at the start.** It adds one entity and one query and
changes nothing already specified.

The minimum page list has no governance page. `Timelock`'s four events, and the
factory's `OwnershipTransferred`, describe the entire set of powers anyone has
over this protocol, and `docs/DATA_MODEL.md` section 2 lists all five as emitted
and consumed by nothing.

### Question

Does the indexer index `Timelock`, and does the API expose a governance query?

### Options

**A. Index and expose**, as one list of operations with their `readyAt`.

**B. Index, expose nothing**, so the history exists if a page is added later.

**C. Do not index.**

### Trade-offs

The argument for A is not a product argument. `TIMELOCK_DELAY` is 48 hours, and
a delay protects users only if somebody can observe what is pending during it.
An unobserved timelock delivers the delay and none of its benefit, and
`docs/THREAT_MODEL.md` treats the delay as a mitigation. Making the pending set
visible is what converts it from a promise into something checkable by anyone.

The cost of A is close to nothing: one event source on a singleton that will
emit a handful of events in its lifetime, plus one page that is not in the
minimum set.

What moderates the urgency is that the powers are small. `setFeeConfig` and
`setProtocolTreasury` cannot reach an existing launch, and `transferOwnership`
reverts (`docs/SPEC.md` section 14), so the only power with a user-visible
effect is `setLaunchesPaused`, whose current value `ProtocolConfig` already
carries. B is therefore defensible: the data is kept, the page waits.

C saves nothing measurable and gives up the auditability for free.

### Recommendation

**A, minimally.** Index the four `Timelock` events and the factory's
`OwnershipTransferred`, expose one `governanceOperations` query, and render it as
a plain list with `readyAt` and a derived status. No voting, no proposal
decoding beyond target and calldata, no notifications.

Fold the integrity cross-check in here as well, since it is the same
near-zero-cost category: if `CurveDeployed` and `TokenDeployed` are indexed,
then a `LaunchCreated` whose launch did not appear in a `CurveDeployed` in the
same transaction is an anomaly, and the right response is an operator alert,
never a displayed field (`docs/DATA_MODEL.md` IDX-8).

---

## 19. The confirmation depth the indexer should trust

**RESOLVED 2026-11-11 by measurement: the indexer follows `latest`, and there is
no confirmation depth.** The entry asked which depth to trust. The answer is that
the question has no good answer on this chain, because no depth is both safe and
usable. What the question was standing in for is a requirement, and
`docs/DATA_MODEL.md` section 7 already states it: every row a pure function of
the canonical log set, no handler storing the result of an `eth_call`, every
handler idempotent (IDX-9, IDX-12, IDX-14). Those were written as correctness
requirements before the measurement existed, and what the measurement shows is
that they are the whole answer. IDX-14's deference to this entry is gone.

The figures are in `docs/CHAIN_FACTS.md` under "Block time and finality tags",
with the commands that produced them. They are deliberately not repeated here,
so that there is one place for them to go stale.

This entry no longer blocks anything. It was raised as blocking Phase 2 before
mainnet on the ground that it needed a measurement rather than an opinion, and
that was right: the depth could not be stated without one, and it turns out it
could not be stated with one either.

**Which argument the measurement settled.** Both rejections in the trade-offs
below were predictions. The measurement converted one into a fact and destroyed
the other.

Option B was rejected as "probably unusable" because "the lag can be minutes to
hours". That prediction holds, at the low end of its own range. Both tags are
served, so B is available rather than impossible, and both are minutes rather
than seconds behind the head — `finalized` by roughly twenty. A trading
interface for a curve whose whole lifetime may be hours cannot show a price that
old. B is therefore unusable as a fact and not as a guess.

Option C was rejected as "a compromise whose N is a guess until somebody
measures". The measurement did not supply N. It removed the parameter. Safety
against replacement of the head is not a continuous function of depth here: the
only depths with a safety property behind them are the two tags, and between
zero and the nearer of them there is no intermediate safety to buy. The
scenarios that replace a single-sequencer chain's head act at the level of the
sequencer's feed and of batch posting, so they are not bounded by a small depth,
and a few hundred blocks of lag would cost tens of seconds of staleness in
exchange for protection against nothing in particular. C's N was not merely
unmeasured, it was a parameter with no safety semantics, and this entry's own
recommendation of "a conservative default" presupposed a continuum that does not
exist.

Option A therefore survives, and not because it is safe. It survives because the
handlers carry the safety and the tags cannot carry the freshness.

One structural point, which is why no operational tuning rescues B. The two tags
are about one Ethereum epoch apart, which is what an L1-derived finality tag
looks like on a Nitro chain. If that is the mechanism, the lag of `safe` is
inherited from L1 finality rather than chosen by whoever operates this chain,
and no batch-posting change brings either tag within seconds of the head. The
distance is structural, not a configuration accident waiting to be optimised
away.

**What the measurement did not answer, and why this resolution does not need
it.** The recommendation below asked for three facts. Two are now recorded: that
both tags are served, and the observed lag of each. The third — whether a reorg
of the unsafe head has ever been observed on this chain — is not, and two `cast`
calls cannot produce it. It needs sustained observation of the head, or a
statement from whoever runs the sequencer, and neither exists here. That missing
fact is a reason the depth was unavailable rather than a hole in this
resolution: reorg-safe handlers are required whether head replacement is
frequent or has never once happened, while choosing a depth would have required
knowing which.

**The prohibition stands, on a new basis.** The recommendation below says that
until the measurement exists, nobody may describe the indexer as reorg-proof.
The condition is discharged and the prohibition is not, because no lag
measurement could have licensed that claim in the first place. The exposure is
in the handlers, and the handlers are not written. Once they are, and once each
has been tested against IDX-9, IDX-12 and IDX-14, the available claim is the
narrower one those items support: reorg-safe by construction, meaning a correct
rollback restores every row exactly. Not that a reorg has no effect on what a
reader was shown.

**The cost this resolution keeps.** Option A's cost in the trade-offs below is
not removed by reorg-safe handlers. The API serves rows that a rollback can
remove, and `docs/DATA_MODEL.md` APP-13 does not cover it: its notice says that
data is behind the head, never that data is ahead of finality. Idempotent
handlers make the database right again after a rollback; they do not make a
reader un-see a trade that was rolled back. This is accepted for the first
release, because the alternative is a twenty-minute-old interface. Whether
`IndexerStatus` should carry the distance to `finalized`, so that a page can
mark the range that is still revocable, is not decided here. It would cost one
field and one live read, and it is the only cheap mitigation in sight.

**Two caveats on the measurement itself.** The lags are what one endpoint
reported at one moment, not a safety property of the chain. A sequencer change
or a batch-posting change moves them, and the figures in `docs/CHAIN_FACTS.md`
are an observation with a date on it rather than a bound. And nothing in the
protocol depends on them: no contract reads a block tag, and `docs/SPEC.md` has
no finality assumption to revise. They bind the read side only, which is why
this resolution lives in `docs/CHAIN_FACTS.md` and `docs/DATA_MODEL.md` and
changes nothing in the specification.

When this entry was raised, `docs/CHAIN_FACTS.md` recorded that this is an
Arbitrum Nitro chain and recorded how `block.number` relates to
`arbBlockNumber()`, but recorded nothing about finality: not the reorg depth,
not whether the RPC serves the `safe` and `finalized` block tags, not the
observed lag of either. `docs/DATA_MODEL.md` IDX-14 therefore stated the
correctness requirements and left the depth as configuration, deliberately,
rather than guessing a number. That gap is what the measurement closed, and
IDX-14 now states the choice instead of deferring to this entry.

### Question

What block does the indexer treat as final, and what does the API serve in the
meantime?

### Options

**A. Index at the unsafe head**, relying on the framework's rollback, with the
reorg-handling depth as configuration.

**B. Index only to `finalized`** (or `safe`), if the RPC serves the tag.

**C. Index at head with a fixed confirmation lag** of N blocks.

### Trade-offs

A gives the freshest data, which a trade feed and a live curve price need. Its
cost is that the API sometimes serves rows that can still disappear, and the
application has no way to signal that: `docs/DATA_MODEL.md` APP-13's staleness
notice covers data that is behind, not data that is ahead of finality.

B is the strongest correctness position and probably unusable. On an L2 whose
finality depends on L1 batch posting, the lag can be minutes to hours; a
launchpad whose trade list is an hour old is not a launchpad.

C is a compromise whose N is a guess until somebody measures.

### Recommendation

**A**, with the framework's rollback relied upon and the depth as configuration
with a conservative default — but the prerequisite is a measurement and not a
choice. Before Phase 2 reaches mainnet, verify against both networks with `cast`
whether `safe` and `finalized` are served, what each one's observed lag is, and
whether a reorg of the unsafe head has ever been observed on this chain. Those
three facts belong in `docs/CHAIN_FACTS.md` with the commands used, in the same
form as everything else in that file, and the depth follows from them.

Until that measurement exists, nobody may describe the indexer as reorg-proof.
What can be said, and is already specified, is that every row is a pure function
of the canonical log set, so a correct rollback restores every row exactly
(IDX-12, IDX-14).

---

## 20. Whether ERC-20 `Transfer` is indexed for every launch token

**Blocks Phase 2 at the start**, because it decides whether `holderCount`,
`marketCapWei` and `HolderRow` exist in the API shapes at all.

Holder counts, circulating supply, market capitalisation and holder
concentration all need the full balance set, which means indexing `Transfer` for
every launch token. It is the largest single cost in the indexer and the only
one that grows with the product's success rather than with its age.

### Question

Is `Transfer` indexed, and for which launches?

### Options

**A. Every launch token, from its creation, forever.**

**B. Only launches past an activity threshold**, backfilled from the token's
first block when the threshold is crossed.

**C. Not at all.** Drop `holderCount` and `marketCapWei`; keep
`uniqueTraderCount` as the activity metric.

### Trade-offs

A is the complete answer. Its cost is unbounded in the number of launches, which
on a launchpad is the fastest-growing number there is, and a graduated token
that trades heavily emits a `Transfer` per swap leg forever.

B is not the saving it looks like. The threshold cannot be a filter, because a
launch whose indexing starts mid-history has wrong balances; it has to be a
backfill trigger, re-reading from the token's first block, which is known. That
is implementable and it keeps the worst case identical to A for exactly the
launches that matter.

C is cheap and honest and loses the metric most readers look for. The deciding
point against it is concentration: top-N holder share is the one holder-derived
figure that sybil wallets cannot inflate, and it needs the full balance set.
`uniqueTraderCount` is a weaker substitute that measures something else.

### Recommendation

**A.** The frontend brief names holder counts, and concentration is worth more
than the count itself. The exclusion set in `docs/DATA_MODEL.md` section 3.9 is
mandatory and not an optimisation: without it the curve, the vesting contract
and — after graduation — the v4 PoolManager all appear as the largest holders of
every launch.

If cost becomes a real problem, retreat to B with a full backfill, not to C, and
make the affected fields null rather than zero so that a missing count is never
read as a count of zero.

---

## 21. The API transport

**Blocks Phase 2 at the start.** It decides the application's entire
data-fetching layer, and it is the one decision in this group that cannot be
deferred by a day.

`docs/DATA_MODEL.md` section 5 specifies the queries, the arguments and the
shapes, and deliberately does not specify the transport. Ponder serves GraphQL
by default and can also serve custom HTTP routes.

### Question

GraphQL, HTTP JSON, or both?

### Options

**A. GraphQL**, with a generated schema the application types against.

**B. HTTP JSON**, one route per query in section 5.3.

**C. Both.**

### Trade-offs

A gives a typed schema both halves share, per-page field selection — which
matters for `LaunchDetail`, the largest shape — and one pagination convention.
Its awkwardness is the request-time derivations: `EffectiveState`,
`availableActions`, `releasableNow` and `claimable` are evaluated against the
server clock rather than read from a column, so each is a resolver rather than a
field, and a resolver that fans out across launches is easy to write and
expensive to run.

B makes those four natural and cacheable per route, and keeps section 5.2's
shapes literal on the wire. Its cost is hand-written types on both sides and a
hand-written cursor convention, which is exactly the kind of duplicated
definition this document exists to avoid.

C is tempting precisely because the awkward cases are few, and it is still two
surfaces to keep in agreement, two places for a field to be added to one and not
the other, and no single schema that is the truth.

### Recommendation

**A**, with the time-dependent values as resolvers and with `claimable` and
`indexerStatus` accepted as the two that will feel wrong there. If either is
materially clearer as a named HTTP route, that is a bounded exception worth
taking — two named routes, documented in `docs/DATA_MODEL.md` section 5.3 — and
not a licence for a second API.

Whichever is chosen: every field name in `docs/DATA_MODEL.md` section 5.2 is
binding, the integer encoding of section 1.2 applies without exception, and the
choice is made before either half writes a line, because retrofitting it is a
rewrite of the application's data layer and of the indexer's API surface at
once.

---

## 22. The precondition graduation places on its pool key

**DECIDED 2026-11-11 by the protocol architect, prompted by findings 2 and 3 of
`docs/security/REVIEW-2026-11-11-phase1-contracts.md`. Changes 1, 2 and 4 are
implemented in `contracts/src`; change 3, `GraduationHelper`, is specified in
spec 8.6 and not yet written. Nothing described here has been deployed to any
network.**

**One deviation from the design, recorded because the equivalence it rests on is
load-bearing.** The shared graduation body is `_settle(PoolKey)`, deriving
whether `ALT_DELAY` applies from the key's `fee` and `tickSpacing`, rather than
`_settle(fee, tickSpacing, bool alternate)` as this entry's change 1 implies. The
two are equivalent by Invariant 67 and not by accident: `graduate` can name
nothing but the canonical pair, and `graduateAlt` refuses that pair before the
body runs, so the delay fires on exactly the set of calls the flag would have
fired on. A change to the permitted alternate ranges is therefore a change to
this derivation. The deviation was forced by EIP-170 and it is the reason the
change set fits at all — spec 2.1 records that the flag form measured 25,445
bytes, 869 over the limit, because a literal argument lets the inliner duplicate
the whole graduation body once per call site. Spec 8.2 carries the prohibition
that follows.

**Two measurements from the implementation that contradict this entry's
estimates, left in place below rather than corrected in line, because the error
is instructive.** The margin went **up**: `CurveDeployer` is 23,690 bytes with
**886 free**, 359 fewer bytes than before a change set that adds a conditional
`initialize`, a two-field alternate key, three new refusals, a new event and two
event fields. And the estimate's component figures were about right while its
total was wrong by the opposite sign, because `_settle` is not a function in the
compiled output and the components do not add. Spec 2.1 states the rule that
follows: measure the whole change set, never the parts.

The decision in one statement, and it is normative:

> No Pledrin contract may require a Uniswap v4 pool key to be uninitialised, or
> to be empty. The only precondition graduation places on a pool is that
> `slot0.sqrtPriceX96` equals `sqrtPriceTerminal` at the moment the core position
> is minted. The protocol moves the price for free or not at all; when it cannot,
> any third party may move it with their own funds in the same transaction; and
> the alternate key space is wide enough that pre-denying all of it is
> infeasible.

### Which premise failed, and it was this document's

Three places asserted that a Pledrin pool key cannot be reached before its launch
transaction: `docs/SPEC.md` 8.1, `docs/THREAT_MODEL.md` 4.1, and
`docs/DATA_MODEL.md` 6.3 with APP-5. The common sentence was that the token
address does not exist before the launch transaction, therefore the key is not
computable, therefore there is no window.

The inference is invalid. A `CREATE` address is `keccak256(rlp([deployer,
nonce]))[12:]`, `TokenDeployer` is a singleton at a fixed address, and its nonce
is one `eth_getTransactionCount` call away, so the address of the token the next
launch will deploy is computable by anyone at any time. **Non-existence is not
unpredictability**, and the three documents used the first word to claim the
second. The reviewer executed the consequence rather than arguing it: 47,027 gas
to seize the canonical key of a launch that does not exist yet, after which
`createLaunch` reverts `PoolAlreadyInitialized` for whoever lands on that nonce,
the revert rolls the deployer's nonce back so the next attempt targets the same
address, and eight future slots fall to one transaction. The factory was bricked
protocol-wide for the price of a rounding error, and the only clearing move cost
452,183 gas against the attacker's 47,027.

The same prediction reaches the 190 alternate keys of a launch that does not
exist yet, which is why findings 2 and 3 are one finding. And 4.5's costing of
the alternate path — that an attacker "must pre-initialise **and hold hostile
liquidity** on all 190 keys", each instance "a losing position" — overstated the
attacker's burden twice over. A bare `initialize` with no capital disqualified a
spacing outright. On the canonical key the liquidity needed to defeat the
restoring swap is one wei, placed single-sided in ETH in a range above the
current tick, so it needs no launch token and nothing had to be bought from the
curve; and a position that small is not a losing position, it is a rounding
error that nobody will arbitrage away.

### Question

Given that every key the protocol can name is computable in advance and can be
initialised, and separately given a dust position, for gas:

1. May `BondingCurve`'s constructor treat an already-initialised canonical key as
   fatal?
2. What does graduation do with a key that is initialised **and not empty**, on
   the canonical key and on every alternate at once?

Question 1 has one answer and it is the phase's blocker. Question 2 is the one
with a design in it.

### Options

**A. Tolerate an initialised but empty key, canonical and alternate alike**, and
let the existing restore-and-assert carry the price property. The reviewer's
recommendation.

**B. Bound the restore's cost instead of requiring it to be zero**, funded from
a named bucket — the bounty, or the protection share.

**C. Widen the key space along `fee`.** `_poolKeyFor` pins `fee` to `POOL_FEE`
and `hooks` to zero, so the reachable key space today is one fee tier times the
tick spacings. With `hooks == address(0)`, v4 accepts any `fee` in
`[0, 1_000_000]`: `Hooks.isValidHookAddress` returns true for the zero address
whenever the fee is not the dynamic-fee sentinel, and `LPFeeLibrary.validate`
rejects only above `MAX_LP_FEE`. The field is free.

**D. Make the token address unpredictable**, with `CREATE2` and a salt an
attacker cannot precompute.

**E. Accept the grief and document it**, on the basis that an empty pool's price
is free for anyone to restore and that `graduate()` can be called atomically
after a restore from a helper contract.

**F. Let the restore spend the caller's money inside the curve.** Not in the
brief this entry was given, and named here because it is what option E is a cheap
version of. `graduate()` becomes payable, settles a non-zero restore delta from
`msg.value` and from tokens pulled from `msg.sender`, refunds the remainder, and
never touches `ethReserve`.

### Trade-offs

**A is necessary and is not sufficient.** It is the whole answer to question 1
and it converts the worst defect in the protocol — a permanent, protocol-wide
brick on the only entry point — into the already-analysed grief of threat model
4.3. It answers nothing in question 2, because the restoring swap nominates one
wei of exact input and settles for nothing only in an empty pool: one wei of
liquidity in the path makes it cost something and `SwapNotFree` reverts. An
attacker who initialises and adds dust blocks that key whether or not
initialisation is tolerated.

**B is worse than the brief credits and should not ship.** The brief describes it
as converting a denial of service into a quantified cost. It does not, on two
counts that both point the same way.

The first is that the bound does not bound the attacker. The attacker chooses how
much liquidity to place and reads the bound out of the deployed bytecode, so they
place the amount that requires the bound plus one wei to clear. The key is
blocked exactly as before, and the only thing the parameter decides is how much
dust the attacker has to post. This is decision 2's objection — "the budget
becomes a number an attacker optimises against" — and it was correct when it was
a prediction.

The second is new and it is disqualifying. Every wei the curve spends crossing
hostile liquidity is a wei the attacker collects as the liquidity provider on the
other side of that trade, plus the pool's fee on it. A bounded budget therefore
does not merely fail to stop the attack; it pays for it. Today the grief has no
payoff at all, which is the single best property this part of the design has, and
a budget trades it for a capped subsidy. The same argument disposes of funding
the bound from the bounty or from the protection share: the question is not which
bucket loses the ETH, it is that the attacker gains it.

**C is the one lever whose cost is small and whose benefit is structural.** It is
easy to read it as "more escape hatches", which would be weak — gas on this chain
is cheap enough that multiplying 190 by a small factor buys little. Its real
effect is different: it removes the reason the alternate path had to use a bad
tick spacing. Threat model 4.5 is right that the restoring swap walks the tick
bitmap in proportion to tick distance divided by tick spacing, and right that
173k gas at spacing 200 against 2.33M at spacing 10 is the difference between an
affordable restore and an unaffordable one. Today the alternate path escapes that
cost only by refusing initialised keys, which is the refusal finding 3 defeats
for gas alone. With the `fee` field in play, the alternate key space contains
keys at the **canonical** spacing, so relaxing the initialised check no longer
imports the fine-spacing bitmap walk: the caller can always name a coarse key.
`fee` is also a better dimension than `tickSpacing` on its own terms. A fee of
9,999 pips and a fee of 10,000 pips are the same pool to a trader and to the
locked position; a tick spacing of 10 and a tick spacing of 200 are not.

Its cost is that the graduated pool's fee tier stops being a protocol constant,
which decision 6 chose deliberately. Three things limit the damage. The canonical
path is unchanged, so the common case is still 1% / 200. The range can be capped
at `POOL_FEE`, so an alternate pool is never *more* expensive for a trader than
the canonical one would have been — the escape can only make the graduated pool
cheaper to trade, never dearer, which is the right direction for a cost imposed
by a transient attack and permanent for the token. And the pool a launch actually
graduated on is already not reconstructible from constants after a `graduateAlt`;
finding 10 says so. That is an existing defect this change makes larger and
therefore has to fix, by putting `fee` and `tickSpacing` in the `Graduated` log.

**D downgrades a permanent brick to a race, and the brief is right that it cannot
do better.** Anything derived from the launch parameters is in the transaction's
own calldata. Anything derived from block state is known to whoever assembles the
block. What is left is a same-block race, winnable only by an attacker who can
see a transaction before it executes. Whether that is possible here is a chain
fact this project does not have, requested at the end of this entry. The decisive
point is not D's strength but its ordering: **a race is acceptable after A and
unacceptable before it.** Before A, losing the race is a permanent brick, and no
probabilistic defence may stand in front of that. After A, losing the race costs a
restore. D is therefore a reduction in how often the recovery path is needed, not
a fix, and it is sequenced accordingly in decision 23.

**E is most of the answer and the brief is right that it is unscheduled.** The
mechanism is real and it already works against today's code: `graduate()` reads
`slot0`, skips its own swap when the price already equals `sqrtPriceTerminal`,
and asserts the price before minting, so a third party who moves the price and
calls `graduate()` in the same transaction graduates the launch with no code
change at all. What makes it work on a pool that is not empty is the fact the
documents never state: hostile liquidity does not disturb the mint. Minting
liquidity is not a trade. The amounts a position consumes are a function of the
price and of that position's own range, so for any third-party liquidity `L` with
the price at terminal, the core mint consumes exactly what it would have consumed
at `L == 0`. The pool having a stranger in it is not a problem; the price being
wrong is, and the wrongness is curable by anyone.

And the cure is cheap in exactly the case that matters. Crossing one wei of
liquidity costs about one wei. The dust block works only against a rule that
demands exactly zero, and that rule exists to protect the curve's reserve, not to
protect the price. Move the payment to a party who volunteered and the attack's
cost to the protocol scales with the attacker's own stake in it: dust is free to
clear, and liquidity deep enough to make clearing expensive is liquidity the
attacker has to fund, at a price that is about to be overwritten, in a pool that
nobody has to use.

**F is correct and unaffordable.** It is the same economics as E — the restore is
paid by whoever wants graduation, never by `ethReserve` — with better ergonomics,
since no second contract is involved. It costs settle, take, token-pull, refund
and slippage paths inside `BondingCurve`, where `_restorePrice` currently has no
settle or take path at all, which is why it is small. `CurveDeployer` has 448
bytes of margin as of this entry (measured below), so F is out on size before it
is out on anything else, and it would also put caller-supplied ETH inside the one
function that must not confuse a payment with a reserve. E gets F's economics for
zero bytes in the contract that has none to spare, which is the whole reason to
prefer it. **E is not a consolation prize for B; E is B with the payer corrected
and the code relocated.**

### Recommendation

All four of the following, in this order. The first is the blocker. The others
make the first safe to take.

**1. Nothing may require a key to be uninitialised or empty.** `BondingCurve`'s
constructor reads `slot0.sqrtPriceX96` on the canonical key and calls
`PoolManager.initialize` if and only if that value is zero. `graduateAlt` loses
`AltPoolInitialized` entirely, and the two branches of `_settle` collapse into
one: initialise if the key is unopened, otherwise restore for free if the price
is wrong, then assert the price. **The constructor must not suppress any other
failure of `initialize`.** A `getSlot0` test does that by construction; a
`try`/`catch` or a swallowed low-level call does not, and would hide a genuine
misconfiguration behind a griefed-pool branch. Which of those the engineer uses
is an implementation choice; distinguishing the two cases is not.

**2. The curve's own restoring swap keeps its zero-net-delta rule unchanged.**
Invariant 41 is not relaxed. What changes is only that its failure is no longer
the end of the path.

**3. Ship `GraduationHelper`,** specified in `docs/SPEC.md` 8.6: stateless,
ownerless, holding nothing between transactions, granted no privilege by any
Pledrin contract, which in one transaction moves a pool to `sqrtPriceTerminal`
with its caller's ETH or launch tokens, calls `graduate` or `graduateAlt`, claims
the bounty it just earned and forwards it with any remainder to its caller. It
takes a list of candidate keys and takes the first that works, which is what
makes a front-run race on a named key survivable. It costs zero bytes against
`CurveDeployer` and it is replaceable by anyone, because it uses nothing but
public functions. That last property is the reason this is a scheduling decision
rather than a trust decision: if the helper is absent or defective, graduation is
still reachable by anyone willing to write the equivalent.

**4. Widen the alternate key space along `fee`, and let it reach the canonical
spacing.** `graduateAlt(uint24 fee, uint24 tickSpacing)`, with
`ALT_POOL_FEE_MIN = 3000`, `ALT_POOL_FEE_MAX = POOL_FEE = 10000`,
`ALT_TICK_SPACING_MIN = 10`, `ALT_TICK_SPACING_MAX = POOL_TICK_SPACING = 200`,
and the single pair `(POOL_FEE, POOL_TICK_SPACING)` refused as
`CanonicalKeyNotAllowed`. That is 7,001 fee values times 191 spacings less one
pair: **1,337,190 keys**, against today's 190, and the launch needs one of them.
`docs/CHAIN_FACTS.md`, under "Gas accounting and what actually limits an
attacker", now costs the denial of that set against this chain's measured limits;
the figures are deliberately not repeated here so that there is one place for
them to go stale. The pair exclusion replaces `ALT_TICK_SPACING_MAX = 199` as the
mechanism that keeps `graduate` the only path to the canonical key, and preserves
that property exactly.

Taken together the four give one rule per case, and no case has no answer:

| State of the key graduation wants | What happens |
|---|---|
| Unopened | The protocol initialises it at `sqrtPriceTerminal`, free |
| At `sqrtPriceTerminal`, any liquidity | The protocol mints; third-party liquidity does not disturb the amounts |
| Wrong price, no liquidity in the path | The protocol restores it for zero net delta, free |
| Wrong price, dust in the path | A third party restores it for about the cost of the dust and graduates atomically |
| Wrong price, deep hostile liquidity | Nobody restores it. Take an alternate key, which is free, and leave the attacker's capital in a pool that will never be the venue |
| Every key pre-seized | Not reachable: 1,337,190 keys, per launch, re-done after every failed attempt |

### What it costs

**ABI.** Three deliberate changes to `contracts/abi/`, all of them in
`BondingCurve`, and none in `LaunchFactory`, `CreatorVesting`, `LiquidityLock`,
`Timelock` or either deployer.

| Change | Kind |
|---|---|
| `graduateAlt(uint24)` becomes `graduateAlt(uint24,uint24)` | new selector, old one gone |
| `Graduated` gains `fee` and `tickSpacing` | event signature change, new topic0 |
| `PoolPreInitialized(launch*, token*, sqrtPriceX96)` added | new event |
| `AltPoolInitialized()` removed; `InvalidPoolFee(uint24)` and `CanonicalKeyNotAllowed()` added | one selector out, two in |

`GraduationHelper`'s own ABI is new rather than changed. No getter is removed, no
getter changes type, and `graduate()` keeps its signature and stays
non-payable — which is the difference between this recommendation and option F.

**EIP-170, as estimated before the change was built.** The figures in this
paragraph and the table under it are the pre-implementation estimate and are
superseded by the measurement at the head of this entry; they are kept because
the way the estimate failed is recorded at the end of them.
`CurveDeployer`'s runtime was 24,049 bytes at commit `5b86188`, read from
`contracts/out/CurveDeployer.sol/CurveDeployer.json`, so the margin was
**527 bytes**. Neither the 596 this entry was briefed with nor the 448 an earlier
revision of this paragraph recorded is current, and both were correct when they
were taken: 596 is exactly the margin at `81b8d77`, the commit before finding 1's
fix, and 448 was a variant of that fix that was never committed. **Finding 1's
fix cost 69 bytes**, not the 176 the 448 variant implied and not the 97 an
earlier revision of this paragraph charged to it. The 97 is real and is the drift since spec 2.1's
row was last measured: 69 for finding 1 plus 28 for two revert-reason rounds that
landed in the contracts without that row being updated. Spec 2.1 has the ledger.
The lesson is in the variance rather than in any of the five numbers: a figure in
a document is a measurement of a tree, and subtracting it from a current build
gives drift rather than the cost of any one change. Every byte of `BondingCurve`
creation code is a byte of `CurveDeployer` runtime, so the constructor change is
charged at full price. Order of magnitude, per change:

| Change | Estimate |
|---|---|
| Constructor reads `slot0` and branches | the only clear addition; ~100 bytes, all in creation code |
| `_settle` loses a branch, a getter call and a custom error | roughly neutral to negative |
| `fee` through `_poolKeyFor`, two range checks, one pair check | ~80 bytes |
| `Graduated` gains two fields; `PoolPreInitialized` added | ~70 bytes |
| `GraduationHelper` | zero against this budget; a separate contract |

Net: **low hundreds of bytes, plausibly under a hundred**, and the sign is not
certain because the branch collapse in `_settle` may pay for the fee plumbing.
That is affordable against 527 bytes only if measured rather than assumed. If the
margin does not hold, the order to drop in is: the `PoolPreInitialized` event
first, since it is telemetry; then the fee widening, which costs the alternate
path its robustness but leaves the blocker fixed; and never change 1, because
change 1 is the finding. If dropping all of that is still not enough, decision
5's option B or splitting the curve stops being optional, which spec 2.1 has said
since it was written.

**What the build said.** The sign was wrong and so was the reasoning behind the
one line of this estimate that was hedged. "The branch collapse in `_settle` may
pay for the fee plumbing" had it backwards: collapsing the branches **cost** 551
bytes, because the two call sites each held a copy of the body with a different
branch folded out, and merging the branches made both copies complete. Nothing in
the component estimates was far off and the total came out 359 bytes to the good
anyway, for a reason none of them could contain. The order-to-drop-in above was
never needed and is left standing because the next change may need it.

**What is not spent.** No curve ETH, in any case, on any path. No new admin
power, no new privileged address, no oracle, no new trust in anything. The
protocol gains no ability to decide who griefed whom.

### Where this disagrees with the review

The reviewer's recommendation for finding 2 is change 1 and it is right. Three
places where this entry goes somewhere else:

- **Finding 3's option 1** accepts an initialised alternate key with **zero
  liquidity**. That reproduces the defect one level down: the attacker adds a wei
  and the key is disqualified again, and the check costs a liquidity read for a
  condition that is not the one that matters. The condition that matters is the
  price, and liquidity is only ever evidence about how expensive the price is to
  fix — which is a judgement for whoever pays, not a predicate for the contract.
  So: no liquidity check at all, on any path.
- **Finding 3's option 2**, accepting a key already at `sqrtPriceTerminal`, is
  correct and is already what the code does on the canonical path; under change 1
  it stops being a special case and becomes the general rule, so it does not need
  to be written as an option.
- **Finding 3 reads the atomic restore as an undocumented mitigation that
  happens to exist.** It is better than that: it is the load-bearing mechanism,
  and the reason is the one the finding does not state, that the mint is
  indifferent to third-party liquidity. Promoting it from a lucky property to a
  specified path with a scheduled contract is most of this decision.

### What this does not close

- **A same-block race for a named key.** An attacker who can see a graduation
  transaction before it executes can initialise and dust the key it names. The
  helper's candidate list is the answer and it is a cost ratio, not a closure:
  the attacker pays per key blocked, the honest caller pays for the probes that
  failed. Recorded in `docs/THREAT_MODEL.md` 10.9.
- **Pre-seizing the canonical key of launches that do not exist yet**, which
  after change 1 is a nuisance rather than a failure: the launch is born with a
  foreign price on its canonical pool and may need the helper at graduation. It
  costs the attacker about 47,027 gas per future nonce. Decision 23 is the
  response and it is deferred, so for now this is accepted and disclosed.
- **A pre-launch shadow market**, which threat model 4.4 already accepts, and
  which gains one honest limit worth stating: a position opened before the launch
  transaction cannot contain launch tokens, because none exist, so the
  pre-launch pool can hold a standing ETH bid and cannot sell anybody a token.
- **Deep hostile liquidity on the canonical key**, which makes the canonical pool
  expensive to restore and is answered by moving to an alternate key rather than
  by paying. The launch then graduates on a key that is not the one
  `LaunchCreated.poolId` named, which is a worse outcome than the canonical pool
  and a much better one than no pool.

### Chain facts this decision needed, and where they landed

Four were requested here rather than written, because this architect does not own
`docs/CHAIN_FACTS.md`. None was needed to take changes 1 to 4. Two have since
been measured and are in that file; two are not.

**Measured, and one of them corrected this entry.** The gas limits are in
`docs/CHAIN_FACTS.md` under "Gas accounting and what actually limits an
attacker", with the commands that produced them, and they make the key-space
argument quantitative rather than rhetorical. They also falsify a sentence this
section used to contain: it said the binding resource in a key-space argument is
block space. It is not. The block gas limit on this chain is `2**50`, a sentinel
rather than a cap, so block space is not scarce; the figures that bind are the
ceiling on a single transaction and the gas-per-second speed limit, the latter
enforced by the price rising rather than by transactions being rejected. The
shape of the conclusion survives — denying the key space of **one** launch costs
hours of the chain's entire throughput and whole ETH, and the work does not
transfer to the next launch because the key contains the token address — but it
is bought by a different mechanism than the one this entry assumed, and an
attacker is throttled by price rather than stopped by capacity.

**Still outstanding, and both bear on decision 23 rather than on this one.**

- **Whether a third party can observe a transaction on chain 4663 before it
  executes, and whether ordering is first-come-first-served.**
  `docs/CHAIN_FACTS.md` records that `txpool_content` and
  `eth_newPendingTransactionFilter` are absent from the endpoint while a
  `pending` tag is served, and records correctly that this is a fact about one
  endpoint and not evidence about the sequencer. No argument here may treat the
  absence of a method as mempool privacy. Everything about racing for a pool key
  turns on the real answer.
- **Whether `blockhash` returns a usable value on this chain**, for the last 256
  blocks, and whether the sequencer knows it before a transaction that reads it
  is ordered. It needs a fork test that calls it from a contract, not a `cast`
  invocation.

A third request was partly answered and is worth keeping open: the gas cost of a
minimal v4 position mint through PositionManager on this chain. The 47,027 gas to
initialise a key is measured; the larger half of the cost table is an estimate,
and it is the half that matters, because after change 1 a bare `initialize` is
tolerated and only liquidity blocks a key.

---

## 23. Whether the launch token's address should be unpredictable

**DEFERRED 2026-11-11, pending a measurement that decision 22's change 1
produces.** Not a blocker, and explicitly sequenced after decision 22: taking
this instead of change 1 would be a probabilistic defence standing in front of a
permanent brick.

### Question

`TokenDeployer.deploy` uses plain `CREATE`, so the launch token's address is
`f(TokenDeployer, nonce)` and both inputs are public. That is what decision 22
records as falsifying three documents. After decision 22's change 1 the
consequence is no longer a brick, but the prediction still lets an attacker seize
the canonical pool key of launches that do not exist yet, at about 47,027 gas per
future nonce, so that whichever launch lands there is born with a foreign price
on its canonical pool. Should the address be made unpredictable with `CREATE2`?

### Options

**A. Leave `CREATE`.** The prediction stands. Launches that were pre-seized reach
graduation through `GraduationHelper` on the canonical key, or through an
alternate key.

**B. `CREATE2` with a salt derived inside `TokenDeployer`** from values its caller
does not choose — for instance the calling curve's address together with the
parent block hash. **This needs no ABI change**: `deploy(string,string)` keeps
its signature and the salt never appears in it. Prediction then requires both the
parent block hash and the launch's own calldata, because the CREATE2 address
depends on the init-code hash and the init code carries `name`, `symbol` and the
curve address. The attacker's window collapses from "any time in advance,
untargeted" to "this block, after seeing a transaction that has not executed".

**C. `CREATE2` with a caller-supplied salt.** An ABI change, and worse than B for
a reason that has nothing to do with pool keys: a chosen salt is a vanity-address
grinder, and the addresses worth grinding are ones that resemble another launch's.
The protocol validates no name, symbol or metadata anywhere, so address
similarity is the one identifier a reader has left.

### Trade-offs

B is nearly free where it sits. `TokenDeployer` has 21,597 bytes of margin, so
nothing competes with it there, and the salt costs no interface. Against that, it
buys a race rather than a closure, and the value of the race is unknown until
somebody establishes whether a pending transaction is observable on this chain —
the first chain fact decision 22 asks for. A sequencer that knows the parent block
hash before it orders a transaction also knows the salt.

B has two second-order costs to write down. A `CREATE2` deployment to an address
that already has code fails, so two identical calls from the same caller in the
same block collide; for a launch this cannot happen, because every curve address
is distinct, and a stranger who collides has only refused their own second call.
And `blockhash` on a Nitro chain is not verified here to return what it returns
on L1, which is the second chain fact asked for.

A has one merit that is easy to miss: initialising at launch is still worth its
gas under A, because it moves the attacker from a targeted attack on a launch
they can see succeeding to an untargeted one on a nonce that may never be used by
a launch that may never reach its cap. Most launches do not graduate. That
argument is now the whole justification for initialising at launch, replacing the
false one, and it survives either option.

### Recommendation

**A for now, B when there is evidence the attack happens.** The evidence is what
decision 22's `PoolPreInitialized` event exists to produce: it fires only when a
launch found its canonical key already taken, so counting it over the first weeks
of testnet and mainnet answers whether this is a real behaviour or a reviewer's
proof of concept. Revisit when either that count is non-zero in normal operation
or the chain facts show that a pending transaction is not observable, which would
make B a near-closure rather than a race. Do not ship C.

A race is acceptable here, and the reason is worth stating precisely rather than
assumed: after decision 22, losing the race costs one extra graduation transaction
through a public helper, with no user funds at risk and no deadline. Before
decision 22 it cost the protocol its only entry point, and no race would have been
acceptable at that price.

---

## 24. The read side's two staleness thresholds

**RESOLVED 2026-11-11 by the protocol architect: one threshold, measured in
seconds. `STALENESS_BLOCK_WARN` is removed from `docs/DATA_MODEL.md` 1.7 and from
section 3.13's warning condition, and `STALENESS_WARN_SECONDS` moves to a default
of 10 with its upper bound tied to `QUOTE_TTL_SECONDS`.** Phase 2, blocks nothing,
and recorded because the shape of the defect is worth more than the constant.

### Question

`docs/DATA_MODEL.md` 1.7 defaulted `STALENESS_BLOCK_WARN` to 50 blocks and
`STALENESS_WARN_SECONDS` to 30 seconds, and section 3.13 warned on either. At the
0.104 s block time measured in `docs/CHAIN_FACTS.md`, 50 blocks is 5.2 seconds and
30 seconds is 288 blocks, so the block threshold fires roughly six times earlier
and the time threshold can never be reached. Should the two be made to agree, or
should one go?

### Options

**A. Make them agree**, by setting `STALENESS_BLOCK_WARN` to about 96 so that both
describe the same 10 seconds.

**B. Remove `STALENESS_BLOCK_WARN`** and warn on elapsed seconds only, keeping
`blocksBehind` as a displayed field in `IndexerStatus`.

### Trade-offs

A keeps two constants that must be held consistent by hand against a block time
that `docs/CHAIN_FACTS.md` is explicit about: 0.104 s is an observation with a
date on it, not a bound, and a sequencer or batch-posting change moves it. Two
constants describing one quantity in two units cannot be made to agree once; they
have to be re-agreed after every change to the conversion factor, and when they
drift the tighter one silently becomes the only one that fires while the looser
one still reads like a second safety net. That is the part of this defect that
outlives the constant: a reader who tunes the dead threshold changes nothing and
has no way to find out.

B cannot disagree with itself. It also measures the quantity a reader actually
has an opinion about — how old the number on the screen is — rather than how many
blocks of work the indexer is behind, which is the same quantity in a unit that is
not stable on this chain. The protocol already refuses block counts as a unit of
time in the contracts for the same reason (`docs/CHAIN_FACTS.md`); the read side
had no reason to be different. The cost of B is that an indexer that has stopped
while the chain keeps producing is detected by elapsed seconds rather than by
block distance, which detects it equally well and sooner.

The default moves from 30 seconds to **10**, and the bound becomes
`2 <= STALENESS_WARN_SECONDS < QUOTE_TTL_SECONDS`. The reason for the relation is
presentational coherence rather than taste: `QUOTE_TTL_SECONDS` is 15, so a
threshold at or above it would let a page display an unwarned price older than the
life of a quote shown next to it.

### Recommendation

**B**, taken now, since it is a deletion plus one default and nothing is built on
either constant yet.

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
| `PoolManager.initialize` with `hooks = address(0)` succeeds and leaves the pool with zero liquidity. | Spec 8.1 | Holds. `sqrtPriceTerminal` is exactly `5000 * 2**96` at the default and ticks 170352, 115135 and 207243 were reproduced; a second `initialize` on the same key reverts `PoolAlreadyInitialized`. **The conclusion drawn from that revert was wrong.** This row read "which is what makes initialising at launch an anti-grief measure", which held only while the key was believed to be unreachable before the launch transaction. It is reachable, the revert fires against the launch rather than against the attacker, and decision 22 is the correction: the launch tolerates an initialised key and the price property is carried by an assertion rather than by a race. |

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
