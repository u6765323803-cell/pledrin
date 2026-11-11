# Security notes

Static-analysis results for `contracts/`, with a verdict for every finding that
is not fixed in code. A finding is only allowed to stay unfixed if the reason is
written here. "Slither is noisy" is not a reason.

Reproduce with the version CI pins, from `contracts/`:

```
pip install slither-analyzer==0.11.6
slither . --config-file slither.config.json --fail-high
```

The configuration lives in `contracts/slither.config.json` rather than in CI
arguments, so a reviewer running the command above analyses the same set of
contracts with the same detectors as the pipeline.

As of this revision Slither reports **28 findings across 9 detectors**,
generates an intermediate representation for every function in `src`, and
`--fail-high` exits **0**:

| Impact | Findings | Detectors |
|---|---|---|
| Medium | 13 | `unused-return` 9, `divide-before-multiply` 2, `incorrect-equality` 1, `locked-ether` 1 |
| Low | 13 | `timestamp` 8, `reentrancy-benign` 4, `reentrancy-events` 1 |
| Informational | 2 | `low-level-calls`, `cyclomatic-complexity` |

None is a defect. One high-impact finding, `reentrancy-balance`, is carried by an
inline directive at its single site rather than by a configuration change, so the
gate still fails on a high finding anywhere else; its verdict is in section 2.
`--fail-high` fails on impact alone and cannot be told that a finding has been
reviewed, and a permanently red gate is an ignored gate, so the choice was
between suppressing the one reviewed site and losing the gate entirely.

---

## 1. Resolved: the analysis once covered less than the whole program

This section is kept after the fix because the failure mode is worth
recognising: for a period, this repository had a static-analysis gate that
reported a clean, ordinary-looking result while six function bodies — including
every buy and the whole of graduation — were absent from the model.

Slither 0.11.6 could not build an intermediate representation for
`BondingCurve.constructor`, `graduateAlt`, `_buy`, `_settle`, `_mintData` and
`LiquidityLock._compoundData`, reported each on stderr as
`ERROR:ContractSolcParsing: Impossible to generate IR ... 'NoneType' object has
no attribute 'parameters'`, and then ran all 102 detectors over what was left.

### Why the exit code did not save us

| Invocation | Exit code |
|---|---|
| `--fail-high` | 255 |
| `--no-fail-pedantic` | 0 |
| `--fail-none` | 0 |

A clean exit was available with six function bodies missing. No flag reports
this condition, so `.github/workflows/security.yml` greps for
`ERROR:ContractSolcParsing` and fails the job itself. **That gate stays even
though the cause is fixed**, because the same class of failure can return with
any dependency bump or Slither release, and the next occurrence would again look
like a clean run.

### Root cause

A library-name collision. `lib/v4-periphery/lib/v4-core/src/libraries/SafeCast.sol`
declares a library also called `SafeCast`, and it declares only `toUint160`,
`toUint128`, `toInt128` and `toInt256`. Slither resolves a `using SafeCast for T`
directive by **name** across the file's scope, and in any file that reaches the
Uniswap v4 surface it binds to v4-core's library rather than to the
OpenZeppelin one the file imports. Every cast whose name that library does not
declare — `toUint8`, `toUint64`, `toInt24` — resolved to `None`, and
`convert_constant_types` in `slither/slithir/convert.py` raised on
`[p.type for p in func.parameters]`. That killed IR generation for the whole
enclosing function.

This explains the distribution exactly. `sell`, `_mintCore` and
`_approvePositionManager` parsed cleanly only because `toUint128` and
`toUint160` happen to exist in v4-core's library; `CreatorVesting` and `Timelock`
used `toUint64` without trouble because neither file reaches v4.

There is a second-order effect worth stating plainly, because it is worse than
the six missing functions and was not visible at all: for every `toUint128` call
site in `BondingCurve` and `LiquidityLock`, Slither was analysing **v4-core's
implementation rather than the OpenZeppelin one solc compiles**. The analyser
was not merely covering less than the program; on those lines it was covering a
different program.

### The fix

`using` directives in `BondingCurve.sol` and `LiquidityLock.sol` now name their
functions:

