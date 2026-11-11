# Security review — 2026-11-11 — Phase 1 close

Reviewer: security-reviewer (read-only). Branch `feat/contracts-core`, HEAD
`78c880e`, working tree clean at the start and at the end of this review.

Scope. Every file in `contracts/src` at `78c880e`, read against `docs/SPEC.md`
and `docs/THREAT_MODEL.md`. This is a re-review of
`docs/security/REVIEW-2026-11-11-phase1-contracts.md`, which returned **CHANGES
REQUESTED** on two high findings, one medium, three low and five informational.
It additionally reviews one contract that did not exist then
(`contracts/src/GraduationHelper.sol`) and the test code that supports the
claims about it, which the previous review deliberately did not read.

**Verdict: CHANGES REQUESTED** — narrowly. Every blocking finding of the
previous review is closed, the new contract holds up against the attacks I
could construct, and **no finding in this review asks for a contract change.**
What blocks is five statements in `docs/` that are false or unqualified against
code I read, four of which this reviewer reported on 2026-11-11 and which were
answered with silence rather than with a sentence. The full statement of what
clears it, and of what an approval here would and would not mean, is at the end.

---

## 1. How this was run, and what came back

Every figure below is from a command run on this tree during this review, not
from a commit message. Commands were run from `contracts/`.

| Command | Result |
|---|---|
| `forge fmt --check` | exit 0, no output |
| `FOUNDRY_PROFILE=ci forge build --sizes` | exit 0 |
| `FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*"` | `Ran 30 test suites in 322.59s: 397 tests passed, 0 failed, 0 skipped (397 total tests)`, exit 0 |
| `FOUNDRY_PROFILE=ci forge test --match-path "test/fork/*" --rpc-url robinhood` | `Ran 4 test suites in 35.56s: 43 tests passed, 0 failed, 0 skipped`, exit 0 |
| `FOUNDRY_PROFILE=default forge coverage …` | exit 0 |
| `../.github/scripts/coverage-gate.sh lcov.info 95` | `lines 99.86% (693/694)`, `branches 98.72% (154/156)`, `coverage-gate: pass`, exit 0 |
| `slither . --config-file slither.config.json --fail-high` | `. analyzed (77 contracts with 102 detectors), 36 result(s) found`, exit 0 |

Sizes, from the `--sizes` table:

| Contract | Runtime | Initcode | Runtime margin |
|---|---|---|---|
| `CurveDeployer` | 23,556 | 23,582 | **1,020** |
| `BondingCurve` | 18,718 | 22,703 | 5,858 |
| `GraduationHelper` | 4,466 | 4,492 | 20,110 |

Coverage, `src` only, from the summary report: `GraduationHelper` 100% of lines
(80/80), statements (103/103), branches (22/22) and functions (11/11);
`BondingCurve` 339/340 lines and 72/73 branches; `CurveMath` 1/2 branches.
Whole-tree functions 100% (94/94).

**The two uncovered items, located rather than inferred.** Parsing `lcov.info`
directly for zero-hit records in `src/` returns exactly three lines, and nothing
else:

```
uncovered branch src/BondingCurve.sol   ['923', '63', '0', '0']
uncovered line   src/BondingCurve.sol   924
uncovered branch src/libraries/CurveMath.sol ['58', '1', '0', '0']
```

Those are `_floorLiquidity`'s one-wei fallback and `CurveMath`'s
`InsufficientValue`, at the exact lines `docs/SECURITY_NOTES.md` section 4
names. The claim that the only unreached branches are the two proved
unreachable is therefore true on this tree, and the two proofs are assessed in
section 3.3.

### The analyser was analysing the whole program

Because this repository has been burned by a clean-looking Slither run over an
incomplete model, that was checked first and separately from the exit code:

- `grep -nE "ERROR|ContractSolcParsing|Impossible to generate IR|Traceback|NoneType"`
  over both streams of the run: **no match**. Zero parse errors.
- The finding set itself is evidence of IR for the bodies that used to be
  missing: `reentrancy-benign` reports the writes inside `_settle` and both
  `_restorePrice` bodies, `timestamp` reports the comparisons inside `_buy` and
  `_settle`, and `unused-return` reports five destructurings inside
  `GraduationHelper`.
- Counted per detector by parsing the report rather than by adding up deltas:

```
divide-before-multiply 2   unused-return      14   reentrancy-events 1
incorrect-equality     1   calls-loop          1   cyclomatic-complexity 1
locked-ether           1   reentrancy-benign   5   low-level-calls 2
timestamp              8                           TOTAL 36
```

That matches `docs/SECURITY_NOTES.md`'s table finding for finding and detector
for detector, and every one of the ten detectors carries a written verdict in
section 2 of that document. **No static-analysis finding on this tree is
ignored without a justification.** I did not find a verdict I disagree with; two
of them I would sharpen, and that is findings 7 and 8 below.

### Two experiments, because three findings are suppressed rather than absent

1. `slither . --config-file slither.config.json --warn-unused-ignores` reports
   exactly two unused directives, both in vendored OpenZeppelin
   (`lib/openzeppelin-contracts/contracts/utils/Panic.sol#25`), and **none in
   `src`**. All three suppressions in `src` are therefore consumed: the findings
   they name really exist and really are being suppressed.
2. I copied `src` to a scratch directory, deleted the three
   `slither-disable-next-line` comments **in the copy only**, and re-ran the
   same command. Exit code **255**, and the three additional findings are
   exactly:

```
Detector: arbitrary-send-eth
GraduationHelper._settleEth(IPoolManager,uint256) sends eth to arbitrary user
	- manager.settle{value: owed}()
GraduationHelper._forward(IERC20,uint256,uint256) sends eth to arbitrary user
	- (ok,None) = msg.sender.call{value: ethAmount}()
Detector: reentrancy-balance
Reentrancy in BondingCurve._mintCore(PoolKey,int24):
	- Possible stale balance used after the call in a condition: remainder > LP_DUST_MAX
```

So the suppressions are accurate, minimal and three in number; nothing else is
hidden behind them; and `--fail-high` does fail on a high in `src`. The gate is
real.

### Disclosure of one procedural slip of my own

