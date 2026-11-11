// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title Deterministic stand-in for Uniswap v4's PoolManager
/// @notice Implements only the entry points the protocol calls — `initialize`, `unlock`,
/// `swap`, `sync`, `settle`, `take`, `extsload` and the native-ETH receive — and
/// implements them with the behaviour measured against the live deployment in
/// `contracts/test/fork`.
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
///   modifier at `:95-98`;
/// - `sync(currency)` takes no lock and is two cases: for native it only resets the synced
///   currency, because "the reserves balance is not used for native settling", and for an
///   ERC-20 it records the currency together with `balanceOfSelf()` as the reserves the
///   next settlement is measured against (`PoolManager.sol:279-288`,
///   `CurrencyReserves.syncCurrencyAndReserves` and `resetCurrency`);
/// - `settle()` is `onlyWhenUnlocked` and credits `msg.sender`. It credits `msg.value`
///   when the synced currency is native **or was never synced**, and otherwise
///   `balanceOfSelf() - syncedReserves`, in which case a non-zero `msg.value` is refused
///   with `NonzeroNativeValue` and the synced currency is reset
///   (`PoolManager.sol:300-302` and `_settle`, `:349-366`). So `sync`, `transfer`,
///   `settle` in that order is the protocol's token-settling sequence and not a choice,
///   which is what `GraduationHelper._settleToken` says at its own call site;
/// - `take(currency, to, amount)` is `onlyWhenUnlocked`, debits `msg.sender` by `amount`
///   and then transfers that much of the currency out of this contract to `to`
///   (`PoolManager.sol:291-297`);
/// - the delta ledger those three move against: `_accountDelta` ignores a zero delta and
///   maintains a count of the (address, currency) pairs with an open balance, and `unlock`
///   reverts `CurrencyNotSettled` when that count is non-zero at the end of the callback
///   (`PoolManager.sol:112`, `:368-379`). `swap` accounts its own reported delta to the
///   locker, both currencies, exactly as `_accountPoolBalanceDelta` does (`:382-384`).
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
/// - the ledger is the accounting and nothing else. This mock holds no pool reserves, so a
///   `take` pays out of whatever balance a test funded this contract with and a `settle`
///   simply keeps what it is paid: a swap's reported delta is still a number a test chose,
///   and nothing here checks that the two sides of a pool's book add up. `swap` itself
///   moves no ETH and no token in either direction — only `settle` and `take` do;
/// - the ledger and the synced currency are ordinary storage, where the real contract
///   keeps both in transient slots. A delta opened inside a call that reverts is rolled
///   back either way; what differs is that a second `unlock` in the same transaction
///   starts from this mock's persisted value rather than from a cleared transient slot,
///   and a settled unlock leaves both at zero;
/// - `receive()` is still here, and the real PoolManager has none: it is paid through
///   `settle{value:}` inside an unlock, so a plain transfer to it reverts on chain and
///   succeeds here. `MockPositionManager` pays this way because that is how it models
///   `SETTLE_PAIR`'s native leg, and the only thing either mock does with the ETH
///   afterwards is hold it;
/// - `LockTaken` and `LockReleased` have no counterpart in the real contract at all.
///   They exist so a test can prove *when* a transfer into this contract happened:
///   `settle` and `take` are guarded by the lock, but a token transfer to this address is
///   a call on the token and nothing here could refuse it, so the second clause of
///   Invariant 68 — settlement to the PoolManager inside that swap's own lock, and nowhere
///   else — is checked by log order against these two.
///
/// The knobs (`setSwapDelta`, `setSwapRestoresPrice`, `pokeSlot0`, `pokeTick`,
/// `setLiquidity`) exist to reach the defensive branches of `graduate` that cannot be
/// reached on a healthy pool, each of which would be unrecoverable in production if it
/// were wrong. They have no counterpart in the real contract.
contract MockPoolManager {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

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
    /// @notice A currency was synced, so the next `settle` measures against this balance.
    event Sync(Currency indexed currency, uint256 reserves);
    /// @notice A debt was settled. `paid` is what the ledger credited `payer` with.
    event Settle(address indexed payer, Currency indexed currency, uint256 paid);
    /// @notice A credit was taken out of this contract.
    event Take(address indexed taker, Currency indexed currency, address to, uint256 amount);
    /// @notice The lock was taken. Test-only: the real contract emits nothing here.
    event LockTaken(address indexed locker);
    /// @notice The lock was released, with the open-delta count that let it be.
    event LockReleased(address indexed locker, uint256 nonzeroDeltas);

    /// @notice True while a callback this mock started is running, as `Lock` is on the
    /// real contract. `swap` is refused outside one and `unlock` refuses to nest.
    bool private _unlocked;

    /// @notice When non-empty, every `initialize` reverts with exactly this data.
    bytes private _initializeRevertData;

    /// @notice What this contract owes an address in a currency (positive) or is owed by
    /// it (negative), as `PoolManager`'s transient `currencyDelta` does.
    mapping(address target => mapping(Currency currency => int256)) public currencyDelta;
    /// @notice How many (address, currency) pairs currently have an open delta.
    uint256 public nonzeroDeltaCount;

    /// @dev The currency `sync` last named, and the balance it recorded for it. The zero
    /// address means native or never synced, which `_settle` treats identically.
    Currency private _syncedCurrency;
    uint256 private _syncedReserves;

    /// @notice Call counts, so a test can assert that a path settled nothing at all.
    uint256 public settleCalls;
    uint256 public takeCalls;
    uint256 public syncCalls;
    /// @notice Everything this contract has been paid through `settle`, by currency.
    mapping(Currency currency => uint256) public settledTotal;
    /// @notice Everything that has left through `take`, by currency.
    mapping(Currency currency => uint256) public takenTotal;

    /// @dev Refuses a call made while the lock is not held, with the error the real
    /// contract's own `onlyWhenUnlocked` gives. `settle` and `take` carry it because the
    /// real ones do, which is what makes a settlement outside a swap's lock unreachable
    /// rather than merely unused.
    modifier onlyWhenUnlocked() {
        if (!_unlocked) revert IPoolManager.ManagerLocked();
        _;
    }

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
        emit LockTaken(msg.sender);
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        // As the real one does, and for the same reason: a currency left open means the
        // locker took value out of the pool and did not pay for it.
        if (nonzeroDeltaCount != 0) revert IPoolManager.CurrencyNotSettled();
        emit LockReleased(msg.sender, nonzeroDeltaCount);
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

        delta = toBalanceDelta(_swapAmount0, _swapAmount1);
        // `_accountPoolBalanceDelta`: the swap's delta belongs to the locker, in both
        // currencies, and has to be closed before `unlock` returns.
        _accountDelta(key.currency0, _swapAmount0, msg.sender);
        _accountDelta(key.currency1, _swapAmount1, msg.sender);
    }

    /// @notice Records the balance the next `settle` of `currency` is measured against.
    /// @dev `PoolManager.sync`. Takes no lock, and for native does nothing but reset.
    /// @param currency The currency to sync.
    function sync(Currency currency) external {
        syncCalls++;
        if (currency.isAddressZero()) {
            _syncedCurrency = CurrencyLibrary.ADDRESS_ZERO;
            _syncedReserves = 0;
            emit Sync(currency, 0);
        } else {
            uint256 balance = currency.balanceOfSelf();
            _syncedCurrency = currency;
            _syncedReserves = balance;
            emit Sync(currency, balance);
        }
    }

    /// @notice Credits the caller for what they have paid, as `PoolManager.settle` does.
    /// @return paid The amount credited.
    function settle() external payable onlyWhenUnlocked returns (uint256 paid) {
        settleCalls++;
        Currency currency = _syncedCurrency;
        if (currency.isAddressZero()) {
            paid = msg.value;
        } else {
            if (msg.value > 0) revert IPoolManager.NonzeroNativeValue();
            uint256 reservesNow = currency.balanceOfSelf();
            paid = reservesNow - _syncedReserves;
            _syncedCurrency = CurrencyLibrary.ADDRESS_ZERO;
            _syncedReserves = 0;
        }

        settledTotal[currency] += paid;
        emit Settle(msg.sender, currency, paid);
        _accountDelta(currency, paid.toInt128(), msg.sender);
    }

    /// @notice Pays a credit out of this contract, as `PoolManager.take` does.
    /// @param currency The currency to pay.
    /// @param to The recipient.
    /// @param amount The amount.
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        takeCalls++;
        takenTotal[currency] += amount;
        emit Take(msg.sender, currency, to, amount);
        _accountDelta(currency, -(amount.toInt128()), msg.sender);
        currency.transfer(to, amount);
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

    /// @notice The currency `sync` last named, zero for native or never synced.
    function syncedCurrency() external view returns (Currency) {
        return _syncedCurrency;
    }

    /// @dev `PoolManager._accountDelta`: a zero delta is ignored, and the open-delta count
    /// moves only when a pair's balance leaves or reaches zero.
    function _accountDelta(Currency currency, int128 delta, address target) private {
        if (delta == 0) return;

        int256 previous = currencyDelta[target][currency];
        int256 next = previous + delta;
        currencyDelta[target][currency] = next;

        if (next == 0) {
            nonzeroDeltaCount--;
        } else if (previous == 0) {
            nonzeroDeltaCount++;
        }
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
