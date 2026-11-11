// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {ICreatorVesting} from "./ICreatorVesting.sol";
import {ILiquidityLock} from "./ILiquidityLock.sol";
import {ITokenDeployer} from "./ITokenDeployer.sol";

/// @title One launch's bonding curve
/// @notice The per-launch contract of `docs/SPEC.md` sections 5 to 11. It holds the
/// curve's ETH reserve, the three fee buckets, the dev bond and every unsold token.
interface IBondingCurve {
    /// @notice The launch lifecycle of `docs/SPEC.md` section 7.
    enum State {
        Live,
        Graduating,
        Graduated,
        Expired,
        Stalled
    }

    /// @notice The dev bond's four states, `docs/SPEC.md` section 11.3.
    enum BondState {
        None,
        Bonded,
        Returned,
        Forfeited
    }

    /// @notice Which bucket a `FeesClaimed` event paid out.
    enum FeeKind {
        Creator,
        Protocol,
        Bounty,
        Bond
    }

    /// @notice Everything a launch fixes at creation. Copied into immutables, so a later
    /// change to factory configuration can never reach an existing launch.
    /// @param creator The launch's creator, the only address its creator fees can pay.
    /// @param protocolTreasury The treasury this launch's protocol fees can pay.
    /// @param tokenDeployer The deployer that mints this launch's token to it.
    /// @param vesting The creator vesting singleton.
    /// @param liquidityLock The permanent liquidity lock.
    /// @param poolManager Uniswap v4 PoolManager.
    /// @param positionManager Uniswap v4 PositionManager.
    /// @param permit2 Permit2, the only approval path PositionManager accepts.
    /// @param virtualEthReserve The curve's only free scalar, `vE0`.
    /// @param bondWei The dev bond posted at launch, possibly zero.
    /// @param gradWindow Seconds from launch within which the cap must be reached.
    /// @param totalFeeBps The launch's total trading fee.
    /// @param creatorShareBps The creator's share of that fee.
    /// @param protocolShareBps The protocol's share of that fee.
    /// @param protectionShareBps The holder-protection share of that fee.
    /// @param name The launch token's name.
    /// @param symbol The launch token's symbol.
    struct CurveConfig {
        address creator;
        address protocolTreasury;
        ITokenDeployer tokenDeployer;
        ICreatorVesting vesting;
        ILiquidityLock liquidityLock;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        uint128 virtualEthReserve;
        uint128 bondWei;
        uint32 gradWindow;
        uint16 totalFeeBps;
        uint16 creatorShareBps;
        uint16 protocolShareBps;
        uint16 protectionShareBps;
        string name;
        string symbol;
    }

    /// @notice Tokens were bought from the curve.
    event Bought(
        address indexed launch,
        address indexed buyer,
        uint256 ethIn,
        uint256 ethToCurve,
        uint256 tokensOut,
        uint256 fee,
        uint256 refund,
        uint256 tokensSold,
        uint256 ethReserve
    );

    /// @notice Tokens were sold back to the curve.
    event Sold(
        address indexed launch,
        address indexed seller,
        uint256 tokensIn,
        uint256 ethGross,
        uint256 ethOut,
        uint256 fee,
        uint256 tokensSold,
        uint256 ethReserve
    );

    /// @notice A trade's fee was split and accrued, one amount per destination. The four
    /// amounts always sum to the trade's fee, in every state, so the split reconciles from
    /// this log alone. `reserveCut` is the part of the fee whose bucket has no payout path
    /// left in the launch's state — the creator's share in `Expired`, the holder-protection
    /// share in either terminal state — and which was added to `ethReserve` instead. It is
    /// zero on every `Live` trade.
    event FeeAccrued(
        address indexed launch,
        uint256 creatorCut,
        uint256 protocolCut,
        uint256 protectionCut,
        uint256 reserveCut
    );

    /// @notice ETH was donated to the curve, raising every holder's exit price.
    event Donated(
        address indexed launch, address indexed donor, uint256 amount, uint256 ethReserve
    );

    /// @notice The curve sold its entire sale supply and froze for graduation.
    event CapReached(address indexed launch, uint256 ethReserve, uint256 timestamp);

    /// @notice The launch graduated into a permanently locked Uniswap v4 position pair.
    event Graduated(
        address indexed launch,
        PoolId indexed poolId,
        uint256 positionIdCore,
        uint256 positionIdFloor,
        uint256 ethToCore,
        uint256 ethToFloor,
        uint256 tokensToCore,
        uint256 bounty,
        address indexed caller
    );

