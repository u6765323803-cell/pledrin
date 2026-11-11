# Security review — 2026-11-11 — Phase 1, `contracts/src`

Reviewer: security-reviewer (read-only). Scope: every file in `contracts/src`,
reviewed against `docs/SPEC.md` and `docs/THREAT_MODEL.md`. `contracts/test/` was
not reviewed and no coverage figure is relied on here.

**Verdict: CHANGES REQUESTED.** Two high-severity findings, one medium, three low,
five informational. Findings 1 and 2 each falsify a load-bearing sentence in the
specification and the threat model; both are liveness attacks on the two
irreversible transitions, not fund loss.

---

## How the analysis was run

Isolated copy, so as not to contend for `contracts/out`:

```
mkdir -p <scratch>/sec && cd <scratch>/sec
cp -r /home/user/pledrin/contracts/src .
cp /home/user/pledrin/contracts/{foundry.toml,slither.config.json,remappings.txt} .
ln -s /home/user/pledrin/contracts/lib lib
slither . --config-file slither.config.json --fail-high
```

Real output, trailer only:

```
INFO:Slither:. analyzed (76 contracts with 102 detectors), 27 result(s) found
EXIT=0
```

Distribution by detector, from that run: `unused-return` 9, `timestamp` 8,
`reentrancy-benign` 4, `divide-before-multiply` 2, `incorrect-equality` 1,
`locked-ether` 1, `reentrancy-events` 1, `low-level-calls` 1. That is exactly the
table in `docs/SECURITY_NOTES.md`, and every one of the 27 carries a written
verdict there. No finding is ignored without a justification, and I did not find
a verdict I disagree with — with one correction, recorded as finding 11.

### The IR-coverage claim, re-derived rather than believed

- `grep -nE "ERROR|ContractSolcParsing|Impossible to generate IR|Traceback" ` over
  both streams of the run: **no match**. Zero parse errors.
- `slither . --print function-summary` lists all 44 members of `BondingCurve`,
  `_buy`, `_settle`, `_mintCore`, `_mintData` and `graduateAlt` included, and the
  `_settle` row carries IR temporaries (`TMP_1939`, `TMP_1952`) and resolved
  library calls — a row that exists only if the IR was built.
- Independent corroboration from the detector output itself: the
  `reentrancy-benign` finding enumerates the external calls *inside* `_mintCore`
  and the state writes in `_settle`, and the `timestamp` finding reports the two
  comparisons inside `_buy`. Those are IR-level facts about the three bodies that
  were previously missing.

The `SafeCast` binding was also checked against the compiler rather than against
the comment: `out/BondingCurve.sol/BondingCurve.json` declares
`SafeCastOverflowedUintDowncast`, `SafeCastOverflowedIntDowncast` and
`SafeCastOverflowedUintToInt` in its ABI — OpenZeppelin's four-error set — and
does **not** declare v4-core's `SafeCastOverflow`. The OZ uint-downcast selector
`6dfcc650` appears twice in the deployed bytecode. The named `using` directives
bind to OpenZeppelin, as claimed.

### Independent re-derivation of the graduation mint arithmetic

Run outside the project tree against the real Uniswap libraries
(`TickMath`, `SqrtPriceMath`, `LiquidityAmounts`, `FullMath`,
`FixedPointMathLib`), for the canonical spacing and for alternates 10–199, over
the whole permitted `virtualEthReserve` range plus a one-wei-stride walk across
the bottom of it, plus 50,000 fuzz runs:

| Quantity | Worst case found | Bound | Verdict |
|---|---|---|---|
| `LP_SUPPLY - amount1Required` (Invariant 39/60 dust) | 31,283 base units at `vE0 = 1.25e16 + 217` | `LP_DUST_MAX = 100,000` | holds, 3.2x margin |
| `R_target - amount0Required` (ETH headroom) | **171 wei** at `vE0 = 1.25e16`, spacing 10 | must be `>= 0` | holds, see finding 8 |
| floor range validity, single-sidedness, `_floorLiquidity` one-wei guard | no counterexample in 50,000 runs | Invariant 42 | holds |

The 28,428 / 1,088 / 240 dust figures quoted in SPEC 8.2 reproduce exactly at
`vE0 = 1.25e16`, `5e17` and `1.25e20`. The claim that the ETH headroom is not
monotone in `virtualEthReserve` I could not reproduce — over my sample it rose
monotonically from 171 to 17,205 wei — but the conclusion drawn from it
(`amount0Max` must stay at exactly `R_target`) is correct for a different and
stronger reason: at the bottom of the range the headroom is 171 wei, so any
tightening at all is unsafe.

