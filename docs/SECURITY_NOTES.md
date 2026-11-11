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

As of this revision Slither reports **35 findings across 11 detectors**, and the
run exits non-zero. None of the 35 is a defect. The run is nonetheless not
acceptable, for the reason in the next section.

---

## 1. Open blocker: the analysis does not cover the whole program

Slither cannot build an intermediate representation for six function bodies and
says so on stderr:

```
ERROR:ContractSolcParsing:Impossible to generate IR for BondingCurve.constructor (src/BondingCurve.sol#133-219):
 'NoneType' object has no attribute 'parameters'
ERROR:ContractSolcParsing:Impossible to generate IR for BondingCurve.graduateAlt (src/BondingCurve.sol#317-327)
ERROR:ContractSolcParsing:Impossible to generate IR for BondingCurve._buy (src/BondingCurve.sol#504-541)
ERROR:ContractSolcParsing:Impossible to generate IR for BondingCurve._settle (src/BondingCurve.sol#561-614)
ERROR:ContractSolcParsing:Impossible to generate IR for BondingCurve._mintData (src/BondingCurve.sol#737-762)
ERROR:ContractSolcParsing:Impossible to generate IR for LiquidityLock._compoundData (src/LiquidityLock.sol#135-152)
```

Those six are the curve's constructor, every buy, the whole of graduation, the
alternate-pool entry point, and the two functions that encode Uniswap v4 action
payloads. Slither then runs all 102 detectors over the remaining model and
reports its findings in the ordinary format.

This matters in both directions.

**False positives.** Every "never initialized" finding in section 2 is an
artefact of the constructor being absent from the model: each of those variables
is assigned in the constructor, and `capReachedAt` is additionally written in
`_buy`. The six dead-code findings and both `constable-states` findings have the
same single cause — the functions that call them, and the functions that write
them, are the ones that failed to parse.

**False negatives, which are the real problem.** A genuine reentrancy, arbitrary
send or uninitialised read inside `_settle` or `_buy` would not be reported at
all, and its absence from the output would be indistinguishable from its absence
from the code.

Nothing in Slither's exit code reflects this. Measured on this repository:

| Invocation | Exit code |
|---|---|
| `--fail-high` | 255 |
| `--no-fail-pedantic` | 0 |
| `--fail-none` | 0 |

A clean exit is therefore available while six function bodies are missing from
the analysis. `.github/workflows/security.yml` greps for `ERROR:ContractSolcParsing`
and fails the job itself, because no flag does it.

Slither 0.11.6 is the current release, so there is no upgrade to take. The
failure does not depend on the IR pipeline: `via_ir = false` produces the same
six errors and the same 35 findings. A minimal reproduction of the most obvious
suspect — a chained `using SafeCast for uint256` call — does **not** reproduce
it, so the triggering construct is not yet identified.

**Status: open, and a gate on closing the contracts phase.** Until it is fixed,
treat static analysis of `BondingCurve` and `LiquidityLock.compound` as not
having run. The invariant and fork test suites are the only coverage those paths
currently have.

---

## 2. Findings not fixed in code

Grouped by detector, with Slither's impact rating.

### arbitrary-send-erc20 — high — not a defect

`BondingCurve._pullToken` is reported for passing a non-literal `from` to
`transferFrom`. It is a private helper with exactly one call site, `sell`, which
passes `msg.sender`. No caller can choose `from`.

### uninitialized-state — high — false positive

`token`, `gradDeadline`, `sqrtPriceTerminal`, `totalFeeBps`, `creatorShareBps`,
`protocolShareBps` and `capReachedAt` are all reported as never initialized. All
seven are assigned in the constructor, which Slither failed to parse; see
section 1. `capReachedAt` is also written in `_buy`, which also failed to parse.
The runtime behaviour is covered by the fork tests — in particular the test that
`graduateAlt` reverts before `ALT_DELAY`, which can only pass if `capReachedAt`
holds a non-zero value.

### locked-ether — medium — intended

`LiquidityLock` accepts ETH and has no withdrawal function. That is the contract's
purpose. Its `receive` additionally rejects every sender other than PoolManager
and PositionManager, so the only ETH that can arrive is a position's residual
`currency0` and PositionManager's native-value sweep; no one can strand their own
ETH there by mistake.

### divide-before-multiply — medium — intended

`TickAlign.down` and `TickAlign.up` divide by the tick spacing and multiply back.
The discarded remainder is the alignment itself, not a loss of precision. Both
sites carry an inline suppression.

### unused-return — medium — intended, four sites

- `poolManager.unlock` returns the callback's encoded result; the price-restoring
  callback returns an empty value and the caller re-reads the restored price from
  `slot0`.
- `poolManager.getSlot0` is destructured for `tick` alone; the other three fields
  are deliberately unused, and reading `tick` rather than deriving it from
  `sqrtPriceX96` is required by the specification.
- `positionManager.getPoolAndPositionInfo` is destructured for the pool key alone.
- `curve.creatorFirstBuy` returns the base units bought; the factory does not need
  them, and the amount reaches indexers through `CreatorVesting`'s
  `VestingCreated` event.

### incorrect-equality — medium — not applicable

`CreatorVesting.release` tests `amount == 0` to reject a no-op release. The
detector is aimed at strict equality against a balance or a timestamp; this is a
zero check on a computed amount.

### reentrancy-benign — low — guarded, three sites

`_restorePrice` writes its own `_unlocking` flag after `poolManager.unlock`
returns, which is the flag's purpose. `LaunchFactory.createLaunch` writes
`isLaunch` and the reputation counters after deploying the curve; the curve is
created by that same call and cannot be a third party. No value moves on any of
the three paths after the write.

### timestamp — low — excluded project-wide

Excluded in `foundry.toml`'s `[lint]` section with its reason: `docs/CHAIN_FACTS.md`
rules out `block.number` on this Arbitrum Nitro chain and specification section 1
requires `block.timestamp` for all time logic. Reported here for completeness
because Slither applies the detector regardless of the Foundry linter's settings.

### low-level-calls — informational — intended

`BondingCurve._sendEth` uses `call` so that a recipient contract's failure to
accept ETH is a revert of the claim rather than a permanently stuck balance.

### dead-code — informational — false positive

`_mintCore`, `_mintFloor`, `_restorePrice`, `_mintData`, `_floorLiquidity` and
`_approvePositionManager` are reported as never used. They are called from
`_settle` and from each other; `_settle` is one of the six functions that failed
to parse. See section 1.

### constable-states — informational — false positive

`capReachedAt` and `graduatedAt` are reported as constant. They are written in
`_buy` and `_settle` respectively, both of which failed to parse. See section 1.

---

## 3. What static analysis here does not cover

Recorded so that a green pipeline is not read as more than it is.

- The six function bodies of section 1, which include all of graduation.
- Economic behaviour. No detector can tell whether the curve's terminal price
  matches the pool's opening price, which is the property that removes the
  migration sandwich. That is `contracts/test/fork/` and the invariant suite.
- The Uniswap v4 integration. Every v4 assumption this protocol relies on is
  verified by fork test against the live deployment, not by analysis.
- Anything in `docs/THREAT_MODEL.md` section 10, which lists what the design does
  not prevent at all.