    /// @notice Graduation was griefed past its grace period and the launch stalled.
    event GraduationStalled(address indexed launch, address indexed caller);

    /// @notice The launch missed its deadline; bond, creator fees and protection ETH
    /// were donated to holders.
    event Expired(
        address indexed launch,
        uint256 bondForfeited,
        uint256 creatorFeesForfeited,
        uint256 protectionForfeited,
        uint256 ethReserve
    );

    /// @notice The dev bond changed state. `destination` is the launch itself whenever
    /// the ETH stayed in the contract.
    event BondStateChanged(
        address indexed launch,
        address indexed creator,
        BondState oldState,
        BondState newState,
        uint256 amount,
        address destination
    );

    /// @notice An accrued bucket was paid out.
    event FeesClaimed(
        address indexed launch, address indexed recipient, FeeKind kind, uint256 amount
    );

    /// @notice The call is not allowed in the launch's current state.
    error WrongState(State current);
    /// @notice The caller's deadline has passed.
    error DeadlinePassed();
    /// @notice The graduation window has closed, so the curve is no longer buyable.
    error BuyWindowClosed();
    /// @notice The graduation window has not closed yet.
    error DeadlineNotReached();
    /// @notice The buy is below `MIN_BUY_WEI`.
    error BuyTooSmall();
    /// @notice A trade would move zero tokens or zero wei.
    error ZeroAmount();
    /// @notice The sell is larger than everything the curve has ever sold.
    error SellExceedsSupplySold();
    /// @notice The trade would give the caller less than they asked for.
    error SlippageExceeded(uint256 got, uint256 wanted);
    /// @notice Only the factory that deployed this curve may call this.
    error NotFactory();
    /// @notice The creator's first buy is only available in the launch transaction.
    error FirstBuyUnavailable();
    /// @notice The creator's first buy exceeds `CREATOR_FIRST_BUY_MAX`.
    error FirstBuyTooLarge(uint256 tokensOut);
    /// @notice The bucket is empty.
    error NothingToClaim();
    /// @notice The bond is still posted against a launch that has not settled, so it is
    /// not claimable yet.
    error BondNotReturned();
    /// @notice This launch posted no dev bond, so it has none to pay.
    error NoBondPosted();
    /// @notice The bond was forfeited to this launch's holders and will never be paid to
    /// the creator.
    error BondForfeitedToHolders();
    /// @notice The returned bond has already been paid to the creator.
    error BondAlreadyClaimed();
    /// @notice An ETH transfer out of the curve failed.
    error EthTransferFailed(address to, uint256 amount);
    /// @notice A launch token transfer failed.
    error TokenTransferFailed();
    /// @notice Only Uniswap v4's PoolManager may call this.
    error NotPoolManager();
    /// @notice The curve is not inside its own `unlock`.
    error NotUnlocking();
    /// @notice The price-restoring swap would have cost the curve value.
    error SwapNotFree(int128 amount0, int128 amount1);
    /// @notice The pool price is not the curve's terminal price.
    error PriceNotRestored(uint160 actual, uint160 expected);
    /// @notice The alternate pool key has already been initialised.
    error AltPoolInitialized();
    /// @notice `ALT_DELAY` has not elapsed since the cap was reached.
    error AltDelayNotElapsed();
    /// @notice `GRAD_GRACE` has not elapsed since the cap was reached.
    error GraceNotElapsed();
    /// @notice The tick spacing is outside the permitted alternate range.
    error InvalidTickSpacing(uint24 tickSpacing);
    /// @notice The core mint left more than `LP_DUST_MAX` base units unconsumed.
    error LpDustTooHigh(uint256 remainder);
    /// @notice The floor range is not strictly above the current tick, or leaves the
    /// pool's aligned tick bounds.
    error FloorRangeInvalid(int24 tickLower, int24 tickUpper, int24 currentTick);
    /// @notice A configuration value handed to the constructor is not acceptable.
    error InvalidConfig();
    /// @notice The ETH sent to the constructor is not exactly the bond.
    error BondValueMismatch();
    /// @notice The launch token did not arrive with its whole supply in this contract.
    error InvalidToken();
    /// @notice The cap has already been reached, so the launch cannot expire.
    error CapAlreadyReached();
    /// @notice ETH may only be sent to a curve through `buy` or `donate`.
    error DirectEthNotAccepted();