### What I could not run

No RPC was available, so **nothing in this review verifies the fork-test claims**:
that the price-restoring swap settles for zero in both currencies against the
deployed PoolManager, the quoted tick-bitmap gas figures, and the behaviour of
`PoolManager.swap` at `amountSpecified = -1` in an empty pool. I read the v4-core
source and the arguments are consistent with it, but I did not observe them.
Findings 1, 2 and 3 do not depend on them.

---

## Finding 1 — HIGH — `_mintCore`'s ETH delta can be inverted by a third party, bricking every graduation path

**Location.** `contracts/src/BondingCurve.sol:709`, `:712-717`, `:719`; consequence
at `:645-646`. The other half of the mechanism is
`lib/v4-periphery/src/PositionManager.sol:499-502`.

```solidity
uint256 ethBefore = address(this).balance;          // 709
positionManager.modifyLiquidities{value: target}(   // 712
    _mintData(key, tickLower, tickUpper, liquidity, target, LP_SUPPLY.toUint128()),
    block.timestamp
);
ethUsed = ethBefore - address(this).balance;        // 719  <-- underflows
```

**Why it underflows.** The mint batch ends in `SWEEP(currency0, MSG_SENDER)`
(`_mintData`, `:825`). v4-periphery's sweep is not "return my unspent value", it
is *"Sweeps the entire contract balance of specified currency to the recipient"*:

```solidity
function _sweep(Currency currency, address to) internal virtual {
    uint256 balance = currency.balanceOfSelf();      // PositionManager's whole ETH balance
    if (balance > 0) currency.transfer(to, balance);
}
```

So with `S` = PositionManager's native balance at the moment of the call and
`U` = the ETH the core position actually consumes:

```
balance_after = balance_before - target + (target - U + S) = balance_before + S - U
ethUsed       = balance_before - balance_after = U - S
```

`U <= R_target` always (`validateMaxIn` caps it at `amount0Max = target`). Any
`S > U` makes line 719 revert with panic `0x11`, and with it `_settle`,
`graduate()` **and** `graduateAlt(any spacing)` — `_mintCore` is on both paths.
`S` is a globally shared balance that anyone can raise.

**Exploit path.** Target: any launch in `Graduating`; `R_target = 4 ETH` at the
default `vE0`, where the mint consumes `3,999,999,999,999,998,912` wei (measured,
see the table above).

1. Attacker raises PositionManager's native balance above that. Two routes, both
   permissionless and neither requiring any Pledrin interaction:
   - `positionManager.modifyLiquidities{value: 4.1 ether}(batch, deadline)` on
     any native-currency v4 pool, where `batch` is an ordinary
     `MINT_POSITION` + `SETTLE_PAIR` for a dust position and **no `SWEEP`**.
     `SETTLE_PAIR` settles only that position's debt; the rest of the forwarded
     value stays in PositionManager. This is exactly the leftover that `SWEEP`
     exists to collect, and the reason every v4-periphery example ends with one.
     (A `liquidity = 0` mint does *not* work as a parking route: v4-core's
     `Position.update` reverts `CannotUpdateEmptyPosition` on a fresh position,
     `src/libraries/Position.sol:86`.)
   - `SELFDESTRUCT` with PositionManager as beneficiary, which bypasses its
     `receive()` sender check entirely.
2. Anyone calls `graduate()`. Inside `_mintCore`: `ethBefore = B`;
   PositionManager holds `4.1e18 + 4e18`; it settles `U` to PoolManager and
   sweeps `4.1e18 + (4e18 - U)` back to the curve, which `receive()` accepts
   because the sender is PositionManager. Balance after is `B + 4.1e18 - U`,
   line 719 underflows, the transaction reverts.
3. `graduateAlt(10..199)` reverts identically. There is no third path.
4. After `GRAD_GRACE`, anyone — including the attacker — calls
   `abortGraduation()`. Resulting state: `state == Stalled`, `ethReserve` holding
   `R_target` plus the protection pool, bond credited back to the creator, **no
   Uniswap position, no locked liquidity, `Graduated` never emitted.** That is the
   outcome `docs/THREAT_MODEL.md` section 4.9 describes as losing "the thing that
   makes a graduated token tradeable at all".
5. The attacker recovers the parked ETH whenever it suits them, with
   `modifyLiquidities([SWEEP(native, attacker)])`.

