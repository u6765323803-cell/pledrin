// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {GraduationHelper} from "src/GraduationHelper.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

/// @title The adversary `GraduationHelper` is built to survive
/// @notice A caller who names a `curve` names the contract that will be asked for the
/// PoolManager, and therefore names the contract that calls `unlockCallback` and chooses
/// its payload. These three contracts are that adversary, written to break the helper
/// rather than to confirm it: a curve that answers with a PoolManager of the attacker's
/// choosing, a PoolManager that forges callback payloads and re-enters from inside every
/// hook it is given control in, and a token that records every pull so a test can prove
/// which allowance was used.
/// @dev Test-only, and **not** a model of Uniswap v4 — `MockPoolManager` is that. This one
/// is deliberately unfaithful: it keeps no delta ledger, it lies about prices, it answers
/// `swap` with whatever delta the attack calls for, and it does all of that on purpose.
/// The property under test is that none of it reaches further than the ETH and the tokens
/// the helper's own caller brought to the call.

/// @notice An ERC-20 that records every pull and can be made to misbehave per destination.
/// @dev `transferFrom` accounting is the point: the security claim is that `graduateVia`
/// pulls `maxTokensIn` once and holds no allowance afterwards, which is a statement about
/// how many times this function is called and with what arguments.
contract RecordingToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Every `transferFrom` this token has seen, in order.
    struct Pull {
        address caller;
        address from;
        address to;
        uint256 amount;
    }

    Pull[] private _pulls;

    /// @notice `transfer` to this address returns false instead of moving anything.
    address public failTransferTo;
    /// @notice `transfer` to this address returns **true** and moves nothing, which is the
    /// one way `GraduationHelper._forward`'s closing assertion can fire on the token side.
    address public lieTransferTo;
    /// @notice `transferFrom` returns false instead of moving anything.
    bool public failTransferFrom;

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setFailTransferTo(address to) external {
        failTransferTo = to;
    }

    function setLieTransferTo(address to) external {
        lieTransferTo = to;
    }

    function setFailTransferFrom(bool value) external {
        failTransferFrom = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == failTransferTo) return false;
        if (to == lieTransferTo) return true;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _pulls.push(Pull({caller: msg.sender, from: from, to: to, amount: amount}));
        if (failTransferFrom) return false;

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    /// @notice How many `transferFrom` calls this token has seen in total.
    function pullCount() external view returns (uint256) {
        return _pulls.length;
    }

    /// @notice One recorded pull.
    function pullAt(uint256 index) external view returns (Pull memory) {
        return _pulls[index];
    }

    /// @notice Everything `spender` has ever pulled out of `from` through this token.
    function pulledBy(address spender, address from) external view returns (uint256 total) {
        for (uint256 i = 0; i < _pulls.length; i++) {
            if (_pulls[i].caller == spender && _pulls[i].from == from) total += _pulls[i].amount;
        }
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice A PoolManager written to rob the contract that unlocks it.
/// @dev Every attack is a named member of `Attack` and is documented where it is executed.
/// Three of them use the fact that the helper's `_unlockManager` flag is still set while a
/// settlement is in flight: this contract gets control inside `settle`, `take` and `sync`,
/// and from there it can call anything on the helper that the flag admits.
contract HostilePoolManager {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice What this PoolManager does when the helper swaps against it.
    enum Attack {
        /// @dev A healthy free restore: both deltas zero, price moved to the limit.
        None,
        /// @dev Demand one wei more ETH than the helper is holding.
        OverspendEth,
        /// @dev Demand one base unit more of the launch token than the helper is holding.
        OverspendTokens,
        /// @dev Demand exactly every wei and every base unit the helper is holding, which
        /// is the largest demand the helper's own budget checks will pay.
        DrainEverything,
        /// @dev Drain, and then re-enter `unlockCallback` from inside the settlement to
        /// drain again, as deep as `nestLimit` allows.
        NestedCallbacks,
        /// @dev Call `graduateVia` from inside the settlement.
        ReenterGraduateVia,
        /// @dev Call `attemptCandidate` from inside the settlement.
        CallAttemptCandidate,
        /// @dev Report a credit and pay it out of this contract's own balance.
        CreditTheHelper,
        /// @dev Settle nothing and leave the price where it was.
        NoRestore
    }

    GraduationHelper public helper;
    IERC20 public launchToken;
    Attack public attack;

    /// @dev What `extsload` answers for every pool id. A hostile PoolManager has no pools.
    uint160 public price;
    /// @dev When true, `swap` moves `price` to the limit it was given.
    bool public restoreOnSwap = true;

    /// @notice When set, `unlock` hands the callback this payload instead of the one its
    /// caller gave it. The whole point of the forged-payload class of attack: the helper
    /// is told to settle a key it never built.
    bytes private _forgedPayload;
    bool public forgePayload;

    /// @notice The payload the nested callbacks use, which is a forgery by construction.
    bytes private _nestedPayload;
    uint8 public nestLimit;
    uint8 public nestDepth;

    /// @notice Arguments for the two reentrant calls, so a test can aim them.
    IBondingCurve public reentryCurve;
    GraduationHelper.Candidate[] private _reentryCandidates;

    uint256 public unlockCalls;
    uint256 public swapCalls;
    uint256 public settleCalls;
    uint256 public takeCalls;
    uint256 public syncCalls;
    uint256 public callbackReturns;
    /// @notice ETH this contract has been paid through `settle`.
    uint256 public ethSettled;
    /// @notice Launch tokens this contract has been paid, measured across each `settle`.
    uint256 public tokensSettled;

    /// @notice Every reentrant call this contract attempted, and how each ended.
    struct Reentry {
        string what;
        bool succeeded;
        bytes returnData;
    }

    Reentry[] private _reentries;

    bool public unlocked;

    error HostileSwapRefused();

    receive() external payable {}

    function setHelper(GraduationHelper helper_) external {
        helper = helper_;
    }

    function setLaunchToken(IERC20 token) external {
        launchToken = token;
    }

    function setAttack(Attack attack_) external {
        attack = attack_;
    }

    function setPrice(uint160 price_) external {
        price = price_;
    }

    function setRestoreOnSwap(bool value) external {
        restoreOnSwap = value;
    }

    function setForgedPayload(PoolKey memory key, bool zeroForOne, uint160 limit) external {
        _forgedPayload = abi.encode(key, zeroForOne, limit);
        forgePayload = true;
    }

    function setNesting(PoolKey memory key, bool zeroForOne, uint160 limit, uint8 limitDepth)
        external
    {
        _nestedPayload = abi.encode(key, zeroForOne, limit);
        nestLimit = limitDepth;
    }

    function setReentryTarget(IBondingCurve curve, GraduationHelper.Candidate[] memory candidates)
        external
    {
        reentryCurve = curve;
        delete _reentryCandidates;
        for (uint256 i = 0; i < candidates.length; i++) {
            _reentryCandidates.push(candidates[i]);
        }
    }

    // -----------------------------------------------------------------
    // The PoolManager surface the helper uses
    // -----------------------------------------------------------------

    /// @notice Answers every slot with this contract's one price, so the helper's two
    /// `getSlot0` reads are whatever the attack wants them to be.
    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(price));
    }

    /// @notice Hands control to the caller's callback, with a payload of this contract's
    /// choosing when `forgePayload` is set.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlockCalls++;
        unlocked = true;
        nestDepth = 0;
        bytes memory payload = data;
        if (forgePayload) payload = _forgedPayload;
        result = IUnlockCallback(msg.sender).unlockCallback(payload);
        callbackReturns++;
        unlocked = false;
    }

    /// @notice Reports whatever delta the current attack calls for.
    function swap(PoolKey memory, SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        swapCalls++;
        if (restoreOnSwap && attack != Attack.NoRestore) price = params.sqrtPriceLimitX96;

        uint256 ethHeld = address(helper).balance;
        uint256 tokensHeld =
            address(launchToken) == address(0) ? 0 : launchToken.balanceOf(address(helper));

        if (attack == Attack.OverspendEth) {
            return toBalanceDelta(-(ethHeld + 1).toInt128(), 0);
        }
        if (attack == Attack.OverspendTokens) {
            return toBalanceDelta(0, -(tokensHeld + 1).toInt128());
        }
        if (attack == Attack.DrainEverything || attack == Attack.NestedCallbacks) {
            return toBalanceDelta(-ethHeld.toInt128(), -tokensHeld.toInt128());
        }
        if (attack == Attack.ReenterGraduateVia || attack == Attack.CallAttemptCandidate) {
            // One wei of debt, so that the helper enters a settlement and hands this
            // contract control at a moment when its unlock flag is set.
            return toBalanceDelta(-1, 0);
        }
        if (attack == Attack.CreditTheHelper) {
            return toBalanceDelta(1, 0);
        }
        return toBalanceDelta(0, 0);
    }

    /// @notice Takes the ETH or tokens the helper owes, and attacks from inside the call.
    function settle() external payable returns (uint256) {
        settleCalls++;
        ethSettled += msg.value;
        if (address(launchToken) != address(0)) {
            tokensSettled = launchToken.balanceOf(address(this));
        }
        _attackFromInsideTheLock();
        return msg.value;
    }

    /// @notice Pays a credit out of this contract's own balance, as the real one does.
    function take(Currency currency, address to, uint256 amount) external {
        takeCalls++;
        currency.transfer(to, amount);
    }

    function sync(Currency) external {
        syncCalls++;
    }

    // -----------------------------------------------------------------
    // What a test reads back
    // -----------------------------------------------------------------

    function reentryCount() external view returns (uint256) {
        return _reentries.length;
    }

    function reentryAt(uint256 index) external view returns (Reentry memory) {
        return _reentries[index];
    }

    /// @notice Calls the helper's callback with no unlock in progress at all, which is the
    /// `NotUnlocking` case from the one address that is otherwise allowed to call it.
    function forgeCallbackOutsideUnlock(PoolKey memory key, bool zeroForOne, uint160 limit)
        external
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = address(helper)
            .call(
                abi.encodeCall(
                    GraduationHelper.unlockCallback, (abi.encode(key, zeroForOne, limit))
                )
            );
    }

    /// @dev The three attacks that need control while the helper's unlock flag is set.
    /// Each is attempted and recorded rather than asserted here, so the test can read the
    /// exact refusal the helper gave.
    function _attackFromInsideTheLock() private {
        if (attack == Attack.NestedCallbacks) {
            if (nestDepth >= nestLimit) return;
            nestDepth++;
            // The helper's flag is still set, so this is admitted. Every nested callback
            // swaps again and the swap above demands the whole remaining balance, so this
            // is the deepest drain the design permits.
            (bool ok, bytes memory ret) = address(helper)
                .call(abi.encodeCall(GraduationHelper.unlockCallback, (_nestedPayload)));
            _reentries.push(
                Reentry({what: "nested unlockCallback", succeeded: ok, returnData: ret})
            );
        } else if (attack == Attack.ReenterGraduateVia) {
            (bool ok, bytes memory ret) = address(helper)
                .call(
                    abi.encodeCall(
                        GraduationHelper.graduateVia,
                        (reentryCurve, _candidatesInMemory(), uint256(0))
                    )
                );
            _reentries.push(Reentry({what: "graduateVia", succeeded: ok, returnData: ret}));
        } else if (attack == Attack.CallAttemptCandidate) {
            GraduationHelper.Candidate memory candidate = _reentryCandidates.length == 0
                ? GraduationHelper.Candidate({fee: 10_000, tickSpacing: 200})
                : _reentryCandidates[0];
            (bool ok, bytes memory ret) = address(helper)
                .call(
                    abi.encodeCall(
                        GraduationHelper.attemptCandidate,
                        (reentryCurve, launchToken, IPoolManager(address(this)), price, candidate)
                    )
                );
            _reentries.push(Reentry({what: "attemptCandidate", succeeded: ok, returnData: ret}));
        }
    }

    /// @dev `abi.encodeCall` needs the array in memory, and the script holds it in storage.
    function _candidatesInMemory() private view returns (GraduationHelper.Candidate[] memory out) {
        out = new GraduationHelper.Candidate[](_reentryCandidates.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = _reentryCandidates[i];
        }
    }
}