    /// @notice Buys tokens from the curve at the current price.
    /// @param minTokensOut Minimum base units the buyer accepts.
    /// @param deadline Latest block time the buyer accepts.
    /// @return tokensOut Base units transferred to the buyer.
    function buy(uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);

    /// @notice Sells tokens back to the curve.
    /// @param tokensIn Base units to sell.
    /// @param minEthOut Minimum wei the seller accepts.
    /// @param deadline Latest block time the seller accepts.
    /// @return ethOut Wei transferred to the seller.
    function sell(uint256 tokensIn, uint256 minEthOut, uint256 deadline)
        external
        returns (uint256 ethOut);

    /// @notice Donates ETH to the curve, raising every holder's exit price.
    function donate() external payable;

    /// @notice Executes the creator's priced, vested first buy. Factory only, once.
    /// @param cliff Seconds after the vesting start before anything releases.
    /// @param duration Seconds of linear release after the cliff.
    /// @return tokensOut Base units delivered to `CreatorVesting`.
    function creatorFirstBuy(uint32 cliff, uint32 duration)
        external
        payable
        returns (uint256 tokensOut);

    /// @notice Graduates the launch on the primary pool key.
    function graduate() external;

    /// @notice Graduates the launch on an uninitialised alternate pool key.
    /// @param tickSpacing The alternate tick spacing, within the permitted range.
    function graduateAlt(uint24 tickSpacing) external;

    /// @notice Moves a launch griefed out of graduation to `Stalled`.
    function abortGraduation() external;

    /// @notice Finalises a launch that missed its deadline.
    function expire() external;

    /// @notice Pays the creator's accrued fee bucket to the creator.
    /// @return amount Wei transferred.
    function claimCreatorFees() external returns (uint256 amount);

    /// @notice Pays the protocol's accrued fee bucket to the treasury.
    /// @return amount Wei transferred.
    function claimProtocolFees() external returns (uint256 amount);

    /// @notice Pays a returned bond to the creator.
    /// @dev Every refusal names the truth rather than an empty bucket. Three come from the
    /// bond state: `NoBondPosted` for a launch that never posted one,
    /// `BondForfeitedToHolders` for a bond already donated into the reserve, and
    /// `BondNotReturned` only while the bond is still held and the launch can still
    /// settle. The fourth, `BondAlreadyClaimed`, is the `Returned` state with an empty
    /// credit, which is reachable only after a successful claim.
    /// @return amount Wei transferred.
    function claimBond() external returns (uint256 amount);

    /// @notice Pays a credited graduation bounty to the address that earned it.
    /// @param earner The address credited by `graduate` or `graduateAlt`.
    /// @return amount Wei transferred.
    function claimBounty(address earner) external returns (uint256 amount);

    /// @notice Quotes a buy against the curve's stored reserves.
    /// @param ethIn Wei the buyer would send.
    /// @return tokensOut Base units out.
    /// @return ethToCurve Wei that would reach the reserve.
    /// @return fee Wei of fee.
    /// @return refund Wei refunded, non-zero only for the clipped final buy.
    function quoteBuy(uint256 ethIn)
        external
        view
        returns (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund);

    /// @notice Quotes a sell against the curve's stored reserves.
    /// @param tokensIn Base units the seller would return.
    /// @return ethGross Wei that would leave the reserve.
    /// @return fee Wei of fee.
    /// @return ethOut Wei the seller would receive.
    function quoteSell(uint256 tokensIn)
        external
        view
        returns (uint256 ethGross, uint256 fee, uint256 ethOut);

    /// @notice The curve's live virtual reserves, read from storage only.
    /// @return virtualEth `virtualEthReserve + ethReserve`.
    /// @return virtualTokens `VIRTUAL_TOKEN_RESERVE - tokensSold`.
    function liveReserves() external view returns (uint256 virtualEth, uint256 virtualTokens);

    /// @notice True when the launch posted a dev bond.
    function pledged() external view returns (bool);

    /// @notice The launch token.
    function token() external view returns (IERC20);

    /// @notice Block time after which the curve is closed to buyers forever.
    function gradDeadline() external view returns (uint64);

    /// @notice The id of the primary pool key.
    function poolId() external view returns (PoolId);
}
