// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {CreatorVesting} from "src/CreatorVesting.sol";
import {CurveDeployer} from "src/CurveDeployer.sol";
import {LaunchFactory} from "src/LaunchFactory.sol";
import {LiquidityLock} from "src/LiquidityLock.sol";
import {Timelock} from "src/Timelock.sol";
import {TokenDeployer} from "src/TokenDeployer.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

/// @dev `ownerOf` is on the deployed PositionManager but not on `IPositionManager`.
interface IPositionManagerOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title Shared setup for the fork suite
/// @notice Deploys the whole protocol against the **real** Uniswap v4 deployment on
/// Robinhood Chain, so every graduation the fork suite performs runs through the real
/// PoolManager, PositionManager and Permit2.
/// @dev The addresses are the ones in `docs/CHAIN_FACTS.md` and nowhere else.
///
/// The fork is not pinned to a block, for the reason `test/fork/V4Assumptions.t.sol`
/// records: the Robinhood Chain mainnet RPC prunes historical state after a few thousand
/// blocks, so a pinned block stops resolving within a day and breaks CI. Nothing asserted
/// here depends on chain state — every launch, pool and position is created inside the
/// test — so running at head is sound.
///
/// These tests are the measurement the deterministic suite's Uniswap stand-ins are held
/// to. Where a number appears in both suites it is the number measured here.
abstract contract ForkBase is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IAllowanceTransfer internal constant PERMIT2 =
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    address internal constant TREASURY = address(0xBEEF);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0xD00D);
    address internal constant OTHER = address(0x5A1E);

    uint128 internal constant DEFAULT_VE0 = 5e17;
    uint32 internal constant DEFAULT_GRAD_WINDOW = 2_592_000;
    uint32 internal constant DEFAULT_CLIFF = 604_800;
    uint32 internal constant DEFAULT_VEST_DURATION = 15_552_000;

    /// @dev Section 8.1 states this is the terminal tick at the default parameters, and
    /// `test/fork/V4Assumptions.t.sol` measures it against the deployed PoolManager.
    int24 internal constant DEFAULT_TERMINAL_TICK = 170_352;

    Timelock internal timelock;
    CreatorVesting internal vesting;
    LiquidityLock internal lock;
    CurveDeployer internal curveDeployer;
    TokenDeployer internal tokenDeployer;
    LaunchFactory internal factory;

    function setUp() public virtual {
        vm.createSelectFork("robinhood");

        timelock = new Timelock(ADMIN);
        vesting = new CreatorVesting();
        lock = new LiquidityLock(POSITION_MANAGER);
        curveDeployer = new CurveDeployer();
        tokenDeployer = new TokenDeployer();

        factory = new LaunchFactory(
            address(timelock),
            curveDeployer,
            tokenDeployer,
            vesting,
            lock,
            POOL_MANAGER,
            POSITION_MANAGER,
            PERMIT2,
            TREASURY,
            ILaunchFactory.FeeConfig({
                totalFeeBps: 100,
                unpledged: ILaunchFactory.FeeShares({
                    creatorShareBps: 3000, protocolShareBps: 4000, protectionShareBps: 3000
                }),
                pledged: ILaunchFactory.FeeShares({
                    creatorShareBps: 5000, protocolShareBps: 3000, protectionShareBps: 2000
                })
            })
        );

        vm.deal(CREATOR, 10_000 ether);
        vm.deal(TRADER, 100_000 ether);
        vm.deal(OTHER, 10_000 ether);
    }

    function defaultParams() internal pure returns (ILaunchFactory.LaunchParams memory) {
        return ILaunchFactory.LaunchParams({
            name: "Pledrin Fork",
            symbol: "PLDRF",
            virtualEthReserve: DEFAULT_VE0,
            bondWei: 0,
            creatorFirstBuyWei: 0,
            gradWindow: DEFAULT_GRAD_WINDOW,
            creatorVestCliff: DEFAULT_CLIFF,
            creatorVestDuration: DEFAULT_VEST_DURATION,
            metadata: ""
        });
    }

    function createLaunch(ILaunchFactory.LaunchParams memory params)
        internal
        returns (BondingCurve curve, IERC20 token)
    {
        uint256 value = uint256(params.bondWei) + params.creatorFirstBuyWei;
        vm.deal(CREATOR, CREATOR.balance + value);
        vm.prank(CREATOR);
        (address launch, address launchToken) = factory.createLaunch{value: value}(params);
        return (BondingCurve(payable(launch)), IERC20(launchToken));
    }

    /// @notice Drives a launch to the cap with one clipped buy.
    /// @dev A buy larger than the remaining supply takes the clipped branch of
    /// `CurveMath.buyQuote`, which charges exactly what the remaining tokens cost and
    /// refunds the rest, so one call reaches the cap and exercises the clip at the same
    /// time.
    function buyToCap(BondingCurve curve) internal {
        uint256 value = 4 * uint256(curve.ethTarget());
        vm.deal(TRADER, TRADER.balance + value);
        vm.prank(TRADER);
        curve.buy{value: value}(0, vm.getBlockTimestamp());
        require(curve.tokensSold() == PledrinConstants.CURVE_SUPPLY, "fork base: cap not reached");
    }

    function poolKeyFor(address token, int24 tickSpacing) internal pure returns (PoolKey memory) {
        return poolKeyFor(token, PledrinConstants.POOL_FEE, tickSpacing);
    }

    /// @notice A pool key for a launch token at any fee and spacing, which is what
    /// `graduateAlt` chooses between. `hooks` is always the zero address.
    function poolKeyFor(address token, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// @notice The native balance the **live** PositionManager holds right now.
    /// @dev Zero whenever nobody has left anything there, which is the ordinary case and
    /// was the case when these tests were written. It does not have to be: a v4 batch that
    /// forwards more value than it settles leaves the remainder in PositionManager, and
    /// `SELFDESTRUCT` bypasses the `receive()` sender check. Whatever is there when a
    /// graduation runs is swept into the curve by the core mint's closing `SWEEP`, so the
    /// assertions about what a graduated launch holds are higher by exactly this amount
    /// and name it rather than assume it away. Finding 1 of
    /// `docs/security/REVIEW-2026-11-11-phase1-contracts.md`; before that finding was
    /// fixed the graduation would have reverted instead.
    function strayInPositionManager() internal view returns (uint256) {
        return address(POSITION_MANAGER).balance;
    }

    /// @notice Every field of one `Graduated` log, indexed topics included.
    struct GraduatedLog {
        bytes32 poolId;
        address caller;
        uint24 fee;
        int24 tickSpacing;
        uint256 positionIdCore;
        uint256 positionIdFloor;
        uint256 ethToCore;
        uint256 ethToFloor;
        uint256 tokensToCore;
        uint256 bounty;
    }

    /// @notice The eight non-indexed fields of `Graduated`, in ABI order.
    struct GraduatedData {
        uint24 fee;
        int24 tickSpacing;
        uint256 positionIdCore;
        uint256 positionIdFloor;
        uint256 ethToCore;
        uint256 ethToFloor;
        uint256 tokensToCore;
        uint256 bounty;
    }

    /// @notice The first `Graduated` log a launch emitted in the recording, decoded.
    /// @dev Requires `vm.recordLogs()` beforehand. `caller` is indexed, so the data carries
    /// eight words: `fee`, `tickSpacing` and the six amounts.
    function graduatedLog(address curve) internal view returns (GraduatedLog memory log) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "Graduated(address,bytes32,uint24,int24,uint256,uint256,uint256,uint256,uint256,uint256,address)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic || logs[i].emitter != curve) continue;
            GraduatedData memory data = abi.decode(logs[i].data, (GraduatedData));
            log.poolId = logs[i].topics[2];
            log.caller = address(uint160(uint256(logs[i].topics[3])));
            log.fee = data.fee;
            log.tickSpacing = data.tickSpacing;
            log.positionIdCore = data.positionIdCore;
            log.positionIdFloor = data.positionIdFloor;
            log.ethToCore = data.ethToCore;
            log.ethToFloor = data.ethToFloor;
            log.tokensToCore = data.tokensToCore;
            log.bounty = data.bounty;
            return log;
        }
        revert("no Graduated event");
    }

    function ownerOfPosition(uint256 tokenId) internal view returns (address) {
        return IPositionManagerOwner(address(POSITION_MANAGER)).ownerOf(tokenId);
    }

    /// @notice The ETH a launch still holds that does not belong to an unclaimed bucket.
    function unassignedEth(BondingCurve curve) internal view returns (uint256) {
        return address(curve).balance - curve.protocolFeeEth() - curve.creatorFeeEth()
            - curve.pendingBountyTotalWei() - curve.pendingBondWei();
    }
}
