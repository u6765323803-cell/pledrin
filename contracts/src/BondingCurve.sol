// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "./interfaces/ICreatorVesting.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "./interfaces/ILiquidityLock.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {PledrinConstants} from "./libraries/PledrinConstants.sol";
import {TickAlign} from "./libraries/TickAlign.sol";

/// @title Pledrin bonding curve
/// @notice One per launch. Holds the curve's ETH reserve, the three fee buckets, the dev
/// bond and every unsold token, and performs the graduation into Uniswap v4.
/// @dev Pricing reads `ethReserve` and `tokensSold` from storage and never a balance, so
/// ETH or tokens forced into this contract by any means cannot move any price
/// (Invariant 10). Every rounding direction favours curve solvency, which keeps
/// `(vE0 + ethReserve) * (vT0 - tokensSold) >= vE0 * vT0` true forever (Invariant 1) and
/// makes the curve solvent against every sell it will accept (Invariant 2).
contract BondingCurve is IBondingCurve, IUnlockCallback, ReentrancyGuardTransient {
    using BalanceDeltaLibrary for BalanceDelta;
    // The casts name their functions instead of attaching the whole library, because
    // Uniswap v4-core declares a second library called `SafeCast` and both reach this file
    // through the imports above. Naming them binds every cast below to OpenZeppelin's
    // implementation at the attachment site, for a reader and for a static analyser alike,
    // and makes any future cast an explicit addition to this list.
    using {SafeCast.toInt24} for int256;
    using {
        SafeCast.toInt256,
        SafeCast.toUint8,
        SafeCast.toUint64,
        SafeCast.toUint128,
        SafeCast.toUint160
    } for uint256;
    using StateLibrary for IPoolManager;

    /// @notice The factory that deployed this launch and holds its reputation counters.
    address public immutable factory;
    /// @notice The launch token. The entire supply was minted to this contract.
    IERC20 public immutable token;
    /// @notice The only address this launch's creator fees and bond can ever pay.
    address public immutable creator;
    /// @notice The only address this launch's protocol fees can ever pay.
    address public immutable protocolTreasury;
    /// @notice The creator vesting singleton.
    ICreatorVesting public immutable vesting;
    /// @notice The permanent liquidity lock that owns both graduation positions.
    ILiquidityLock public immutable liquidityLock;
    /// @notice Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice Uniswap v4 PositionManager.
    IPositionManager public immutable positionManager;
    /// @notice Permit2, the only approval path PositionManager accepts.
    IAllowanceTransfer public immutable permit2;
    /// @notice The curve's only free scalar, `vE0`.
    uint128 public immutable virtualEthReserve;
    /// @notice `R_target`, the ETH the curve holds once the cap is reached.
    uint128 public immutable ethTarget;
    /// @notice The dev bond posted in the launch transaction, possibly zero.
    uint128 public immutable bondWei;
    /// @notice Block time after which the curve is closed to buyers forever.
    uint64 public immutable gradDeadline;
    /// @notice The pool price the curve's last buyer paid, and the price the pool opens at.
    uint160 public immutable sqrtPriceTerminal;
    /// @notice This launch's total trading fee in basis points.
    uint16 public immutable totalFeeBps;
    /// @notice The creator's share of this launch's fee.
    uint16 public immutable creatorShareBps;
    /// @notice The protocol's share of this launch's fee.
    uint16 public immutable protocolShareBps;
    /// @notice The holder-protection share of this launch's fee.
    uint16 public immutable protectionShareBps;

    /// @notice ETH backing the curve, `r`. Decreases only in `sell` and at graduation.
    uint128 public ethReserve;
    /// @notice Tokens bought minus tokens returned, `s`.
    uint128 public tokensSold;

    /// @notice Accrued creator fees, claimable only once the launch has delivered.
    uint128 public creatorFeeEth;
    /// @notice Accrued protocol fees, claimable at any time.
    uint128 public protocolFeeEth;

    /// @notice Accrued holder-protection fees, including every fee-split remainder.
    uint128 public protectionEth;
    /// @notice Block time the cap was reached, which starts the graduation clocks.
    uint64 public capReachedAt;
    /// @notice The launch's lifecycle state.
    State public state;
    /// @notice The dev bond's state.
    BondState public bondState;

    /// @notice ETH still held on the bond account.
    uint128 public bondHeldWei;
    /// @notice Block time the launch graduated.
    uint64 public graduatedAt;

    /// @notice Bond ETH credited to the creator, awaiting `claimBond`.
    uint128 public pendingBondWei;
    /// @notice Sum of every unclaimed graduation bounty.
    uint128 public pendingBountyTotalWei;

    /// @notice Graduation bounty credited to the address that earned it.
    mapping(address earner => uint256 weiAmount) public pendingBountyWei;

    /// @dev True only while this contract is inside its own `PoolManager.unlock`.
    bool private transient _unlocking;

    /// @notice Fixes every launch parameter, takes delivery of the launch token's entire
    /// supply and initialises the Uniswap v4 pool at the curve's terminal price.
    /// @dev Initialising the pool here rather than at graduation is the primary anti-grief
    /// measure: the token address does not exist before this transaction, so the pool key
    /// is not computable before it and no attacker can ever choose the pool's initial
    /// price. The token is minted by the deployer directly to this contract and the whole
    /// supply is checked to have arrived. The bond is funded by the ETH sent with this
    /// call.
    /// @param factory_ The factory this launch reports its outcome to.
    /// @param config Everything this launch fixes for its lifetime.
    constructor(address factory_, CurveConfig memory config) payable {
        if (
            factory_ == address(0) || config.creator == address(0)
                || config.protocolTreasury == address(0)
                || address(config.tokenDeployer) == address(0)
                || address(config.vesting) == address(0)
                || address(config.liquidityLock) == address(0)
                || address(config.poolManager) == address(0)
                || address(config.positionManager) == address(0)
                || address(config.permit2) == address(0)
        ) revert InvalidConfig();
        if (
            config.virtualEthReserve < PledrinConstants.MIN_VIRTUAL_ETH_RESERVE
                || config.virtualEthReserve > PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
        ) revert InvalidConfig();
        if (
            config.gradWindow < PledrinConstants.MIN_GRAD_WINDOW
                || config.gradWindow > PledrinConstants.MAX_GRAD_WINDOW
        ) revert InvalidConfig();
        if (config.totalFeeBps > PledrinConstants.MAX_TOTAL_FEE_BPS) revert InvalidConfig();
        if (
            uint256(config.creatorShareBps) + config.protocolShareBps + config.protectionShareBps
                != PledrinConstants.BPS_DENOMINATOR
        ) revert InvalidConfig();
        if (msg.value != config.bondWei) revert BondValueMismatch();

        uint256 target = PledrinConstants.ETH_TARGET_MULTIPLE * config.virtualEthReserve;
        if (config.bondWei != 0) {
            uint256 minBond = PledrinConstants.minBondWei(target);
            if (config.bondWei < minBond || config.bondWei > PledrinConstants.MAX_BOND_WEI) {
                revert InvalidConfig();
            }
        }

        factory = factory_;
        creator = config.creator;
        protocolTreasury = config.protocolTreasury;
        vesting = config.vesting;
        liquidityLock = config.liquidityLock;
        poolManager = config.poolManager;
        positionManager = config.positionManager;
        permit2 = config.permit2;
        virtualEthReserve = config.virtualEthReserve;
        ethTarget = target.toUint128();
        bondWei = config.bondWei;
        gradDeadline = (block.timestamp + config.gradWindow).toUint64();
        totalFeeBps = config.totalFeeBps;
        creatorShareBps = config.creatorShareBps;
        protocolShareBps = config.protocolShareBps;
        protectionShareBps = config.protectionShareBps;

        // sqrt(mulDiv(S_LP, 2**192, R_target)), rounded down, on a 512-bit intermediate.
        sqrtPriceTerminal = FixedPointMathLib.sqrt(
                FullMath.mulDiv(PledrinConstants.LP_SUPPLY, 1 << 192, target)
            )
            .toUint160();

        if (config.bondWei != 0) {
            bondHeldWei = config.bondWei;
            bondState = BondState.Bonded;
            emit BondStateChanged(
                address(this),
                config.creator,
                BondState.None,
                BondState.Bonded,
                config.bondWei,
                address(this)
            );
        }

        IERC20 launchToken = config.tokenDeployer.deploy(config.name, config.symbol);
        // Exact equality is the point: the launch owns its entire supply at construction
        // or this launch does not exist.
        // forge-lint: disable-next-item(incorrect-strict-equality)
        if (
            launchToken.totalSupply() != PledrinConstants.TOTAL_SUPPLY
                || launchToken.balanceOf(address(this)) != PledrinConstants.TOTAL_SUPPLY
        ) revert InvalidToken();
        token = launchToken;

        // The returned tick is the tick of `sqrtPriceTerminal` and is not needed here.
        // forge-lint: disable-next-item(unused-return)
        config.poolManager
            .initialize(
                _poolKeyFor(launchToken, PledrinConstants.POOL_TICK_SPACING), sqrtPriceTerminal
            );
    }

    /// @notice Accepts the unspent ETH Uniswap v4 returns from a graduation mint.
    /// @dev Restricted so that a user cannot lose ETH by sending it here instead of
    /// calling `donate`. ETH forced in by other means changes no price either way.
    receive() external payable {
        if (msg.sender != address(positionManager)) revert DirectEthNotAccepted();
    }

    /// @inheritdoc IBondingCurve
    function buy(uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        uint256 refund;
        (tokensOut, refund) = _buy(msg.value, minTokensOut, deadline, msg.sender);

        _transferToken(msg.sender, tokensOut);
        if (refund != 0) _sendEth(msg.sender, refund);
    }

    /// @inheritdoc IBondingCurve
    function sell(uint256 tokensIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        State current = state;
        if (current != State.Live && current != State.Expired && current != State.Stalled) {
            revert WrongState(current);
        }
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (tokensIn == 0) revert ZeroAmount();

        uint128 sold = tokensSold;
        if (tokensIn > sold) revert SellExceedsSupplySold();

        (uint256 ethGross, uint256 fee, uint256 out) = CurveMath.sellQuote(
            virtualEthReserve + ethReserve,
            PledrinConstants.VIRTUAL_TOKEN_RESERVE - sold,
            totalFeeBps,
            tokensIn
        );
        if (ethGross == 0 || out == 0) revert ZeroAmount();
        if (out < minEthOut) revert SlippageExceeded(out, minEthOut);

        uint128 feeToReserve = _accrueFee(fee, current);
        uint128 reserveAfter = ethReserve - ethGross.toUint128() + feeToReserve;
        uint128 soldAfter = sold - tokensIn.toUint128();
        ethReserve = reserveAfter;
        tokensSold = soldAfter;

        emit Sold(address(this), msg.sender, tokensIn, ethGross, out, fee, soldAfter, reserveAfter);

        _pullToken(msg.sender, tokensIn);
        _sendEth(msg.sender, out);
        ethOut = out;
    }

    /// @inheritdoc IBondingCurve
    function donate() external payable nonReentrant {
        State current = state;
        if (current == State.Graduated) revert WrongState(current);
        if (msg.value == 0) revert ZeroAmount();

        uint128 reserveAfter = ethReserve + msg.value.toUint128();
        ethReserve = reserveAfter;

        emit Donated(address(this), msg.sender, msg.value, reserveAfter);
    }

    /// @inheritdoc IBondingCurve
    function creatorFirstBuy(uint32 cliff, uint32 duration)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != factory) revert NotFactory();
        if (tokensSold != 0) revert FirstBuyUnavailable();

        // A first buy large enough to be clipped at the cap would have to take the whole
        // sale supply, which the ceiling below always rejects, so no refund can arise.
        (tokensOut,) = _buy(msg.value, 0, block.timestamp, creator);
        if (tokensOut > PledrinConstants.CREATOR_FIRST_BUY_MAX) revert FirstBuyTooLarge(tokensOut);

        _approve(address(vesting), tokensOut);
        vesting.createSchedule(creator, address(token), tokensOut.toUint128(), cliff, duration);
    }

    /// @inheritdoc IBondingCurve
    function graduate() external nonReentrant {
        _settle(PledrinConstants.POOL_TICK_SPACING, false);
    }

    /// @inheritdoc IBondingCurve
    function graduateAlt(uint24 tickSpacing) external nonReentrant {
        int24 spacing = uint256(tickSpacing).toInt256().toInt24();
        if (
            spacing < PledrinConstants.ALT_TICK_SPACING_MIN
                || spacing > PledrinConstants.ALT_TICK_SPACING_MAX
        ) revert InvalidTickSpacing(tickSpacing);
        _settle(spacing, true);
    }

    /// @inheritdoc IBondingCurve
    function abortGraduation() external nonReentrant {
        if (state != State.Graduating) revert WrongState(state);
        if (block.timestamp < uint256(capReachedAt) + PledrinConstants.GRAD_GRACE) {
            revert GraceNotElapsed();
        }

        state = State.Stalled;

        uint128 protection = protectionEth;
        if (protection != 0) {
            protectionEth = 0;
            uint128 reserveAfter = ethReserve + protection;
            ethReserve = reserveAfter;
            emit Donated(address(this), address(this), protection, reserveAfter);
        }
        bool bondReturned = _returnBond();

        vesting.start();
        ILaunchFactory(factory).recordStall(creator, bondReturned);

        emit GraduationStalled(address(this), msg.sender);
    }

    /// @inheritdoc IBondingCurve
    function expire() external nonReentrant {
        if (state != State.Live) revert WrongState(state);
        if (block.timestamp < gradDeadline) revert DeadlineNotReached();
        if (tokensSold >= PledrinConstants.CURVE_SUPPLY) revert CapAlreadyReached();

        state = State.Expired;

        uint128 bond = bondHeldWei;
        uint128 creatorFees = creatorFeeEth;
        uint128 protection = protectionEth;
        uint128 reserveAfter = ethReserve + bond + creatorFees + protection;

        ethReserve = reserveAfter;
        creatorFeeEth = 0;
        protectionEth = 0;
        if (bond != 0) {
            bondHeldWei = 0;
            bondState = BondState.Forfeited;
            emit BondStateChanged(
                address(this), creator, BondState.Bonded, BondState.Forfeited, bond, address(this)
            );
        }

        vesting.void();
        ILaunchFactory(factory).recordExpiry(creator, bond != 0 ? bondWei : 0);

        emit Expired(address(this), bond, creatorFees, protection, reserveAfter);
    }

    /// @inheritdoc IBondingCurve
    function claimCreatorFees() external nonReentrant returns (uint256 amount) {
        State current = state;
        if (current != State.Graduated && current != State.Stalled) revert WrongState(current);

        amount = creatorFeeEth;
        if (amount == 0) revert NothingToClaim();
        creatorFeeEth = 0;

        emit FeesClaimed(address(this), creator, FeeKind.Creator, amount);
        _sendEth(creator, amount);
    }

    /// @inheritdoc IBondingCurve
    function claimProtocolFees() external nonReentrant returns (uint256 amount) {
        amount = protocolFeeEth;
        if (amount == 0) revert NothingToClaim();
        protocolFeeEth = 0;

        emit FeesClaimed(address(this), protocolTreasury, FeeKind.Protocol, amount);
        _sendEth(protocolTreasury, amount);
    }

    /// @inheritdoc IBondingCurve
    function claimBond() external nonReentrant returns (uint256 amount) {
        BondState bond = bondState;
        if (bond != BondState.Returned) {
            if (bond == BondState.None) revert NoBondPosted();
            if (bond == BondState.Forfeited) revert BondForfeitedToHolders();
            // `BondState` has four values and is only ever written to one of them, so the
            // case left here is `Bonded`: the bond is posted against a launch that has not
            // settled, and that is the one refusal a later call can turn into a payment.
            revert BondNotReturned();
        }

        amount = pendingBondWei;
        // The credit is written once, by the transition that set `Returned`, and nothing
        // ever adds to it, so an empty credit in this state means the bond has been paid.
        if (amount == 0) revert BondAlreadyClaimed();
        pendingBondWei = 0;

        emit FeesClaimed(address(this), creator, FeeKind.Bond, amount);
        _sendEth(creator, amount);
    }

    /// @inheritdoc IBondingCurve
    function claimBounty(address earner) external nonReentrant returns (uint256 amount) {
        amount = pendingBountyWei[earner];
        if (amount == 0) revert NothingToClaim();
        pendingBountyWei[earner] = 0;
        pendingBountyTotalWei -= amount.toUint128();

        emit FeesClaimed(address(this), earner, FeeKind.Bounty, amount);
        _sendEth(earner, amount);
    }

    /// @notice Executes the price-restoring swap of `docs/SPEC.md` section 8.2 step 2.
    /// @dev Reverts unless PoolManager is calling and this contract is inside its own
    /// `unlock` (Invariant 56). The swap must settle for nothing in both currencies, so
    /// there is no settle or take path here at all: a non-zero delta reverts instead
    /// (Invariant 41), which is what stops hostile liquidity from making graduation spend
    /// curve ETH. State stays frozen and graduation is retryable forever.
    /// @param data The pool key and swap direction, encoded by `_restorePrice`.
    /// @return An empty value; the caller reads the restored price from `slot0`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_unlocking) revert NotUnlocking();

        (PoolKey memory key, bool zeroForOne) = abi.decode(data, (PoolKey, bool));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: sqrtPriceTerminal
            }),
            ""
        );
        if (delta.amount0() != 0 || delta.amount1() != 0) {
            revert SwapNotFree(delta.amount0(), delta.amount1());
        }
        return "";
    }

    /// @inheritdoc IBondingCurve
    function quoteBuy(uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund)
    {
        uint128 sold = tokensSold;
        return CurveMath.buyQuote(
            virtualEthReserve + ethReserve,
            PledrinConstants.VIRTUAL_TOKEN_RESERVE - sold,
            PledrinConstants.CURVE_SUPPLY - sold,
            totalFeeBps,
            ethIn
        );
    }

    /// @inheritdoc IBondingCurve
    function quoteSell(uint256 tokensIn)
        external
        view
        returns (uint256 ethGross, uint256 fee, uint256 ethOut)
    {
        return CurveMath.sellQuote(
            virtualEthReserve + ethReserve,
            PledrinConstants.VIRTUAL_TOKEN_RESERVE - tokensSold,
            totalFeeBps,
            tokensIn
        );
    }

    /// @inheritdoc IBondingCurve
    function liveReserves() external view returns (uint256 virtualEth, uint256 virtualTokens) {
        virtualEth = virtualEthReserve + ethReserve;
        virtualTokens = PledrinConstants.VIRTUAL_TOKEN_RESERVE - tokensSold;
    }

    /// @inheritdoc IBondingCurve
    function pledged() external view returns (bool) {
        return bondWei != 0;
    }

    /// @inheritdoc IBondingCurve
    function poolId() external view returns (PoolId) {
        return _poolKeyFor(token, PledrinConstants.POOL_TICK_SPACING).toId();
    }

    /// @dev The shared body of `buy` and `creatorFirstBuy`. Writes every storage change
    /// the trade causes, including the transition to `Graduating`, before returning to a
    /// caller that then performs the token and ETH transfers.
    function _buy(uint256 value, uint256 minTokensOut, uint256 deadline, address buyer)
        private
        returns (uint256 tokensOut, uint256 refund)
    {
        if (state != State.Live) revert WrongState(state);
        // The launch's window is consulted before the caller's own deadline. A call that is
        // both stale and past `gradDeadline`, on a launch nobody has yet moved out of
        // `Live` with `expire()`, would otherwise be told to resubmit against a window no
        // later call can reopen. While the window is open this check cannot fire, so a
        // stale call still answers `DeadlinePassed`.
        if (block.timestamp >= gradDeadline) revert BuyWindowClosed();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (value < PledrinConstants.MIN_BUY_WEI) revert BuyTooSmall();

        uint128 sold = tokensSold;
        uint256 ethToCurve;
        uint256 fee;
        (tokensOut, ethToCurve, fee, refund) = CurveMath.buyQuote(
            virtualEthReserve + ethReserve,
            PledrinConstants.VIRTUAL_TOKEN_RESERVE - sold,
            PledrinConstants.CURVE_SUPPLY - sold,
            totalFeeBps,
            value
        );
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        uint128 reserveAfter = ethReserve + ethToCurve.toUint128();
        uint128 soldAfter = sold + tokensOut.toUint128();
        ethReserve = reserveAfter;
        tokensSold = soldAfter;
        // Every share has a payout path while the launch is `Live`, which is the only
        // state this body runs in, so the split redirects nothing here.
        _accrueFee(fee, State.Live);

        emit Bought(
            address(this), buyer, value, ethToCurve, tokensOut, fee, refund, soldAfter, reserveAfter
        );

        if (soldAfter == PledrinConstants.CURVE_SUPPLY) {
            state = State.Graduating;
            capReachedAt = block.timestamp.toUint64();
            emit CapReached(address(this), reserveAfter, block.timestamp);
        }
    }

    /// @dev Splits one trade's fee three ways and accrues each share that still has a
    /// payout path. The holder-protection share is the residual, so the three parts sum to
    /// `fee` exactly (Invariants 14, 17).
    ///
    /// Two of the three destinations close for good at a terminal transition, while `sell`
    /// stays open in both terminal states and keeps charging the fee. The protection
    /// bucket has no claim function at all and is distributed only by the transition
    /// itself, which has already happened; `claimCreatorFees` reverts in `Expired`. A
    /// share accrued into either bucket after that point could never leave this contract,
    /// so it is reported to the caller for the reserve instead: holder protection is for
    /// holders, and the reserve is what holders sell against. `Stalled` keeps the
    /// creator's claim open, so only the protection share moves there, and the protocol
    /// share keeps its path in every state.
    ///
    /// Adding wei to the reserve only raises `(vE0 + ethReserve) * (vT0 - tokensSold)`, so
    /// Invariant 1 is unaffected.
    /// @param fee The trade's fee in wei.
    /// @param current The state the trade is executing in.
    /// @return feeToReserve Wei the caller adds to `ethReserve` instead of to a bucket. It
    /// is emitted as `FeeAccrued.reserveCut`, so that event's four amounts sum to the
    /// trade's fee in every state and a reader never has to infer a destination.
    function _accrueFee(uint256 fee, State current) private returns (uint128 feeToReserve) {
        (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut) =
            CurveMath.splitFee(fee, creatorShareBps, protocolShareBps);

        if (current == State.Expired) {
            feeToReserve = (creatorCut + protectionCut).toUint128();
            creatorCut = 0;
            protectionCut = 0;
        } else if (current == State.Stalled) {
            feeToReserve = protectionCut.toUint128();
            protectionCut = 0;
        }

        creatorFeeEth += creatorCut.toUint128();
        protocolFeeEth += protocolCut.toUint128();
        protectionEth += protectionCut.toUint128();

        emit FeeAccrued(address(this), creatorCut, protocolCut, protectionCut, feeToReserve);
    }

    /// @dev The graduation procedure of `docs/SPEC.md` section 8.2, shared by `graduate`
    /// and `graduateAlt`. `state` is written before any external call, so a reentrant
    /// attempt fails the state check and the two together succeed at most once
    /// (Invariant 36). Nothing here sends ETH to an address the caller controls: the bond
    /// and the bounty are credited, not pushed (Invariant 45).
    function _settle(int24 tickSpacing, bool alternate) private {
        if (state != State.Graduating) revert WrongState(state);
        // The alternate path's delay is checked here rather than in `graduateAlt`, so that
        // the state check runs first: a launch that has already graduated answers
        // `WrongState` instead of telling the caller to wait out a delay that is not what
        // stands in their way.
        if (alternate && block.timestamp < uint256(capReachedAt) + PledrinConstants.ALT_DELAY) {
            revert AltDelayNotElapsed();
        }

        state = State.Graduated;
        graduatedAt = block.timestamp.toUint64();

        PoolKey memory key = _poolKeyFor(token, tickSpacing);
        PoolId id = key.toId();

        if (alternate) {
            (uint160 existing,,,) = poolManager.getSlot0(id);
            if (existing != 0) revert AltPoolInitialized();
            // forge-lint: disable-next-line(unused-return)
            poolManager.initialize(key, sqrtPriceTerminal);
        } else {
            (uint160 current,,,) = poolManager.getSlot0(id);
            if (current != sqrtPriceTerminal) _restorePrice(key, current > sqrtPriceTerminal);
        }

        (uint160 price,,,) = poolManager.getSlot0(id);
        if (price != sqrtPriceTerminal) revert PriceNotRestored(price, sqrtPriceTerminal);

        (uint256 corePositionId, uint256 coreEth, uint256 coreTokens) = _mintCore(key, tickSpacing);

        uint256 floorEth =
            uint256(protectionEth) + (ethReserve - ethTarget) + (uint256(ethTarget) - coreEth);
        uint256 bounty = FullMath.mulDiv(
            protocolFeeEth, PledrinConstants.GRAD_BOUNTY_BPS, PledrinConstants.BPS_DENOMINATOR
        );

        protectionEth = 0;
        ethReserve = 0;
        protocolFeeEth -= bounty.toUint128();
        pendingBountyWei[msg.sender] += bounty;
        pendingBountyTotalWei += bounty.toUint128();
        bool bondReturned = _returnBond();

        (uint256 floorPositionId, uint256 floorEthUsed) = _mintFloor(key, tickSpacing, floorEth);

        vesting.start();
        ILaunchFactory(factory).recordGraduation(creator, ethTarget, bondReturned);

        emit Graduated(
            address(this),
            id,
            corePositionId,
            floorPositionId,
            coreEth,
            floorEthUsed,
            coreTokens,
            bounty,
            msg.sender
        );
    }

    /// @dev Restores a griefed zero-liquidity pool to `sqrtPriceTerminal`. The swap
    /// nominates one unit of exact input because `PoolManager.swap` rejects an
    /// `amountSpecified` of zero, and the caller only reaches this path when the price
    /// differs, because a limit equal to the current price reverts.
    function _restorePrice(PoolKey memory key, bool zeroForOne) private {
        _unlocking = true;
        // The callback asserts the swap settled for nothing and returns no value.
        // forge-lint: disable-next-line(unused-return)
        poolManager.unlock(abi.encode(key, zeroForOne));
        _unlocking = false;
    }

    /// @dev Mints the full-range core position to the lock. Sized by liquidity, because
    /// `MINT_POSITION` takes a liquidity value and the `currency1` it owes is a step
    /// function of that, so no liquidity lands on `LP_SUPPLY` exactly: this takes the
    /// largest value that fits and asserts the remainder is dust (Invariant 39).
    /// `amount0Max` is exactly `R_target` and must not be tightened; the ETH headroom is
    /// not monotone in `virtualEthReserve`, and anything unspent flows into the floor
    /// position rather than being stranded. The ETH cost is computed from the position's
    /// parameters and the token cost is a delta across the call: both choices are forced,
    /// and by opposite considerations, which the body states at each site.
    function _mintCore(PoolKey memory key, int24 tickSpacing)
        private
        returns (uint256 positionId, uint256 ethUsed, uint256 tokensUsed)
    {
        int24 tickLower = TickAlign.up(TickMath.MIN_TICK, tickSpacing);
        int24 tickUpper = TickAlign.down(TickMath.MAX_TICK, tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceTerminal, PledrinConstants.LP_SUPPLY
        );

        // What the mint costs in ETH, computed from the position's own parameters and
        // computed before the call, so nothing the call reaches can alter it. For a
        // position whose range contains the current tick, v4-core charges exactly this
        // much `currency0` (`Pool.modifyLiquidity`), and `_settle` asserted the price
        // equals `sqrtPriceTerminal` immediately above, so this is the amount
        // PositionManager settles below — and at most `target`, because `amount0Max` is
        // `target` and the mint reverts rather than exceed it. A balance delta would not
        // measure this: the batch's closing `SWEEP` sends PositionManager's entire native
        // balance here rather than this mint's unspent remainder, so any balance a third
        // party parked there beforehand arrives inside the call and subtracts from the
        // reading. Finding 1 of
        // `docs/security/REVIEW-2026-11-11-phase1-contracts.md`.
        ethUsed = SqrtPriceMath.getAmount0Delta(
            sqrtPriceTerminal, TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
        );

        uint128 target = ethTarget;
        _approvePositionManager(PledrinConstants.LP_SUPPLY);

        positionId = positionManager.nextTokenId();
        uint256 tokensBefore = token.balanceOf(address(this));

        positionManager.modifyLiquidities{value: target}(
            _mintData(
                key, tickLower, tickUpper, liquidity, target, PledrinConstants.LP_SUPPLY.toUint128()
            ),
            block.timestamp
        );

        tokensUsed = tokensBefore - token.balanceOf(address(this));

        uint256 remainder = PledrinConstants.LP_SUPPLY - tokensUsed;
        // `tokensUsed` is a delta across the mint and `remainder` is derived from it and a
        // constant, never from an absolute post-call balance. That is deliberate: it is
        // what makes a token donation to the curve cancel out instead of reverting
        // graduation. Verdict in `docs/SECURITY_NOTES.md` section 2.
        // slither-disable-next-line reentrancy-balance
        if (remainder > PledrinConstants.LP_DUST_MAX) revert LpDustTooHigh(remainder);

        // Revoked before the floor position is minted, so that position's funding in
        // `currency0` alone is structural rather than a property of its parameters.
        _approve(address(permit2), 0);
        liquidityLock.registerPosition(positionId, ILiquidityLock.PositionKind.Core);
    }

    /// @dev Mints the single-sided holder-protection position to the lock. `currency0` is
    /// ETH and `currency1` is the token, so the tick axis runs opposite to the token's
    /// ETH price: the band immediately below the opening price in price terms is the tick
    /// range immediately above the current tick, and that is the range Uniswap v4 funds
    /// in ETH alone. `currentTick` comes from `slot0.tick` and is never derived from
    /// `slot0.sqrtPriceX96`, which can disagree with it by one tick (Invariant 42).
    function _mintFloor(PoolKey memory key, int24 tickSpacing, uint256 floorEth)
        private
        returns (uint256 positionId, uint256 ethUsed)
    {
        // Below the de-minimis threshold the mint's gas and a permanent position NFT cost
        // more than the bid is worth. The skipped ETH stays in a contract that has no
        // withdrawal path after graduation, so it leaves circulation instead.
        if (floorEth < PledrinConstants.MIN_FLOOR_WEI) return (0, 0);

        bytes memory mintData;
        {
            (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
            int24 tickLower = TickAlign.down(currentTick, tickSpacing) + tickSpacing;
            int24 tickUpper =
                tickLower + TickAlign.down(PledrinConstants.FLOOR_RANGE_TICKS, tickSpacing);
            if (
                tickLower <= currentTick
                    || tickUpper > TickAlign.down(TickMath.MAX_TICK, tickSpacing)
            ) revert FloorRangeInvalid(tickLower, tickUpper, currentTick);

            mintData = _mintData(
                key,
                tickLower,
                tickUpper,
                _floorLiquidity(
                    TickMath.getSqrtPriceAtTick(tickLower),
                    TickMath.getSqrtPriceAtTick(tickUpper),
                    floorEth
                ),
                floorEth.toUint128(),
                0
            );
        }

        positionId = positionManager.nextTokenId();
        // This delta is sound where the core mint's was not. The core mint's own `SWEEP`
        // ran first and left PositionManager holding no native balance, and nothing
        // between the two calls can give it one, so what the sweep below returns is this
        // mint's unspent `currency0` and nothing else.
        uint256 ethBefore = address(this).balance;

        positionManager.modifyLiquidities{value: floorEth}(mintData, block.timestamp);

        ethUsed = ethBefore - address(this).balance;
        liquidityLock.registerPosition(positionId, ILiquidityLock.PositionKind.Floor);
    }

    /// @dev The largest liquidity whose `currency0` requirement fits in `floorEth`.
    /// Rounding the requirement up can exceed `floorEth` by one wei, and a graduation
    /// that reverted on that would be unrecoverable, so the liquidity for one wei less
    /// is used instead; its requirement is at most `floorEth` by the same bound.
    function _floorLiquidity(uint160 sqrtLower, uint160 sqrtUpper, uint256 floorEth)
        private
        pure
        returns (uint128 liquidity)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, floorEth);
        if (SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true) > floorEth) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, floorEth - 1);
        }
    }

    /// @dev One `MINT_POSITION` batch owned by the lock, settled from this contract and
    /// with the unspent `currency0` swept straight back here.
    function _mintData(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            Actions.MINT_POSITION.toUint8(), Actions.SETTLE_PAIR.toUint8(), Actions.SWEEP.toUint8()
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            address(liquidityLock),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);
        return abi.encode(actions, params);
    }

    /// @dev Moves the bond out of `Bonded` exactly once, crediting it to the creator
    /// rather than pushing it, so no address can make graduation revert (Invariant 25).
    function _returnBond() private returns (bool returned) {
        uint128 held = bondHeldWei;
        if (held == 0) return false;

        bondHeldWei = 0;
        bondState = BondState.Returned;
        pendingBondWei = held;

        emit BondStateChanged(
            address(this), creator, BondState.Bonded, BondState.Returned, held, creator
        );
        return true;
    }

    /// @dev The two-leg approval path PositionManager requires. Neither leg alone works.
    function _approvePositionManager(uint256 amount) private {
        _approve(address(permit2), amount);
        permit2.approve(
            address(token), address(positionManager), amount.toUint160(), type(uint48).max
        );
    }

    /// @dev Every launch-token call checks the boolean the ERC-20 standard returns.
    function _approve(address spender, uint256 amount) private {
        if (!token.approve(spender, amount)) revert TokenTransferFailed();
    }

    /// @dev Sends tokens the curve holds. Used by `buy` and never for a fee.
    function _transferToken(address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TokenTransferFailed();
    }

    /// @dev Takes a seller's tokens back into the curve. The only transfer of a user's
    /// tokens the protocol ever makes, and it moves only what that user is selling.
    function _pullToken(address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TokenTransferFailed();
    }

    /// @dev Every ETH payment out of this contract. A recipient that reverts blocks only
    /// its own payment: no trade and no state transition depends on one succeeding.
    function _sendEth(address to, uint256 amount) private {
        // The destination is the trader, the creator, the treasury or a recorded bounty
        // earner, and the amount is the balance recorded for that destination alone.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }

    /// @dev Native ETH sorts below every token address, so ETH is always `currency0` and
    /// the launch token always `currency1`. There is no ordering branch anywhere.
    function _poolKeyFor(IERC20 launchToken, int24 tickSpacing)
        private
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(launchToken)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }
}