While verifying the ABI claim I ran `.github/scripts/freeze-abi.sh` against a
scratch build. That script **writes** `contracts/abi/`, which is outside the one
directory I am permitted to write, and I should not have run it. The output was
byte-identical to the committed files: `git status --porcelain` and
`git diff --stat` are both empty afterwards and `HEAD` is still `78c880e`, so no
tracked content changed. It does corroborate the commit's claim that all nine
ABI files regenerate byte-identically, but it was not mine to verify that way.

### What this review did not verify

- The 10,000-run fuzz and 1,000x150 invariant campaigns were run, not audited
  line by line. I read four handlers and two invariant contracts; the rest of
  `contracts/test` I sampled.
- `contracts/script/` is empty, so nothing about deployment, wiring order or
  ownership hand-off is reviewed here. No contract in this tree has been
  deployed to any network.
- The chain facts in `docs/CHAIN_FACTS.md` (gas prices, finality, mempool
  visibility) are inputs I take as given.
- Uniswap v4 itself. I read the vendored sources the arguments below depend on
  and name the lines; I did not audit v4.

---

## 2. The three findings that returned CHANGES REQUESTED are closed

**Finding 1 (HIGH, the core mint's ETH cost read from a balance) — fixed.**
`contracts/src/BondingCurve.sol:827-829` now computes the cost instead of
measuring it:

```solidity
ethUsed = SqrtPriceMath.getAmount0Delta(
    sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
);
```

That is the recommended fix verbatim, and it is the quantity v4-core charges:
`SqrtPriceMath.getAmount0Delta(a, b, L, true)` is
`divRoundingUp(mulDivRoundingUp(L << 96, b - a, b), a)`
(`lib/v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol:188-210`), and
`Pool.modifyLiquidity`'s in-range add calls the signed overload, which takes the
same `roundUp = true` magnitude. The position is full-range, so the in-range
branch is the only reachable one, and `_settle` asserts
`price == sqrtPriceTerminal` immediately above. No balance is read for control
flow on this path any more.

Two things make the fix more than a patch, and both check out:

- `MockPositionManager._sweep` now sends the whole balance
  (`contracts/test/mocks/MockPositionManager.sol:377-393`), with the old model
  named as the reason the defect was invisible, and the mock's header now marks
  each modelled behaviour `verified` or `inferred`.
- `contracts/test/helpers/PreFixCoreMint.sol` keeps the removed expression alive
  next to the landed one and returns both from one mint, so the harness is held
  honest by an equality that fails if the batch, ticks, liquidity or rounding
  drift from `_mintCore`'s. That is a real negative control: it is what makes
  "7 of 10 tests fail against the pre-fix contract" a measurement rather than an
  assertion.

Invariant 70 is the second half of the fix, and it holds for the reason it
states: nothing between the two mints can give PositionManager a native balance
(`_approve(0)`, `liquidityLock.registerPosition`, `getSlot0`, `nextTokenId`, and
arithmetic — no third-party code), so the floor mint's delta measures the floor
mint alone.

**Findings 2 and 3 (HIGH and MEDIUM, the pool-key precondition) — answered.**
Verified in code, not in prose:

- `BondingCurve.sol:234-243` reads `getSlot0` and calls `initialize` only when
  `opened == 0`, emitting `PoolPreInitialized` otherwise. It is a test on
  `slot0` and not a caught revert, so every other failure of `initialize` still
  reverts the launch (Invariant 65). An unopened v4 pool cannot report a
  non-zero `sqrtPriceX96`, and `extsload` against an immutable address cannot be
  made to revert, so the test cannot be gamed in either direction.
- `_settle` places one precondition on its key for both paths
  (`:698-711`): open it if `current == 0`, else restore if
  `current != sqrtPriceTerminal`, then assert. `AltPoolInitialized` is gone from
  the interface. Nothing reads the pool's liquidity anywhere.
- `graduateAlt(uint24 fee, uint24 tickSpacing)` ranges over
  `fee ∈ [3000, 10000]` and `tickSpacing ∈ [10, 200]`, refusing the single pair
  `(POOL_FEE, POOL_TICK_SPACING)`. `7001 × 191 − 1 = 1,337,190`, as claimed.
  Both fields are narrowed through `SafeCast`, the key `attemptCandidate` builds
  and the key `graduateAlt` builds agree field for field, and the fee range
  cannot reach v4's dynamic-fee flag (`0x800000`), which with `hooks == 0` would
  make `initialize` revert.
- `GraduationHelper` is the specified escape and is assessed below.

The spec and threat-model premises that these findings falsified have been
withdrawn rather than quietly edited (`SPEC.md:27`, `THREAT_MODEL.md:12`, 4.1,
4.3, 4.5, 4.10, 5.2, 10.9). 10.9 in particular states the residual race, says
the chain fact that would settle it is still missing, and declines to treat a
missing RPC method as mempool privacy. That is the right standard.

Previous finding 7 (the 171-wei headroom) is now pinned by
`contracts/test/unit/CoreMintArithmetic.t.sol:79,152` and by
`test/fork/GraduationRange.fork.t.sol:100` — 171 wei at spacing 10, 172 at the
canonical spacing, and the worst case located at the bottom of the range.
Previous finding 11 is corrected in `docs/SECURITY_NOTES.md` section 2, with the
in-window argument scoped to the token delta, as asked. Previous finding 10 is
closed by documentation and by the two new `Graduated` fields (Invariant 69):
`poolId()` still returns the canonical key always, but the interface now says
"canonical" and the graduated key is reconstructible from one log.

---

## 3. The six things I was asked to disbelieve

### 3.1 The loss bound on `GraduationHelper` — it holds, and here is the theorem it holds as

I attacked the claim rather than the tests. The adversary I assumed is the
strongest one the design admits: the caller names `curve`, so the adversary
supplies `curve.token()`, `curve.poolManager()`, `curve.sqrtPriceTerminal()`,
`curve.graduate()`, `curve.graduateAlt()` and `curve.claimBounty()`, and
therefore controls every `swap`, `take`, `settle`, `sync`, `getSlot0`,
`balanceOf`, `transfer` and `transferFrom` the helper calls, chooses when and
how often `unlockCallback` is invoked while `_unlockManager` is set, and chooses
that callback's entire payload — including both currencies of the key, which the
helper then settles.

**What I verified.** For any such adversary and any interleaving:

1. Every ETH payment out is capped at a balance the helper holds at that
   instant: `_settleEth` refuses when `owed > address(this).balance`
   (`GraduationHelper.sol:339-340`) and `_forward` sends a balance it is not
   entitled to keep (`:416-425`).
2. Every token payment out is capped the same way, against `balanceOf(this)` of
   the currency named in the payload (`:354-355`), so a forged currency reaches
   only a balance the helper already holds.
3. The caller's allowance is touched exactly once, by the single
   `transferFrom(msg.sender, address(this), maxTokensIn)` at `:161`. That line
   is reachable once per transaction, and three gates make it so: the transient
   `nonReentrant` on `graduateVia` (`:150`), `msg.sender != address(this)` on
   `attemptCandidate` (`:212`), and `msg.sender != _unlockManager` on
   `unlockCallback` (`:256`). Transient storage reverts with the frame, so a
   failed candidate also restores the flag.
4. The contract grants no allowance to anybody: there is no `approve` call in
   the file at all. So nothing it touches can spend from it after the call.
5. `_forward` pays `msg.sender`, which inside a private call from `graduateVia`
   is that call's own caller, and then reverts `BalanceNotZero` unless the
   helper ends empty in ETH and in `curve.token()`.

Therefore the caller's loss of value is at most `msg.value` in ETH and at most
`maxTokensIn` in the token, separately as well as jointly. The bound is
structural, not behavioural: it does not depend on the curve behaving, on the
token behaving, or on the caller's approval hygiene.

**The load-bearing gate is the reentrancy guard, and it is load-bearing for a
different reason than it looks.** Without it, a hostile PoolManager holding
control inside `settle` could re-enter `graduateVia`, and the re-entrant call
would pull against the caller's *standing allowance* and then `_forward` the
proceeds to itself as `msg.sender`. That is the weaker, allowance-shaped bound
spec 8.6 step 1 exists to refuse, and the guard plus the single-pull structure
is what refuses it. `docs/THREAT_MODEL.md` 4.10 states this correctly, including
that a standing approval to a *hostile copy* of the helper is outside the
guarantee.

**Three things the claim does not cover, and one of them a caller will
misread.** See findings 8 and 11. In short: gas is unbounded; the *quality* of
the trade is not bounded (only its size is); and a stray balance in a currency
other than `curve.token()` is reachable by an arbitrary address.

**What would break it**, so that a future change is measured against something:
a second `transferFrom(msg.sender, …)` site anywhere; a cap written against a
remembered amount while the spend is a balance, or the reverse; any `approve` in
the file; moving `_claimBounty` or `_forward` inside a lock; `_forward` paying
anything but `msg.sender`; or the guard becoming non-transient — which would
keep the bound and break Invariant 68(c), which is precisely the failure mode
that clause was written to catch.

Two smaller properties I checked because the design leans on them and neither is
asserted in prose: **all spending happens inside the winning candidate**
(a failed attempt reverts its own frame, and the only value movement outside
`attemptCandidate` is the bounty claim and the forward), so on a real curve there
is no path in which the caller pays and gets no graduation; and **the two unlocks
are sequential**, since `_restorePrice` returns before `curve.graduate()` is
called, which is what keeps v4's `AlreadyUnlocked` out of the way.

The tests are good: `GraduationHelperHostile.t.sol` attacks from nine
directions, names the three it could not construct, and
`GraduationHelperBounds.invariant.t.sol` asserts conservation over a closed set
of addresses funded once — which is the right way to make a loss bound
assertable. Two honest limits on them: the bound asserted is **cumulative** per
actor rather than per call, and the campaign runs against mocks, so it measures
the helper's logic and not v4's. The fork suite covers the real thing
(`test/fork/GraduationHelper.fork.t.sol`, five tests including paid restores in
both directions and the escape onto an alternate key), which is also the only
evidence I accept for `_EXACT_INPUT_TO_LIMIT = -(2^128-1)` being accepted by the
deployed `PoolManager.swap`.

### 3.2 The two suppressed `arbitrary-send-eth` findings — both justified, one clause decorative

**`_settleEth` (`GraduationHelper.sol:342`).** The verdict is sound and the cap
is the whole of it. One clause in it is decorative rather than wrong: "the
amount is what closing that lock costs" is true of an honest manager and false
of a hostile one, which is the case the verdict exists for. The clause that
carries the argument is the next one — "a hostile answer therefore reaches the
balance the caller brought to this call and nothing else" — and that one I
verified. Keep the suppression.

**`_forward` (`GraduationHelper.sol:423`).** The "arbitrary" destination is
`msg.sender`. Paying the caller is the only thing this contract may do with ETH
outside a lock, the amount is a balance it may not keep, and the following
`BalanceNotZero` assertion is what makes the suppression reviewable instead of a
promise. Not a defect. Keep the suppression.

Both verdicts understate one adversarial consequence of the cap being a balance,
and that is finding 8 — it does not change either verdict.

### 3.3 The two unreachability proofs — both sound; I re-derived them from the vendored source

**`CurveMath.sol:58`, `InsufficientValue`.** Re-derived independently, with
`V = value`, `f = feeBps`, `D = 10000`:

- Entering the clipped branch requires
  `floor(vT·netMax/(vE + netMax)) > R`, hence
  `netMax·(vT − R) > R·vE`, hence `netMax > vE·R/(vT − R)`; `netMax` is an
  integer strictly above that real value, so
  `netMax ≥ ceil(vE·R/(vT − R)) = ethToCurve`.
- `netMax = V − ceil(V·f/D) ≤ V·(D − f)/D`, so
  `netMax·f/(D − f) ≤ V·f/D`, and `ceil` is monotone, so
  `fee = ceil(netMax·f/(D − f)) ≤ ceil(V·f/D) = feeMax`.
- Adding: `required = ethToCurve + fee ≤ netMax + feeMax = V`, with equality
  attainable. So `required > value` is unreachable for every input.

Premises checked rather than assumed: `vT − R = VIRTUAL_TOKEN_TAIL > 0`, so the
division exists; and `D − f > 0`, because `totalFeeBps ≤ MAX_TOTAL_FEE_BPS = 200`
is validated **in the curve's own constructor** (`BondingCurve.sol:166`) and not
only in the factory, so a directly deployed curve cannot reach `f = D` either.
Guard must be kept: a rounding flip in either `mulDivRoundingUp` in that branch
makes it live, and what it then prevents is an underflow of the next line's
`refund`.

**`BondingCurve.sol:923`, `_floorLiquidity`'s fallback.** Also sound, and
stronger than the comment above it, as section 4 says. Read from the vendored
source during this review:

- `LiquidityAmounts.getLiquidityForAmount0` is
  `L = floor(A·floor(a·b/2^96)/(b − a))`
  (`lib/v4-periphery/src/libraries/LiquidityAmounts.sol:25-26`).
- `SqrtPriceMath.getAmount0Delta(a, b, L, true)` is
  `ceil(ceil(L·2^96·(b − a)/b)/a)`
  (`…/v4-core/src/libraries/SqrtPriceMath.sol:207-209`).
- The nested-ceiling identity is correct: for a positive integer `a` and real
  `x`, `ceil(ceil(x)/a) = ceil(x/a)`, so
  `ceil(ceil(x/b)/a) = ceil(x/(a·b))`. The document's own justification —
  each side is `≤ k` exactly when `x ≤ k·a·b` — is also correct.
- The two floors give `L·(b − a) ≤ A·I ≤ A·a·b/2^96`, hence
  `L·2^96·(b − a)/(a·b) ≤ A`, and `A` is an integer, so the single ceiling is
  `≤ A`. The test `> floorEth` is false for every `(a, b, A)` with `b > a`.

`b > a` holds because `tickLower < tickUpper` by construction, and `floorEth > 0`
because `floorEth < MIN_FLOOR_WEI` returns early — so the fallback's
`floorEth - 1` could not underflow even if it ran. Guard must be kept, for the
reason given: three rounding directions in code this repository does not own.

**The hole is not in either proof. It is in the sentence section 4 adds at the
end**, and it matters because that sentence is what Invariant 71 and
`THREAT_MODEL.md` 5.5 both cite. That is finding 7, with the missing derivation
supplied there.

### 3.4 `_settle`'s inlining — one copy, but the stated mechanism is backwards, and the cost is larger than documented

Measured, not read. Built the tree with `--extra-output-files irOptimized` in a
scratch copy and inspected `BondingCurve.iropt`:

- **Current tree:** `function fun_settle(var_key_mpos)` is **defined once**
  (iropt line 3137) and **called from two sites** (lines 2115 and 2770 — the
  `graduate` and `graduateAlt` bodies). The `PriceNotRestored` selector literal
  `0xe7a1edfb` appears **once** in the IR.
- **The `(PoolKey, bool)` form**, which I reconstructed in a second scratch copy
  by restoring the flag parameter and passing `false`/`true` at the two call
  sites: `fun_settle` **does not exist** — it is fully inlined — and
  `0xe7a1edfb` appears **twice**. `BondingCurve` goes to 20,683 bytes (+1,965)
  and `CurveDeployer` to **25,528 bytes, which is 952 bytes over EIP-170**, and
  the build fails with
  `Error: some contracts exceed the runtime size limit (EIP-170: 24576 bytes)`.

So the property that matters is confirmed twice over: **one copy of the
graduation body, and the flag form does not deploy.** The normative rule — never
give `_settle` an argument that is a literal at its call sites — is correct and
my measurement makes it stricter than the document does: I measure the delta at
1,972 bytes against 1,020 bytes of margin, where the document says "about
1.7 KB" against a stale "886 bytes".

What is wrong is the mechanism both the source comment and the spec assert in
the present tense. `BondingCurve.sol:645-646` says "This function does not exist
in the compiled output: `via_ir` inlines it into both `graduate` and
`graduateAlt`", and `SPEC.md:332-333` says the same in bold. On this tree the
opposite is true, and the same paragraphs say so four sentences later ("makes
the inliner decline and leaves one copy"). See finding 6.

### 3.5 Invariant 71 has no test — the missing test does not block; the wording does

My answer to the question as asked: **an invariant that is a consequence of a
proof over vendored rounding behaviour, whose two named reverts are already
covered by tests, does not need its own test to close a phase.**
`LiquidityLock.t.sol` tests `NothingToCompound` (`:147,153,159,180,263`) and
`LiquidityNotIncreased` (`:163-175`), and section 4's bound is what rules out
the third possibility. Shipping that as "awaiting a test", in an entry that says
so in its own text, is an honest book-keeping state and I would not hold a phase
for it.

What does need fixing before that test is written is the invariant's own
sentence, because the test will be written against it and it is false as
written. `compound` has a **third** deliberate revert — `NotLocked(positionId)`
at `LiquidityLock.sol:102` — and it is already tested, at
`LiquidityLock.t.sol:193`. A fourth, `ReentrancyGuardReentrantCall`, follows
from `nonReentrant`. This is the same defect as previous finding 8 on Invariant
34: a normative sentence that a faithful test must contradict. Finding 4.

I did verify the substantive half of the invariant, both sides of it, which
section 4 asserts and does not derive — see finding 7. `compound` cannot revert
for a rounding reason.

### 3.6 `INCREASE_LIQUIDITY_FROM_DELTAS` and `THREAT_MODEL` 5.5 — the argument holds

Checked against the vendored source rather than against the prose:

- The sandwich is real and takes nothing. `_compoundData` has no recipient
  parameter and no caller-supplied number; `CLOSE_CURRENCY` resolves to
  `msgSender()`, which for a batch the lock submits is the lock
  (`PositionManager.msgSender() = _getLocker()`), and the lock has no withdrawal
  path. The liquidity not bought becomes retained residual. Griefing at the
  attacker's expense, with the two legs of fees paid **into the position being
  griefed**.
- The lock-computed variant really is worse, and both new reasons check out. It
  reads the same `slot0` the attacker just moved, the pool is hookless and v4
  core keeps no price history, so the sandwich survives the move of the
  arithmetic. And `_increase` settles whatever the liquidity costs, so an
  over-estimate by one wei creates a debt: `DeltaResolver._settle` pays a native
  debt with `poolManager.settle{value: amount}()` out of **PositionManager's own
  balance**, and a `currency1` debt through `_pay` → `permit2.transferFrom(payer, …)`,
  for which the lock holds no approval. That is finding 1's surface inside the
  lock, and the rewrite is right to name it.
- "`INCREASE_LIQUIDITY_FROM_DELTAS` cannot create a debt at all" is correct:
  `_increaseFromDeltas` sizes the mint from `_getFullCredit` of each currency
  (`PositionManager.sol:308-334`), the preceding zero-liquidity
  `DECREASE_LIQUIDITY` makes both credits non-negative so `DeltaNotPositive` is
  unreachable, and the rounding bound caps what the mint requires at the credit
  on each side, so `_close` takes and never settles.

One caveat on the last bullet, which is finding 7 rather than an objection: the
bound is written for the `currency0` side only, and the `currency1` side is
asserted by analogy.

---

## 4. Findings

Nothing here asks for a contract change. Findings 1 to 5 are the blocking set
and are all statements in `docs/`; findings 6 to 12 are informational.

### Finding 1 — LOW — the graduation bounty can be zeroed by any address for the price of gas, and three documents still claim otherwise

**Carried from the previous review (finding 4), not fixed and not disclosed. It
is now more load-bearing than when it was reported.**

**Location.** `contracts/src/BondingCurve.sol:432-441` (`claimProtocolFees`) and
`:718-724` (the bounty read inside `_settle`).

```solidity
// :432-434 — no state gate, which is correct: the destination is the immutable treasury
function claimProtocolFees() external nonReentrant returns (uint256 amount) {
    amount = protocolFeeEth;

// :718-720 — and the bounty is read from that same bucket, at graduation time
uint256 bounty = FullMath.mulDiv(
    protocolFeeEth, PledrinConstants.GRAD_BOUNTY_BPS, PledrinConstants.BPS_DENOMINATOR
);
```

**Exploit path.** A launch reaches its cap and enters `Graduating`. `Graduating`
admits no trade (Invariants 31, 33), so `protocolFeeEth` cannot grow again —
`SPEC.md:2584` says exactly that: in `Graduating` the bucket is refillable only
by way of `Stalled`. Any address now calls `claimProtocolFees()`. The ETH goes
to the immutable `protocolTreasury`, which is correct and is not the point: the
bucket is zero, so the bounty computed at `:718` is **zero, permanently**. Cost
to the griefer: one transaction's gas. Benefit to the griefer: none directly —
which is why it was LOW and remains LOW.

**Why it matters more now.** The liveness story for a griefed launch is no
longer "someone calls `graduate()` for 0.00004 ETH of gas"; it is "someone pays
real ETH or real launch tokens to cross hostile liquidity, in a transaction
whose upside is the bounty". `THREAT_MODEL.md` 4.10 says so itself — "The
graduation bounty funds it when there is one" — and the same attacker who makes
the restore expensive can remove the funding for free, in the same block, with a
call that looks like housekeeping. What is left is altruism: the creator, whose
vesting is gated on graduation, and the holders. That is a real incentive, and it
is not the one the documents claim.

**Three statements that are false as written.** `SPEC.md:1441-1442`: "The bounty
exceeds the gas cost by more than an order of magnitude and scales with the
raise, so **there is always an economic actor willing to call it**."
`THREAT_MODEL.md` 4.6, which rests the whole of "nobody calls `graduate()`" on
the same sizing. `THREAT_MODEL.md` 4.10's "Who pays and who can pay", which
names the bounty first.

**Recommended fix**, unchanged from the previous review and still a choice of
two: snapshot the bounty into a `pendingGradBountyWei` in `_buy`'s cap branch,
deducted from `protocolFeeEth` there — which makes the sentence true — or state
in SPEC 8.3, THREAT_MODEL 4.6 and 4.10 that the bounty is best-effort, can be
zeroed by any third party after the cap, and that the recovery path's funding is
therefore not guaranteed. The code already tolerates a zero bounty correctly
(`GraduationHelper._claimBounty` catches `NothingToClaim`), so the documentation
route is sound; silence is not.

### Finding 2 — LOW — a forfeited bond is substantially capturable by a deadline sniper, and SPEC 11.4 still presents it as reaching holders

**Carried from the previous review (finding 5), not fixed and not disclosed.**

**Location.** `contracts/src/BondingCurve.sol:389-416` (`expire`), with
`:267-303` (`sell` is open in `Expired`) and `docs/SPEC.md` 11.4.

Re-checked on this tree: `sell` admits `Live`, `Expired` and `Stalled`
(`:273-275`), and `expire()` adds `bondHeldWei + creatorFeeEth + protectionEth`
into `ethReserve` in one transaction. With `E0 = vE0 + ethReserve` just before
the deadline and `D` the donated total, a buyer who enters with `x` wei in the
last block before `gradDeadline` and sells after `expire()` realises
`D·x/(E0 + x)` minus a round trip of fees, so the snipe pays whenever
`D/(E0 + x) > 2·totalFeeBps`, and at `x = E0` it takes half of `D`. The bond
floor is `max(MIN_BOND_WEI, R_target/10)`, so at the default fee that inequality
has a solution for **every** launch that posted a bond.

No protocol funds are at risk. This is a redistribution from the holders the
bond exists to compensate, to a party who bore no exposure. `SPEC.md` 11.4 still
says only that the ETH "raises the exit price for every holder immediately",
which is true and is the sentence that needs the qualifier.

**Recommended fix.** The disclosure belongs in `THREAT_MODEL.md` section 10,
next to 10.1–10.3, which is where this class of statement already lives — the
document is otherwise scrupulous about this kind of limit (10.6's "It pays
nothing to anyone" is the model). A mechanism is a design change and out of
scope for Phase 1.

### Finding 3 — LOW — `abortGraduation`'s "gains nothing" argument covers the creator and not a large holder

**Carried from the previous review (finding 6), not fixed and not disclosed.**

**Location.** `contracts/src/BondingCurve.sol:365-369`; `THREAT_MODEL.md` 4.9.

The only preconditions are `state == Graduating` and `GRAD_GRACE` elapsed; there
is no check that graduation actually failed. 4.9 argues a creator gains nothing
by forcing `Stalled`, which is right. For a large holder it is not neutral: at
the cap the curve's remaining virtual token reserve is
`VIRTUAL_TOKEN_TAIL = 112.5e24` against the pool's `LP_SUPPLY = 100e24` at the
same marginal price, so exiting a large fraction of supply yields slightly more
against the curve in `Stalled` than against the core position after graduation.
Small exits are identical by construction. Combined with findings 1 and 2 of the
previous review it was motive plus means; with those closed it is motive and a
seven-day public window in which anyone may graduate first.

**Recommended fix.** No code change. Extend 4.9's analysis to a large holder, so
the incentive is on the record rather than implied absent.

### Finding 4 — LOW — Invariant 71's revert set is false as written, and it is the invariant awaiting a test

**Location.** `docs/SPEC.md:3108-3119`; `contracts/src/LiquidityLock.sol:102`;
already contradicted by `contracts/test/unit/LiquidityLock.t.sol:193`.

The invariant says `compound` "can revert for exactly two reasons". It has a
third deliberate revert, `NotLocked(positionId)`, reached by any unregistered
`positionId` and already asserted by a passing test in the same suite; and a
fourth, `ReentrancyGuardReentrantCall`, from its own modifier. A test written
faithfully against the current wording either fails or quietly asserts something
weaker than the sentence, which is the failure mode previous finding 8 described
for Invariant 34.

**Recommended fix.** Reword to the property that is actually true and is worth
having: *for a registered position, `compound` reverts only `NothingToCompound`
or `LiquidityNotIncreased`; it cannot revert for a rounding reason, because …*.
Then the test is a short one, and it will say what the invariant says.

### Finding 5 — INFORMATIONAL — Invariant 34 is still false as literally written

**Carried from the previous review (finding 8), not fixed.** `docs/SPEC.md:2806-2807`
still reads: "`Graduating` requires `tokensSold == CURVE_SUPPLY && block.timestamp
< gradDeadline`." The second conjunct is a condition on the **transition**, not
on the state: `MIN_GRAD_WINDOW` is one day and `GRAD_GRACE` is seven, so a
launch that caps near its deadline sits in `Graduating` long past `gradDeadline`
legitimately. One-word fix: "the transition into `Graduating` requires …".
Grouped with the blocking set because it is the same defect as finding 4 in the
same section, and fixing one without the other would be arbitrary.

### Finding 6 — INFORMATIONAL — the `_settle` size note asserts the opposite of what the compiler does, in the same paragraph that states the truth

**Location.** `contracts/src/BondingCurve.sol:645-646` and `docs/SPEC.md:332-333`.

Measured in 3.4: on this tree `fun_settle` is a function in the optimized IR,
defined once and called twice. "This function does not exist in the compiled
output: `via_ir` inlines it into both `graduate` and `graduateAlt`" describes the
form that was abandoned, and both documents then say so themselves.

The normative conclusion is right and should be kept, in the stronger form my
measurement supports: the flag signature does not merely cost ~1.7 KB, it
**fails EIP-170 by 952 bytes** on this tree, and the margin it eats is 1,020
bytes rather than the 886 that `SPEC.md:358` and the section 2.1 ledger still
carry. Recommended: change the two present-tense sentences to the past, state
that the current output holds one out-of-line copy, and refresh the margin
figure. A reader who believes "it does not exist as a function" cannot reason
about what the next change costs, which is the entire purpose of the note.

### Finding 7 — INFORMATIONAL — section 4 proves the `currency0` side of the compounding bound and asserts the `currency1` side, which Invariant 71 and THREAT_MODEL 5.5 both depend on

**Location.** `docs/SECURITY_NOTES.md` section 4, closing paragraph
("the same bound applies on each side of `LiquidityLock`'s compounding batch");
cited by `docs/SPEC.md` Invariant 71 and by `THREAT_MODEL.md` 5.5's last two
paragraphs, the latter naming only `getLiquidityForAmount0` and
`getAmount0Delta`.

The conclusion is true. I derived the missing side so that it is on the record
rather than on analogy. For the `currency1` leg:
`LiquidityAmounts.getLiquidityForAmount1` is `L = floor(A·2^96/(b − a))`
(`LiquidityAmounts.sol:43`) and `SqrtPriceMath.getAmount1Delta(a, b, L, true)` is
`ceil(L·(b − a)/2^96)` (`SqrtPriceMath.sol:234-254`). One floor and one ceiling,
not nested: `L·(b − a) ≤ A·2^96` gives `L·(b − a)/2^96 ≤ A`, and `A` is an
integer, so the ceiling is `≤ A`. In the in-range case
`L = min(L0, L1)` and both delta functions are monotone in `L`, so each side's
requirement is still bounded by that side's credit; in the two out-of-range
cases one side is zero. I also checked the boundary case where v4's
`slot0.tick` and `sqrtPriceX96` disagree by one tick — `Pool.modifyLiquidity`
branches on the tick while `LiquidityAmounts` branches on the price — and the
mismatch is harmless in both directions, because the leg the tick branch adds
evaluates to zero at a price sitting exactly on the range's endpoint.

**Why this is worth an entry rather than a footnote.** Section 4's whole purpose
is that these bounds rest on rounding directions this repository does not own,
so that a dependency bump knows what to re-verify. It currently names **three**
such directions. With the `currency1` leg included there are **five**: both
floors in `getLiquidityForAmount0`, the round-up in `getAmount0Delta`, the floor
in `getLiquidityForAmount1` and the round-up in `getAmount1Delta`. A bump that
changed one of the last two would falsify Invariant 71 and 5.5's "no debt"
argument while leaving section 4's three checks green.

### Finding 8 — INFORMATIONAL — a stray balance in any currency other than `curve.token()` is extractable from the helper by any address, to an address of the attacker's choosing

**Location.** `contracts/src/GraduationHelper.sol:259-272` (the payload's two
currencies), `:352-364` (`_settleToken`), `:412-430` (`_forward` measures only
`launchToken`). Described from the other end by
`contracts/test/unit/GraduationHelperHostile.t.sol:326-378`, which contains both
halves of the mechanism as two separate tests.

**Construction.** An attacker deploys a curve and a PoolManager of their own and
calls `graduateVia(hostileCurve, [any candidate], 0)` with no value. The forged
`unlockCallback` payload names currency `X` — any ERC-20 — and the forged `swap`
returns a delta owing `X`. `_settleToken` checks `X.balanceOf(helper)` and
transfers that balance to `msg.sender`-as-manager, which is the attacker's
contract. `_forward` then measures ETH and `hostileCurve.token()`, both zero, so
`BalanceNotZero` does not fire and the call returns.

**Impact: none on any party's funds**, and the reasoning the spec already gives
is the right one — stray value has no owner, a caller cannot lose what they did
not send, and the helper is specified to hold nothing. The finding is that two
documents and one test comment describe a narrower mechanism than the code has:

- `docs/SECURITY_NOTES.md` section 2 says stray value "leaves with the next
  caller, because `_forward` sends balances". True for ETH and for
  `curve.token()`; not true for any other currency, which does not leave with
  the next caller and can instead be taken by anyone, immediately, to an
  arbitrary destination.
- `GraduationHelperHostile.t.sol:361-363` says such a balance "is reachable by a
  `graduateVia` for that launch and by nothing else". It is reachable by a
  `graduateVia` for **any** curve, including one the attacker wrote for the
  purpose, which is the same file's other test.
- Invariant 68(a) says "zero base units of any launch token" and then scopes
  itself to `curve.token()`. The scoped form is the one the code implements.

**Recommended fix.** No code change — widening `_forward` to currencies named at
runtime would add a loop and a trust surface to buy nothing. State the
adversarial form in all three places, because the project's own standard is that
an argument states its strongest form, and "leaves with the next caller" is the
benign one.

### Finding 9 — INFORMATIONAL — `docs/SECURITY_NOTES.md` section 4's coverage figures are a release behind

Section 4 opens with "99.84% of lines (613/614) and 98.51% of branches
(132/134)". Measured on this tree: **99.86% (693/694) and 98.72% (154/156)**.
The document's header table was updated to 36 Slither findings in the same
commit, so this is drift in one section rather than a stale document. It matters
only because section 4 is the place a reader goes to find out whether the
uncovered branches are the proved ones, and a figure that does not match the
report invites the reader to assume the rest of the section is stale too. It is
not: the file and line references in it are exact.

### Finding 10 — INFORMATIONAL — `_buy` still discards `_accrueFee`'s redirect

**Carried from the previous review (finding 9), not fixed.**
`contracts/src/BondingCurve.sol:583` calls `_accrueFee(fee, State.Live)` and
drops `feeToReserve`. Correct today — the function returns zero in `Live` and
`_buy` runs only in `Live` — and the comment at `:581-582` says so. Noted again
only because the safety of the discard is a two-step argument that a future
caller in another state would silently break. `assert`-free options: add it to
`reserveAfter`, or make the call site assert the zero.

### Finding 11 — INFORMATIONAL — "bounds the caller's loss completely" excludes gas and says nothing about the price paid

**Location.** `docs/SPEC.md` 8.6 step 1; `docs/THREAT_MODEL.md` 4.10.

Two gaps between what the sentence guarantees and what a caller will read into
it, both of which I would want stated where the guarantee is:

1. **Gas is unbounded.** A hostile curve can burn the whole gas limit, and every
   value the helper reads from it — `token()`, `poolManager()`,
   `sqrtPriceTerminal()`, `getSlot0`, `swap` — is an external call whose return
   data the caller's own frame pays to copy, so a returndata bomb is available
   too. The loss bound is a bound on **value**, not on the cost of the call.
2. **There is no slippage control other than the budget.** `msg.value` and
   `maxTokensIn` cap what the restore may spend; nothing caps what it gets back.
   On a real pool an attacker who holds liquidity between the current price and
   `sqrtPriceTerminal` is the counterparty to the restoring swap and keeps the
   spread, so a caller who brings a large budget to be safe is handing the
   attacker a larger target. `THREAT_MODEL.md` 4.10 makes the honest version of
   this point about depth; what is missing is the operational consequence, which
   is that sizing `msg.value` **is** the slippage control and should be sized to
   the bounty rather than to the expected cost.

Neither is a defect. Both belong next to the guarantee, because the guarantee is
written to be relied on.

### Finding 12 — INFORMATIONAL — the alternate key is a unilateral, irreversible choice after one hour, available on healthy launches, and the fee range's justification is one-sided

**Location.** `contracts/src/BondingCurve.sol:347-363`;
`contracts/src/libraries/PledrinConstants.sol:55-75`.

`graduateAlt` has no precondition that the canonical key is unusable. After
`ALT_DELAY = 3600`, any address may graduate a healthy launch onto any of
1,337,189 other keys — including `(3000, 10)` — and the choice is permanent.
`SPEC.md:1493-1501` records this and handles it with caller guidance plus the
delay ("so that the honest primary key wins when it is available"), which is a
deliberate trade and I am not asking for a constraint: a precondition would
hand the key back to the griefer, which is the mistake decision 22 just
withdrew.

The one sentence I would qualify is `ALT_POOL_FEE_MAX`'s: "an escape forced by a
transient attack can only make the graduated pool cheaper to trade." That is the
trader's side. The other side is that every future fee on the graduated pool
accrues to a position that can never be withdrawn and is compounded back into
itself, so a lower tier also means a permanently slower-growing locked position.
The net effect is genuinely ambiguous and probably small — which is worth
writing down, rather than resolving the question in the direction that happens
to favour the constant.

---

## 5. Checks that passed

Recorded so the review is falsifiable in both directions. Each of these I
followed through the code on this tree rather than carrying forward.

**The helper is as powerless as it claims.** `grep` over `contracts/src` finds
no reference to `GraduationHelper` other than a doc comment in
`IBondingCurve.sol:369` (Invariant 68(d)). The file contains no `approve`, no
`delegatecall`, no `assembly`, no `selfdestruct`, no `tx.origin`, no
`block.number`, no owner, no admin function, no constructor and one state
variable, declared `transient` (Invariant 68(c)). Its only loop is the candidate
walk, which is bounded by an array the caller supplies and pays for.

**A rogue curve cannot complete a graduation through the helper.**
`LaunchFactory.recordGraduation` is `onlyLaunch` (`LaunchFactory.sol:58-59, 184`),
so a curve the factory did not create reverts at the end of `_settle`, the
candidate fails, and the walk reverts with the caller's funds intact.

**Graduation's ordering properties.** The two unlocks are sequential, not nested
(spec 8.6 step 4). Nothing third-party executes between the price assertion and
the core mint, or between the core mint and the floor mint, which is what
Invariants 66 and 70 need. Third-party liquidity on the graduating key cannot
change what the mints deposit, because both amounts are functions of the price
and of the position's own range.

**The pre-initialised-key tolerance is a test and not a swallow.** The
constructor branches on `getSlot0` and suppresses no failure of `initialize`
(Invariant 65); the launch's observable state is identical except for the new log
(Invariant 64); `PoolPreInitialized` carries the price a third party chose, and
nothing reads it.

**Key arithmetic.** `graduateAlt`'s two range checks and the canonical refusal
precede the state check, and all three are verdicts about calldata alone
(Invariant 67). The fee range cannot express v4's dynamic-fee flag. The
`uint24 → int24` narrowing is checked at both the helper and the curve, and the
two keys agree field for field. `1,337,190` is arithmetically right.

**Static-analysis hygiene.** 36 findings, 10 detectors, every detector with a
written verdict; three suppressions, all three consumed, all three accurate, each
anchored to a line rather than to the configuration; `slither.config.json`
excludes nothing by impact, so a fourth high anywhere in `src` fails the build.
Zero parse errors, checked independently of the exit code.

**Quality bar, re-checked on the changed files.** No `require`/string reverts —
custom errors only, with parameters. Every state change emits an event, the new
`PoolPreInitialized` and `GraduatedVia` included. No unbounded loop in `src`
outside the helper's caller-paid walk. No admin power over user funds: nothing
in the diff adds a privileged path, and the bond and the bounty are still
credited rather than pushed. `block.timestamp` throughout; no `block.number`.
Checks-effects-interactions holds in the two places the previous review found it
relaxed and nowhere new; `state` is still written before every external call in
`_settle`.

**The ABI surface.** All nine files in `contracts/abi/` regenerate
byte-identically from a build of this tree (see the disclosure in section 1), so
the frozen interface Phase 2 consumes is the interface this tree compiles to.

---

## 6. Verdict

**CHANGES REQUESTED.**

**What blocks.** Findings 1, 2, 3, 4 and 5. All five are statements in `docs/`
that are false or materially unqualified against code I read on this tree. Four
of the five were reported by this reviewer on 2026-11-11; that review's verdict
said they "can be closed by a code change or by an honest sentence in
`docs/THREAT_MODEL.md`, **but not by silence**", and three document-only commits
have landed since without touching them. No contract change is required by any
of them.

**What clears it.** All five of the following, each by whichever route the
project prefers where one is offered. I will re-review on the diff alone, and
none of it needs a test:

1. SPEC 8.3's "there is always an economic actor willing to call it", and the
   paragraphs in THREAT_MODEL 4.6 and 4.10 that rest on it, state that the
   bounty is best-effort and can be zeroed after the cap by any address for the
   price of gas — or `_buy` snapshots it and the sentence becomes true.
2. SPEC 11.4, or a new entry in THREAT_MODEL section 10, states that a buyer who
   enters in the last block before the deadline shares in the forfeited bond.
3. THREAT_MODEL 4.9's "gains nothing" analysis covers a large holder as well as
   the creator.
4. Invariant 71's revert enumeration is scoped to a registered position, so that
   the test it awaits can be written against a true sentence.
5. Invariant 34 is reworded to constrain the transition rather than the state.

Findings 6 to 12 should be fixed in the same pass — they are documentation and
each one is a sentence — but none of them blocks.

**What an approval of this phase would cover, and what it would not.** Stated
here because the next version of this document will be read as a sign-off, and
it should state its own limits rather than be read as more than it is.

It would cover: the nine contracts in `contracts/src` at `78c880e`, read against
the specification and threat model as they stand; the three findings of the
previous review and their fixes; the loss bound on `GraduationHelper` as the
theorem stated in 3.1, with its named premises; the two unreachability proofs,
re-derived; the inlining and size claims, measured; and the reproduction of every
command in section 1.

It would **not** cover: Uniswap v4, Permit2, OpenZeppelin or solmate, none of
which this review audits and all of which the protocol's correctness depends on;
the economic design, which is a set of trade-offs recorded in
`THREAT_MODEL.md` section 10 and not a thing a reviewer can approve; deployment,
wiring, ownership hand-off and the timelock's operation, because
`contracts/script/` is empty and Phase 3 has not happened; the indexer, the
application, and every claim in `DATA_MODEL.md`; the invariant campaigns as
proofs, since a zero revert count from handlers that catch internally is not
evidence and the project knows it; any statement about mempool visibility on this
chain, which `CHAIN_FACTS.md` records as unknown; and the residual race of
THREAT_MODEL 10.9, which is open by design and mitigated rather than closed.

And it would not be a substitute for the external audit the founder's standing
rule requires before mainnet. Two specific items to put in front of that audit,
because they are where this review's confidence rests on something it does not
own: the five vendored rounding directions of finding 7, any one of which a
dependency bump can flip; and the loss bound of 3.1, which is a structural
argument over an adversary who supplies every address in the call and is the
strongest position anyone holds anywhere in this protocol.

Nothing in this review found a path to taking another party's funds, a
reentrancy hole, a fee-split leak, an admin power over user value, an exit from
`LiquidityLock`, or a way for a creator to extract value they did not earn.
