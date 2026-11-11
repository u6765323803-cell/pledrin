// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PledrinConstants} from "./libraries/PledrinConstants.sol";

/// @title Pledrin launch token
/// @notice The fixed-supply ERC-20 of one Pledrin launch, as specified in
/// `docs/SPEC.md` section 3.
/// @dev Deliberately featureless. There is no mint, burn, owner, pause, blacklist,
/// transfer hook, transfer fee, rebase or upgrade path, and the constructor is the only
/// code that ever moves supply other than ERC-20 `transfer` and `transferFrom`. That is
/// what the protocol buys by charging every fee in ETH: nothing needs to observe or
/// intercept a transfer, so the token is never a reentrancy entry point.
contract PledrinToken is ERC20 {
    /// @notice Deploys the token and mints the entire supply to its bonding curve.
    /// @dev Called from `BondingCurve`'s constructor, so `curve` is the curve being
    /// deployed and the whole supply starts there.
    /// @param name_ The token name, immutable afterwards.
    /// @param symbol_ The token symbol, immutable afterwards.
    /// @param curve The launch's bonding curve, which receives `TOTAL_SUPPLY`.
    constructor(string memory name_, string memory symbol_, address curve) ERC20(name_, symbol_) {
        _mint(curve, PledrinConstants.TOTAL_SUPPLY);
    }
}
