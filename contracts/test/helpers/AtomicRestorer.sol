// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

import {PoolSwapHelper} from "./PoolSwapHelper.sol";

/// @notice A third party that moves a griefed pool back to a launch's terminal price and
/// graduates the launch in the same transaction.
/// @dev Not a model of anything in `contracts/src`: it calls two public functions that any
/// address may call, holds nothing, and has no privilege. It exists because the recovery
/// path for a griefed graduation is only a recovery path if it is **atomic** — restoring a
/// zero-liquidity pool's price is permissionless, so a griefer can always move it back
/// before the next block, and a restore in one transaction followed by a `graduate()` in
/// another is a race the griefer wins. Doing both in one transaction is not a race at all.
///
/// Finding 3 of `docs/security/REVIEW-2026-11-11-phase1-contracts.md` observed that this
/// mechanism is what actually saves a griefed graduation and that nothing in the
/// repository exercised it. `docs/SPEC.md` section 8.6 specifies a shipped
/// `GraduationHelper` for the same job; this is not that contract and is not a stand-in
/// for it — when it exists, Invariant 68 is about it and this stays what it is, the
/// smallest thing that shows the path works from an arbitrary address.
contract AtomicRestorer {
    PoolSwapHelper public immutable swapper;

    constructor(PoolSwapHelper swapper_) {
        swapper = swapper_;
    }

    receive() external payable {}

    /// @notice Restores `key`'s price to `sqrtPriceTerminal` and graduates `curve`.
    /// @param curve The launch to graduate.
    /// @param key The pool key to restore.
    /// @param zeroForOne Direction of the restoring swap.
    /// @param sqrtPriceTerminal The price to restore to, which is the launch's terminal
    /// price and the only price at which it will mint.
    function restoreAndGraduate(
        IBondingCurve curve,
        PoolKey memory key,
        bool zeroForOne,
        uint160 sqrtPriceTerminal
    ) external payable {
        swapper.swap{value: msg.value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: sqrtPriceTerminal
            })
        );
        curve.graduate();
    }
}
