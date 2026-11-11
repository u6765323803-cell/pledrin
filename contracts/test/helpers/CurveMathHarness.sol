// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {CurveMath} from "src/libraries/CurveMath.sol";
import {TickAlign} from "src/libraries/TickAlign.sol";

/// @notice External surface over the two internal libraries, so a revert inside one of
/// them can be asserted with `vm.expectRevert`.
/// @dev Test-only. `vm.expectRevert` needs a call boundary, and an internal library
/// function is inlined into its caller, so a revert in `CurveMath` would abort the test
/// itself rather than be caught. Every function here forwards verbatim and adds nothing.
contract CurveMathHarness {
    function buyQuote(
        uint256 virtualEth,
        uint256 virtualTokens,
        uint256 remaining,
        uint256 feeBps,
        uint256 value
    ) external pure returns (uint256 tokensOut, uint256 ethToCurve, uint256 fee, uint256 refund) {
        return CurveMath.buyQuote(virtualEth, virtualTokens, remaining, feeBps, value);
    }

    function sellQuote(uint256 virtualEth, uint256 virtualTokens, uint256 feeBps, uint256 tokensIn)
        external
        pure
        returns (uint256 ethGross, uint256 fee, uint256 ethOut)
    {
        return CurveMath.sellQuote(virtualEth, virtualTokens, feeBps, tokensIn);
    }

    function splitFee(uint256 fee, uint256 creatorShareBps, uint256 protocolShareBps)
        external
        pure
        returns (uint256 creatorCut, uint256 protocolCut, uint256 protectionCut)
    {
        return CurveMath.splitFee(fee, creatorShareBps, protocolShareBps);
    }

    function alignDown(int24 tick, int24 spacing) external pure returns (int24) {
        return TickAlign.down(tick, spacing);
    }

    function alignUp(int24 tick, int24 spacing) external pure returns (int24) {
        return TickAlign.up(tick, spacing);
    }
}