**Economics, stated honestly.** The parked balance is sweepable by *anyone*, so an
attentive creator, holder or MEV searcher can take it (`>= R_target`) and then
graduate — which makes the attack expensive against a watched launch and free
against an unwatched one. The attacker needs the condition to hold only at the
moments someone attempts graduation, and a single parked balance above the
largest live `R_target` blocks every launch on the protocol at once. Independent
of any attacker, this also means an **accidental** stray balance left in
PositionManager by an unrelated v4 user — 0.1 ETH is enough for a minimum-size
launch — silently bricks that launch's graduation. The smallest permitted
`R_target` is 0.1 ETH.

**Second-order effect even when `S < U`.** `coreEth` is then under-reported by
`S`, so `floorEth` at `:645-646` is over-stated by `S` and the floor position
absorbs a third party's stray ETH. The curve's balance still covers it (Invariant
3 gives `balance >= protectionEth + ethReserve`), so nothing becomes insolvent,
but `Graduated.ethToCore` and `ethToFloor` are both wrong, and Invariant 60's
promise that `ethToCore` is independent of outside interference is false for ETH
even though it is true for tokens.

**Which claims this falsifies.**
- `docs/THREAT_MODEL.md` 6.6: *"Two adjacent underflows, neither reachable ...
  Neither can happen, because no code a third party controls executes inside that
  call."* The argument is correct for the token delta and does not transfer to the
  ETH delta, because the ETH increase needs no third-party code inside the window
  — PositionManager's own `SWEEP` carries it in, and the attacker acts before the
  window opens.
- `docs/THREAT_MODEL.md` 2.7: *"Forcing ETH into the curve ... cannot move any
  price."* True for pricing; `_mintCore` is the one place that reads
  `address(this).balance`, and it reads it for control flow.
- SPEC 8.2: *"`coreEth` is this contract's ETH balance before the call minus its
  balance after it ... This is normative and not an implementation choice."* The
  normative statement is what introduces the defect.
- `docs/THREAT_MODEL.md` 4.5's enumeration of what an attacker must do to block
  graduation. This bypasses all 190 keys with one deposit.

**Recommended fix** (for `contracts-engineer`; I have made no change). Stop
deriving `coreEth` from the curve's balance. The amount is deterministic once the
price is asserted equal to `sqrtPriceTerminal` at `:640-641`, so compute it with
the same function v4 charges with:

```solidity
uint256 ethRequired = SqrtPriceMath.getAmount0Delta(
    sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
);
```

and return that as `coreEth`. It is a pure function of immutables and constants,
it cannot be influenced, and it keeps `Graduated.ethToCore` honest. Any ETH swept
in on top then simply sits in the curve, where Invariant 43 already accounts for
"ETH that reached the curve outside its own paths".

If the delta form is kept for any reason, it must at minimum be saturating
(`balanceAfter >= ethBefore ? 0 : ethBefore - balanceAfter`) so that a stray
balance cannot revert graduation — but that still mis-reports the event and still
lets a stray inflate `floorEth`, so the deterministic computation is the better
fix.

**Suggested invariant.** Invariant 60 should quantify over a stray PositionManager
balance as well as a token donation: for any `S` held by PositionManager before
`graduate()`, the graduation's success, `positionIdCore`, `tokensToCore` and
`ethToCore` are identical to the `S = 0` case. That assertion fails on today's
code and would have caught this.

---

## Finding 2 — HIGH — the launch pool key *is* computable before the launch transaction, and seizing it bricks `createLaunch` protocol-wide

**Location.** `contracts/src/TokenDeployer.sol:23`
(`token = new PledrinToken(name, symbol, msg.sender);`),
`contracts/src/BondingCurve.sol:214` and `:226-229`.

**The false premise.** SPEC 8.1: *"The token address does not exist before the
launch transaction, so no attacker can reach the pool key first."*
`docs/THREAT_MODEL.md` 4.1: *"The token address does not exist before that
transaction, so the pool key is not computable before it, so there is no
window."* `docs/DATA_MODEL.md` 6.3 restates it as *"The launch's address is not
knowable before the transaction lands."*

A plain `CREATE` address is `keccak256(rlp([deployer, nonce]))[12:]`. Both inputs
are public: `TokenDeployer` is a singleton at a fixed address and its nonce is one
`eth_getTransactionCount` call away. The address of the token the *next* launch
will deploy is therefore computable by anyone, at any time, before any launch
transaction exists. Non-existence is not unpredictability.

**What the attacker gets.** Not the price — the launch reverts rather than
inheriting a hostile pool, so the conclusion *"no attacker can ever choose the
pool's initial price"* survives. What they get is a denial of service on the
protocol's only entry point. `Pool.initialize` reverts `PoolAlreadyInitialized()`
when `slot0.sqrtPriceX96 != 0`
(`lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol:101`), and
`PoolManager.initialize` is permissionless, so a pre-initialised canonical key
makes `BondingCurve`'s constructor revert, which reverts `createLaunch` for
whoever happens to land on that nonce.

