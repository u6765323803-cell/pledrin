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

As of this revision Slither reports **28 findings across 9 detectors** and
generates an intermediate representation for every function in `src`:

| Impact | Findings | Detectors |
|---|---|---|
| High | 1 | `reentrancy-balance` |
| Medium | 13 | `unused-return` 9, `divide-before-multiply` 2, `incorrect-equality` 1, `locked-ether` 1 |
| Low | 13 | `timestamp` 8, `reentrancy-benign` 4, `reentrancy-events` 1 |
| Informational | 1 | `low-level-calls` |

None is a defect. The one high finding has a written verdict in section 2, and
it is the reason `--fail-high` exits 255: the flag fails on impact alone and
cannot be told that a high finding has been reviewed. A permanently red gate is
an ignored gate, so this will not be left as it stands — the fix belongs in the
same change that implements it, not in a note here.

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

### reentrancy-balance — high — not a defect

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
