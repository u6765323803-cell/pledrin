// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title Launch factory
/// @notice The singleton of `docs/SPEC.md` sections 13 to 15: it creates launches,
/// holds the configuration future launches copy, and keeps the creator reputation
/// counters. It never holds value and has no power over an existing launch.
interface ILaunchFactory {
    /// @notice One fee split. The three shares must sum to exactly 10000.
    /// @param creatorShareBps The creator's share of a trade's fee.
    /// @param protocolShareBps The protocol's share of a trade's fee.
    /// @param protectionShareBps The holder-protection share of a trade's fee.
    struct FeeShares {
        uint16 creatorShareBps;
        uint16 protocolShareBps;
        uint16 protectionShareBps;
    }

    /// @notice The fee configuration future launches copy.
    /// @param totalFeeBps The total trading fee, at most `MAX_TOTAL_FEE_BPS`.
    /// @param unpledged Split applied when the launch posts no bond.
    /// @param pledged Split applied when the launch posts a bond.
    struct FeeConfig {
        uint16 totalFeeBps;
        FeeShares unpledged;
        FeeShares pledged;
    }

    /// @notice Everything a creator chooses for one launch.
    /// @param name The token name, 1 to 64 bytes.
    /// @param symbol The token symbol, 1 to 16 bytes.
    /// @param virtualEthReserve The curve's only free scalar; `R_target` is eight times it.
    /// @param bondWei The dev bond, zero or within the bounds of section 11.1.
    /// @param creatorFirstBuyWei ETH the creator spends on their own vested first buy.
    /// @param gradWindow Seconds within which the cap must be reached.
    /// @param creatorVestCliff Seconds after graduation before anything vests.
    /// @param creatorVestDuration Seconds of linear vesting after the cliff.
    /// @param metadata Opaque bytes emitted once and never stored.
    struct LaunchParams {
        string name;
        string symbol;
        uint128 virtualEthReserve;
        uint128 bondWei;
        uint128 creatorFirstBuyWei;
        uint32 gradWindow;
        uint32 creatorVestCliff;
        uint32 creatorVestDuration;
        bytes metadata;
    }

    /// @notice One creator's raw, recomputable record. No score, ratio or decay is
    /// stored: a policy baked into a non-upgradeable contract cannot be corrected.
    /// @param launches Launches created.
    /// @param graduations Launches graduated.
    /// @param stalls Launches stalled after being griefed out of graduation.
    /// @param expiries Launches that missed their deadline.
    /// @param bondsPosted Launches created with a bond.
    /// @param bondsReturned Bonds that left `Bonded` by being returned.
    /// @param bondsForfeited Bonds that left `Bonded` by being forfeited to holders.
    /// @param bondWeiPosted Wei of bond posted across all launches.
    /// @param bondWeiForfeited Wei of bond actually lost to holders.
    /// @param ethRaisedGraduated Wei of `R_target` across graduated launches.
    struct Reputation {
        uint32 launches;
        uint32 graduations;
        uint32 stalls;
        uint32 expiries;
        uint32 bondsPosted;
        uint32 bondsReturned;
        uint32 bondsForfeited;
        uint128 bondWeiPosted;
        uint128 bondWeiForfeited;
        uint128 ethRaisedGraduated;
    }

    /// @notice Identifies which reputation counter a `ReputationUpdated` event reports.
    enum Counter {
        Launches,
        Graduations,
        Stalls,
        Expiries,
        BondsPosted,
        BondsReturned,
        BondsForfeited,
        BondWeiPosted,
        BondWeiForfeited,
        EthRaisedGraduated
    }

    /// @notice A launch was created, with every value it fixed for its lifetime.
    event LaunchCreated(
        address indexed launch,
        address indexed token,
        address indexed creator,
        uint128 virtualEthReserve,
        uint256 ethTarget,
        uint16 totalFeeBps,
        uint16 creatorShareBps,
        uint16 protocolShareBps,
        uint16 protectionShareBps,
        uint128 bondWei,
        uint64 gradDeadline,
        PoolId poolId
    );

    /// @notice A launch's descriptive data, emitted once and never stored.
    event LaunchMetadata(address indexed launch, string name, string symbol, bytes metadata);

