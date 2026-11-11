// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

/// @title The callers `GraduationHelper` pays out to
/// @notice `GraduationHelper._forward` sends everything it holds to `msg.sender` and then
/// asserts it holds nothing, so what the caller does when the ETH arrives decides which
/// of the helper's closing branches runs. This contract is every such caller, selected by
/// a mode, because the four behaviours differ only inside `receive()`.
/// @dev Test-only. A caller that refuses the refund, pushes value back or re-enters can
/// only fail its own call — that is the claim these modes exist to check, and the helper's
/// own documentation of `_forward` states it.
contract HelperCaller {
    /// @notice What this caller does when the helper pays it.
    enum OnRefund {
        /// @dev Take the money, as an ordinary caller does.
        Accept,
        /// @dev Revert, which turns the refund into `EthTransferFailed`.
        Refuse,
        /// @dev Send a wei straight back into the helper, which is the only way the closing
        /// `BalanceNotZero` assertion can fire on the ETH side.
        PushBack,
        /// @dev Call `graduateVia` again from inside the refund, while the helper is still
        /// holding its guard.
        Reenter
    }

    GraduationHelper public immutable helper;

    OnRefund public onRefund;
    /// @notice How many times this caller's `receive` has run.
    uint256 public refunds;
    /// @notice Set when a `Reenter` refund hook got a successful call, which it must not.
    bool public reentrySucceeded;
    /// @notice The refusal the reentrant call gave.
    bytes public reentryError;

    /// @dev The arguments a `Reenter` refund replays.
    IBondingCurve private _curve;
    GraduationHelper.Candidate[] private _candidates;

    error RefundRefused();

    constructor(GraduationHelper helper_) {
        helper = helper_;
    }

    receive() external payable {
        refunds++;
        if (onRefund == OnRefund.Refuse) revert RefundRefused();
        if (onRefund == OnRefund.PushBack) {
            (bool ok,) = address(helper).call{value: 1}("");
            require(ok, "HelperCaller: the helper refused a wei");
        } else if (onRefund == OnRefund.Reenter) {
            (bool ok, bytes memory ret) = address(helper)
                .call(
                    abi.encodeCall(
                        GraduationHelper.graduateVia, (_curve, _candidatesInMemory(), uint256(0))
                    )
                );
            reentrySucceeded = ok;
            reentryError = ret;
        }
    }

    function setOnRefund(OnRefund mode) external {
        onRefund = mode;
    }

    function setReentry(IBondingCurve curve, GraduationHelper.Candidate[] memory candidates)
        external
    {
        _curve = curve;
        delete _candidates;
        for (uint256 i = 0; i < candidates.length; i++) {
            _candidates.push(candidates[i]);
        }
    }

    function approveHelper(IERC20 token, uint256 amount) external {
        // The approval is to the helper and to nothing else, which is what bounds what a
        // hostile `curve` can reach: `maxTokensIn`, pulled once, by this one spender.
        // forge-lint: disable-next-line(unused-return)
        token.approve(address(helper), amount);
    }

    /// @notice One ordinary call, with the index it returned.
    function graduateVia(
        IBondingCurve curve,
        GraduationHelper.Candidate[] memory candidates,
        uint256 maxTokensIn,
        uint256 value
    ) external returns (uint256) {
        return helper.graduateVia{value: value}(curve, candidates, maxTokensIn);
    }

    /// @notice One call whose failure is returned rather than propagated.
    function tryGraduateVia(
        IBondingCurve curve,
        GraduationHelper.Candidate[] memory candidates,
        uint256 maxTokensIn,
        uint256 value
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = address(helper).call{value: value}(
            abi.encodeCall(GraduationHelper.graduateVia, (curve, candidates, maxTokensIn))
        );
    }

    /// @notice One call given exactly `gasStipend` gas, so a test can under-fund a walk.
    /// @dev The point of measuring this from a contract rather than with a cheatcode: the
    /// 1/64 rule applies to this call frame, so the helper really is left with a 63/64
    /// share and its own self-calls really do run out where they would on chain.
    function graduateViaWithGas(
        IBondingCurve curve,
        GraduationHelper.Candidate[] memory candidates,
        uint256 maxTokensIn,
        uint256 value,
        uint256 gasStipend
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = address(helper).call{value: value, gas: gasStipend}(
            abi.encodeCall(GraduationHelper.graduateVia, (curve, candidates, maxTokensIn))
        );
    }

    function _candidatesInMemory() private view returns (GraduationHelper.Candidate[] memory out) {
        out = new GraduationHelper.Candidate[](_candidates.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = _candidates[i];
        }
    }
}
