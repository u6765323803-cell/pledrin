// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "src/interfaces/ICreatorVesting.sol";
import {ILiquidityLock} from "src/interfaces/ILiquidityLock.sol";
import {ITokenDeployer} from "src/interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {RogueCurveDeployer} from "../helpers/RogueCurveDeployer.sol";

/// @title `BondingCurve`'s constructor
/// @notice Covers `docs/SPEC.md` sections 8.1, 15.2 and 15.3, and Invariants 16, 28, 40
/// and 53: every launch-time value is checked in the curve itself and then frozen into an
/// immutable, so a launch's rules are fixed the moment it exists.
/// @dev The curve re-checks what the factory already validated. That duplication is the
/// point of Invariants 16 and 28, which require the bound to hold "in the curve's
/// constructor and not only in factory config", so each branch is exercised here directly
/// through `CurveDeployer` rather than through `createLaunch`.
contract BondingCurveConstructorTest is PledrinTestBase {
    RogueCurveDeployer internal deployer;

    function setUp() public override {
        super.setUp();
        deployer = new RogueCurveDeployer();
    }

    /// @notice Every immutable the launch freezes, and the pool it opens.
    function test_everyLaunchTimeValueIsFrozenIntoAnImmutable() public {
        (BondingCurve curve, IERC20 token) = createPledgedLaunch();

        assertEq(curve.factory(), address(factory), "factory");
        assertEq(curve.creator(), CREATOR, "creator");
        assertEq(curve.protocolTreasury(), TREASURY, "treasury");
        assertEq(address(curve.vesting()), address(vesting), "vesting");
        assertEq(address(curve.liquidityLock()), address(lock), "lock");
        assertEq(address(curve.poolManager()), address(poolManager), "poolManager");
        assertEq(address(curve.positionManager()), address(positionManager), "positionManager");
        assertEq(address(curve.permit2()), address(permit2), "permit2");
        assertEq(curve.virtualEthReserve(), DEFAULT_VE0, "virtualEthReserve");
        assertEq(curve.ethTarget(), 4 ether, "R_target == 8 * vE0");
        assertEq(curve.bondWei(), 0.4 ether, "bondWei");
        assertEq(curve.gradDeadline(), vm.getBlockTimestamp() + DEFAULT_GRAD_WINDOW, "gradDeadline");
        assertEq(curve.totalFeeBps(), DEFAULT_FEE_BPS, "totalFeeBps");
        assertEq(curve.creatorShareBps(), PLEDGED_CREATOR_BPS, "pledged creator share");
        assertEq(curve.protocolShareBps(), PLEDGED_PROTOCOL_BPS, "pledged protocol share");
        assertEq(curve.protectionShareBps(), PLEDGED_PROTECTION_BPS, "pledged protection share");
        assertEq(address(curve.token()), address(token), "token");
        assertEq(uint8(curve.state()), uint8(IBondingCurve.State.Live), "state");
        assertTrue(curve.pledged(), "pledged");
    }

    /// @notice Section 8.1 and Invariant 40: the pool is initialised in the launch
    /// transaction, at `sqrtPriceTerminal`, with zero liquidity.
    function test_thePoolIsOpenedAtTheTerminalPriceInTheLaunchTransaction() public {
        (BondingCurve curve,) = createDefaultLaunch();

        uint256 ratio = FullMath.mulDiv(PledrinConstants.LP_SUPPLY, 1 << 192, curve.ethTarget());
        uint160 expected = uint160(FixedPointMathLib.sqrt(ratio));

        (uint160 price, int24 tick) = poolManager.slot0(curve.poolId());
        assertEq(curve.sqrtPriceTerminal(), expected, "sqrtPriceTerminal");
        assertEq(price, expected, "the pool opened at the terminal price");
        assertEq(tick, 170_352, "the tick section 8.1 states for the default parameters");
        assertEq(poolManager.liquidity(curve.poolId()), 0, "the pool opens with no liquidity");
        assertTrue(poolManager.initialized(curve.poolId()), "initialised");
    }

    /// @notice An unpledged launch takes the unpledged share set and posts no bond.
    function test_anUnpledgedLaunchTakesTheUnpledgedShares() public {
        (BondingCurve curve,) = createDefaultLaunch();

        assertEq(curve.creatorShareBps(), UNPLEDGED_CREATOR_BPS, "creator share");
        assertEq(curve.protocolShareBps(), UNPLEDGED_PROTOCOL_BPS, "protocol share");
        assertEq(curve.protectionShareBps(), UNPLEDGED_PROTECTION_BPS, "protection share");
        assertEq(curve.bondWei(), 0, "no bond");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.None), "bond state");
        assertFalse(curve.pledged(), "not pledged");
    }

    /// @notice Invariant 29: `pledged()` reads the immutable `bondWei` and is therefore
    /// unchanged by any bond transition.
    function test_pledgedSurvivesTheBondLeavingBonded() public {
        (BondingCurve curve,) = createPledgedLaunch();
        assertTrue(curve.pledged(), "pledged at launch");

        buyToCap(curve);
        vm.prank(GRADUATOR);
        curve.graduate();

        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Returned), "returned");
        assertTrue(curve.pledged(), "Invariant 29: still pledged after the bond is returned");
    }

    // ------------------------------------------------------------------
    // Rejections. Each is a separate branch of the constructor.
    // ------------------------------------------------------------------

    function test_constructorRejectsAZeroFactory() public {
        _expectInvalid(_config(), address(0), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroCreator() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.creator = address(0);
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroTreasury() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.protocolTreasury = address(0);
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroTokenDeployer() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.tokenDeployer = ITokenDeployer(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroVesting() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.vesting = ICreatorVesting(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroLiquidityLock() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.liquidityLock = ILiquidityLock(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroPoolManager() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.poolManager = IPoolManager(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroPositionManager() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.positionManager = IPositionManager(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    function test_constructorRejectsAZeroPermit2() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.permit2 = IAllowanceTransfer(address(0));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    /// @notice Section 15.2's reserve bounds, one wei outside on each side.
    function test_constructorRejectsAReserveOutsideTheBounds() public {
        IBondingCurve.CurveConfig memory low = _config();
        low.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE - 1;
        _expectInvalid(low, address(factory), IBondingCurve.InvalidConfig.selector);

        IBondingCurve.CurveConfig memory high = _config();
        high.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE + 1;
        _expectInvalid(high, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    /// @notice The bounds themselves are accepted.
    function test_constructorAcceptsTheReserveBoundsExactly() public {
        IBondingCurve.CurveConfig memory low = _config();
        low.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE;
        BondingCurve atMin = _deploy(low, address(factory), 0);
        assertEq(atMin.ethTarget(), 0.1 ether, "smallest raise");

        IBondingCurve.CurveConfig memory high = _config();
        high.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        BondingCurve atMax = _deploy(high, address(factory), 0);
        assertEq(atMax.ethTarget(), 1000 ether, "largest raise");
    }

    /// @notice Section 15.2's window bounds, one second outside on each side.
    function test_constructorRejectsAGradWindowOutsideTheBounds() public {
        IBondingCurve.CurveConfig memory short_ = _config();
        short_.gradWindow = PledrinConstants.MIN_GRAD_WINDOW - 1;
        _expectInvalid(short_, address(factory), IBondingCurve.InvalidConfig.selector);

        IBondingCurve.CurveConfig memory long_ = _config();
        long_.gradWindow = PledrinConstants.MAX_GRAD_WINDOW + 1;
        _expectInvalid(long_, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    /// @notice **Invariant 16.** The fee ceiling is enforced in the curve's constructor
    /// and not only in factory config: one bps over `MAX_TOTAL_FEE_BPS` is rejected even
    /// though no factory would ever propose it.
    function test_constructorRejectsAFeeAboveTheCeiling() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.totalFeeBps = PledrinConstants.MAX_TOTAL_FEE_BPS + 1;
        _expectInvalid(config, address(factory), IBondingCurve.InvalidConfig.selector);

        IBondingCurve.CurveConfig memory atCeiling = _config();
        atCeiling.totalFeeBps = PledrinConstants.MAX_TOTAL_FEE_BPS;
        assertEq(
            _deploy(atCeiling, address(factory), 0).totalFeeBps(),
            PledrinConstants.MAX_TOTAL_FEE_BPS,
            "the ceiling itself is accepted"
        );
    }

    /// @notice **Invariant 15** in the curve: a share set that does not sum to exactly
    /// 10000 is rejected, one bps either way.
    function test_constructorRejectsSharesThatDoNotSumToTenThousand() public {
        IBondingCurve.CurveConfig memory under = _config();
        under.protectionShareBps = UNPLEDGED_PROTECTION_BPS - 1;
        _expectInvalid(under, address(factory), IBondingCurve.InvalidConfig.selector);

        IBondingCurve.CurveConfig memory over = _config();
        over.protectionShareBps = UNPLEDGED_PROTECTION_BPS + 1;
        _expectInvalid(over, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    /// @notice **Invariant 28** in the curve: a non-zero bond below the proportional floor
    /// or above `MAX_BOND_WEI` is rejected.
    function test_constructorRejectsABondOutsideItsBounds() public {
        IBondingCurve.CurveConfig memory low = _config();
        low.bondWei = 0.4 ether - 1; // one wei below `R_target / 10`
        _expectInvalid(low, address(factory), IBondingCurve.InvalidConfig.selector);

        IBondingCurve.CurveConfig memory high = _config();
        high.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        high.bondWei = uint128(PledrinConstants.MAX_BOND_WEI) + 1;
        _expectInvalid(high, address(factory), IBondingCurve.InvalidConfig.selector);
    }

    /// @notice The bond floor itself is accepted, and the bond is held from the first
    /// moment of the launch.
    function test_constructorAcceptsTheBondFloorExactly() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.bondWei = 0.4 ether;
        BondingCurve curve = _deploy(config, address(factory), 0.4 ether);

        assertEq(curve.bondHeldWei(), 0.4 ether, "bondHeldWei");
        assertEq(curve.bondWei(), 0.4 ether, "bondWei");
        assertEq(uint8(curve.bondState()), uint8(IBondingCurve.BondState.Bonded), "Bonded");
        assertEq(address(curve).balance, 0.4 ether, "the bond is the curve's whole balance");
    }

    /// @notice The largest permitted bond on the largest permitted raise.
    function test_constructorAcceptsTheMaximumBond() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        config.bondWei = uint128(PledrinConstants.MAX_BOND_WEI);
        BondingCurve curve = _deploy(config, address(factory), PledrinConstants.MAX_BOND_WEI);

        assertEq(curve.bondWei(), PledrinConstants.MAX_BOND_WEI, "the ceiling is accepted");
    }

    /// @notice `msg.value` has to be exactly the bond: more or less is rejected.
    function test_constructorRejectsAValueThatIsNotExactlyTheBond() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.bondWei = 0.4 ether;
        _expectInvalidWithValue(
            config, address(factory), 0.4 ether - 1, IBondingCurve.BondValueMismatch.selector
        );
        _expectInvalidWithValue(
            config, address(factory), 0.4 ether + 1, IBondingCurve.BondValueMismatch.selector
        );

        IBondingCurve.CurveConfig memory unbonded = _config();
        _expectInvalidWithValue(
            unbonded, address(factory), 1, IBondingCurve.BondValueMismatch.selector
        );
    }

    /// @notice The curve requires its whole supply to have arrived, which a deployer that
    /// mints to somebody else cannot satisfy.
    function test_constructorRejectsATokenThatDidNotDeliverTheSupply() public {
        IBondingCurve.CurveConfig memory config = _config();
        config.tokenDeployer = ITokenDeployer(address(new MisdirectingTokenDeployer(OTHER)));
        _expectInvalid(config, address(factory), IBondingCurve.InvalidToken.selector);
    }

    /// @notice Section 8.1's anti-grief claim, from the other side: the pool key is
    /// occupied the moment the launch exists, so there is no window in which anyone else
    /// could have initialised it at a price of their choosing.
    function test_thePoolKeyIsOccupiedTheMomentTheLaunchExists() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: PledrinConstants.POOL_FEE,
            tickSpacing: PledrinConstants.POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(curve.poolId()), "the launch's key");

        // The price is read into a local first: `vm.expectRevert` attaches to the next
        // call, and an argument that is itself an external call would consume it.
        uint160 price = curve.sqrtPriceTerminal();
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        poolManager.initialize(key, price);
    }

    /// @notice `sqrtPriceTerminal` stays above v4's minimum price and inside its tick
    /// bounds across the whole permitted reserve range.
    function testFuzz_terminalPriceIsInsideTheV4Bounds(uint128 vE0) public {
        vE0 = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );

        IBondingCurve.CurveConfig memory config = _config();
        config.virtualEthReserve = vE0;
        BondingCurve curve = _deploy(config, address(factory), 0);

        uint160 price = curve.sqrtPriceTerminal();
        assertGt(price, TickMath.MIN_SQRT_PRICE, "above MIN_SQRT_PRICE");
        assertLt(price, TickMath.MAX_SQRT_PRICE, "below MAX_SQRT_PRICE");

        (uint160 poolPrice,) = poolManager.slot0(curve.poolId());
        assertEq(poolPrice, price, "Invariant 40 at launch");
    }

    // ------------------------------------------------------------------

    function _config() private view returns (IBondingCurve.CurveConfig memory) {
        return IBondingCurve.CurveConfig({
            creator: CREATOR,
            protocolTreasury: TREASURY,
            tokenDeployer: ITokenDeployer(address(tokenDeployer)),
            vesting: ICreatorVesting(address(vesting)),
            liquidityLock: ILiquidityLock(address(lock)),
            poolManager: IPoolManager(address(poolManager)),
            positionManager: IPositionManager(address(positionManager)),
            permit2: IAllowanceTransfer(address(permit2)),
            virtualEthReserve: DEFAULT_VE0,
            bondWei: 0,
            gradWindow: DEFAULT_GRAD_WINDOW,
            totalFeeBps: DEFAULT_FEE_BPS,
            creatorShareBps: UNPLEDGED_CREATOR_BPS,
            protocolShareBps: UNPLEDGED_PROTOCOL_BPS,
            protectionShareBps: UNPLEDGED_PROTECTION_BPS,
            name: "Probe",
            symbol: "PRB"
        });
    }

    function _deploy(IBondingCurve.CurveConfig memory config, address factory_, uint256 value)
        private
        returns (BondingCurve)
    {
        vm.deal(OTHER, OTHER.balance + value);
        vm.prank(OTHER);
        return BondingCurve(payable(deployer.deploy{value: value}(factory_, config)));
    }

    function _expectInvalid(
        IBondingCurve.CurveConfig memory config,
        address factory_,
        bytes4 selector
    ) private {
        _expectInvalidWithValue(config, factory_, config.bondWei, selector);
    }

    function _expectInvalidWithValue(
        IBondingCurve.CurveConfig memory config,
        address factory_,
        uint256 value,
        bytes4 selector
    ) private {
        vm.deal(OTHER, OTHER.balance + value);
        vm.prank(OTHER);
        vm.expectRevert(selector);
        deployer.deploy{value: value}(factory_, config);
    }
}

/// @notice A token deployer that mints the supply somewhere other than its caller.
contract MisdirectingTokenDeployer {
    address private immutable _recipient;

    constructor(address recipient) {
        _recipient = recipient;
    }

    function deploy(string calldata name, string calldata symbol) external returns (IERC20) {
        return IERC20(address(new MisdirectedToken(name, symbol, _recipient)));
    }
}

/// @notice A token whose supply goes to an address the curve did not ask for.
contract MisdirectedToken {
    string public name;
    string public symbol;
    uint256 public totalSupply = PledrinConstants.TOTAL_SUPPLY;

    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, address holder) {
        name = name_;
        symbol = symbol_;
        balanceOf[holder] = PledrinConstants.TOTAL_SUPPLY;
    }
}
