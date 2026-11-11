// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IBondingCurve} from "./interfaces/IBondingCurve.sol";
import {PledrinConstants} from "./libraries/PledrinConstants.sol";

/// @title Pledrin graduation helper
/// @notice The recovery path of `docs/SPEC.md` section 8.6. It moves a griefed pool back to
/// a launch's terminal price with the caller's own ETH or launch tokens and graduates the
/// launch in the same transaction, so a graduation that the curve's own free restore cannot
/// deliver is still reachable by anybody willing to pay for it.
/// @dev Deliberately powerless. It calls only functions that any address may call, no
/// Pledrin contract names it, and deleting it, replacing it or deploying a second instance
/// changes no curve's behaviour and no invariant (Invariant 68). So it has no owner, no admin
/// function, no pause, no constructor, no storage that outlives a transaction and nothing to
/// configure: the PoolManager it swaps through is read off the curve being graduated, which
/// is also what stops a restore and the graduation that follows it from reaching two
/// different Uniswap deployments.
///
/// What a caller risks is bounded by the two values they bring, and bounded structurally:
/// `msg.value` and `maxTokensIn` are taken into this contract once, at the top of the call,
/// every restore is paid out of those balances and out of nothing else, and whatever is left
/// — including the bounty — goes back to the caller before the call returns. So this contract
/// holds no allowance it could spend later, and a candidate that fails spends nothing at all,
/// because each attempt is a self-call whose revert unwinds its swap.
///
/// Reentrancy, in one place so that every function below can be read against it:
/// `graduateVia` holds the guard; `attemptCandidate` is reachable only from this contract and
/// therefore only from inside that guard; `unlockCallback` is reachable only from the
/// PoolManager this contract is currently inside an `unlock` of. No other function moves
/// value, and no path moves value to any address other than the call's own caller.
contract GraduationHelper is IUnlockCallback, ReentrancyGuardTransient {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    // The casts name their functions instead of attaching the whole library, because Uniswap
    // v4-core declares a second library called `SafeCast` and both reach this file through
    // the imports above. Naming them binds the cast below to OpenZeppelin's implementation at
    // the attachment site, for a reader and for a static analyser alike.
    using {SafeCast.toInt24} for int256;
    using {SafeCast.toInt256} for uint256;

    /// @notice One pool key a caller is willing to graduate on, named by the key's two free
    /// fields. The pair `(POOL_FEE, POOL_TICK_SPACING)` means the canonical key.
    /// @param fee The key's LP fee in pips.
    /// @param tickSpacing The key's tick spacing.
    struct Candidate {
        uint24 fee;
        uint24 tickSpacing;
    }

    /// @dev The restoring swap's nominal exact input, negative because v4 reads a negative
    /// `amountSpecified` as exact input. It is far above anything a restore can require, so
    /// `sqrtPriceLimitX96` and not this number decides the swap's real size, which is how
    /// "sized to reach the limit" is expressed to v4: the swap settles whatever crossing the
    /// liquidity in its path costs, and the budget checks in `_resolve` are what cap that.
    int256 private constant _EXACT_INPUT_TO_LIMIT = -int256(uint256(type(uint128).max));

    /// @dev The PoolManager this contract is currently inside an `unlock` of, and the zero
    /// address at every other moment, so it doubles as the flag that no callback is expected.
    /// It is the only state this contract has, and it does not outlive the call that set it.
    address private transient _unlockManager;

    /// @notice A launch was graduated through this helper.
    /// @dev Indexed on the launch and on the caller, which are the two questions this
    /// contract's logs can answer: what happened to a launch, and what an address has done.
    /// The key the graduation used is carried by the curve's own `Graduated` log, so this one
    /// carries the winning candidate's index instead — every candidate before it failed, and
    /// that is the only record of the walk which survives, since a walk where nothing
    /// graduates reverts and keeps no logs at all.
    event GraduatedVia(
        address indexed launch,
        address indexed caller,
        uint256 candidateIndex,
        uint256 bounty,
        uint256 ethReturned,
        uint256 tokensReturned
    );

    /// @notice No candidate in the list graduated the launch, so the caller keeps everything.
    error NoCandidateGraduated(uint256 candidatesTried);
    /// @notice Only this contract may attempt a candidate.
    error NotSelf();
    /// @notice The caller is not the PoolManager this contract is currently unlocking.
    error NotUnlocking();
    /// @notice The restoring swap did not arrive at the launch's terminal price.
    error PriceNotRestored(uint160 actual, uint160 expected);
    /// @notice The restore needs more ETH than this contract was given.
    error EthBudgetExceeded(uint256 required, uint256 available);
    /// @notice The restore needs more launch tokens than this contract was given.
    error TokenBudgetExceeded(uint256 required, uint256 available);
    /// @notice A launch token transfer failed.
    error TokenTransferFailed();
    /// @notice An ETH transfer to the caller failed.
    error EthTransferFailed(address to, uint256 amount);
    /// @notice This contract would have ended an external call still holding value, which
    /// Invariant 68 forbids.
    error BalanceNotZero(uint256 ethBalance, uint256 tokenBalance);

    /// @notice Accepts ETH from any sender.
    /// @dev PoolManager pays a restore's credited ETH here and the curve pays a claimed
    /// bounty here, both with a plain call, so a sender filter would have to name two
    /// addresses this contract deliberately does not store. Anything that arrives outside a
    /// call of its own leaves with the next caller, because `_forward` sends balances rather
    /// than the amounts this contract believes it did not spend.
    receive() external payable {}

    /// @notice Restores a griefed pool price and graduates a launch in the same transaction,
    /// walking the caller's candidate keys until one of them graduates.
    /// @dev The loop is the only one in this protocol's source, and section 8.6 states the
    /// properties that permit it here: the bound is an array the caller supplies and pays the
    /// gas for, in a contract that holds nothing, that no other contract names, and whose
    /// failure harms nobody but its own caller. Every attempt is a self-call, so one
    /// candidate's failure neither ends the walk nor spends anything, and the only call that
    /// reverts is a walk in which nothing graduated.
    ///
    /// The three values read off the curve are read once for the whole walk rather than once
    /// per candidate, so every attempt builds its key from the same token and asks the same
    /// PoolManager for the same terminal price.
    /// @param curve The launch to graduate. Every address this call touches other than its
    /// own caller comes from this curve, so a hostile value here costs its caller the ETH and
    /// the tokens they brought to the call, and nothing else.
    /// @param candidates The pool keys to try, in order. An attacker who can see a
    /// transaction before it executes can seize the one key it names, but not a list they
    /// have not seen, and a failed candidate costs a `slot0` read and a revert. A caller with
    /// no reason to prefer otherwise orders them by the largest tick spacing first and then
    /// the fee closest to `POOL_FEE`, which is the guidance of section 8.4.
    /// @param maxTokensIn Base units of `curve.token()` to bring to the call. Restoring a
    /// price that sits below the terminal price is paid in launch tokens, so a caller facing
    /// that direction approves this contract for at least this much first; a caller who knows
    /// the restore is free or paid in ETH passes zero and needs no approval at all. It is
    /// pulled once, before the walk, and whatever the restore does not spend comes back.
    /// @return index The index of the candidate that graduated.
    function graduateVia(IBondingCurve curve, Candidate[] calldata candidates, uint256 maxTokensIn)
        external
        payable
        nonReentrant
        returns (uint256 index)
    {
        IERC20 launchToken = curve.token();
        IPoolManager manager = curve.poolManager();
        uint160 terminal = curve.sqrtPriceTerminal();

        // Both currencies are brought to the call and then spent out of this contract's own
        // balances, so nothing below has to be told whose funds it is spending and no
        // allowance of the caller's is reachable after this line. The ETH arrived with
        // `msg.value`; this is the token leg of the same step.
        if (maxTokensIn != 0 && !launchToken.transferFrom(msg.sender, address(this), maxTokensIn)) {
            revert TokenTransferFailed();
        }

        uint256 candidatesTried = candidates.length;
        // The length is not a reachable index, so it stands for "nothing graduated" and the
        // walk needs no second local to carry that fact out of the loop.
        index = candidatesTried;
        for (uint256 i = 0; i < candidatesTried; ++i) {
            // An external call in a loop is what this contract is for, and the self-call is
            // what makes a candidate's failure survivable rather than final.
            // forge-lint: disable-next-line(calls-loop)
            try this.attemptCandidate(curve, launchToken, manager, terminal, candidates[i]) {
                index = i;
                break;
            } catch {
                // The revert reason is deliberately not bound. A walk that goes on to
                // graduate discards it anyway, and copying the return data of a call into a
                // contract the caller chose would charge the rest of the walk for that
                // choice. A caller diagnosing a refusal simulates the curve's own call.
            }
        }
        if (index == candidatesTried) revert NoCandidateGraduated(candidatesTried);

        _finish(curve, launchToken, index);
    }

    /// @notice Restores one pool key's price and graduates the launch on that key.
    /// @dev Callable only by this contract, and therefore only from inside `graduateVia`'s
    /// reentrancy guard. It is external so that it can revert on its own: a candidate that
    /// cannot graduate unwinds its own swap, leaves the balances brought to the call where
    /// they were, and the walk goes on to the next key.
    ///
    /// Step 4 of section 8.6 is the ordering this function exists to get right.
    /// `_restorePrice`'s `unlock` has **returned** before `graduate` is called, because
    /// `PoolManager.unlock` reverts `AlreadyUnlocked` when re-entered and the graduation mint
    /// takes that same lock through PositionManager. The two unlocks are sequential within one
    /// transaction, never nested. Nothing executes between the restore and the graduation, so
    /// nothing can move the price back in between either.
    /// @param curve The launch to graduate.
    /// @param launchToken `curve.token()`, read once for the whole walk.
    /// @param manager The curve's own PoolManager, likewise.
    /// @param terminal `curve.sqrtPriceTerminal()`, the only price the launch will mint at.
    /// @param candidate The pool key to try.
    function attemptCandidate(
        IBondingCurve curve,
        IERC20 launchToken,
        IPoolManager manager,
        uint160 terminal,
        Candidate calldata candidate
    ) external {
        if (msg.sender != address(this)) revert NotSelf();

        // Narrowed through `SafeCast` for the reason `graduateAlt` narrows the same field: a
        // truncating cast would restore the price on a key built from one spacing and then
        // ask the curve to graduate on another, and the two keys have to agree field for
        // field.
        int24 tickSpacing = uint256(candidate.tickSpacing).toInt256().toInt24();
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(launchToken)),
            fee: candidate.fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();

        (uint160 current,,,) = manager.getSlot0(id);
        // An unopened key is opened by the graduation itself and a key already at the terminal
        // price needs no swap, so only a third price is paid for here.
        if (current != 0 && current != terminal) {
            _restorePrice(manager, key, current > terminal, terminal);
            (uint160 restored,,,) = manager.getSlot0(id);
            if (restored != terminal) revert PriceNotRestored(restored, terminal);
        }

        if (
            candidate.fee == PledrinConstants.POOL_FEE
                && tickSpacing == PledrinConstants.POOL_TICK_SPACING
        ) {
            curve.graduate();
        } else {
            curve.graduateAlt(candidate.fee, candidate.tickSpacing);
        }
    }

    /// @notice Executes the restoring swap of section 8.6 step 3.
    /// @dev Reachable only from the PoolManager this contract is currently unlocking, which is
    /// the PoolManager the curve named. The decoded payload is treated as data and never as an
    /// authority, which costs nothing to guarantee here: a caller who names a curve of their
    /// own choosing chooses this callback's caller and its payload too, and the most either
    /// can reach is the balances this contract is holding for that same caller.
    /// @param data The pool key, swap direction and price limit, encoded by `_restorePrice`.
    /// @return An empty value; `attemptCandidate` re-reads the price from `slot0`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != _unlockManager) revert NotUnlocking();
        IPoolManager manager = IPoolManager(msg.sender);

        (PoolKey memory key, bool zeroForOne, uint160 terminal) =
            abi.decode(data, (PoolKey, bool, uint160));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: _EXACT_INPUT_TO_LIMIT,
                sqrtPriceLimitX96: terminal
            }),
            ""
        );

        _resolve(manager, key.currency0, delta.amount0());
        _resolve(manager, key.currency1, delta.amount1());
        return "";
    }

    /// @dev Takes the PoolManager's lock, swaps to `terminal` and releases it. The flag is
    /// written back once `unlock` has returned rather than left set, because the graduation
    /// that follows in the same transaction reaches this same PoolManager through
    /// PositionManager: an unlock this contract is not inside must not be able to reach its
    /// callback.
    /// @param manager The curve's PoolManager.
    /// @param key The pool key to restore.
    /// @param zeroForOne The direction, by the orientation of section 8.1: a price above the
    /// terminal price comes down on ETH in, a price below it comes up on launch tokens in.
    /// @param terminal The price to restore to, which is also the swap's price limit.
    function _restorePrice(
        IPoolManager manager,
        PoolKey memory key,
        bool zeroForOne,
        uint160 terminal
    ) private {
        _unlockManager = address(manager);
        // The callback settles both legs of the swap and returns no value of its own.
        // forge-lint: disable-next-line(unused-return)
        manager.unlock(abi.encode(key, zeroForOne, terminal));
        _unlockManager = address(0);
    }

    /// @dev Resolves this contract's delta in one of the swap's two currencies. A credit is
    /// taken here and forwarded to the caller with everything else; a debt is paid by the two
    /// functions below, each out of the balance of that currency the caller brought to the
    /// call and neither out of anything else.
    /// @param manager The PoolManager whose lock is held.
    /// @param currency The currency to resolve.
    /// @param amount This contract's delta in it: negative is owed, positive is credited, and
    /// zero needs neither call.
    function _resolve(IPoolManager manager, Currency currency, int128 amount) private {
        if (amount > 0) {
            // casting to 'uint256' is safe because the branch fixes `amount` positive
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(currency, address(this), uint256(int256(amount)));
        } else if (amount < 0) {
            // casting to 'uint256' is safe because `amount` is negative here and the negation
            // is taken after widening, so no `int128` value can overflow it
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(-int256(amount));
            if (currency.isAddressZero()) {
                _settleEth(manager, owed);
            } else {
                _settleToken(manager, currency, owed);
            }
        }
    }

    // Both analysers report the destination here as user-controlled, and it is: the
    // PoolManager comes off the curve the caller named. What makes that safe is not the
    // destination but the amount — a lock this contract took moments ago is asking what
    // closing it costs, and the check above caps that at the balance the caller brought. A
    // hostile answer can reach that balance and nothing else, which is the same exposure the
    // caller already accepted by naming the curve.
    // forge-lint: disable-next-item(arbitrary-send-eth)
    /// @dev Pays the swap's ETH leg out of this contract's balance, which is `msg.value` plus
    /// anything that reached this contract outside a call of its own. The balance rather than
    /// `msg.value` is the right bound because stray value belongs to nobody and is forwarded
    /// to this caller regardless, so `msg.value` is still all a caller can lose.
    /// @param manager The PoolManager whose lock is held.
    /// @param owed Wei the pool is owed.
    function _settleEth(IPoolManager manager, uint256 owed) private {
        uint256 held = address(this).balance;
        if (owed > held) revert EthBudgetExceeded(owed, held);
        // slither-disable-next-line arbitrary-send-eth
        manager.settle{value: owed}();
    }

    /// @dev Pays the swap's launch token leg out of the balance `graduateVia` pulled from the
    /// caller, which is the exact counterpart of the ETH leg above: this contract spends only
    /// what it is holding, so no allowance of the caller's is reachable from inside the lock
    /// and no address has to be trusted with one.
    /// @param manager The PoolManager whose lock is held.
    /// @param currency The launch token, as the pool's `currency1`.
    /// @param owed Base units the pool is owed.
    function _settleToken(IPoolManager manager, Currency currency, uint256 owed) private {
        IERC20 launchToken = IERC20(Currency.unwrap(currency));
        uint256 held = launchToken.balanceOf(address(this));
        if (owed > held) revert TokenBudgetExceeded(owed, held);

        // v4 credits a token by measuring what it gained since `sync`, so the order of these
        // three calls is the protocol's and not a choice.
        manager.sync(currency);
        if (!launchToken.transfer(address(manager), owed)) revert TokenTransferFailed();
        // `settle` returns what it credited, which is the amount transferred in above.
        // forge-lint: disable-next-line(unused-return)
        manager.settle();
    }

    /// @dev Step 5 of section 8.6, once a candidate has graduated: collect the bounty the
    /// graduation credited to this contract and hand it to the caller together with
    /// everything else this contract holds. The log is emitted before the value moves,
    /// because the amounts it reports are known before the two transfers and the transfers
    /// reach an address this contract does not choose.
    /// @param curve The launch that graduated.
    /// @param launchToken The launch's token.
    /// @param index The index of the candidate that graduated.
    function _finish(IBondingCurve curve, IERC20 launchToken, uint256 index) private {
        uint256 bounty = _claimBounty(curve);
        uint256 ethBack = address(this).balance;
        uint256 tokensBack = launchToken.balanceOf(address(this));

        emit GraduatedVia(address(curve), msg.sender, index, bounty, ethBack, tokensBack);
        _forward(launchToken, ethBack, tokensBack);
    }

    /// @dev Collects the bounty the graduation credited to this contract, which is what makes
    /// Invariant 68's balance clause reachable at all: `graduate` credits `msg.sender`, which
    /// here is this contract, and a credit left behind would be payable only into a contract
    /// with no way to pay it out.
    ///
    /// The claim's failure is tolerated because the bounty is not what the call was for. A
    /// launch whose accrued protocol fee is under ten wei credits a bounty of zero and
    /// `claimBounty` refuses an empty credit, and a graduation that has already happened must
    /// not be undone by that refusal. No other failure is reachable on a real curve: the
    /// credit was written moments earlier by the call this one follows, and this contract's
    /// `receive` takes the payment from any sender.
    /// @param curve The launch that graduated.
    /// @return amount The wei collected, zero when there was no credit to collect.
    function _claimBounty(IBondingCurve curve) private returns (uint256 amount) {
        try curve.claimBounty(address(this)) returns (uint256 claimed) {
            amount = claimed;
        } catch {}
    }

    /// @dev Sends everything this contract holds to its caller and asserts that it then holds
    /// nothing, which is Invariant 68's balance clause in full. It forwards balances rather
    /// than the amounts it believes it did not spend, so a stray transfer into this contract
    /// leaves with the next caller instead of failing this assertion forever. The assertion
    /// runs after the transfers, where it can still catch a launch token that under-delivers;
    /// a caller that pushes value back in from its own receive hook fails its own call, which
    /// is the only call it can affect.
    /// @param launchToken The launch token to forward and then assert against.
    /// @param ethAmount This contract's whole ETH balance.
    /// @param tokenAmount This contract's whole launch token balance.
    function _forward(IERC20 launchToken, uint256 ethAmount, uint256 tokenAmount) private {
        if (tokenAmount != 0 && !launchToken.transfer(msg.sender, tokenAmount)) {
            revert TokenTransferFailed();
        }
        if (ethAmount != 0) {
            // Both analysers call this an arbitrary destination because it is the caller's
            // own address. Paying the caller is the one thing this contract may do with ETH,
            // and the amount is a balance it is never entitled to keep, so the finding is
            // the design rather than a defect in it.
            // forge-lint: disable-next-line(arbitrary-send-eth)
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = msg.sender.call{value: ethAmount}("");
            if (!ok) revert EthTransferFailed(msg.sender, ethAmount);
        }

        uint256 ethLeft = address(this).balance;
        uint256 tokensLeft = launchToken.balanceOf(address(this));
        if (ethLeft != 0 || tokensLeft != 0) revert BalanceNotZero(ethLeft, tokensLeft);
    }
}
