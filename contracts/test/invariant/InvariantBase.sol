// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";

/// @title Shared setup for the invariant suite
/// @notice Deploys the protocol, creates three launches that differ in every free
/// parameter, and hands them to one handler whose methods are the only call surface the
/// invariant runner sees.
/// @dev The three launches are deliberately different: the smallest permitted raise with
/// no bond, the default raise with a bond and a creator first buy, and the largest
/// permitted raise. The handler can create more. Each invariant contract gets its own
/// handler instance, so the runs are independent.
abstract contract InvariantBase is PledrinTestBase {
    ProtocolHandler internal handler;

    function setUp() public virtual override {
        super.setUp();

        BondingCurve[] memory initial = new BondingCurve[](3);

        ILaunchFactory.LaunchParams memory smallest = defaultParams();
        smallest.name = "Smallest";
        smallest.symbol = "SML";
        smallest.virtualEthReserve = PledrinConstants.MIN_VIRTUAL_ETH_RESERVE;
        // The shortest permitted window, so a run reaches `Expired` without having to
        // jump past every other launch's deadline to get there.
        smallest.gradWindow = PledrinConstants.MIN_GRAD_WINDOW;
        (initial[0],) = createLaunch(smallest);

        ILaunchFactory.LaunchParams memory bonded = defaultParams();
        bonded.name = "Bonded";
        bonded.symbol = "BND";
        bonded.bondWei = 0.4 ether;
        bonded.creatorFirstBuyWei = 0.009 ether;
        bonded.gradWindow = 60 days;
        (initial[1],) = createLaunchFrom(OTHER, bonded);

        ILaunchFactory.LaunchParams memory largest = defaultParams();
        largest.name = "Largest";
        largest.symbol = "LRG";
        largest.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        largest.bondWei = uint128(PledrinConstants.MAX_BOND_WEI);
        // Deliberately the longest-lived of the three: a jump to one launch's deadline
        // must not leave the whole run with nothing left to buy.
        largest.gradWindow = PledrinConstants.MAX_GRAD_WINDOW;
        (initial[2],) = createLaunch(largest);

        handler = new ProtocolHandler(factory, initial, 4);
        targetContract(address(handler));
    }

    /// @notice `(vE0 + ethReserve) * (vT0 - tokensSold)`.
    function productOf(BondingCurve curve) internal view returns (uint256) {
        (uint256 virtualEth, uint256 virtualTokens) = curve.liveReserves();
        return virtualEth * virtualTokens;
    }

    /// @notice `vE0 * vT0`.
    function kOf(BondingCurve curve) internal view returns (uint256) {
        return uint256(curve.virtualEthReserve()) * PledrinConstants.VIRTUAL_TOKEN_RESERVE;
    }

    /// @notice True while the launch still prices trades off its reserve. A graduated
    /// launch does not: `graduate` deliberately zeroes `ethReserve` after depositing it
    /// into the two locked positions, and closes both sides of the book in the same
    /// transaction.
    function stillTrades(BondingCurve curve) internal view returns (bool) {
        return curve.state() != IBondingCurve.State.Graduated;
    }

    /// @notice Reports how much of the run was real work, so a green invariant run cannot
    /// be a run in which nothing happened.
    function logHandlerActivity() internal view {
        console2.log("buys", handler.buys());
        console2.log("sells", handler.sells());
        console2.log("sells in a terminal state", handler.postTerminalSells());
        console2.log("donations", handler.donations());
        console2.log("graduations", handler.graduations());
        console2.log("stalls", handler.stalls());
        console2.log("expiries", handler.expiries());
        console2.log("claims", handler.claims());
        console2.log("new launches", handler.newLaunches());
        console2.log("time jumps", handler.timeJumps());
    }
}
