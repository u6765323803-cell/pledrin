#!/usr/bin/env bash
#
# Writes one ABI file per deployable contract into contracts/abi/, which is what the
# indexer and the web app build against. Phase 2 works from these files rather than from
# contracts/out/, so that a contract change cannot silently alter what those two consume:
# CI regenerates and diffs, so any change to an ABI has to appear in a reviewed commit.
#
# The output is only the `abi` array, not the whole Foundry artifact. Artifacts carry
# bytecode, metadata and compiler settings that churn on every unrelated build, which
# would make the diff check noise instead of a signal.
#
# Usage: freeze-abi.sh [artifact-root]   (default: contracts/out)
set -euo pipefail

root="${1:-contracts/out}"
dest="contracts/abi"

if [ ! -d "$root" ]; then
  echo "freeze-abi: no artifacts at '$root' — run 'forge build' first" >&2
  exit 1
fi

mkdir -p "$dest"

# Interfaces and libraries are deliberately absent. An interface's ABI is a subset of the
# concrete contract's, and events are emitted by the concrete contract, so consuming the
# interface would hand Phase 2 an incomplete event set.
contracts=(
  BondingCurve
  CreatorVesting
  CurveDeployer
  LaunchFactory
  LiquidityLock
  PledrinToken
  Timelock
  TokenDeployer
)

for name in "${contracts[@]}"; do
  src="$root/$name.sol/$name.json"
  if [ ! -f "$src" ]; then
    echo "freeze-abi: missing artifact for $name at $src" >&2
    exit 1
  fi
  # Sorted keys and a fixed indent, so the file is a function of the ABI alone and two
  # builds of the same sources produce byte-identical output.
  python3 -c "
import json, sys
abi = json.load(open(sys.argv[1]))['abi']
with open(sys.argv[2], 'w') as f:
    json.dump(abi, f, indent=2, sort_keys=True)
    f.write('\n')
" "$src" "$dest/$name.json"
  echo "freeze-abi: wrote $dest/$name.json"
done
