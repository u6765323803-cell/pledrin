// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {PledrinConstants} from "./PledrinConstants.sol";

/// @title Constant-product curve arithmetic over virtual reserves
/// @notice The closed-form buy and sell quotes of `docs/SPEC.md` sections 5.4 and 5.5.
/// @dev Both directions are pure functions of the reserves passed in. The caller is
/// responsible for reading those reserves from storage rather than from balances, which
/// is what keeps Invariant 10 true. Every rounding direction here is chosen to make
/// `(vE0 + ethReserve) * (vT0 - tokensSold)` non-decreasing, which is Invariant 1 and
/// from which full solvency against any sell follows (section 5.6).
///
/// Every product here runs through `FullMath`, the same 512-bit implementation Uniswap
/// v4's own position maths uses, so the graduation path and the curve path share one
/// audited copy of it and no quote can overflow for any input, including inputs no
/// quantity of real ETH could reach.
library CurveMath {
    /// @notice The clipped final buy needs more ETH than the buyer sent.
    /// @param available The value the buyer sent.
    /// @param required The ETH the clipped buy costs, fee included.
    error InsufficientValue(uint256 available, uint256 required);

    /// @notice Quotes a buy, clipping it to the remaining curve supply.
    /// @param virtualEth Live virtual ETH reserve, `vE0 + ethReserve`.
    /// @param virtualTokens Live virtual token reserve, `vT0 - tokensSold`.
    /// @param remaining Tokens still sellable on the curve, `CURVE_SUPPLY - tokensSold`.
    /// @param feeBps The launch's total fee in basis points.
    /// @param value The ETH the buyer sent.
    /// @return tokensOut Base units the buyer receives.
    /// @return ethToCurve Wei added to `ethReserve`.
    /// @return fee Wei split between the three fee buckets.
    /// @return refund Wei returned to the buyer, non-zero only on the clipped final buy.
    function buyQuote(
        uint256 virtualEth,
        uint256 virtualTokens,
        uint256 remaining,
        uint256 feeBps,
        uint256 value
    ) internal pure returns (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) {
        uint256 feeMax = FullMath.mulDivRoundingUp(value, feeBps, PledrinConstants.BPS_DENOMINATOR);
        uint256 netMax = value - feeMax;
        tokensOut = FullMath.mulDiv(virtualTokens, netMax, virtualEth + netMax);

        if (tokensOut <= remaining) return (tokensOut, netMax, feeMax, 0);

        // The final buy. The buyer pays for the tokens they actually receive, and the fee
        // is recomputed on that ETH so the refunded portion is never charged a fee.
        tokensOut = remaining;
        ethToCurve = FullMath.mulDivRoundingUp(virtualEth, tokensOut, virtualTokens - tokensOut);
        fee = FullMath.mulDivRoundingUp(
            ethToCurve, feeBps, PledrinConstants.BPS_DENOMINATOR - feeBps
        );

        uint256 required = ethToCurve + fee;
        if (required > value) revert InsufficientValue(value, required);
        refund = value - required;
    }

    /// @notice Quotes a sell.
    /// @param virtualEth Live virtual ETH reserve, `vE0 + ethReserve`.
    /// @param virtualTokens Live virtual token reserve, `vT0 - tokensSold`.
    /// @param feeBps The launch's total fee in basis points.
    /// @param tokensIn Base units the seller returns to the curve.
    /// @return ethGross Wei removed from `ethReserve`.
    /// @return fee Wei split between the three fee buckets.
    /// @return ethOut Wei paid to the seller.
    function sellQuote(uint256 virtualEth, uint256 virtualTokens, uint256 feeBps, uint256 tokensIn)
        internal
        pure
        returns (uint256 ethGross, uint256 fee, uint256 ethOut)
    {
        ethGross = FullMath.mulDiv(virtualEth, tokensIn, virtualTokens + tokensIn);
        fee = FullMath.mulDivRoundingUp(ethGross, feeBps, PledrinConstants.BPS_DENOMINATOR);
        ethOut = ethGross - fee;
    }

    /// @notice Splits a fee three ways with the remainder going to holder protection.
    /// @dev The third share is the residual and never a product, so the three parts sum
    /// to `fee` for every possible value. This is Invariants 14 and 17.
    /// @param fee The fee in wei.
    /// @param creatorShareBps The creator's share of the fee.
    /// @param protocolShareBps The protocol's share of the fee.
    /// @return creatorCut Wei accrued to the creator bucket.
    /// @return protocolCut Wei accrued to the protocol bucket.
    /// @return protectionCut Wei accrued to the holder-protection bucket.
    function splitFee(uint256 fee, uint256 creatorShareBps, uint256 protocolShareBps)
        internal
        pure
        returns (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut)
    {
        creatorCut = FullMath.mulDiv(fee, creatorShareBps, PledrinConstants.BPS_DENOMINATOR);
        protocolCut = FullMath.mulDiv(fee, protocolShareBps, PledrinConstants.BPS_DENOMINATOR);
        protectionCut = fee - creatorCut - protocolCut;
    }
}
