// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {ICreatorVesting} from "./interfaces/ICreatorVesting.sol";
import {ICurveDeployer} from "./interfaces/ICurveDeployer.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {ILiquidityLock} from "./interfaces/ILiquidityLock.sol";
import {ITokenDeployer} from "./interfaces/ITokenDeployer.sol";
import {PledrinConstants} from "./libraries/PledrinConstants.sol";

/// @title Pledrin launch factory
/// @notice Creates launches and keeps the creator reputation counters of
/// `docs/SPEC.md` section 13.
/// @dev Every launch-time value is copied into the new launch's immutables, so a later
/// configuration change reaches future launches only and can never touch an existing one.
/// The owner is a timelock whose complete set of powers is pausing new launches, changing
/// the defaults future launches copy, and changing the treasury future launches record.
/// None of those can move a single wei of any launch's value, and a pause stops nothing
/// but `createLaunch`.
contract LaunchFactory is ILaunchFactory, Ownable, ReentrancyGuardTransient {
    /// @notice The deployer that carries `BondingCurve`'s creation code.
    ICurveDeployer public immutable curveDeployer;
    /// @notice The deployer that carries `PledrinToken`'s creation code.
    ITokenDeployer public immutable tokenDeployer;
    /// @notice The creator vesting singleton every launch uses.
    ICreatorVesting public immutable vesting;
    /// @notice The permanent liquidity lock every launch graduates into.
    ILiquidityLock public immutable liquidityLock;
    /// @notice Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice Uniswap v4 PositionManager.
    IPositionManager public immutable positionManager;
    /// @notice Permit2, the only approval path PositionManager accepts.
    IAllowanceTransfer public immutable permit2;

    /// @notice The treasury recorded into the next launch.
    address public protocolTreasury;
    /// @notice True while the creation of new launches is paused.
    bool public launchesPaused;

    /// @notice True for every curve this factory deployed.
    mapping(address launch => bool) public isLaunch;

    FeeConfig private _feeConfig;
    mapping(address creator => Reputation) private _reputation;

    /// @dev Only a curve this factory deployed may write a reputation counter. There is no
    /// setter, no admin write and no off-chain input anywhere in this contract.
    modifier onlyLaunch() {
        if (!isLaunch[msg.sender]) revert NotLaunch();
        _;
    }

    /// @notice Wires the factory to its dependencies and sets the initial configuration.
    /// @dev Every external address arrives here as an argument. None is a literal
    /// anywhere in the source.
    /// @param initialOwner The timelock that owns this factory.
    /// @param curveDeployer_ The deployer that carries `BondingCurve`'s creation code.
    /// @param tokenDeployer_ The deployer that carries `PledrinToken`'s creation code.
    /// @param vesting_ The creator vesting singleton.
    /// @param liquidityLock_ The permanent liquidity lock.
    /// @param poolManager_ Uniswap v4 PoolManager.
    /// @param positionManager_ Uniswap v4 PositionManager.
    /// @param permit2_ Permit2.
    /// @param treasury The treasury recorded into the first launches.
    /// @param config The fee configuration the first launches copy.
    constructor(
        address initialOwner,
        ICurveDeployer curveDeployer_,
        ITokenDeployer tokenDeployer_,
        ICreatorVesting vesting_,
        ILiquidityLock liquidityLock_,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        address treasury,
        FeeConfig memory config
    ) Ownable(initialOwner) {
        if (
            address(curveDeployer_) == address(0) || address(tokenDeployer_) == address(0)
                || address(vesting_) == address(0) || address(liquidityLock_) == address(0)
                || address(poolManager_) == address(0) || address(positionManager_) == address(0)
                || address(permit2_) == address(0)
        ) revert InvalidDependency();

        curveDeployer = curveDeployer_;
        tokenDeployer = tokenDeployer_;
        vesting = vesting_;
        liquidityLock = liquidityLock_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;

        _setProtocolTreasury(treasury);
        _setFeeConfig(config);
    }

    /// @inheritdoc ILaunchFactory
    /// @dev One transaction deploys the token and the curve, initialises the Uniswap v4
    /// pool at the curve's terminal price, posts the bond and performs the creator's
    /// priced, vested first buy. The pool is initialised here, before the token address
    /// is public, which is what makes it impossible for anyone else to choose the pool's
    /// initial price.
    function createLaunch(LaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (address launch, address launchToken)
    {
        if (launchesPaused) revert LaunchesArePaused();
        _validate(params, msg.value);

        FeeConfig memory config = _feeConfig;
        FeeShares memory shares = params.bondWei != 0 ? config.pledged : config.unpledged;

        // The bond is forwarded to the launch being created, the only contract that can
        // ever hold it, and `msg.value` was checked to be exactly bond plus first buy.
        // forge-lint: disable-next-item(arbitrary-send-eth)
        launch = curveDeployer.deploy{value: params.bondWei}(
            IBondingCurve.CurveConfig({
                creator: msg.sender,
                protocolTreasury: protocolTreasury,
                tokenDeployer: tokenDeployer,
                vesting: vesting,
                liquidityLock: liquidityLock,
                poolManager: poolManager,
                positionManager: positionManager,
                permit2: permit2,
                virtualEthReserve: params.virtualEthReserve,
                bondWei: params.bondWei,
                gradWindow: params.gradWindow,
                totalFeeBps: config.totalFeeBps,
                creatorShareBps: shares.creatorShareBps,
                protocolShareBps: shares.protocolShareBps,
                protectionShareBps: shares.protectionShareBps,
                name: params.name,
                symbol: params.symbol
            })
        );

        IBondingCurve curve = IBondingCurve(launch);
        launchToken = address(curve.token());
        isLaunch[launch] = true;

        if (params.creatorFirstBuyWei != 0) {
            // The base units delivered are emitted by `CreatorVesting`'s `VestingCreated`.
            // forge-lint: disable-next-item(arbitrary-send-eth, unused-return)
            curve.creatorFirstBuy{value: params.creatorFirstBuyWei}(
                params.creatorVestCliff, params.creatorVestDuration
            );
        }

        _recordLaunch(msg.sender, params.bondWei);

        emit LaunchCreated(
            launch,
            launchToken,
            msg.sender,
            params.virtualEthReserve,
            PledrinConstants.ETH_TARGET_MULTIPLE * params.virtualEthReserve,
            config.totalFeeBps,
            shares.creatorShareBps,
            shares.protocolShareBps,
            shares.protectionShareBps,
            params.bondWei,
            curve.gradDeadline(),
            curve.poolId()
        );
        emit LaunchMetadata(launch, params.name, params.symbol, params.metadata);
    }

    /// @inheritdoc ILaunchFactory
    function recordGraduation(address creator, uint128 ethRaised, bool bondReturned)
        external
        onlyLaunch
    {
        Reputation storage record = _reputation[creator];

        emit ReputationUpdated(creator, Counter.Graduations, ++record.graduations);

        uint128 raised = record.ethRaisedGraduated + ethRaised;
        record.ethRaisedGraduated = raised;
        emit ReputationUpdated(creator, Counter.EthRaisedGraduated, raised);

        if (bondReturned) {
            emit ReputationUpdated(creator, Counter.BondsReturned, ++record.bondsReturned);
        }
    }

    /// @inheritdoc ILaunchFactory
    function recordStall(address creator, bool bondReturned) external onlyLaunch {
        Reputation storage record = _reputation[creator];

        emit ReputationUpdated(creator, Counter.Stalls, ++record.stalls);

        if (bondReturned) {
            emit ReputationUpdated(creator, Counter.BondsReturned, ++record.bondsReturned);
        }
    }

    /// @inheritdoc ILaunchFactory
    function recordExpiry(address creator, uint128 bondForfeited) external onlyLaunch {
        Reputation storage record = _reputation[creator];

        emit ReputationUpdated(creator, Counter.Expiries, ++record.expiries);

        if (bondForfeited != 0) {
            emit ReputationUpdated(creator, Counter.BondsForfeited, ++record.bondsForfeited);

            uint128 forfeited = record.bondWeiForfeited + bondForfeited;
            record.bondWeiForfeited = forfeited;
            emit ReputationUpdated(creator, Counter.BondWeiForfeited, forfeited);
        }
    }

    /// @inheritdoc ILaunchFactory
    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        emit LaunchesPausedSet(paused);
    }

    /// @inheritdoc ILaunchFactory
    function setFeeConfig(FeeConfig calldata config) external onlyOwner {
        _setFeeConfig(config);
    }

    /// @inheritdoc ILaunchFactory
    function setProtocolTreasury(address treasury) external onlyOwner {
        _setProtocolTreasury(treasury);
    }

    /// @notice Disabled: this factory's ownership can never move to another address.
    /// @dev `Ownable` declares this function and the four configuration powers of
    /// `docs/SPEC.md` section 14 sit behind a timelock. A `transferOwnership` executed
    /// through that timelock could put ownership in an EOA, which would remove the delay
    /// from every subsequent configuration change and quietly void the guarantee section 14
    /// exists to make. Overriding it to revert makes "the owner is the timelock,
    /// permanently" a property of the code rather than a promise. `renounceOwnership` is
    /// deliberately left working, because it only ever reduces power.
    function transferOwnership(address) public pure override {
        revert OwnershipTransferDisabled();
    }

    /// @inheritdoc ILaunchFactory
    function feeConfig() external view returns (FeeConfig memory config) {
        return _feeConfig;
    }

    /// @inheritdoc ILaunchFactory
    function reputationOf(address creator) external view returns (Reputation memory record) {
        return _reputation[creator];
    }

    /// @dev Checks every per-launch parameter against `docs/SPEC.md` section 15.2. The
    /// bond's floor is proportional to the raise it backs, so a bond is always meaningful
    /// relative to the launch rather than trivial on a large one.
    function _validate(LaunchParams calldata params, uint256 value) private pure {
        uint256 nameLength = bytes(params.name).length;
        if (nameLength == 0 || nameLength > PledrinConstants.MAX_NAME_BYTES) revert InvalidName();

        uint256 symbolLength = bytes(params.symbol).length;
        if (symbolLength == 0 || symbolLength > PledrinConstants.MAX_SYMBOL_BYTES) {
            revert InvalidSymbol();
        }

        if (
            params.virtualEthReserve < PledrinConstants.MIN_VIRTUAL_ETH_RESERVE
                || params.virtualEthReserve > PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
        ) revert InvalidVirtualEthReserve();

        if (
            params.gradWindow < PledrinConstants.MIN_GRAD_WINDOW
                || params.gradWindow > PledrinConstants.MAX_GRAD_WINDOW
        ) revert InvalidGradWindow();

        if (params.creatorVestCliff > PledrinConstants.MAX_VEST_CLIFF) revert InvalidVestCliff();

        if (
            params.creatorVestDuration < PledrinConstants.MIN_VEST_DURATION
                || params.creatorVestDuration > PledrinConstants.MAX_VEST_DURATION
        ) revert InvalidVestDuration();

        if (params.bondWei != 0) {
            uint256 minBond = PledrinConstants.minBondWei(
                PledrinConstants.ETH_TARGET_MULTIPLE * params.virtualEthReserve
            );
            if (params.bondWei < minBond || params.bondWei > PledrinConstants.MAX_BOND_WEI) {
                revert InvalidBond();
            }
        }

        if (
            params.creatorFirstBuyWei != 0
                && params.creatorFirstBuyWei < PledrinConstants.MIN_BUY_WEI
        ) revert InvalidFirstBuy();

        uint256 expected = uint256(params.bondWei) + params.creatorFirstBuyWei;
        if (value != expected) revert ValueMismatch(value, expected);
    }

    /// @dev Reputation is raw counters only. The wei-denominated ones exist because a
    /// count is cheap to fabricate from a fresh address and wei is not.
    function _recordLaunch(address creator, uint128 bondWei) private {
        Reputation storage record = _reputation[creator];

        emit ReputationUpdated(creator, Counter.Launches, ++record.launches);

        if (bondWei != 0) {
            emit ReputationUpdated(creator, Counter.BondsPosted, ++record.bondsPosted);

            uint128 posted = record.bondWeiPosted + bondWei;
            record.bondWeiPosted = posted;
            emit ReputationUpdated(creator, Counter.BondWeiPosted, posted);
        }
    }

    function _setFeeConfig(FeeConfig memory config) private {
        if (config.totalFeeBps > PledrinConstants.MAX_TOTAL_FEE_BPS) revert InvalidFeeConfig();
        if (!_sharesSumToOne(config.unpledged) || !_sharesSumToOne(config.pledged)) {
            revert InvalidFeeConfig();
        }

        _feeConfig = config;

        emit FeeConfigSet(
            config.totalFeeBps,
            config.unpledged.creatorShareBps,
            config.unpledged.protocolShareBps,
            config.unpledged.protectionShareBps,
            config.pledged.creatorShareBps,
            config.pledged.protocolShareBps,
            config.pledged.protectionShareBps
        );
    }

    function _setProtocolTreasury(address treasury) private {
        if (treasury == address(0)) revert InvalidTreasury();

        protocolTreasury = treasury;

        emit TreasurySet(treasury);
    }

    function _sharesSumToOne(FeeShares memory shares) private pure returns (bool) {
        return uint256(shares.creatorShareBps) + shares.protocolShareBps + shares.protectionShareBps
            == PledrinConstants.BPS_DENOMINATOR;
    }
}