```solidity
using {SafeCast.toInt24} for int256;
using {
    SafeCast.toInt256, SafeCast.toUint8, SafeCast.toUint64, SafeCast.toUint128, SafeCast.toUint160
} for uint256;
```

Slither's function-list path keeps searching every library called `SafeCast`
until it finds one that declares the named function, so the binding becomes the
same one solc uses. This is standard Solidity since 0.8.13, it is the same
OpenZeppelin implementation with the same checks and the same custom errors, and
the compiled bytecode is unchanged. It also documents at the attachment site
which of the two `SafeCast` libraries applies, which is the same ambiguity that
fooled the analyser and can fool a reviewer.

Two alternatives were rejected for making the code worse to satisfy a tool:
plain `uint8(...)` / `uint64(...)` truncations, which drop the overflow checks,
and a project-local reimplementation of `SafeCast`, which would duplicate
audited code.

### Correction to the previous revision of this section

An earlier revision recorded "SafeCast through a `using` directive" as
**eliminated** by minimal reproduction, and noted that every failing function
used a cast other than `toUint128` while the one clean function used only
`toUint128` — then dismissed that as coincidence. It was not coincidence; it was
the signal, and the reasoning that discarded it was wrong. The reproduction that
cleared the hypothesis did not import anything from Uniswap v4, so it contained
only one library called `SafeCast` and could not exhibit the collision. The
hypothesis was correct and the test of it was inadequate.

The other two hypotheses recorded there were genuinely eliminated and remain so:
interface-declared errors and events, and `bytes("")` string-literal conversion.
Neither reproduces, and neither is implicated by the cause above.

### Reproduction

`slither . --config-file slither.config.json` against a two-file project that
imports both `SafeCast` libraries reproduces the error for a plain local, a
library constant, `block.timestamp`, an explicit `SafeCast.toUint8(x)` call and a
chained cast; aliasing the OpenZeppelin import does not help; `toUint128` does
not reproduce; and a contract using the function-list directive produces no
errors. On the real sources the parse errors went from six to **zero** and the
findings from 35 to 28.

---

## 2. Findings not fixed in code

Grouped by detector, with Slither's impact rating.

Four detectors that appeared in the previous revision are absent from this one —
`arbitrary-send-erc20` and `uninitialized-state` (both high), `dead-code` and
`constable-states`. All four were artefacts of the missing function bodies
described in section 1 and disappeared when the analysis became complete. They
are not suppressed and not fixed; they were never real.

### reentrancy-balance — high — not a defect, suppressed at the site

Carried by a `slither-disable-next-line reentrancy-balance` directive on the dust
comparison in `_mintCore`, with a comment there pointing at this verdict. The
directive is deliberately anchored to that one condition and
`slither.config.json` is untouched, so the detector still runs everywhere else
and a second `reentrancy-balance` anywhere in `src` fails the build. Verified
consumed rather than coincidentally absent: `--warn-unused-ignores` does not
report this directive as unused.

```
Reentrancy in BondingCurve._mintCore(PoolKey,int24):
  External call allowing reentrancy:
  - positionManager.modifyLiquidities{value: target}(_mintData(...), block.timestamp)
  Balance read before the call:
  - tokensBefore = token.balanceOf(address(this))
  Possible stale balance used after the call in a condition:
  - remainder > PledrinConstants.LP_DUST_MAX
```

The detector's premise is that a balance read before an external call may be
stale when used after it. Here the value used after the call is not that balance:

```solidity
uint256 tokensBefore = token.balanceOf(address(this));
positionManager.modifyLiquidities{value: target}(...);
tokensUsed = tokensBefore - token.balanceOf(address(this));
uint256 remainder = PledrinConstants.LP_SUPPLY - tokensUsed;
if (remainder > PledrinConstants.LP_DUST_MAX) revert LpDustTooHigh(remainder);
```

