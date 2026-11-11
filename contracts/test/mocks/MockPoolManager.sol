// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title Deterministic stand-in for Uniswap v4's PoolManager
/// @notice Implements only the five entry points the protocol calls — `initialize`,
/// `unlock`, `swap`, `extsload` and the native-ETH receive — and implements them with the
/// behaviour measured against the live deployment in `contracts/test/fork`.
/// @dev Test-only, and deliberately narrow. It exists because `foundry.toml` pins
/// `solc_version = 0.8.38` while `PoolManager.sol` pins `=0.8.26`, so the real core
/// contract cannot be compiled into this project and the deterministic suite — which CI
/// runs with no network — has no way to deploy one. Everything this mock asserts about v4
/// is pinned against the real contracts by `test/fork/V4Assumptions.t.sol` and
/// `test/fork/Graduation.fork.t.sol`; nothing here is a substitute for those.
///
/// As in `MockPositionManager`, every behaviour is marked with where it was checked.
/// `verified` means the line of v4-core it models was read and is named here; `inferred`
/// means nothing has confirmed it. The one inferred behaviour in that mock's `SWEEP` was a
/// high-severity defect's hiding place, so the list is kept complete rather than
/// flattering.
///
/// Modelled and verified against the real source:
///
/// - `slot0` is readable through `extsload` at `keccak256(poolId, bytes32(6))`, which is
///   the slot `StateLibrary` computes (`StateLibrary.POOLS_SLOT` and
///   `_getPoolStateSlot`, `libraries/StateLibrary.sol:11` and `:324-326`), packed as
///   `sqrtPriceX96 | tick << 160 | protocolFee << 184 | lpFee << 208`
///   (`types/Slot0.sol:36-38`), so `BondingCurve`'s `getSlot0` calls exercise the real
///   read path rather than a convenience getter;
/// - `initialize` reverts `Pool.PoolAlreadyInitialized()` when `slot0.sqrtPriceX96` is
///   already non-zero, and returns `TickMath.getTickAtSqrtPrice(sqrtPriceX96)`
///   (`libraries/Pool.sol:100-107`);
/// - `swap` rejects `amountSpecified == 0` with `SwapAmountCannotBeZero()`
///   (`PoolManager.sol:193`), requires the pool to be initialised
///   (`PoolManager.sol:196`, `Pool.checkPoolInitialized`), and rejects a
///   `sqrtPriceLimitX96` that is not strictly on the near side of the current price —
///   `limit >= current` for `zeroForOne` and `limit <= current` otherwise — with
///   `PriceLimitAlreadyExceeded` (`libraries/Pool.sol:322-338`). The equality case is why
///   `graduate` has to guard its restoring swap with an `if`, and the inequality case is
///   why it has to pick the direction from the comparison rather than guess;
/// - `unlock` refuses to nest (`AlreadyUnlocked`) and `swap` refuses to run outside an
///   unlock (`ManagerLocked`): `PoolManager.sol:104-114` and the `onlyWhenUnlocked`
///   modifier at `:95-98`.
///
/// Inferred, not verified:
///
/// - a swap in a pool with no liquidity settles for nothing in both currencies and leaves
///   the price at the limit. This is the one assumption the protocol's free price
///   restoration rests on, it is a property of `Pool.swap`'s loop rather than of a line
///   that states it, and it is measured against the deployed PoolManager by
///   `test/fork/V4Assumptions.t.sol` and `test/fork/Graduation.fork.t.sol` — not here;
/// - `initialize` performs none of the key validation the real one does: tick spacing
///   within `[1, 32767]`, currencies in order, a valid hook address, an LP fee inside
///   `MAX_LP_FEE` (`PoolManager.sol:117-134`). Every one of those is a function of
///   protocol constants and the token address, so none can fire at any permitted
///   parameter set — but this mock would accept a key that the chain rejects;
/// - there is no delta ledger. The real `unlock` reverts `CurrencyNotSettled` when a
///   currency is left open and `take`/`settle` move balances against it; here a swap's
///   reported delta is a number a test chose and nothing accounts for it. `swap` moves no
///   ETH and no token in either direction;
/// - `receive()` stands in for `settle()`. The real PoolManager has no `receive` at all
///   and is paid through `settle{value:}` inside an unlock, so a plain transfer to it
///   reverts on chain and succeeds here. Only `MockPositionManager` pays it, and the only
///   thing either mock does with the ETH afterwards is hold it.
///
/// The knobs (`setSwapDelta`, `setSwapRestoresPrice`, `pokeSlot0`, `pokeTick`,
/// `setLiquidity`) exist to reach the defensive branches of `graduate` that cannot be
/// reached on a healthy pool, each of which would be unrecoverable in production if it
/// were wrong. They have no counterpart in the real contract.
contract MockPoolManager {
    /// @dev `StateLibrary.POOLS_SLOT`. The protocol reads `slot0` through `extsload`, so
    /// the mock has to store it where the real contract stores it.
    uint256 private constant POOLS_SLOT = 6;

    /// @notice True once `initialize` has been called for a pool id.
    mapping(PoolId => bool) public initialized;
    /// @notice Liquidity the mock believes a pool holds. Zero unless a test sets it.
    mapping(PoolId => uint128) public liquidity;

    /// @notice Every `initialize` call this mock has seen, in order.
    PoolId[] public initializedPools;

    /// @notice Net delta `swap` reports, non-zero only when a test forces it.
    int128 private _swapAmount0;
    int128 private _swapAmount1;
    /// @notice When false, `swap` leaves the price where it was.
    bool private _swapRestoresPrice = true;
    /// @notice Number of `swap` calls, so a test can prove the `if` guard skipped one.
    uint256 public swapCalls;
    /// @notice The direction of the last swap, so a test can check the one `graduate`
    /// chose: a pool price above `sqrtPriceTerminal` must be restored `zeroForOne`.
    bool public lastSwapZeroForOne;
    /// @notice The limit the last swap nominated.
    uint160 public lastSwapLimit;
    /// @notice The size the last swap nominated. `PoolManager` rejects zero.
    int256 public lastSwapAmountSpecified;

    /// @notice A pool was initialised.
    event Initialize(PoolId indexed id, uint160 sqrtPriceX96, int24 tick);
    /// @notice A swap was executed.
    event Swap(PoolId indexed id, bool zeroForOne, int256 amountSpecified, uint160 limit);

    /// @notice True while a callback this mock started is running, as `Lock` is on the
    /// real contract. `swap` is refused outside one and `unlock` refuses to nest.
    bool private _unlocked;

    /// @notice When non-empty, every `initialize` reverts with exactly this data.
    bytes private _initializeRevertData;

    /// @dev Native ETH settled by a mint. The mock keeps it, as the real one does.
    receive() external payable {}

    /// @notice Initialises a pool at a price, as `PoolManager.initialize` does.
    /// @param key The pool key.
    /// @param sqrtPriceX96 The starting price.
    /// @return tick The tick of that price.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolId id = key.toId();
        // Fault injection. The real `initialize` has four other refusals — tick spacing out
        // of range, an LP fee above `MAX_LP_FEE`, currencies out of order, a hook address
        // v4 rejects — and every one of them is a function of this protocol's own constants
        // and of the token address, so none can fire at any permitted parameter set.
        // Invariant 65 nonetheless requires that the constructor suppress none of them, and
        // this is the only way a test can produce one.
        if (_initializeRevertData.length != 0) {
            bytes memory data = _initializeRevertData;
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        if (initialized[id]) revert Pool.PoolAlreadyInitialized();

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        initialized[id] = true;
        initializedPools.push(id);
        _writeSlot0(id, sqrtPriceX96, tick);

        emit Initialize(id, sqrtPriceX96, tick);
    }

    /// @notice Hands control back to the caller, as `PoolManager.unlock` does.
    /// @param data Opaque payload handed to the callback.
    /// @return result The callback's return value.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_unlocked) revert IPoolManager.AlreadyUnlocked();
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        // The real contract reverts `CurrencyNotSettled` here if any currency is still
        // open. This mock keeps no delta ledger, so it cannot: see the class list above.
        _unlocked = false;
    }

    /// @notice Swaps against a pool with no liquidity, which costs nothing and moves the
    /// price to the limit.
    /// @param key The pool key.
    /// @param params The swap parameters.
    /// @return delta The net delta, zero unless a test forced one.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta delta)
    {
        if (!_unlocked) revert IPoolManager.ManagerLocked();
        if (params.amountSpecified == 0) revert IPoolManager.SwapAmountCannotBeZero();

        PoolId id = key.toId();
        (uint160 current,) = _readSlot0(id);
        if (current == 0) revert Pool.PoolNotInitialized();
        // The real check is an inequality in both directions, not an equality: a limit on
        // the far side of the current price is refused just as a limit equal to it is.
        // Equality is the case `graduate`'s `if` guard exists for; the far side is the case
        // its choice of direction exists for, and a mock that only modelled equality would
        // accept a swap the chain refuses.
        bool exceeded = params.zeroForOne
            ? params.sqrtPriceLimitX96 >= current
            : params.sqrtPriceLimitX96 <= current;
        if (exceeded) {
            revert Pool.PriceLimitAlreadyExceeded(current, params.sqrtPriceLimitX96);
        }

        swapCalls++;
        lastSwapZeroForOne = params.zeroForOne;
        lastSwapLimit = params.sqrtPriceLimitX96;
        lastSwapAmountSpecified = params.amountSpecified;
        if (_swapRestoresPrice) {
            _writeSlot0(
                id, params.sqrtPriceLimitX96, TickMath.getTickAtSqrtPrice(params.sqrtPriceLimitX96)
            );
        }

        emit Swap(id, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        return toBalanceDelta(_swapAmount0, _swapAmount1);
    }

    /// @notice The `extsload` of `IExtsload`, which is how `StateLibrary` reads `slot0`.
    /// @param slot The storage slot to read.
    /// @return value The word at that slot.
    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    /// @notice Reads a pool's price and tick the way the protocol does.
    /// @param id The pool id.
    /// @return sqrtPriceX96 The pool's price.
    /// @return tick The pool's tick.
    function slot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return _readSlot0(id);
    }

    /// @notice How many pools this mock has initialised.
    function initializedPoolCount() external view returns (uint256) {
        return initializedPools.length;
    }

    /// @notice Forces `swap` to report a non-zero net delta, which is what hostile
    /// liquidity in the pool would do.
    function setSwapDelta(int128 amount0, int128 amount1) external {
        _swapAmount0 = amount0;
        _swapAmount1 = amount1;
    }

    /// @notice Forces `swap` to leave the price unmoved.
    function setSwapRestoresPrice(bool restores) external {
        _swapRestoresPrice = restores;
    }

    /// @notice Sets a pool's price and tick directly, which is how a test moves a pool
    /// out from under `graduate`.
    function pokeSlot0(PoolId id, uint160 sqrtPriceX96, int24 tick) external {
        _writeSlot0(id, sqrtPriceX96, tick);
    }

    /// @notice Sets only the tick, leaving the price alone. `Pool.swap` can leave the two
    /// disagreeing by one tick, which is why the protocol reads the tick and never derives
    /// it from the price.
    function pokeTick(PoolId id, int24 tick) external {
        (uint160 price,) = _readSlot0(id);
        _writeSlot0(id, price, tick);
    }

    /// @notice Records liquidity for a pool. Read by `MockPositionManager` only.
    function setLiquidity(PoolId id, uint128 amount) external {
        liquidity[id] = amount;
    }

    /// @notice Makes every `initialize` call revert with this exact data, whatever the
    /// pool's state. Empty data clears it.
    /// @dev Fault injection for Invariant 65, which is about the four refusals of the real
    /// `initialize` that this mock does not model and that no permitted parameter set can
    /// reach.
    function setInitializeRevertData(bytes calldata data) external {
        _initializeRevertData = data;
    }

    /// @notice The storage slot `StateLibrary` reads a pool's `slot0` from.
    function slot0Slot(PoolId id) external pure returns (bytes32) {
        return _slot0Slot(id);
    }

    /// @notice The storage slot `StateLibrary` reads a pool's active liquidity from.
    /// @dev `StateLibrary.LIQUIDITY_OFFSET` is 3 words into `Pool.State`. Exposed so a test
    /// can assert against `vm.accesses` that no Pledrin contract ever reads it, which is
    /// the second clause of Invariant 38.
    function liquiditySlot(PoolId id) external pure returns (bytes32) {
        return bytes32(uint256(_slot0Slot(id)) + 3);
    }

    /// @dev `slot0` packs `sqrtPriceX96 | tick << 160 | protocolFee << 184 | lpFee << 208`.
    function _writeSlot0(PoolId id, uint160 sqrtPriceX96, int24 tick) private {
        bytes32 slot = _slot0Slot(id);
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160);
        assembly ("memory-safe") {
            sstore(slot, packed)
        }
    }

    function _readSlot0(PoolId id) private view returns (uint160 sqrtPriceX96, int24 tick) {
        bytes32 slot = _slot0Slot(id);
        bytes32 data;
        assembly ("memory-safe") {
            data := sload(slot)
        }
        sqrtPriceX96 = uint160(uint256(data));
        tick = int24(uint24(uint256(data) >> 160));
    }

    /// @dev `StateLibrary._getPoolStateSlot`.
    function _slot0Slot(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(POOLS_SLOT)));
    }
}