/// @notice A curve that is not a curve: it answers the three getters the helper reads and
/// does whatever the attacker wants when asked to graduate or to pay a bounty.
/// @dev This is the contract the whole security argument of section 8.6 turns on. The
/// helper reads its PoolManager off this address, so this address chooses who calls
/// `unlockCallback`; it reads `token()` off it, so this address chooses which ERC-20 the
/// helper pulls; and it is called at the end of a successful attempt, so it gets control
/// once more after the lock has been released.
contract HostileCurve {
    /// @notice What `graduate` and `graduateAlt` do when the helper calls them.
    enum OnGraduate {
        /// @dev Return quietly, as a graduation that worked would.
        Succeed,
        /// @dev Refuse, so the candidate fails and the walk goes on.
        Refuse,
        /// @dev Call the helper's `unlockCallback` from outside any unlock.
        ForgeCallback,
        /// @dev Call `graduateVia` again, from inside the guard it is already holding.
        ReenterGraduateVia,
        /// @dev Push a wei into the helper, so a test can see what a mid-call arrival does.
        PushEth
    }

    /// @notice What `claimBounty` does.
    enum OnClaim {
        /// @dev Credit nothing and say so, which is what a real curve cannot do.
        ReturnZero,
        /// @dev Refuse, as `BondingCurve.claimBounty` does on an empty credit.
        Refuse,
        /// @dev Pay `bountyWei` out of this contract's balance.
        PayReal,
        /// @dev Claim to have paid a fortune and pay nothing.
        LieAboutTheAmount,
        /// @dev Call `graduateVia` again from inside the claim.
        ReenterGraduateVia
    }

    IERC20 public token;
    IPoolManager public poolManager;
    uint160 public sqrtPriceTerminal;

    GraduationHelper public helper;
    OnGraduate public onGraduate;
    OnClaim public onClaim;
    uint256 public bountyWei;

    uint256 public graduateCalls;
    uint256 public graduateAltCalls;
    uint256 public claimCalls;
    uint24 public lastFee;
    uint24 public lastTickSpacing;
    address public lastEarner;

    /// @notice Every call this curve made back into the helper, and how it ended.
    struct Callback {
        string what;
        bool succeeded;
        bytes returnData;
    }

    Callback[] private _callbacks;

    /// @dev The key `ForgeCallback` names. Set by the test.
    bytes private _forgedPayload;
    /// @dev The candidate list `ReenterGraduateVia` uses.
    GraduationHelper.Candidate[] private _reentryCandidates;

    error CurveRefuses();
    error NothingToClaim();

    receive() external payable {}

    constructor(IERC20 token_, IPoolManager poolManager_, uint160 terminal) {
        token = token_;
        poolManager = poolManager_;
        sqrtPriceTerminal = terminal;
    }

    function setHelper(GraduationHelper helper_) external {
        helper = helper_;
    }

    function setToken(IERC20 token_) external {
        token = token_;
    }

    function setPoolManager(IPoolManager manager) external {
        poolManager = manager;
    }

    function setTerminal(uint160 terminal) external {
        sqrtPriceTerminal = terminal;
    }

    function setOnGraduate(OnGraduate value) external {
        onGraduate = value;
    }

    function setOnClaim(OnClaim value, uint256 amount) external {
        onClaim = value;
        bountyWei = amount;
    }

    function setForgedPayload(PoolKey memory key, bool zeroForOne, uint160 limit) external {
        _forgedPayload = abi.encode(key, zeroForOne, limit);
    }

    function setReentryCandidates(GraduationHelper.Candidate[] memory candidates) external {
        delete _reentryCandidates;
        for (uint256 i = 0; i < candidates.length; i++) {
            _reentryCandidates.push(candidates[i]);
        }
    }

    function graduate() external {
        graduateCalls++;
        lastFee = 10_000;
        lastTickSpacing = 200;
        _act();
    }

    function graduateAlt(uint24 fee, uint24 tickSpacing) external {
        graduateAltCalls++;
        lastFee = fee;
        lastTickSpacing = tickSpacing;
        _act();
    }

    function claimBounty(address earner) external returns (uint256) {
        claimCalls++;
        lastEarner = earner;

        if (onClaim == OnClaim.Refuse) revert NothingToClaim();
        if (onClaim == OnClaim.LieAboutTheAmount) return type(uint256).max;
        if (onClaim == OnClaim.PayReal) {
            (bool ok,) = earner.call{value: bountyWei}("");
            require(ok, "HostileCurve: bounty payment refused");
            return bountyWei;
        }
        if (onClaim == OnClaim.ReenterGraduateVia) {
            (bool ok, bytes memory ret) = address(helper)
                .call(
                    abi.encodeCall(
                        GraduationHelper.graduateVia,
                        (IBondingCurve(address(this)), _candidatesInMemory(), uint256(0))
                    )
                );
            _callbacks.push(
                Callback({what: "graduateVia from claimBounty", succeeded: ok, returnData: ret})
            );
            return 0;
        }
        return 0;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 index) external view returns (Callback memory) {
        return _callbacks[index];
    }

    function _act() private {
        if (onGraduate == OnGraduate.Refuse) revert CurveRefuses();
        if (onGraduate == OnGraduate.ForgeCallback) {
            // The helper's unlock has returned by the time a curve is called, so this is
            // the `NotUnlocking` case reached from inside a live `graduateVia`.
            (bool ok, bytes memory ret) = address(helper)
                .call(abi.encodeCall(GraduationHelper.unlockCallback, (_forgedPayload)));
            _callbacks.push(
                Callback({what: "unlockCallback after unlock", succeeded: ok, returnData: ret})
            );
        } else if (onGraduate == OnGraduate.ReenterGraduateVia) {
            (bool ok, bytes memory ret) = address(helper)
                .call(
                    abi.encodeCall(
                        GraduationHelper.graduateVia,
                        (IBondingCurve(address(this)), _candidatesInMemory(), uint256(0))
                    )
                );
            _callbacks.push(
                Callback({what: "graduateVia from graduate", succeeded: ok, returnData: ret})
            );
        } else if (onGraduate == OnGraduate.PushEth) {
            (bool ok,) = address(helper).call{value: 1}("");
            require(ok, "HostileCurve: helper refused a wei");
        }
    }

    /// @dev `abi.encodeCall` needs the array in memory, and the script holds it in storage.
    function _candidatesInMemory() private view returns (GraduationHelper.Candidate[] memory out) {
        out = new GraduationHelper.Candidate[](_reentryCandidates.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = _reentryCandidates[i];
        }
    }
}