`tokensUsed` is a **delta across the call** and `remainder` is derived from it
and from a constant, never from an absolute post-call balance. Any token balance
the curve holds beyond what the mint consumes therefore raises both ends of the
subtraction equally and cancels: a donation of `D` before `graduate()` gives
`tokensBefore = LP_SUPPLY + D` and a post-call balance of `LP_SUPPLY + D - U`,
so `tokensUsed = U` and `remainder = LP_SUPPLY - U`, both independent of `D`.
The amount the mint pulls is set by the position's parameters and capped at
`LP_SUPPLY`; it is in no way a function of the curve's balance.

For the read to be stale in a way that changed `remainder`, the balance would
have to move during the call by something other than the mint's own pull. Inside
`modifyLiquidities` the pool is hookless and the currencies are native ETH and
the launch token, a plain ERC20 with no transfer callbacks. The call reaches
Uniswap v4's own contracts, whose addresses are immutable, and exactly one piece
of Pledrin code: the curve's `receive()`, which reverts for every sender other
than `positionManager`. No third party can execute anything in that window.

**That argument is scoped to the token delta and does not extend to the ETH
delta measured two lines above it.** The Phase 1 security review
(`docs/security/REVIEW-2026-11-11-phase1-contracts.md`, finding 1) shows that
`_mintData`'s closing `SWEEP(currency0, MSG_SENDER)` sends PositionManager's
*entire* native balance to the curve rather than the mint's unspent remainder,
so `ethBefore - address(this).balance` is influenced by any balance parked in
PositionManager beforehand — with nobody executing anything inside the window and
no reentrancy involved. "No third party can execute anything here" was therefore
true and insufficient, and generalising it from the token reading to the whole
function was my error. The ETH reading is a confirmed high-impact finding and is
being fixed; this verdict covers `remainder` and the dust check alone.

`LiquidityLock.onERC721Received` is deliberately **not** part of that argument,
although the position NFT is minted to the lock during this call. v4's
PositionManager mints with `_mint(owner, tokenId)`
(`lib/v4-periphery/src/PositionManager.sol:369`), inheriting solmate's `ERC721`,
whose `_mint` emits `Transfer` and invokes no receiver hook — only
`safeTransferFrom` does. So that callback does not run here at all. An earlier
revision of this verdict named it as a window participant and argued that its
`external view` declaration made it inert; the declaration is real and is pinned
by Invariant 57, but it was the wrong reason, because the function is never
reached on this path. Naming a surface that is not on the path makes an argument
look broader while leaving it resting on something unverified.

Both failure directions also fail closed rather than open: an in-window balance
increase would underflow `tokensBefore - balanceOf` and revert, and
`tokensUsed > LP_SUPPLY` would underflow `remainder` and revert.

**This construction is load-bearing and must not be simplified.** Reading the
post-call balance directly and treating it as the remainder would let any holder
push `remainder` past `LP_DUST_MAX` by sending tokens to the curve, revert
`graduate()` at will, hold a launch that had reached its cap out of graduation
until `GRAD_GRACE` expired, and leave `abortGraduation` to strand it in `Stalled`
with no Uniswap pool — a griefing attack on every holder, at the cost of a token
balance the attacker already owns.

This finding was invisible before the fix in section 1, because `_mintCore` calls
`_mintData`, one of the six functions that failed to parse.

One adjacent fact, recorded because the opposite is the natural assumption:
`_mintCore` revokes only the **ERC-20** leg of the Permit2 approval, which is
what specification section 8.2 step 4 prescribes. The Permit2 registration
itself survives graduation carrying the unspent remainder — at the default
virtual reserve, an allowance of 1,088 base units with `expiration` at
`type(uint48).max`. It is inert, because a Permit2 pull also needs the curve's
own ERC-20 allowance to Permit2, which is zero and which no code path can set
again. It is worth knowing anyway: adding any `_approve` to the curve in future
would turn a dust-sized dormant registration into a live one.

### unused-return — medium — intended, nine findings

Five of the nine are newly visible — four in `_settle` and one in the
constructor — for the same reason.

- `poolManager.initialize` returns the initial tick, at both call sites — the
  constructor's and `_settle`'s. Neither needs it: the specification requires the
  tick to be read back from `slot0`, which both do.
- `poolManager.getSlot0` is destructured for one field at four sites, three in
  `_settle` and one in `_mintFloor`. The other fields are deliberately unused, and
  reading `tick` rather than deriving it from `sqrtPriceX96` is required by the
  specification.
