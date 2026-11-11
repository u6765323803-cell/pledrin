#!/usr/bin/env bash
# Gate on line and branch coverage parsed from an lcov report.
#
# Usage: coverage-gate.sh <lcov-file> <minimum-percent>
#
# lcov records totals per source file as LF/LH (lines found/hit) and
# BRF/BRH (branches found/hit). We sum them across files and compare the
# resulting rates against the minimum.
set -euo pipefail

lcov_file=${1:?usage: coverage-gate.sh <lcov-file> <minimum-percent>}
minimum=${2:?usage: coverage-gate.sh <lcov-file> <minimum-percent>}

if [[ ! -s $lcov_file ]]; then
  echo "coverage-gate: '$lcov_file' is missing or empty" >&2
  exit 1
fi

awk -v minimum="$minimum" '
  /^LF:/  { lines_found   += substr($0, 4) }
  /^LH:/  { lines_hit     += substr($0, 4) }
  /^BRF:/ { branches_found += substr($0, 5) }
  /^BRH:/ { branches_hit   += substr($0, 5) }
  END {
    if (lines_found == 0) {
      print "coverage-gate: no lines found in report" > "/dev/stderr"
      exit 1
    }

    line_rate = 100 * lines_hit / lines_found
    printf "lines    %7.2f%%  (%d/%d)\n", line_rate, lines_hit, lines_found

    failed = 0
    if (line_rate < minimum) failed = 1

    if (branches_found == 0) {
      print "branches     n/a  (no branches in scope)"
    } else {
      branch_rate = 100 * branches_hit / branches_found
      printf "branches %7.2f%%  (%d/%d)\n", branch_rate, branches_hit, branches_found
      if (branch_rate < minimum) failed = 1
    }

    printf "minimum  %7.2f%%\n", minimum
    if (failed) {
      print "coverage-gate: below minimum" > "/dev/stderr"
      exit 1
    }
    print "coverage-gate: pass"
  }
' "$lcov_file"