    /// @notice One reputation counter changed.
    event ReputationUpdated(address indexed creator, Counter counter, uint256 newValue);

    /// @notice New launches were paused or unpaused. Affects no existing launch.
    event LaunchesPausedSet(bool paused);

    /// @notice The configuration future launches copy changed.
    event FeeConfigSet(
        uint16 totalFeeBps,
        uint16 creatorShareBps,
        uint16 protocolShareBps,
        uint16 protectionShareBps,
        uint16 pledgedCreatorShareBps,
        uint16 pledgedProtocolShareBps,
        uint16 pledgedProtectionShareBps
    );

    /// @notice The treasury recorded into future launches changed.
    event TreasurySet(address indexed treasury);

    /// @notice New launches are paused.
    error LaunchesArePaused();
    /// @notice The token name is empty or longer than 64 bytes.
    error InvalidName();
    /// @notice The token symbol is empty or longer than 16 bytes.
    error InvalidSymbol();
    /// @notice `virtualEthReserve` is outside the permitted range.
    error InvalidVirtualEthReserve();
    /// @notice `gradWindow` is outside the permitted range.
    error InvalidGradWindow();
    /// @notice `creatorVestCliff` is longer than permitted.
    error InvalidVestCliff();
    /// @notice `creatorVestDuration` is outside the permitted range.
    error InvalidVestDuration();
    /// @notice `bondWei` is non-zero and outside the permitted range.
    error InvalidBond();
    /// @notice `creatorFirstBuyWei` is non-zero and below `MIN_BUY_WEI`.
    error InvalidFirstBuy();
    /// @notice `msg.value` is not exactly the bond plus the first buy.
    error ValueMismatch(uint256 sent, uint256 expected);
    /// @notice A fee configuration exceeds the fee ceiling or its shares do not sum to
    /// exactly 10000.
    error InvalidFeeConfig();
    /// @notice The treasury address is zero.
    error InvalidTreasury();
    /// @notice A dependency handed to the constructor is the zero address.
    error InvalidDependency();
    /// @notice Only a curve this factory deployed may call this.
    error NotLaunch();
    /// @notice Ownership of the factory can only be renounced, never transferred.
    error OwnershipTransferDisabled();
    /// @notice Creates a launch: token, curve, pool and optional bond and first buy.
    /// @param params The creator's choices for this launch.
    /// @return launch The launch's bonding curve.
    /// @return launchToken The launch's ERC-20.
    function createLaunch(LaunchParams calldata params)
        external
        payable
        returns (address launch, address launchToken);

    /// @notice Records a graduation. Callable only by a curve this factory deployed.
    /// @param creator The launch's creator.
    /// @param ethRaised The launch's `R_target`.
    /// @param bondReturned True when the launch's bond left `Bonded` as returned.
    function recordGraduation(address creator, uint128 ethRaised, bool bondReturned) external;

    /// @notice Records a stall. Callable only by a curve this factory deployed.
    /// @param creator The launch's creator.
    /// @param bondReturned True when the launch's bond left `Bonded` as returned.
    function recordStall(address creator, bool bondReturned) external;

    /// @notice Records an expiry. Callable only by a curve this factory deployed.
    /// @param creator The launch's creator.
    /// @param bondForfeited Wei of bond the launch forfeited to holders, possibly zero.
    function recordExpiry(address creator, uint128 bondForfeited) external;

    /// @notice Pauses or unpauses the creation of new launches.
    /// @param paused The new pause state.
    function setLaunchesPaused(bool paused) external;

    /// @notice Sets the fee configuration future launches copy.
    /// @param config The new configuration.
    function setFeeConfig(FeeConfig calldata config) external;

    /// @notice Sets the treasury recorded into future launches.
    /// @param treasury The new treasury.
    function setProtocolTreasury(address treasury) external;

    /// @notice True for every curve this factory deployed.
    function isLaunch(address launch) external view returns (bool);

    /// @notice The configuration the next launch will copy.
    function feeConfig() external view returns (FeeConfig memory config);

    /// @notice One creator's raw counters.
    /// @param creator The creator to read.
    /// @return record The stored counters.
    function reputationOf(address creator) external view returns (Reputation memory record);
}