- `poolManager.unlock` returns the callback's encoded result; the price-restoring
  callback returns an empty value and the caller re-reads the restored price.
- `positionManager.getPoolAndPositionInfo` is destructured for the pool key alone.
- `curve.creatorFirstBuy` returns the base units bought; the factory does not need
  them, and the amount reaches indexers through `CreatorVesting`'s
  `VestingCreated` event.

### divide-before-multiply — medium — intended

`TickAlign.down` and `TickAlign.up` divide by the tick spacing and multiply back.
The discarded remainder is the alignment itself, not a loss of precision. Both
sites carry an inline suppression.

### incorrect-equality — medium — not applicable

`CreatorVesting.release` tests `amount == 0` to reject a no-op release. The
detector is aimed at strict equality against a balance or a timestamp; this is a
zero check on a computed amount.

### locked-ether — medium — intended

`LiquidityLock` accepts ETH and has no withdrawal function. That is the contract's
purpose. Its `receive` additionally rejects every sender other than PoolManager
and PositionManager, so the only ETH that can arrive is a position's residual
`currency0` and PositionManager's native-value sweep; no one can strand their own
ETH there by mistake.

### timestamp — low — eight findings, deliberate

Every deadline, vesting cliff and timelock comparison in the protocol.
`docs/CHAIN_FACTS.md` rules out `block.number` on this Arbitrum Nitro chain and
specification section 1 requires `block.timestamp` for all time logic, so each of
the eight is intended. The detector is excluded in `foundry.toml`'s `[lint]`
section for the Foundry linter; Slither applies its own and is reported here for
completeness.

### reentrancy-benign — low — guarded, four findings

`_restorePrice` writes its own `_unlocking` flag after `poolManager.unlock`
returns, which is the flag's purpose. `_settle` writes after `initialize` and
`_restorePrice`, both calls to the immutable PoolManager. `LaunchFactory.createLaunch`
accounts for two of the four: it writes `isLaunch` and the reputation counters
after deploying the curve, and the curve is created by that same call and cannot
be a third party. No value moves on any of these paths after the write.

### reentrancy-events — low — not reachable

`CurveDeployer.deploy` emits after `new BondingCurve{value: msg.value}(...)`. The
curve does not exist before that statement, so nothing can re-enter to reorder or
fabricate the log.

### cyclomatic-complexity — informational — true, and accepted

`BondingCurve`'s constructor measures 12 against Slither's threshold of 11. It
was at 11 before decision 22 and the pre-initialised-pool branch put it over.

The finding is accurate rather than noisy: that constructor validates a
fourteen-field configuration, deploys the launch token, checks the supply
landed, records the bond, and now tolerates a pool key a third party may already
have opened. A reviewer does have to hold all of that at once.

It is accepted rather than refactored, and the reason is the opposite of the one
that keeps `reentrancy-balance` suppressed. There, restructuring would have made
the code worse. Here, extracting the configuration checks into a private
function would be harmless — the IR inliner folds it straight back, so the
bytecode is identical — and that is exactly why it is not worth doing: the same
logic would run, a reviewer would have to understand the same amount, and the
only thing that would change is a number going under a threshold. A verdict that
says the constructor is complex and why is more use to an auditor than a count
that no longer trips.

What a reviewer should check there, since this entry is the place to say it: that
the `getSlot0` test is a test and not a caught revert, so every other failure
mode of `initialize` still reverts the launch; and that the token's supply
assertion is exact equality, so a token that is not the one the deployer made
cannot pass.

### low-level-calls — informational — intended

`BondingCurve._sendEth` uses `call` so that a recipient contract's failure to
accept ETH is a revert of the claim rather than a permanently stuck balance.

---

## 3. What static analysis here does not cover

Recorded so that a green pipeline is not read as more than it is.

- Economic behaviour. No detector can tell whether the curve's terminal price
  matches the pool's opening price, which is the property that removes the
  migration sandwich. That is `contracts/test/fork/` and the invariant suite.
