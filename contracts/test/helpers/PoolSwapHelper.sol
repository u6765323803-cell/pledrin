// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Minimal `unlock`-callback swapper against the real PoolManager.
/// @dev Test-only. Deliberately written against `PoolManager` directly rather than
/// through UniversalRouter so that the swap parameters the tests exercise — in
/// particular `amountSpecified` and `sqrtPriceLimitX96` — reach the pool verbatim
/// and nothing in a router can mask the behaviour being measured. It settles and
/// takes whatever the swap returns, so the recorded delta is the pool's own answer.
contract PoolSwapHelper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    error NotPoolManager();

    struct CallbackData {
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    receive() external payable {}

    /// @notice Executes one swap and returns the caller-facing balance delta.
    function swap(PoolKey memory key, SwapParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory result =
            poolManager.unlock(abi.encode(CallbackData({key: key, params: params})));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");
        _resolve(data.key.currency0, delta.amount0());
        _resolve(data.key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _resolve(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            poolManager.sync(currency);
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
