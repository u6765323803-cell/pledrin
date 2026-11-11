// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondingCurve} from "src/BondingCurve.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {PledrinConstants} from "src/libraries/PledrinConstants.sol";

import {PledrinTestBase} from "../base/PledrinTestBase.sol";
import {ReentrantSeller, RevertingReceiver} from "../mocks/Actors.sol";

/// @title `BondingCurve.sell`
/// @notice Covers `docs/SPEC.md` section 5.5 and Invariants 1, 2, 4, 5, 7, 8, 11, 19, 31,
/// 33 and 55.
/// @dev Two properties here are easy to get wrong in a test. The first: `sell` is strict
/// checks-effects-interactions — the reserve, the sold counter and the fee buckets are
/// written *before* `token.transferFrom`, so nothing here asserts that the seller's tokens
/// are pulled first; section 5.5's step order was corrected to match the code. The second:
/// `sell` stays open in `Expired` and `Stalled` and decrements `tokensSold` there, which
/// Invariant 31 now states is mandatory rather than incidental, because the sell price
/// reads `vT = vT0 - tokensSold` and holding the counter fixed while the reserve fell
/// would break Invariants 1 and 2.
///
/// Where a test sells in `Expired` or `Stalled` it asserts the reserve, the counter and
/// the solvency product only. It deliberately asserts nothing about where the fee of such
/// a sell lands, because two of the three shares currently accrue to buckets with no
/// payout path in those states and that is being changed.
contract BondingCurveSellTest is PledrinTestBase {
    /// @notice Section 5.5's steps 1 to 11 on an ordinary sell.
    function test_sellMovesTheReserveTheSoldCounterAndPaysTheSeller() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        uint256 reserveBefore = curve.ethReserve();
        (uint256 quotedGross, uint256 quotedFee, uint256 quotedOut) = curve.quoteSell(bought / 2);
        uint256 balanceBefore = TRADER.balance;

        uint256 out = sell(curve, TRADER, bought / 2);

        assertEq(out, quotedOut, "the quote is what the trade does");
        assertEq(curve.ethReserve(), reserveBefore - quotedGross, "Invariant 4: gross leaves");
        assertEq(curve.tokensSold(), bought - bought / 2, "tokensSold");
        assertEq(TRADER.balance - balanceBefore, quotedOut, "the seller was paid");
        assertEq(token.balanceOf(TRADER), bought - bought / 2, "the tokens went back");
        assertEq(
            token.balanceOf(address(curve)),
            PledrinConstants.TOTAL_SUPPLY - curve.tokensSold(),
            "Invariant 5"
        );
        assertEq(quotedOut + quotedFee, quotedGross, "gross splits into out and fee");
    }

    /// @notice The `Sold` event carries the numbers an indexer needs.
    function test_sellEmitsSold() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);
        (uint256 gross, uint256 fee, uint256 out) = curve.quoteSell(bought);

        vm.prank(TRADER);
        token.approve(address(curve), bought);

        vm.expectEmit(true, true, false, true, address(curve));
        emit IBondingCurve.Sold(
            address(curve), TRADER, bought, gross, out, fee, 0, curve.ethReserve() - gross
        );
        vm.prank(TRADER);
        curve.sell(bought, 0, vm.getBlockTimestamp());
    }

    /// @notice Invariant 11: a sell that would pay less than the caller asked for reverts.
    function test_sellRevertsBelowMinEthOut() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);
        (,, uint256 out) = curve.quoteSell(bought);

        vm.prank(TRADER);
        token.approve(address(curve), bought);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.SlippageExceeded.selector, out, out + 1)
        );
        curve.sell(bought, out + 1, vm.getBlockTimestamp());

        vm.prank(TRADER);
        assertEq(
            curve.sell(bought, out, vm.getBlockTimestamp()), out, "exactly the quote is accepted"
        );
    }

    /// @notice A sell larger than everything the curve has ever sold is rejected, which is
    /// what keeps `tokensSold` from underflowing. One base unit over is enough.
    function test_sellRevertsAboveTokensSold() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        vm.prank(OTHER);
        curve.buy{value: 1 ether}(0, vm.getBlockTimestamp());
        uint256 sold = curve.tokensSold();

        vm.prank(TRADER);
        token.approve(address(curve), type(uint256).max);
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.SellExceedsSupplySold.selector);
        curve.sell(sold + 1, 0, vm.getBlockTimestamp());

        // Exactly `tokensSold` is accepted, which is the "one seller sells everything ever
        // sold" case Invariant 2 names. The seller only holds part of it, so the pull is
        // what fails, not the quote.
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, TRADER, bought, sold
            )
        );
        curve.sell(sold, 0, vm.getBlockTimestamp());
    }

    /// @notice Section 5.5: there is no minimum sell beyond `out >= 1`. A holder with a
    /// dust balance can always exit, which a minimum size would prevent.
    function test_aDustHolderCanAlwaysExit() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, 1 ether);

        // A dust balance, far below anything a minimum sell size would let out.
        uint256 amount = 1e10;
        (,, uint256 out) = curve.quoteSell(amount);
        assertGt(out, 0, "the dust is worth something");

        vm.prank(TRADER);
        token.transfer(OTHER, amount);
        uint256 balanceBefore = OTHER.balance;
        assertEq(sell(curve, OTHER, amount), out, "the dust holder exited");
        assertEq(OTHER.balance - balanceBefore, out, "and was paid");
    }

    /// @notice A sell that would pay nothing is rejected rather than taking the tokens for
    /// free. One base unit at the opening price is worth less than a wei.
    function test_sellRevertsWhenTheQuoteRoundsToNothing() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        buy(curve, TRADER, PledrinConstants.MIN_BUY_WEI);

        (uint256 gross,, uint256 out) = curve.quoteSell(1);
        assertEq(gross, 0, "one base unit is worth no wei here");
        assertEq(out, 0, "so the seller would be paid nothing");

        vm.prank(TRADER);
        token.approve(address(curve), 1);
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.ZeroAmount.selector);
        curve.sell(1, 0, vm.getBlockTimestamp());
    }

    /// @notice A fee that takes the whole gross is rejected by the same check: `out` must
    /// be at least one wei.
    function test_sellRevertsWhenTheFeeTakesTheWholeGross() public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = PledrinConstants.MAX_VIRTUAL_ETH_RESERVE;
        (BondingCurve curve, IERC20 token) = createLaunch(params);
        buy(curve, TRADER, 100 ether);

        // An amount whose gross is exactly one wei: the 1% fee rounds up to that wei and
        // leaves the seller nothing.
        uint256 amount = _amountWithGrossOfOneWei(curve);
        (uint256 gross, uint256 fee, uint256 out) = curve.quoteSell(amount);
        assertEq(gross, 1, "gross");
        assertEq(fee, 1, "the fee rounds up to the whole wei");
        assertEq(out, 0, "nothing left for the seller");

        vm.prank(TRADER);
        token.approve(address(curve), amount);
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.ZeroAmount.selector);
        curve.sell(amount, 0, vm.getBlockTimestamp());
    }

    /// @notice A zero-size sell is rejected before anything else.
    function test_sellRevertsOnZeroTokens() public {
        (BondingCurve curve,) = createDefaultLaunch();

        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.ZeroAmount.selector);
        curve.sell(0, 0, vm.getBlockTimestamp());
    }

    /// @notice The caller's own deadline, one second past.
    function test_sellRevertsAfterTheCallersDeadline() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        vm.prank(TRADER);
        token.approve(address(curve), bought);
        vm.prank(TRADER);
        vm.expectRevert(IBondingCurve.DeadlinePassed.selector);
        curve.sell(bought, 0, vm.getBlockTimestamp() - 1);
    }

    /// @notice **Invariant 33.** `sell` succeeds in `Live`, `Expired` and `Stalled`, and
    /// reverts in `Graduating` and `Graduated`.
    function test_sellIsOpenInLiveExpiredAndStalledOnly() public {
        // Live
        (BondingCurve live,) = createDefaultLaunch();
        uint256 bought = buy(live, TRADER, 1 ether);
        assertGt(sell(live, TRADER, bought / 4), 0, "Live");

        // Graduating
        (BondingCurve graduating, IERC20 gToken) = createLaunchAtCap();
        vm.prank(TRADER);
        gToken.approve(address(graduating), type(uint256).max);
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondingCurve.WrongState.selector, IBondingCurve.State.Graduating
            )
        );
        graduating.sell(1e18, 0, vm.getBlockTimestamp());

        // Graduated
        vm.prank(GRADUATOR);
        graduating.graduate();
        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.WrongState.selector, IBondingCurve.State.Graduated)
        );
        graduating.sell(1e18, 0, vm.getBlockTimestamp());

        // Expired
        (BondingCurve expired,) = createDefaultLaunch();
        uint256 expiredBought = buy(expired, TRADER, 1 ether);
        vm.warp(expired.gradDeadline());
        expired.expire();
        assertGt(sell(expired, TRADER, expiredBought / 4), 0, "Expired");

        // Stalled
        (BondingCurve stalled,) = createLaunchAtCap();
        vm.warp(stalled.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalled.abortGraduation();
        assertGt(sell(stalled, TRADER, 1e18), 0, "Stalled");
    }

    /// @notice Sells stay open forever in `Expired`: there is no second deadline, so the
    /// exit never closes.
    function test_sellsNeverCloseAfterExpiry() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);
        vm.warp(curve.gradDeadline());
        curve.expire();

        vm.warp(vm.getBlockTimestamp() + 365 days * 10);
        assertGt(sell(curve, TRADER, bought / 2), 0, "a decade later the exit is still open");
    }

    /// @notice **The true form of Invariant 31.** `tokensSold` never increases once the
    /// state leaves `Live`, and in `Graduating` and `Graduated` it does not change at all.
    /// It decreases in `Expired` and `Stalled`, because `sell` stays open there and
    /// Invariants 1 and 2 require the counter to follow the tokens back.
    function test_tokensSoldNeverIncreasesOnceTheStateLeavesLive() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);
        vm.warp(curve.gradDeadline());
        curve.expire();

        uint256 atExpiry = curve.tokensSold();
        sell(curve, TRADER, bought / 2);
        assertLt(curve.tokensSold(), atExpiry, "a sell in Expired decrements the counter");
        assertGe(curveProduct(curve), curveK(curve), "and Invariant 1 still holds");

        // `Graduating` and `Graduated` freeze it outright.
        (BondingCurve graduating,) = createLaunchAtCap();
        uint256 atCap = graduating.tokensSold();
        vm.prank(GRADUATOR);
        graduating.graduate();
        assertEq(graduating.tokensSold(), atCap, "frozen through graduation");
    }

    /// @notice Invariant 19: the only transfer of a user's tokens the protocol makes is
    /// the one the user is selling, and it needs their allowance.
    function test_sellNeedsTheSellersAllowanceAndTakesOnlyWhatIsSold() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        vm.prank(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(curve), 0, bought
            )
        );
        curve.sell(bought, 0, vm.getBlockTimestamp());

        // An allowance for exactly the sell is spent exactly.
        vm.prank(TRADER);
        token.approve(address(curve), bought / 2);
        vm.prank(TRADER);
        curve.sell(bought / 2, 0, vm.getBlockTimestamp());
        assertEq(token.allowance(TRADER, address(curve)), 0, "the allowance was spent exactly");
        assertEq(token.balanceOf(TRADER), bought - bought / 2, "the rest stayed with the seller");
    }

    /// @notice A failed token pull reverts the whole sell, so no state survives it. This
    /// is the testable form of the checks-effects-interactions ordering: the writes happen
    /// first, and an interaction that fails undoes them.
    function test_aFailedTokenPullLeavesNoStateBehind() public {
        (BondingCurve curve,) = createDefaultLaunch();
        uint256 bought = buy(curve, TRADER, 1 ether);

        uint256 reserveBefore = curve.ethReserve();
        uint256 soldBefore = curve.tokensSold();
        uint256 protectionBefore = curve.protectionEth();

        vm.prank(TRADER);
        vm.expectRevert();
        curve.sell(bought, 0, vm.getBlockTimestamp());

        assertEq(curve.ethReserve(), reserveBefore, "ethReserve");
        assertEq(curve.tokensSold(), soldBefore, "tokensSold");
        assertEq(curve.protectionEth(), protectionBefore, "protectionEth");
    }

    /// @notice A seller whose address reverts on receiving ETH blocks only their own sell.
    function test_aSellerThatRefusesEthBlocksOnlyItself() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        RevertingReceiver seller = new RevertingReceiver();
        buy(curve, TRADER, 1 ether);

        uint256 amount = 1e24;
        vm.prank(TRADER);
        token.transfer(address(seller), amount);
        vm.prank(address(seller));
        token.approve(address(curve), amount);

        (,, uint256 out) = curve.quoteSell(amount);
        vm.prank(address(seller));
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurve.EthTransferFailed.selector, address(seller), out)
        );
        curve.sell(amount, 0, vm.getBlockTimestamp());

        // Everyone else still trades.
        assertGt(sell(curve, TRADER, 1e18), 0, "another seller is unaffected");
    }

    /// @notice Invariant 55: `sell` holds a reentrancy guard, so the proceeds callback
    /// cannot start a second sell.
    function test_sellCannotBeReenteredFromTheProceeds() public {
        (BondingCurve curve, IERC20 token) = createDefaultLaunch();
        ReentrantSeller attacker = new ReentrantSeller();
        vm.deal(address(attacker), 10 ether);
        attacker.prepare(IBondingCurve(address(curve)), token);
        attacker.buy{value: 1 ether}(1 ether);

        uint256 held = token.balanceOf(address(attacker));
        vm.expectRevert();
        attacker.sell(held / 2);

        assertEq(curve.tokensSold(), held, "no sell went through");
    }

    /// @notice **Invariant 4.** `ethReserve` falls only in `sell`, by exactly `ethGross`,
    /// and at graduation, to zero. Every other path either raises it or leaves it alone.
    function test_onlyASellOrGraduationEverReducesTheReserve() public {
        (BondingCurve curve,) = createPledgedLaunch();

        // A buy raises it.
        uint256 reserve = curve.ethReserve();
        uint256 bought = buy(curve, TRADER, 1 ether);
        assertGt(curve.ethReserve(), reserve, "buy");

        // A sell lowers it by exactly the gross.
        reserve = curve.ethReserve();
        (uint256 gross,,) = curve.quoteSell(bought / 4);
        sell(curve, TRADER, bought / 4);
        assertEq(curve.ethReserve(), reserve - gross, "sell lowers it by exactly ethGross");

        // A donation raises it.
        reserve = curve.ethReserve();
        vm.prank(OTHER);
        curve.donate{value: 1 ether}();
        assertEq(curve.ethReserve(), reserve + 1 ether, "donate");

        // Claiming the protocol bucket leaves it alone.
        reserve = curve.ethReserve();
        curve.claimProtocolFees();
        assertEq(curve.ethReserve(), reserve, "claimProtocolFees");

        // Expiry raises it, and the claims available afterwards leave it alone.
        (BondingCurve expiring,) = createPledgedLaunch();
        buy(expiring, TRADER, 1 ether);
        uint256 expiringReserve = expiring.ethReserve();
        vm.warp(expiring.gradDeadline());
        expiring.expire();
        assertGt(expiring.ethReserve(), expiringReserve, "expire");
        expiringReserve = expiring.ethReserve();
        expiring.claimProtocolFees();
        assertEq(expiring.ethReserve(), expiringReserve, "claimProtocolFees after expiry");

        // A stall raises it, and the claims it opens leave it alone.
        (BondingCurve stalling,) = createPledgedLaunch();
        buyToCap(stalling);
        uint256 stallingReserve = stalling.ethReserve();
        vm.warp(stalling.capReachedAt() + PledrinConstants.GRAD_GRACE);
        stalling.abortGraduation();
        assertGt(stalling.ethReserve(), stallingReserve, "abortGraduation");
        stallingReserve = stalling.ethReserve();
        stalling.claimCreatorFees();
        stalling.claimBond();
        assertEq(stalling.ethReserve(), stallingReserve, "the claims a stall opens");

        // Graduation takes it to zero and nothing else can.
        (BondingCurve graduating,) = createPledgedLaunch();
        buyToCap(graduating);
        assertGt(graduating.ethReserve(), 0, "there is a reserve to spend");
        vm.prank(GRADUATOR);
        graduating.graduate();
        assertEq(graduating.ethReserve(), 0, "graduate drains it");
        graduating.claimProtocolFees();
        graduating.claimCreatorFees();
        graduating.claimBond();
        graduating.claimBounty(GRADUATOR);
        assertEq(graduating.ethReserve(), 0, "and the claims leave it at zero");
    }

    /// @notice **Invariant 2 by fuzz, through the contract.** Whatever sequence of buys and
    /// sells a launch has seen, the gross for every size up to `tokensSold` is at most the
    /// reserve, so the curve can always pay.
    function testFuzz_theCurveCanAlwaysPayAnySellItAccepts(
        uint128 vE0,
        uint96 buyValue,
        uint96 sellFraction
    ) public {
        ILaunchFactory.LaunchParams memory params = defaultParams();
        params.virtualEthReserve = uint128(
            bound(
                vE0,
                PledrinConstants.MIN_VIRTUAL_ETH_RESERVE,
                PledrinConstants.MAX_VIRTUAL_ETH_RESERVE
            )
        );
        (BondingCurve curve, IERC20 token) = createLaunch(params);

        uint256 value = bound(buyValue, PledrinConstants.MIN_BUY_WEI, 2000 ether);
        vm.deal(TRADER, value);
        vm.prank(TRADER);
        uint256 bought = curve.buy{value: value}(0, vm.getBlockTimestamp());

        uint256 amount = bound(sellFraction, 1, bought);
        (uint256 gross,, uint256 out) = curve.quoteSell(amount);
        assertLe(gross, curve.ethReserve(), "Invariant 2 for the size being sold");

        (uint256 wholeGross,,) = curve.quoteSell(curve.tokensSold());
        assertLe(wholeGross, curve.ethReserve(), "Invariant 2 for everything ever sold");

        if (curve.state() != IBondingCurve.State.Live || out == 0) return;

        vm.prank(TRADER);
        token.approve(address(curve), amount);
        vm.prank(TRADER);
        uint256 paid = curve.sell(amount, 0, vm.getBlockTimestamp());

        assertEq(paid, out, "the sell paid the quote");
        assertGe(curveProduct(curve), curveK(curve), "Invariant 1 after the round trip");
        assertLe(paid, value, "Invariant 7: the round trip did not profit");
    }

    /// @dev The smallest token amount whose gross is exactly one wei at the curve's
    /// current reserves, found by inverting the sell formula rather than by searching.
    function _amountWithGrossOfOneWei(BondingCurve curve) private view returns (uint256) {
        (uint256 virtualEth, uint256 virtualTokens) = curve.liveReserves();
        // gross = floor(vE * dT / (vT + dT)) == 1 at dT = ceil(vT / (vE - 1)).
        return (virtualTokens + (virtualEth - 2)) / (virtualEth - 1);
    }
}