- The Uniswap v4 integration. Every v4 assumption this protocol relies on is
  verified by fork test against the live deployment, not by analysis.
- Anything in `docs/THREAT_MODEL.md` section 10, which lists what the design does
  not prevent at all.
- Whether the analyser is analysing the program at all. Section 1 is the standing
  evidence that this needs its own check, which is why CI has one.

---

## 4. The two branches the suite never takes

The deterministic suite measures **99.84% of lines (613/614) and 98.51% of
branches (132/134)** against the 95% the project requires. Two branches are never
taken, and neither is a gap in the suite: no input reaches either, and in both
cases that is established by proof over all inputs rather than by a search that
happened to find nothing.

That distinction is the whole reason this section exists. An unsearched branch
and a proved-unreachable one are indistinguishable in a coverage report, so a
reviewer who cannot tell them apart has to treat the second as the first. Both
guards are kept, neither may be deleted as dead code or narrowed to an unchecked
operation, and the reason is the same for both: unreachability holds because of
specific rounding directions in library code this repository vendors and does not
own. A dependency bump that changes one of those directions makes the guard live,
which is the event each exists to survive.

### `CurveMath.sol:58` — `InsufficientValue` inside `buyQuote`'s clipped branch

`docs/SPEC.md` section 5.4 proves this unreachable for every input and records
that keeping it is a decision. It was re-derived independently during this round
and the two derivations agree; nothing here supersedes that proof. What is worth
adding is where the margin comes from, because it is narrower than "the buyer
sent enough":

- entering the clipped branch requires
  `floor(vT*netMax/(vE + netMax)) > remaining`, which forces
  `netMax >= ceil(vE*remaining/(vT - remaining))` — exactly the clipped cost. So
  the clipped net never exceeds the net the buyer already sent.
- the fee on that clipped net is bounded by the fee already taken:
  `netMax <= value*(D - f)/D` gives
  `ceil(netMax*f/(D - f)) <= ceil(value*f/D)`.

The two together give `required <= value` identically, with equality attainable —
a clipped buy whose refund is zero. The guard therefore becomes live the moment
either `mulDivRoundingUp` in that branch is changed to round the other way, and
what it would then prevent is an underflow of the next line's `refund`: the one
failure mode in that function that would not announce itself.

### `BondingCurve.sol:923` — `_floorLiquidity`'s one-wei fallback

Read from the vendored source during this round rather than carried over from the
comment above it, and the result is **stronger than that comment claims**: the
double rounding-up the fallback guards against cannot overshoot at all.

With `a = sqrtLower`, `b = sqrtUpper`, `A = floorEth`:

- `LiquidityAmounts.getLiquidityForAmount0` computes `I = floor(a*b/2^96)` and
  then `L = floor(A*I/(b - a))`. Its `toUint128` reverts on overflow rather than
  truncating, and truncation would only lower `L` in any case.
- `SqrtPriceMath.getAmount0Delta(a, b, L, true)` computes
  `ceil(ceil(L*2^96*(b - a)/b)/a)`.

Nested ceiling division composes exactly: for positive integers,
`ceil(ceil(x/b)/a) = ceil(x/(a*b))`, because each side is `<= k` exactly when
`x <= k*a*b`. So the amount required is **one** rounding, not two. And the two
floors give `L*(b - a) <= A*I <= A*a*b/2^96`, hence
`L*2^96*(b - a)/(a*b) <= A`; `A` is an integer, so its ceiling is `<= A` as well.
The test `> floorEth` is false for every `(a, b, A)` — not merely for every
permitted one, so there is no crafted direct call either. The security review's
50,000-run search found no counterexample because there is none to find.

Three rounding choices over the same `(a, b)` hold this up: both floors in
`getLiquidityForAmount0` and the round-up in `getAmount0Delta`. A v4-periphery
bump that rounded `intermediate` up would make the fallback live, and graduation
would revert without it.

One consequence worth stating because it is not obvious from the code: the same
bound applies on each side of `LiquidityLock`'s compounding batch, so that batch
cannot require more than the credit it was given. `compound` therefore cannot
revert for a rounding reason, and the only reverts it can produce are its two
deliberate ones.