**Exploit path, executed.** I ran this; it is not a thought experiment. Test file:
`<scratch>/sec/test/LaunchBrick.t.sol`, three tests, all passing. The real
`PoolManager` could not be compiled alongside the project (`pragma =0.8.26`
versus the pinned 0.8.38), so it is replaced by a 12-line stand-in that reproduces
the one behaviour involved — revert `PoolAlreadyInitialized()` when already
initialised — quoted verbatim from the vendored source above. Everything else is
the real `LaunchFactory`, `CurveDeployer`, `TokenDeployer`, `BondingCurve`,
`CreatorVesting` and `LiquidityLock`.

1. `test_happyPath_launchSucceeds` asserts the premise: the token address of a
   successful launch equals `vm.computeCreateAddress(tokenDeployer, 1)`, computed
   before the launch ran.
2. Attacker calls `poolManager.initialize(PoolKey(ETH, thatAddress, 10000, 200, 0),
   anyPrice)`. Measured cost in the harness: **47,027 gas**.
3. `factory.createLaunch(...)` by the creator reverts `PoolAlreadyInitialized()`.
4. **The revert rolls back `TokenDeployer`'s nonce**, so the next attempt by
   anybody targets the same poisoned address and fails the same way. The factory
   is bricked, not merely delayed.
5. Anyone can step past the poisoned slot by calling the permissionless
   `TokenDeployer.deploy("burn","BURN")` — measured **452,183 gas**, a throwaway
   ERC-20 — after which the next launch succeeds.
6. The attacker re-poisons the following slot for 47k gas. A roughly 10:1 cost
   asymmetry in the attacker's favour, indefinitely sustainable.
7. `test_attackerPoisonsManySlotsAhead` poisons eight consecutive future slots in
   one go and shows eight consecutive `createLaunch` failures, so there is no
   race to win: the attacker works ahead of the queue rather than front-running a
   victim's transaction, which also means an FCFS sequencer is no defence.

**Amplifier for finding 3.** The same prediction lets an attacker pre-initialise
the 190 *alternate* keys of a token address that does not exist yet, so a launch
can be born already unable to use `graduateAlt`, before anyone knows which launch
will land there.

**Recommended fix** (describe-only; pick one):
- *Preferred, smallest:* make the constructor tolerant instead of fatal — read
  `getSlot0` and skip `initialize` when the key is already initialised. The
  price property is then carried by the machinery that already exists for a
  griefed pool: `_settle` restores a zero-liquidity pool to `sqrtPriceTerminal`
  for free and asserts it at `:640-641`, with `graduateAlt` as the fallback. That
  converts a permanent factory brick into the already-analysed section 4.3 grief,
  and SPEC 8.1's conclusion is preserved by the assertion rather than by the
  race.
- Or make the key unpredictable to a pre-committing attacker: deploy the token
  with `CREATE2` from a salt that includes a value not knowable before the
  launch transaction executes. Note `docs/CHAIN_FACTS.md` constrains what is
  usable on this chain, and a same-block race remains; this is strictly weaker
  than the fix above.
- Either way, SPEC 8.1, THREAT_MODEL 4.1 and DATA_MODEL 6.3/APP-5 need the
  premise corrected: the key *is* computable, and what protects the price is the
  revert (or, after the fix, the restore-and-assert), not the absence of a
  window.

---

## Finding 3 — MEDIUM — all 190 alternate pool keys can be blocked for gas alone, so the documented escape from a graduation grief is not the escape it is costed as

**Location.** `contracts/src/BondingCurve.sol:630-634`.

```solidity
(uint160 existing,,,) = poolManager.getSlot0(id);
if (existing != 0) revert AltPoolInitialized();
```

`docs/THREAT_MODEL.md` 4.5 costs the attack as: *"An attacker must therefore
pre-initialise **and hold hostile liquidity** on all 190 keys, continuously, for
as long as the launch exists ... Each instance is a losing position."* The code
requires no liquidity for the block. A bare `initialize` — ~50k gas, no capital,
no position, nothing at risk — permanently removes that spacing from the usable
set. 190 of them is one transaction batch and pennies on this chain.

The canonical key is comparably cheap to hold hostage. `graduate()` reverts
`SwapNotFree` whenever the restoring swap crosses *any* liquidity, and the
restoring swap nominates one wei of exact input, so **one wei of liquidity**
anywhere between the pool's current price and `sqrtPriceTerminal` is enough; the
price itself moves for free in an empty pool (4.2). "A losing position" overstates
a dust position nobody will arbitrage.

