// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";

import {MockPermit2} from "./MockPermit2.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @title Deterministic stand-in for Uniswap v4's PositionManager
/// @notice Executes the two action batches the protocol builds — the `MINT_POSITION`,
/// `SETTLE_PAIR`, `SWEEP` batch of `BondingCurve._mintData` and the `DECREASE_LIQUIDITY`,
/// `INCREASE_LIQUIDITY_FROM_DELTAS`, `CLOSE_CURRENCY`, `CLOSE_CURRENCY` batch of
/// `LiquidityLock._compoundData` — and nothing else.
/// @dev Test-only, and faithful where it matters. The amount a mint owes is computed with
/// the real `SqrtPriceMath` at the real rounding direction (`roundUp = true`, as
/// `Pool.modifyLiquidity` uses when liquidity is added), against the tick the pool
/// actually reports, so the token shortfall this mock produces for the core position is
/// the same number the live PositionManager produces: 1,088 base units at the default
/// `virtualEthReserve`, which `test/fork/Graduation.fork.t.sol` measures against the real
/// contract and `test/unit/BondingCurveGraduation.t.sol` asserts here.
///
/// It exists because `foundry.toml` pins `solc_version = 0.8.38` and `PositionManager.sol`
/// pins `^0.8.26` through a core that pins `=0.8.26`, so the real periphery cannot be
/// compiled into this project, and the deterministic suite runs with no network.
///
/// **Each behaviour below is marked with where it was checked.** `verified` means the
/// line of v4-periphery or v4-core it models was read and is named; `inferred` means it is
/// this mock's reading of what the real contract would do and nothing has confirmed it.
/// The distinction is not pedantry: this mock modelled `SWEEP` as a refund of the mint's
/// unspent value for one release cycle, reproduced all three fork-measured dust figures
/// exactly while doing so, and therefore made finding 1 of
/// `docs/security/REVIEW-2026-11-11-phase1-contracts.md` — a high-severity, protocol-wide
/// denial of graduation — invisible to every test in the suite. An inferred behaviour is
/// where the next one of those hides.
///
/// Modelled and verified against the real source:
///
/// - `SWEEP` sends the **entire** balance of the named currency, not the mint's unspent
///   remainder (`PositionManager._sweep`, `PositionManager.sol:499-502`:
///   `currency.balanceOfSelf()` then `currency.transfer(to, balance)`). The recipient
///   sentinels are mapped as `BaseActionsRouter._mapRecipient` maps them
///   (`base/BaseActionsRouter.sol:61-69`);
/// - the native leg of `SETTLE_PAIR` is paid out of **this contract's balance** rather
///   than out of `msg.value`: `DeltaResolver._settle` calls `poolManager.settle{value:
///   amount}()` (`base/DeltaResolver.sol:38-48`), which spends PositionManager's balance,
///   and `msg.value` is only how that balance usually arrives;
/// - a range strictly above the current tick owes `currency0` only, which is what makes
///   the floor position an ETH bid and needs no token approval, and the three-branch
///   amount computation is `Pool.modifyLiquidity`'s
///   (`v4-core/src/libraries/Pool.sol:206-237`), including that it compares `slot0.tick`
///   against the range and uses `slot0.sqrtPriceX96` for the in-range branch;
/// - `amount0Max` / `amount1Max` are enforced with v4's own
///   `SlippageCheck.MaximumAmountExceeded` and in the same direction
///   (`libraries/SlippageCheck.sol:38-52`, reached from `PositionManager._mint`, `:384`);
/// - the token is collected through Permit2 by `permit2.transferFrom(payer, poolManager,
///   amount, token)`, so both approval legs must be present (`PositionManager._pay`,
///   `:528-535`, taking the `payer != address(this)` branch because the payer is the
///   locker);
/// - `nextTokenId` starts at 1 and is assigned before the increment
///   (`PositionManager.sol:121` and `:365-367`);
/// - minting does **not** call `onERC721Received` on the recipient
///   (`PositionManager._mint` calls solmate's `_mint`, `:369`), which is why
///   `LiquidityLock.onERC721Received` is never reached by a graduation;
/// - `modifyLiquidities` rejects a passed deadline with `DeadlinePassed(deadline)`
///   (`checkDeadline`, `:146-149`);
/// - a mint adds to the pool's *active* liquidity only when the position's range contains
///   the current tick, because that is the only branch in which `Pool.modifyLiquidity`
///   touches `self.liquidity` (`v4-core/src/libraries/Pool.sol:226`). So the floor
///   position, whose range starts above the tick, adds nothing to it;
/// - `receive()` refuses ETH from anyone but the PoolManager
///   (`NativeWrapper.receive`, `base/NativeWrapper.sol:31-33`, which also admits WETH9 —
///   this mock has no WETH9 and models no wrap action). A balance can still be forced in
///   by `SELFDESTRUCT` or by a block reward, which is what `vm.deal` stands for in the
///   tests that park one.
///
/// Inferred, not verified, and listed so the list is complete:
///
/// - the residual of a compounding goes to the position's owner. The real router takes it
///   to `msgSender()` (`PositionManager._close` -> `_take`, `:468-481`), which is the lock
///   for every call the lock makes, so the two coincide here and would diverge for any
///   other caller;
/// - the amounts a compounding's `INCREASE_LIQUIDITY_FROM_DELTAS` consumes are recomputed
///   from the liquidity it added, rather than being the deltas the PoolManager actually
///   opened. The real figure is `Pool.modifyLiquidity`'s and is what `CLOSE_CURRENCY`
///   settles against;
/// - a batch is dispatched by matching the whole action array against the two batches the
///   protocol builds, where the real router dispatches each action independently
///   (`PositionManager._handleAction`). Any other batch reverts `UnsupportedActions`
///   rather than executing;
/// - `SETTLE_PAIR`'s own parameters are not decoded: the mock settles the amounts the
///   mint computed, where the real action settles whatever debt is open in each currency;
/// - `getPositionLiquidity`, `getPoolAndPositionInfo` and `ownerOf` answer from this
///   mock's own record of the mint. The real `getPositionLiquidity` reads the
///   PoolManager's position storage through `Position.calculatePositionKey`
///   (`PositionManager.sol:566-574`), so the two would diverge for any position the pool
///   changed without this mock being told;
/// - fault injection — `setMintTokenShortfall`, `setProbe`,
///   `setLiquidityDeltaOverride`, `mintBare`, `accrueFees` — has no counterpart in the
///   real contract at all. Each exists to reach a defensive branch of the protocol that a
///   healthy v4 cannot produce, and each is named at its definition;
/// - nothing here models v4-core's delta ledger. The real `PoolManager.unlock` reverts
///   `CurrencyNotSettled` if any currency is left open at the end of the batch, and the
///   real `modifyLiquidities` runs the whole batch inside one `unlock`. This mock settles
///   action by action and never unlocks, so a batch that left a currency open would pass
///   here and revert on chain.
///
/// Everything in both lists that can be observed from outside is pinned against the
/// deployed contracts by `test/fork/V4Assumptions.t.sol` and `test/fork/Graduation.fork.t.sol`.
contract MockPositionManager {
    using PositionInfoLibrary for PositionInfo;

    struct Position {
        PoolKey key;
        PositionInfo info;
        uint128 liquidity;
        address owner;
    }

    /// @dev One `MINT_POSITION` action's parameters, in memory rather than on the stack.
    struct MintArgs {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address owner;
    }

    /// @notice Uniswap v4 PoolManager, read by `LiquidityLock`'s constructor.
    IPoolManager public immutable poolManager;
    /// @notice The same contract, typed for the mock's own reads and writes.
    MockPoolManager public immutable mockPoolManager;
    /// @notice The allowance registry this mock collects tokens through.
    MockPermit2 public immutable permit2;

    uint256 private _nextTokenId = 1;

    mapping(uint256 tokenId => Position) private _positions;
    /// @notice Fees a test has credited to a position, awaiting a `compound`.
    mapping(uint256 tokenId => uint256) public pendingFees0;
    /// @notice Fees a test has credited to a position, awaiting a `compound`.
    mapping(uint256 tokenId => uint256) public pendingFees1;

    /// @notice Base units a mint deliberately fails to collect. Fault injection.
    uint256 private _mintShortfall1;

    /// @notice A call the mock makes from inside `modifyLiquidities`, so a test can see
    /// what an external call made mid-graduation observes and whether it is let in.
    address private _probeTarget;
    bytes private _probeData;
    /// @notice True once the probe has been attempted.
    bool public probeCalled;
    /// @notice Whether the probe call succeeded.
    bool public probeSucceeded;
    /// @notice The probe call's return or revert data.
    bytes public probeReturn;

    /// @notice When set, `compound` moves a position's liquidity by this signed amount
    /// instead of by what its fees buy.
    int256 private _liquidityDeltaOverride;
    /// @notice True once an override is in force; distinguishes a forced zero.
    bool private _overrideSet;

    /// @notice A position was minted to an owner.
    event Mint(uint256 indexed tokenId, address indexed owner, uint128 liquidity);
    /// @notice A position's fees were reinvested into it.
    event Compound(uint256 indexed tokenId, uint128 liquidityAdded);

    /// @notice The batch handed in is not one of the two this mock executes.
    error UnsupportedActions(bytes actions);
    /// @notice This contract does not hold enough native value to settle the mint.
    error CurrencyNotSettled();
    /// @notice ETH arrived from an address the real PositionManager refuses it from.
    error InvalidEthSender();
    /// @notice The deadline on the batch has passed.
    error DeadlinePassed(uint256 deadline);
    /// @notice The token id was never minted.
    error NoPosition(uint256 tokenId);

    constructor(MockPoolManager poolManager_, MockPermit2 permit2_) {
        poolManager = IPoolManager(address(poolManager_));
        mockPoolManager = poolManager_;
        permit2 = permit2_;
    }

    /// @dev `NativeWrapper.receive`: ETH is accepted from the PoolManager and from WETH9,
    /// and refused from everyone else. There is no WETH9 here, so the PoolManager is the
    /// whole admitted set. A test that needs this contract to hold a balance anyway uses
    /// `vm.deal`, which is what `SELFDESTRUCT` and a block reward both look like from
    /// inside the EVM: no code of this contract runs and the guard is bypassed.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert InvalidEthSender();
    }

    /// @notice Executes one action batch.
    /// @param unlockData The encoded `(bytes actions, bytes[] params)` pair.
    /// @param deadline Latest block time the batch may execute at.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        if (_probeTarget != address(0)) _runProbe();

        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (
            actions.length == 3 && uint8(actions[0]) == uint8(Actions.MINT_POSITION)
                && uint8(actions[1]) == uint8(Actions.SETTLE_PAIR)
                && uint8(actions[2]) == uint8(Actions.SWEEP)
        ) {
            _mint(params[0], params[2]);
            return;
        }
        if (
            actions.length == 4 && uint8(actions[0]) == uint8(Actions.DECREASE_LIQUIDITY)
                && uint8(actions[1]) == uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS)
                && uint8(actions[2]) == uint8(Actions.CLOSE_CURRENCY)
                && uint8(actions[3]) == uint8(Actions.CLOSE_CURRENCY)
        ) {
            _compound(params[0]);
            return;
        }
        revert UnsupportedActions(actions);
    }

    /// @notice The id the next mint will take.
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @notice A position's pool key and packed tick range.
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory, PositionInfo)
    {
        Position storage position = _positions[tokenId];
        if (position.owner == address(0)) revert NoPosition(tokenId);
        return (position.key, position.info);
    }

    /// @notice A position's liquidity.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    /// @notice A position's packed info.
    function positionInfo(uint256 tokenId) external view returns (PositionInfo) {
        return _positions[tokenId].info;
    }

    /// @notice The owner of a position, as ERC-721 reports it.
    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _positions[tokenId].owner;
        if (owner == address(0)) revert NoPosition(tokenId);
        return owner;
    }

    /// @notice Mints a position to an owner without settling anything.
    /// @dev Test-only shortcut for the cases that need a position to exist without a
    /// launch having paid for it: the `LiquidityLock.NotOwned` branch needs a position
    /// owned by somebody other than the lock, and the real mint path cannot produce one.
    /// @return tokenId The new position's id.
    function mintBare(
        address owner,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _positions[tokenId] = Position({
            key: key,
            info: PositionInfoLibrary.initialize(key, tickLower, tickUpper),
            liquidity: liquidity,
            owner: owner
        });
        emit Mint(tokenId, owner, liquidity);
    }

    /// @notice Credits a position with accrued fees, funded by the caller.
    /// @dev The native side arrives as `msg.value` and the token side is pulled from the
    /// caller, so the fees a `compound` reinvests are real balances this mock holds rather
    /// than numbers it invented.
    function accrueFees(uint256 tokenId, uint256 amount1) external payable {
        Position storage position = _positions[tokenId];
        if (position.owner == address(0)) revert NoPosition(tokenId);

        pendingFees0[tokenId] += msg.value;
        if (amount1 != 0) {
            pendingFees1[tokenId] += amount1;
            require(
                IERC20(Currency.unwrap(position.key.currency1))
                    .transferFrom(msg.sender, address(this), amount1),
                "MockPositionManager: fee transfer failed"
            );
        }
    }

    /// @notice Makes the next mint collect `amount` base units fewer than the liquidity
    /// it mints requires.
    /// @dev Fault injection, and the only way to reach `BondingCurve`'s `LpDustTooHigh`
    /// assertion: the real arithmetic cannot leave more than `LP_DUST_MAX` unconsumed, and
    /// the fork tests measure the real shortfall at 240, 1,088 and 28,428 base units
    /// across the permitted range. The assertion still has to be shown to fire, because a
    /// graduation that silently immobilised a meaningful part of `LP_SUPPLY` is exactly
    /// what it exists to stop.
    function setMintTokenShortfall(uint256 amount) external {
        _mintShortfall1 = amount;
    }

    /// @notice Arranges for the mock to make one call from inside `modifyLiquidities`.
    /// @dev This is how a test sees the state an external call observes mid-graduation,
    /// which is what Invariant 55(b) and (c) are about, and whether a reentrant entry is
    /// refused, which is Invariant 55(a).
    function setProbe(address target, bytes calldata data) external {
        _probeTarget = target;
        _probeData = data;
        probeCalled = false;
        probeSucceeded = false;
        probeReturn = "";
    }

    /// @notice Forces the next `compound` to move liquidity by a fixed signed amount.
    /// @dev Zero reaches `NothingToCompound` and a negative value reaches the
    /// `LiquidityNotIncreased` backstop, neither of which a healthy v4 pool can produce.
    function setLiquidityDeltaOverride(int256 delta) external {
        _liquidityDeltaOverride = delta;
        _overrideSet = true;
    }

    /// @notice Drops any override.
    function clearLiquidityDeltaOverride() external {
        _liquidityDeltaOverride = 0;
        _overrideSet = false;
    }

    /// @dev `MINT_POSITION` followed by `SETTLE_PAIR` and a `SWEEP` of `currency0` back to
    /// the caller.
    /// @dev Split into shallow helpers on purpose: `forge coverage` compiles with the
    /// optimizer and the IR pipeline disabled, and the eight-element decode of a
    /// `MINT_POSITION` parameter plus the amounts it needs does not fit on the legacy
    /// codegen's stack in one frame. The split is what keeps the coverage build working
    /// without `--ir-minimum`, which the CI command does not pass.
    function _mint(bytes memory param, bytes memory sweepParam) private {
        MintArgs memory args = _decodeMint(param);
        (uint256 amount0, uint256 amount1) =
            _amountsForLiquidity(args.key.toId(), args.tickLower, args.tickUpper, args.liquidity);

        _settleMint(args, amount0, amount1);
        _recordMint(args);
        _sweep(sweepParam);
    }

    /// @dev `PositionManager._sweep`, which is **not** a refund of the mint's unspent
    /// value: it reads `currency.balanceOfSelf()` and sends that whole balance to the
    /// recipient. Any balance this contract held when the batch arrived therefore leaves
    /// with the remainder, in one transfer that the caller sees as one credit. Modelling
    /// it as `msg.value - amount0` instead is what hid finding 1 of
    /// `docs/security/REVIEW-2026-11-11-phase1-contracts.md` from the whole suite: under
    /// that model a caller measuring its own balance across the call measured the mint's
    /// cost, and under this one it measures the cost minus whatever was parked here.
    function _sweep(bytes memory sweepParam) private {
        (Currency currency, address to) = abi.decode(sweepParam, (Currency, address));
        if (to == ActionConstants.MSG_SENDER) to = msg.sender;
        else if (to == ActionConstants.ADDRESS_THIS) to = address(this);

        if (currency.isAddressZero()) {
            uint256 balance = address(this).balance;
            if (balance == 0) return;
            (bool swept,) = to.call{value: balance}("");
            require(swept, "MockPositionManager: sweep failed");
        } else {
            IERC20 erc20 = IERC20(Currency.unwrap(currency));
            uint256 balance = erc20.balanceOf(address(this));
            if (balance == 0) return;
            require(erc20.transfer(to, balance), "MockPositionManager: sweep failed");
        }
    }

    /// @dev The trailing `bytes` of the action's parameter is hook data the mock ignores,
    /// so it is left undecoded rather than put on the stack.
    function _decodeMint(bytes memory param) private pure returns (MintArgs memory args) {
        uint256 liquidity;
        (
            args.key,
            args.tickLower,
            args.tickUpper,
            liquidity,
            args.amount0Max,
            args.amount1Max,
            args.owner
        ) = abi.decode(param, (PoolKey, int24, int24, uint256, uint128, uint128, address));
        args.liquidity = uint128(liquidity);
    }

    /// @dev Enforces both maxima with v4's own error and collects what the mint owes: the
    /// native side out of this contract's balance, the token side through Permit2.
    /// @dev The native side is deliberately not `msg.value`. `DeltaResolver._settle` pays
    /// the native debt with `poolManager.settle{value: amount}()`, which spends
    /// PositionManager's balance; `msg.value` is only the usual way that balance arrives,
    /// and a batch under-funded by its caller settles out of a parked balance instead of
    /// reverting. The same reading of the balance is what makes `SWEEP` carry a parked
    /// balance away afterwards.
    function _settleMint(MintArgs memory args, uint256 amount0, uint256 amount1) private {
        if (amount0 > args.amount0Max) {
            revert SlippageCheck.MaximumAmountExceeded(args.amount0Max, uint128(amount0));
        }
        if (amount1 > args.amount1Max) {
            revert SlippageCheck.MaximumAmountExceeded(args.amount1Max, uint128(amount1));
        }
        if (address(this).balance < amount0) revert CurrencyNotSettled();

        uint256 collect1 = amount1 - (amount1 < _mintShortfall1 ? amount1 : _mintShortfall1);
        if (collect1 != 0) {
            permit2.transferFrom(
                msg.sender,
                address(poolManager),
                uint160(collect1),
                Currency.unwrap(args.key.currency1)
            );
        }
        if (amount0 != 0) {
            (bool settled,) = address(poolManager).call{value: amount0}("");
            require(settled, "MockPositionManager: settle failed");
        }
    }

    /// @dev Mints the position NFT. Deliberately without a receiver hook: the real
    /// PositionManager's solmate-derived `_mint` does not call `onERC721Received` either,
    /// which is why `LiquidityLock.onERC721Received` is never reached by a graduation.
    function _recordMint(MintArgs memory args) private {
        uint256 tokenId = _nextTokenId++;
        _positions[tokenId] = Position({
            key: args.key,
            info: PositionInfoLibrary.initialize(args.key, args.tickLower, args.tickUpper),
            liquidity: args.liquidity,
            owner: args.owner
        });
        // `Pool.State.liquidity` is the liquidity **in range at the current tick**, not the
        // sum of every position: `Pool.modifyLiquidity` touches it in the in-range branch
        // alone (`v4-core/src/libraries/Pool.sol:226`). So the floor position, whose range
        // starts above the current tick, adds nothing to it — which is the same property
        // that makes the floor position an ETH bid rather than liquidity at the opening
        // price, measured here the way the pool measures it.
        (, int24 tick) = mockPoolManager.slot0(args.key.toId());
        if (tick >= args.tickLower && tick < args.tickUpper) {
            mockPoolManager.setLiquidity(
                args.key.toId(), mockPoolManager.liquidity(args.key.toId()) + args.liquidity
            );
        }

        emit Mint(tokenId, args.owner, args.liquidity);
    }

    /// @dev A zero-liquidity `DECREASE_LIQUIDITY` credits the position's fees, the
    /// `INCREASE_LIQUIDITY_FROM_DELTAS` spends that credit on new liquidity in the same
    /// position, and the ratio residual goes to the position's owner.
    function _compound(bytes memory param) private {
        (uint256 tokenId,,,,) = abi.decode(param, (uint256, uint256, uint128, uint128, bytes));

        Position storage position = _positions[tokenId];
        if (position.owner == address(0)) revert NoPosition(tokenId);

        uint256 fees0 = pendingFees0[tokenId];
        uint256 fees1 = pendingFees1[tokenId];
        pendingFees0[tokenId] = 0;
        pendingFees1[tokenId] = 0;

        uint128 added;
        if (_overrideSet) {
            int256 delta = _liquidityDeltaOverride;
            position.liquidity = delta < 0
                ? position.liquidity - uint128(uint256(-delta))
                : position.liquidity + uint128(uint256(delta));
            added = delta < 0 ? 0 : uint128(uint256(delta));
        } else {
            (uint160 price,) = mockPoolManager.slot0(position.key.toId());
            added = LiquidityAmounts.getLiquidityForAmounts(
                price,
                TickMath.getSqrtPriceAtTick(position.info.tickLower()),
                TickMath.getSqrtPriceAtTick(position.info.tickUpper()),
                fees0,
                fees1
            );
            position.liquidity += added;
        }

        emit Compound(tokenId, added);
        _payResidual(tokenId, added, fees0, fees1);
    }

    /// @dev The ratio residual of a compounding, paid to the position's owner. Uniswap v4
    /// routes it to `msgSender()`, which for a call the lock makes is the lock itself.
    function _payResidual(uint256 tokenId, uint128 added, uint256 fees0, uint256 fees1) private {
        Position storage position = _positions[tokenId];
        (uint256 used0, uint256 used1) = _amountsForLiquidity(
            position.key.toId(), position.info.tickLower(), position.info.tickUpper(), added
        );
        if (fees0 > used0) {
            (bool ok,) = position.owner.call{value: fees0 - used0}("");
            require(ok, "MockPositionManager: residual0 failed");
        }
        if (fees1 > used1) {
            require(
                IERC20(Currency.unwrap(position.key.currency1))
                    .transfer(position.owner, fees1 - used1),
                "MockPositionManager: residual1 failed"
            );
        }
    }

    /// @dev One call out of the middle of a batch, recorded rather than bubbled. It fires
    /// on every batch until `setProbe(address(0), "")` clears it, so a test can look at
    /// both the core mint and the floor mint of one graduation.
    function _runProbe() private {
        (bool ok, bytes memory ret) = _probeTarget.call(_probeData);
        probeCalled = true;
        probeSucceeded = ok;
        probeReturn = ret;
    }

    /// @dev `Pool.modifyLiquidity`'s amounts for added liquidity, rounded up.
    function _amountsForLiquidity(PoolId id, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 price, int24 tick) = mockPoolManager.slot0(id);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        if (tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(price, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, price, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }
}