Combined: every documented graduation path is closed at a cost that is pure gas
plus dust. What actually saves graduation is a mechanism the documents do not
mention: because restoring a griefed price is free and permissionless, any third
party can move the canonical pool back to `sqrtPriceTerminal` and call
`graduate()` — atomically, from a helper contract, which defeats the re-grief
race. No such helper exists in this repository, and nothing in the specification
says a graduation may need one.

Impact is liveness only: no user funds are at risk at any point, state stays
frozen in `Graduating`, and after `GRAD_GRACE` the launch stalls. Medium rather
than high because the atomic-restore escape genuinely exists and finding 1 is the
cheaper and more complete version of the same denial.

**Recommended fix.** Do not treat "initialised" as disqualifying by itself. The
reason the check exists is gas — the restoring swap's tick-bitmap walk is
expensive at small spacings (4.5's own 173k/2.33M figures) — not safety, since
the zero-delta assertion at `:467-469` and the price assertion at `:640-641`
already make a hostile price harmless.

1. *The actual fix:* accept an initialised alternate key that has **zero
   liquidity**, and run the same restore-and-assert path on it that the canonical
   key already gets. The caller chooses the spacing, so they choose the gas; a
   griefer can then raise the cost of a particular key but cannot remove it from
   the set. The gas-exhaustion concern is preserved as a cost the caller opts
   into rather than a path the protocol forfeits.
2. *Necessary but not sufficient on its own:* also accept an initialised key
   whose `sqrtPriceX96` already equals `sqrtPriceTerminal`, which needs no
   restore at all. Note this does **not** close the finding by itself — an
   attacker simply initialises at some other price — so it is worth having only
   alongside option 1.
3. *Whatever lands:* revise 4.5 to state the real cost (gas per key, no capital,
   nothing at risk, and one wei of liquidity on the canonical key) and document
   the atomic restore-and-graduate recovery as a supported path, with a test that
   exercises it.

---

## Finding 4 — LOW — anyone can zero the graduation bounty for the price of gas

**Location.** `contracts/src/BondingCurve.sol:405-412` and `:647-649`.

`claimProtocolFees()` has no caller restriction — correctly, since it pays the
immutable `protocolTreasury` — and the graduation bounty is
`floor(protocolFeeEth * 1000 / 10000)` read at graduation time. `Graduating`
admits no trade, so `protocolFeeEth` cannot grow again. A griefer who calls
`claimProtocolFees()` in the block after the cap is reached therefore sets the
bounty to zero permanently, at no cost to themselves and with the treasury, not
the griefer, receiving the ETH.

This falsifies SPEC 8.3's *"The bounty exceeds the gas cost by more than an order
of magnitude ... so there is always an economic actor willing to call it"* and
THREAT_MODEL 4.6's reliance on it. Low, because graduation gas is quoted at
~0.00004 ETH and every holder and the creator have a direct interest in the pool
existing, so the altruistic caller is cheap to find — the bounty is a convenience,
not the only incentive. But the sentence should not be left standing as written.

**Recommended fix.** Either snapshot the bounty when the cap is reached (set a
`pendingGradBountyWei` in `_buy`'s cap branch, deducted from `protocolFeeEth`
there) and pay that at graduation, or state in SPEC 8.3 that the bounty is
best-effort and can be zeroed by a third party.

---

## Finding 5 — LOW — a forfeited bond is substantially capturable by a deadline sniper

**Location.** `contracts/src/BondingCurve.sol:362-389` (`expire`), with
`docs/SPEC.md` 11.4.

SPEC 11.4: *"The forfeited ETH is donated into the curve reserve, which raises the
exit price for every holder immediately."* It does — including for a holder who
became one seconds earlier precisely to collect it.

**Path.** Let `E0 = vE0 + ethReserve` just before the deadline and
`D = bondHeldWei + creatorFeeEth + protectionEth`. In the last block with
`block.timestamp < gradDeadline`, the sniper buys with `x` wei of ETH to the
curve. In any later block they call `expire()` (permissionless) and sell
everything back. The curve's own algebra gives, exactly:

```
gross on the way out = x + D * x / (E0 + x)
profit              = D * x / (E0 + x)  -  round-trip fees (~2 * totalFeeBps of x)
```

So the snipe pays whenever `D / (E0 + x) > 2 * totalFeeBps`, and a sniper sized
at `x = E0` takes half of `D`. The bond floor is
`max(MIN_BOND_WEI, R_target/10) = max(1e16, 0.8 * vE0)` and `E0 = vE0 +
ethReserve` with `ethReserve < R_target = 8 * vE0`, so at the default 100 bps fee
the inequality holds at some `x` for **every** launch that posted a bond. The
worst case is a bonded launch that got little traction: with `ethReserve ~ 0`, a
sniper risking `0.125 * R_target` for one block takes roughly half the bond.

No protocol funds are at risk; this is a redistribution from the holders the bond
exists to compensate to a party who bore no exposure. Low severity, and it is the
mirror image of a trade-off the project already makes explicitly — SPEC 10.2
rejects snapshots, and 10.4 says the protection pool "does not compensate an
individual for a loss". The gap is that 11.4 does not say the same about the bond,
and section 11.1 presents the bond as reaching harmed holders.

**Recommended fix.** Document it in THREAT_MODEL section 10 next to 10.1–10.3,
which is where this class of statement already lives. If a mechanism is wanted
rather than a disclosure, the only snapshot-free option that helps is making the
distribution gradual (e.g. the forfeited amount vesting into `ethReserve`), which
is a design change and out of scope for Phase 1.

---

## Finding 6 — LOW — `abortGraduation` is available even when graduation would succeed, and a large holder can prefer that

**Location.** `contracts/src/BondingCurve.sol:338-342`.

The only preconditions are `state == Graduating` and `GRAD_GRACE` elapsed. There
is no check that graduation actually failed, so after seven days any address can
convert a healthy capped launch into `Stalled` and deny it a pool. THREAT_MODEL
4.9 argues the creator gains nothing by this, which is right, but the argument is
made only for the creator.

For a large holder it is not neutral. At the cap the curve's remaining virtual
token reserve is `VIRTUAL_TOKEN_TAIL = 112.5e24` against the pool's
`LP_SUPPLY = 100e24` at the same marginal price, so a holder exiting a large
fraction of supply gets slightly more out of the curve in `Stalled` than out of
the pool after graduation (selling 112.5M base units: `0.5625 * R_target` from the
curve versus `~0.53 * R_target` from the core position, before the floor bid and
before fees). Small exits are identical by construction. So a whale has a mild,
real incentive to stall — which, combined with findings 1 and 3, is motive plus
means.

Low: the margin is small, the window is seven days of public opportunity to
graduate first, and `Stalled` is a designed state that harms no balance.
**Recommended fix:** none in code; extend 4.9's "gains nothing" analysis to a
large holder rather than the creator alone, so the incentive is on the record.

---

## Finding 7 — INFORMATIONAL — the core mint has 171 wei of ETH headroom at the smallest permitted launch

Measured, not estimated: at `vE0 = MIN_VIRTUAL_ETH_RESERVE` and alt spacing 10,
`amount0Required = R_target - 171`. If that number ever goes negative,
`validateMaxIn` reverts the mint, graduation is impossible for that launch, and
the only exit is `abortGraduation`. It depends on nothing an attacker controls, so
it is a parameter-range property rather than a vulnerability — but a 171-wei
margin on an unrecoverable failure deserves to be pinned rather than inferred.
**Recommended:** a test that asserts the exact `amount0Required` at
`virtualEthReserve == MIN_VIRTUAL_ETH_RESERVE` for both spacing 200 and spacing
10, so that a library bump that changes a rounding direction fails loudly. SPEC
8.2's non-monotonicity claim should also be restated as the stronger and verified
fact: the headroom is 171 wei at the bottom of the range.

## Finding 8 — INFORMATIONAL — Invariant 34 is false as literally written

*"`Graduating` requires `tokensSold == CURVE_SUPPLY && block.timestamp <
gradDeadline`."* The second conjunct is a condition on the *transition*, not on
the state: `MIN_GRAD_WINDOW` is one day and `GRAD_GRACE` is seven, so any launch
that reaches its cap near the deadline sits in `Graduating` long past
`gradDeadline`, legitimately and with no grief involved. A test that asserts this
as a state predicate will fail on honest behaviour; one that passes is probably
asserting the transition. **Recommended:** reword to "the transition into
`Graduating` requires ...".

## Finding 9 — INFORMATIONAL — `_buy` discards `_accrueFee`'s redirect

`contracts/src/BondingCurve.sol:555` calls `_accrueFee(fee, State.Live)` and drops
the returned `feeToReserve`. That is correct today — the function returns zero in
`Live` and `_buy` runs only in `Live` (`:526`) — and the comment says so. It is
noted because the post-terminal redirect is new this phase and the safety of the
discard is a two-step argument; a future caller in another state would silently
strand the redirected wei in no bucket at all (without breaking Invariant 3).
**Recommended:** either assert `feeToReserve == 0` or add it to `reserveAfter`,
so the call site is correct by construction rather than by context.

## Finding 10 — INFORMATIONAL — no on-chain view reports the pool a launch actually graduated on

`poolId()` (`:515-517`) always returns the canonical key, which after a
`graduateAlt` is a pool with no protocol liquidity and possibly hostile dust in
it. The interface documents it as "the primary pool key" and `DATA_MODEL.md`
IDX-18 already tells the indexer to prefer `Graduated.poolId`, so this is a trap
only for an integrator reading the chain rather than the logs. **Recommended:**
store the graduated `tickSpacing` (or the `PoolId`) at `_settle` and expose it, or
note in the interface doc that the graduated key is only available from the event.

## Finding 11 — INFORMATIONAL — the `reentrancy-balance` suppression should stay, but its verdict needs one sentence corrected

`docs/SECURITY_NOTES.md` section 2 is right about what the detector found: the
*token* delta at `BondingCurve.sol:710/720/722` cannot be influenced by a
donation of any size, both failure directions fail closed, and the delta form is
load-bearing and must not be simplified. I tried to falsify it and could not. The
Permit2 observation at the end of that verdict is also correct, and the corrected
account of `_mint` versus `safeTransferFrom` checks out against
`lib/v4-periphery/src/PositionManager.sol:369` and solmate's `_mint`.

The sentence that needs qualifying is the generalisation: *"No third party can
execute anything in that window."* It is true, and finding 1 shows it is not
sufficient — the ETH reading two lines above the suppressed one is influenced
without executing anything in the window, by PositionManager's own `SWEEP`
carrying in a balance that was established before the call. **Recommended edit to
`docs/SECURITY_NOTES.md` section 2** (I did not make it; I may only write under
`docs/security/`): scope the in-window argument to the token delta, and add that
the ETH delta on line 719 is *not* protected by it, cross-referencing finding 1
and whatever fix lands. Leaving the verdict as it stands would let the next
reader conclude that both deltas were reviewed under the same argument.

---

## Checks that passed

Recorded so the review is falsifiable in both directions. Each of these I
followed through the code rather than taking from the documents.

**Curve solvency.** Invariant 1 is maintained by every path: buys
(`tokensOut` floored, `feeMax` ceiled), sells (`ethGross` floored), `donate`,
`expire`, `abortGraduation` and the post-terminal redirect, which only adds to
`ethReserve`. Invariant 2 follows from Invariant 1 with the inequality tight, and
`tokensIn <= tokensSold` is enforced (`:267`). Invariant 13 (`ethReserve >=
ethTarget` at the cap) holds in **both** branches of `buyQuote`, which is what
makes `ethReserve - ethTarget` at `:646` safe: the clipped branch gives
`E_new >= E * T / tau >= 9 * vE0` directly from Invariant 1, and the exact-fit
branch gives the same bound from `tokensOut == remaining`.

**Fee split.** `protectionCut` is the residual, so the three parts sum to `fee`
for every input, and the four `FeeAccrued` amounts sum to `fee` in all five
states — `Live` (`reserveCut = 0`), `Expired` (`creator + protection`
redirected), `Stalled` (`protection` redirected), and `Graduating`/`Graduated`,
which `_accrueFee` is unreachable in. Rounding always moves dust toward the
holder-protection residual, so grinding donates to holders; buy fees round up,
`tokensOut` and `ethGross` round down. No path lets a trader extract a rounding
remainder. Invariants 14, 17, 59 hold.

**Post-terminal redirect and graduation arithmetic.** The redirect fires only in
terminal states, which are unreachable from `Graduating`, so it cannot touch
`_settle`'s arithmetic. It raises the solvency product. `ethReserve` as `uint128`
cannot be overflowed by any reachable donation.

**Bond lifecycle.** `bondState` leaves `Bonded` at most once: `_returnBond`
(`:831-843`) early-returns on `held == 0` and is reachable from `_settle` and
`abortGraduation`, which are mutually exclusive by state; `expire` requires
`Live`. `pendingBondWei` is assigned, never accumulated, and zeroed by
`claimBond`, so a second claim hits `BondAlreadyClaimed`. Every payment goes to
the immutable `creator`. `claimBond`'s four refusals map exactly onto Invariant
63, and `CreatorVesting.release`'s four onto Invariant 62. Invariants 25, 26, 27,
29 hold.

**Liquidity lock has no exit.** No `transferFrom`, `safeTransferFrom`, `approve`,
`setApprovalForAll`, `permit` or `BURN_POSITION` anywhere in the file; the single
`DECREASE_LIQUIDITY` carries `uint128(0)` as a literal in the encoding
(`LiquidityLock.sol:151`), in the position the v4 decoder reads liquidity from.
`compound` forwards no value and holds no Permit2 approval, so a currency1 debt
would revert rather than spend anything, and `CLOSE_CURRENCY` can only pay the
lock. `registerPosition` is permissionless but can only name a position the lock
already owns, and cannot be used to pre-empt a graduation's `positionId` because
that id does not exist until the mint inside the same transaction
(`nextTokenId++` at `PositionManager.sol:366-369`). A donated NFT is inert:
`onERC721Received` is `external view`. No value leaves the lock on any path.

**Timelock and the four powers.** `DELAY` is a constant, `readyAt` is set to
`now + DELAY`, `execute` clears the record before calling, `setAdmin` is
self-call-only so the admin's own rotation waits out the delay, and nothing
shortens or bypasses it. `transferOwnership` reverts while OZ's
`renounceOwnership` still works, because the override is on the public function
and `renounceOwnership` goes through `_transferOwnership`. No power reaches user
funds: the factory copies every launch parameter into immutables, has no
curve-facing function other than `creatorFirstBuy` (which is factory-only and
reachable only while `tokensSold == 0`, itself reachable only inside
`createLaunch`), and `tokenDeployer`/`curveDeployer`/`vesting`/`liquidityLock` are
immutable with no setter. Invariants 51, 52, 53 hold. Worth knowing: the timelock
is a *general* executor, not restricted to the factory, so SPEC 14's "its
authority is exactly the four `onlyOwner` functions" is true only because no other
contract trusts `msg.sender == timelock` and it holds no value — a future contract
that does would inherit this surface.

**Reentrancy and call discipline.** Every value-moving external function holds
`nonReentrant`; `unlockCallback` holds none deliberately — it is entered while
`graduate` holds the guard — and is gated on `msg.sender == poolManager` **and**
the transient `_unlocking` flag, which is set only by `_restorePrice`. Invariant
55's strict form holds in `buy`, `sell`, `donate`, `creatorFirstBuy`, all four
claims, both `CreatorVesting` value movers and `compound`, and I confirmed the
relaxation is confined to the two places named: `_settle` (`floorEth` needs the
mint's result) and `createLaunch` (`isLaunch` cannot precede the curve). `expire`
and `abortGraduation` in fact satisfy the strict form. The launch token is a
featureless OZ ERC-20 with no hook, so token movement is not an entry point, and
every `approve`/`transfer`/`transferFrom` return value is checked.

**Quality bar.** No loops anywhere in `src`, so nothing unbounded. No
`require`/string reverts — custom errors only. No `block.number`, no `tx.origin`,
no `selfdestruct`, no `delegatecall`, no assembly, no proxy, no initialiser. Every
state change emits an event, including both terminal-fee redirects via
`FeeAccrued.reserveCut`.

**Vesting.** Schedules are keyed by `msg.sender`, funded from `msg.sender` in the
same call, and cannot be created for an address the caller does not control, so
the contract is safely permissionless. `start`/`void` are mutually exclusive on a
real launch's state machine. A malicious caller can only harm its own schedule,
and a malicious token passed to `createSchedule` gets control only during a call
already protected by the guard and keyed to itself. `CREATOR_FIRST_BUY_MAX` is
enforced after the buy, so the refund case the comment rules out is additionally
unreachable, and a second first buy is blocked twice over (`tokensSold != 0` and
`ScheduleExists`).

**Reputation.** Counters are monotone, have no setter, and are written only by
`isLaunch` curves; at most one terminal outcome per launch, so Invariant 49 holds.
Farming is possible and already acknowledged in THREAT_MODEL 10.2 — for the
record, the computed cost of a self-dealt "graduation" is roughly 11–13% of
`R_target` (buy the curve out, then dump the whole sale supply into the core
position), which is the number the wei-denominated counters are worth reading
against.

---

**Verdict: CHANGES REQUESTED.**

Findings 1 and 2 must be fixed before testnet; each is a cheap, protocol-wide
denial of one of the two irreversible transitions, and each rests on a
specification sentence that is wrong rather than on an implementation slip.
Finding 3 should be fixed or re-costed in the same pass, since it is the
documented escape hatch for the grief class findings 1 and 2 live in. Findings 4
to 6 can be closed by a code change or by an honest sentence in
`docs/THREAT_MODEL.md`, but not by silence. Findings 7 to 11 are documentation,
test-pinning and one SECURITY_NOTES correction.

Nothing in this review found a path to taking another party's funds, a reentrancy
hole, a fee-split leak, an admin power over user value, or an exit from
`LiquidityLock`.
