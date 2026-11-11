# Pledrin — threat model

Companion to `docs/SPEC.md`. Section references are to that document.

This document has two halves. The first enumerates attacks the design addresses
and says how. The second, section 10, states what the design does not prevent.
Section 10 is the more important half. The product's claim is that rugging is
expensive, not that it is impossible, and this document exists to hold that line.

---

## 1. Adversaries

| Adversary | Capability | Wants |
|---|---|---|
| Trader-MEV | Sees pending state, orders transactions within a block, large capital | Extract value from curve and pool trades |
| Griefer | Modest capital, willing to lose it | Make a launch fail, make graduation impossible, make a user's transaction fail |
| Rounding grinder | Unlimited transaction count, tiny amounts | Extract wei from arithmetic, or inflate state cheaply |
| Dishonest creator | Controls the launch parameters, arbitrary number of fresh addresses, off-chain narrative | Take ETH out and leave holders with nothing |
| Early buyer cartel | Coordinated, bought cheap | Exit into later buyers |
| Protocol insider | Holds the factory owner key | Divert fees or user funds |
| External dependency | Uniswap governance, chain operator | Not adversarial by intent, but changes outcomes |

The Robinhood Chain sequencer is first-come-first-served with no public mempool,
which raises the cost of mempool-based attacks but is not relied on anywhere.
Every mitigation below holds against a fully public mempool.

---

## 2. Economic attacks on the bonding curve

### 2.1 Draining the reserve

The curve pays out at most `ethReserve` for any accepted sell if and only if
`vE * vT >= K` (section 5.6). Every rounding direction makes that product
monotonically non-decreasing, so the inequality holds from initialisation
forever. There is no sequence of buys, sells, donations or state transitions
that makes the curve unable to honour a sell. Invariants 1 and 2.

The derivation is tight, not conservative: the inequality is *equivalent* to
solvency against the maximum possible sell, so the invariant is also not
over-strong in a way that would reject legitimate trades.

### 2.2 Round-trip extraction

Buying and immediately selling returns at most what was paid, with zero fees, at
every state. Invariant 7, verified by fuzzing across the whole `tokensSold`
range. With the default fee the loss is at least `2 * totalFeeBps` of notional
plus two roundings. There is no arbitrage against the curve by itself.

### 2.3 Sandwiching a curve trade

The curve has no external price reference, so a sandwich against it is an
ordinary price-impact game: the attacker buys ahead, the victim buys at a worse
price, the attacker sells back. The attacker's own round trip loses fees and
rounding (2.2), so the attack is profitable only when the victim's price impact
exceeds the attacker's round-trip cost. Mitigations:

- `minTokensOut` on `buy` and `minEthOut` on `sell` are mandatory parameters, not
  optional. A caller passing zero is accepting unbounded slippage knowingly.
- A `deadline` parameter on both, checked against `block.timestamp`.
- The fee is charged on both legs of the attacker's round trip, so the curve and
  its holders are paid for the sandwich.

This is not eliminated. It is the same exposure any AMM has and it is bounded by
the slippage parameter the user sets.

### 2.4 Front-running a buy with a donation

A donation raises `vE` without raising `tokensSold`, so a pending buy receives
fewer tokens than quoted (section 5.7). The attacker gains nothing — the donated
ETH is irrecoverable and goes to holders — so this is pure griefing at the
attacker's full expense. `minTokensOut` reverts the victim's transaction instead
of filling it badly.

### 2.5 Sniping the cap

The buy that reaches the cap is clipped to exactly `CURVE_SUPPLY - tokensSold`,
charged a fee only on the ETH actually consumed, and refunded the remainder
(section 5.4, Invariant 12). A snipe of the last buy therefore buys tokens at
the curve's terminal price and gains no discount. Being the one who triggers
`Graduating` confers no advantage: it does not reserve the graduation bounty, it
does not give priority in the new pool, and it does not change the price anyone
pays.

### 2.6 Rounding grind

Every rounding step favours the curve, so repeated small trades transfer value
*to* holders. A grinder pays `MIN_BUY_WEI` per buy plus gas and receives strictly
less than a single large buy would give. There is no accumulation path: the
product drift is monotone upward, so no amount of grinding can bring the curve
closer to insolvency.

The grinder also cannot cheaply inflate `tokensSold` toward the cap. The cost of
reaching the cap is the curve integral, which is `R_target` wei regardless of how
many transactions it is split into.

### 2.7 Manipulating the price through balances

`buy`, `sell` and every quote read `tokensSold` and `ethReserve` from storage.
Neither is derived from `address(this).balance` or from `token.balanceOf`.
Invariant 10. Forcing ETH into the curve, forcing tokens into it, or any future
chain mechanism that credits balances without a call cannot move any price. This
single rule removes the whole class of balance-manipulation attacks rather than
patching instances of it.

### 2.8 Blocking a specific user

A user whose address reverts on receiving ETH cannot sell or receive a clipped-buy
refund. That is a property of their own address. It blocks nobody else: no trade,
no claim and no state transition depends on a transfer to a third party
succeeding. Invariant 58.

---

## 3. Fee-split rounding leaks

### 3.1 Dust creation or destruction

Two of the three shares are floored products and the third is the residual
(section 6.1). Therefore the three parts sum to the fee exactly for every
possible fee value, including 1 wei, including every value where two floors round
down at once. Invariant 14. There is no code path where a floor is applied to all
three shares, which is the usual source of a leak.

### 3.2 Where the dust goes

Into `protectionEth`, and from there into the permanently locked floor position
(section 10 of the spec) or, if the launch does not graduate, into `ethReserve`
where it raises every holder's exit price. The remainder's destination is a
single named bucket, stated in the spec, asserted by Invariant 17, and is the
party that should win an ambiguous rounding.

### 3.3 Grinding the dust

An attacker could trade at sizes chosen so that `fee * creatorShareBps / 10000`
and `fee * protocolShareBps / 10000` both round down maximally, pushing up to 2
wei per trade into `protectionEth` instead of to the creator and protocol. The
"attack" costs a full fee per trade to move 2 wei to holders. It is not an
attack; it is a donation with extra steps.

### 3.4 Fee accounting drift

Accrued-but-unclaimed fees are tracked in three storage buckets, never pushed
during a trade, and never commingled with `ethReserve`. Invariants 3 and 18
assert that the contract's ETH balance covers every bucket plus the reserve plus
the bond plus every credited-but-unclaimed payout, and that total fees charged
equals total fees paid out plus total fees held. A leak in either direction fails
a test.

### 3.5 Redirecting fees after launch

`protocolTreasury` and all three share values are copied immutably into the curve
at launch. A later factory config change affects future launches only.
Invariant 53. A compromised factory owner cannot reach a single wei of an
existing launch.

---

## 4. Griefing graduation

This is the attack surface that matters most, because graduation is
irreversible, happens once, and strands every holder if it cannot complete.

### 4.1 Pre-initialising the pool at a hostile price

The classic attack: an attacker calls `PoolManager.initialize` on the launch's
pool key before the protocol does, at an absurd price, so that the protocol's own
`initialize` reverts and its liquidity would be minted against a manipulated
price.

Closed completely. `createLaunch` initialises the pool in the launch transaction
(section 8.1). The token address does not exist before that transaction, so the
pool key is not computable before it, so there is no window. **No attacker can
ever choose a Pledrin pool's initial price.** This is the single most valuable
property bought by initialising at launch rather than at graduation, and it is
why the extra `initialize` gas on launches that never graduate is accepted.

### 4.2 Moving the price of the zero-liquidity pool

A pool with no liquidity can have its `sqrtPriceX96` moved to an arbitrary limit
by a swap that transfers nothing, because there is no liquidity to swap against.
An attacker can therefore shift a pre-initialised Pledrin pool away from
`sqrtPriceTerminal` at near-zero cost at any time during the curve phase.

`graduate()` reads `slot0` and, if the price has moved, restores it with a swap
whose `sqrtPriceLimitX96` is `sqrtPriceTerminal` and whose direction follows from
comparing the two, then asserts both that the swap's net deltas in both
currencies were zero and that the restored price is exactly `sqrtPriceTerminal`
(section 8.2, Invariants 40 and 41). In an empty pool this reset settles for
nothing in either currency, verified in both directions on a fork against the
deployed PoolManager. It is not a literally zero-sized swap: `PoolManager.swap`
rejects `amountSpecified == 0`, so the restoring call nominates one unit of exact
input and relies on an empty pool consuming none of it. The attack costs the
attacker gas and achieves nothing.

### 4.3 Adding liquidity so that the reset is not free

If the attacker mints real liquidity into the pool at the ticks between the
manipulated price and `sqrtPriceTerminal`, restoring the price would require
actually trading against it, which would cost the curve ETH or tokens.

`graduate()` requires the reset's net deltas to be zero, so it reverts rather
than spending any curve value on a swap. Consequences:

- The curve never funds a swap. `ethReserve` is spent only on sells and on the
  core position. Invariant 4.
- State remains frozen in `Graduating`. `tokensSold`, `ethReserve` and every
  token held by the curve are untouched and remain under Invariants 1 and 2.
  **No user funds are at risk at any point during this grief; the only cost is
  delay.**
- `graduate()` is retryable forever with no deadline.
- After `ALT_DELAY` the launch can graduate on a different pool key
  (section 4.5).

The attacker also pays for the privilege: liquidity minted at a wrong price in a
pool whose price is about to be reset to `sqrtPriceTerminal` is a losing
position, and tokens they used to mint it had to be bought from the curve at the
curve's price.

### 4.4 The pre-initialised pool as a shadow market

Because the pool exists from launch, anyone may add liquidity to it and trade
against it before graduation. A second market therefore exists alongside the
curve for the whole curve phase, and the two prices can diverge.

This is accepted and is not a vulnerability. The curve is the canonical venue:
it is the only source of new supply, it is where the cap is measured, and its
solvency is independent of any pool price. Arbitrage between the two is ordinary
and transfers value from whichever side is mispriced. A user who buys on the
shadow market at a worse price than the curve offers has made a choice the
frontend should discourage, not a loss the protocol caused.

### 4.5 Blocking every pool key

After `ALT_DELAY = 1 hour` in `Graduating`, `graduateAlt(uint24 tickSpacing)`
performs the identical procedure on a caller-supplied `tickSpacing` in
`[10, 200]`, and requires that pool to be uninitialised so that it is
initialised at `sqrtPriceTerminal` with no prior liquidity (Invariant 38). An
attacker must therefore pre-initialise and hold hostile liquidity on every
permitted spacing in that range, continuously, for as long as the launch exists,
and re-do it after every failed attempt. Each instance is a losing position.

The uninitialised requirement is load-bearing in a second way that is easy to
miss, and must not be relaxed. Restoring a griefed price is free in both
currencies but not in gas: the restoring swap walks the tick bitmap in proportion
to the tick distance divided by the tick spacing. Measured on a fork against the
deployed PoolManager, restoring from the extreme tick cost 173k gas of EVM
execution at `tickSpacing = 200` and 2.33M at `ALT_TICK_SPACING_MIN = 10`, the
latter alone exceeding the two-million-gas graduation the bounty is sized
against. Because `graduateAlt` opens the alternate pool itself at
`sqrtPriceTerminal`, that cost never enters the graduation path. Allowing an
already-initialised alt pool would import it and would hand an attacker a
gas-exhaustion grief on the one path that exists to defeat griefing. The figures
are EVM execution gas under a forked EVM; Nitro's gas accounting differs
(`docs/CHAIN_FACTS.md`), so they describe the relative cost of the loop and not a
chain gas quote.

`ALT_DELAY` exists so the honest primary key wins when it is available; without
it, a caller could fragment the canonical pool onto an odd spacing for no reason.

### 4.6 Nobody calls `graduate()`

Permissionless and bounty-paid at 10% of the launch's accrued protocol fees,
which is at least `0.0004 * R_target` and exceeds the observed graduation gas
cost on these networks by more than an order of magnitude, scaling with the
raise (section 8.3). The bounty is drawn from the protocol's fee bucket and never
from the reserve, the protection pool, the creator's fees or the bond.

### 4.7 Reverting on ETH receipt to make `graduate()` fail

If `graduate()` pushed the bond to the creator or the bounty to the caller, an
address that reverts on receipt could make the whole transaction revert forever
and strand every holder. Both are therefore **credited as claimable balances, not
pushed** (section 8.2, Invariant 45). `graduate()` sends ETH only to PoolManager
and PositionManager.

### 4.8 Selling at the cap to prevent graduation

With sells enabled at `tokensSold == CURVE_SUPPLY`, anyone could sell one base
unit to push the launch back below the threshold and repeat indefinitely for the
cost of gas, holding a launch at the cap forever.

`Graduating` freezes both buys and sells (section 7, Invariants 31 and 33), so
the cap is a one-way door. The cost is that holders cannot sell during the window
between the cap and migration, which is why section 4.9 exists.

### 4.9 Succeeding at all of the above

After `GRAD_GRACE = 7 days` in `Graduating`, `abortGraduation()` moves the launch
to `Stalled`: sells reopen permanently with no deadline, the bond is **returned**
to the creator, creator fees become claimable, `protectionEth` is donated into
`ethReserve`, and vesting starts. Holders exit against the deepest reserve the
curve ever held — `8 * vE0` plus rounding surplus plus the entire protection pool
— at the curve's terminal price.

The bond is returned rather than forfeited because the creator met the only
condition the bond encodes (section 11.1), and a third party's grief must not
cost them. A creator who griefs their own graduation to force `Stalled` gains
nothing: they receive exactly the bond and fees `graduate()` would have given
them, and they pay for the grief. What they lose is the locked Uniswap pool,
which is the thing that makes a graduated token tradeable at all.

---

## 5. Sandwiching the migration

### 5.1 The usual attack

Migrations are normally sandwiched because the new pool opens at a price that
differs from the price the last curve buyer paid. The gap is free money for
whoever trades first.

The supply constants are chosen so that the gap is zero. `C * tau == vT0 * S_LP`
exactly, which makes the curve's terminal marginal price exactly equal to the
price of a full-range pool holding `R_target` wei against `S_LP` base units
(section 5.3). At the first post-graduation block there is nothing to arbitrage.
This is arithmetic, not a slippage guard, and it is the reason for the 90/10
split rather than the more common 80/20: an 80/20 split opens the pool 20% below
the curve's last price and hands that 20% to the first seller.

### 5.2 No window between seeding and tradeability

Pool initialisation happens at launch; the price assertion, the core mint and the
floor mint all happen inside one `graduate()` transaction. There is no block in
which the pool is initialised but unseeded in a way an attacker can exploit for
value — only the free price-shift of 4.2, which `graduate()` undoes.

### 5.3 The floor position cannot create a gap

Position B is single-sided `currency0` with `tickLower` strictly **above** the
current tick (Invariant 42). Because `currency0` is ETH and `currency1` is the
token, the tick axis runs opposite to the token's ETH price (spec 8.1), so that
range is the band immediately *below* the opening price in price terms and is the
side v4 funds in ETH alone. Minting it moves neither the price nor the tick, adds
nothing to active liquidity, holds no token, and opens no gap upward; all four
were measured on the fork. Had the range been specified below the current tick,
as an earlier draft of spec 10.1 did, the position would have been funded in the
token and would have been a sell wall rather than a bid. The naive alternative —
adding the protection pool's ETH into the core position — would raise the opening
price above the curve's terminal price and hand the difference to the first
seller. That is why the protection pool funds a separate bid position rather than
being added to the core.

### 5.4 What is not prevented

The first swap in the new pool is ordinary MEV. Whoever wins the ordering
captures ordinary price impact on their own trade. They capture no protocol
subsidy, no mispricing and no discount, because there is none to capture. This
is not fixed and cannot be fixed from inside the contract.

---

## 6. First-depositor and donation attacks

### 6.1 First depositor on the curve: structurally absent

The classic first-depositor attack needs a share token whose exchange rate is
derived from a balance, so that a tiny first deposit followed by a large donation
inflates the rate and truncates every later depositor's shares to zero.

The curve mints no shares. It has no exchange rate derived from a balance. Its
reserves are virtual constants plus two storage counters, both non-zero and
well-defined from the first block. There is no empty-pool state and no first
depositor. This immunity is one of the reasons the design is a virtual-reserve
CPMM rather than a share-based pool, and it is a property of the construction
rather than a check that could be forgotten.

### 6.2 Donation to the curve

A donation routed through `donate()` raises `ethReserve` and therefore raises
every holder's exit price and lowers every future buyer's token count. It cannot
be withdrawn, cannot trigger graduation (the trigger is `tokensSold`, not
`ethReserve`), and cannot break solvency (it only increases the product). The
only adverse use is front-running a buy, covered in 2.4.

Making the graduation trigger token-denominated rather than ETH-denominated is
load-bearing here: an ETH-denominated threshold would let anyone force a launch
to graduate by donating, at a price nobody paid.

### 6.3 Donation outside `donate()`

ETH or tokens sent to the curve by any other means change no price (2.7) and are
not counted in any bucket. Forced ETH is bounded in effect: after graduation the
curve has no withdrawal path, so it is permanently removed from circulation.
Forced tokens sit in the curve and, since `buy` transfers out exactly the computed
`tokensOut` and nothing reads `balanceOf`, they are inert — and after `Expired`,
`Stalled` or `Graduated` they can never leave.

The graduation remainder joins them. The core position is parameterised by
liquidity, so it consumes at most `LP_SUPPLY` and leaves a few hundred base units
behind (spec 8.2, Invariant 39), and those are stranded in the curve forever. At
roughly `10**-15` whole tokens this changes no quantity anyone can observe, and
it is recorded here rather than claimed away.

### 6.4 First depositor on the Uniswap pool

Removed by initialising the pool at launch at a price the protocol chooses
(4.1). The protocol is always the pool's initialiser.

### 6.5 Donation to the locked position

Anyone may mint additional liquidity into the graduated pool, including a
single-sided ETH bid in the band below spot in price terms, which per spec 8.1 is
the tick range above the current tick. That deepens the floor for every holder
and the depositor keeps their own position. Nothing about it harms the protocol or
holders, and nothing about it gives the depositor access to the locked positions.

---

## 7. Reentrancy surfaces

Every function that moves value carries a reentrancy guard and follows
checks-effects-interactions, with no storage write after an external call
(Invariant 55). The complete enumeration:

| Surface | Entry | Discipline |
|---|---|---|
| `buy` | clipped-buy ETH refund to `msg.sender` | guard; `tokensSold`, `ethReserve`, fee buckets and the `Graduating` transition all written before the token transfer and before the refund |
| `buy` | `token.transfer` to `msg.sender` | the token is a plain ERC-20 with no hook, so this is not a callback surface; ordering is still CEI |
| `sell` | ETH payout to `msg.sender` | guard; `ethReserve`, `tokensSold` and fee buckets written before the payout |
| `sell` | `token.transferFrom` from `msg.sender` | pulled before any state write; plain ERC-20, no hook |
| `donate` | none | no external call |
| `claimCreatorFees`, `claimProtocolFees`, `claimBounty`, `claimBond` | ETH to recipient | guard; bucket zeroed before the call |
| `graduate`, `graduateAlt` | PoolManager `unlock`, PositionManager `modifyLiquidities` | guard; `state` set to `Graduated` as the first write, before any external call, so a reentrant `graduate` fails the state check (Invariant 36) |
| `unlockCallback` | PoolManager | reverts unless `msg.sender` is PoolManager and the curve is inside its own `unlock` (Invariant 56) |
| `onERC721Received` | PositionManager | reverts unless `msg.sender` is PositionManager (Invariant 57) |
| `expire`, `abortGraduation` | `CreatorVesting.start` / `void`, `LaunchFactory.record*` | all protocol-internal, non-reentrant callees, called after every local write |
| `CreatorVesting.release` | `token.transfer` to `creator` | guard; `released` incremented before the transfer |
| `createLaunch` | token deploy, curve deploy, `PoolManager.initialize`, the creator's first buy | guard; reputation counters written last; the first buy runs against a curve the transaction just created, with no third-party code in the path |

Two notes that remove surfaces rather than guarding them:

- The launch token has no transfer hook, no callback and no fee on transfer, so
  token movement is never a reentrancy entry point. This is a direct consequence
  of charging all protocol fees in ETH (section 3 of the spec).
- No trade makes an outbound call to the creator or the treasury. Fees accrue to
  storage and are claimed separately, so a trade's call graph contains only the
  trader and the token.

---

## 8. Insider and governance risk

The factory owner is a timelock with a 48-hour delay and exactly three powers:
pause new launches, change defaults for future launches within code-enforced
bounds, and change the treasury recorded into future launches (section 14).

There is no function on any deployed contract by which the owner, the timelock,
the treasury or any other address can move curve reserves, bond ETH, protection
ETH, accrued fees, vested tokens or a locked position. Invariant 52. A pause
cannot stop a trade, a sell, a donation, a graduation, an expiry, a claim or a
vesting release. Invariant 50.

A fully compromised owner key can therefore do two things: stop new launches
being created, and set hostile-but-bounded fee parameters on launches created
after the 48-hour delay elapses. It cannot touch any existing launch or any user's
funds. Residual exposure: a user who creates a launch after a malicious config
change takes effect gets the new parameters. The 48-hour delay and the
`FeeConfigSet` event are the mitigation; who holds the timelock's proposer role
is an open decision.

---

## 9. External dependency risk

These are not Pledrin vulnerabilities. They are disclosed because graduated
liquidity depends on them.

**Uniswap protocol fees.** `PoolManager.protocolFeeController()` returns a
non-zero address on mainnet 4663 and the zero address on testnet 46630, verified
with `cast` against the PoolManager address in `docs/CHAIN_FACTS.md`. Where a
controller is set, Uniswap governance can enable a protocol fee on any v4 pool,
bounded by a constant in the v4 code, which diverts part of the swap fee away
from liquidity providers — here, away from the permanently locked positions.
Pledrin cannot prevent this and does not promise a fee rate on graduated pools.
The two controller values are not reproduced here because no address may appear
outside `docs/CHAIN_FACTS.md`; see the note at the end of
`docs/OPEN_DECISIONS.md`.

**PoolManager ownership.** `PoolManager.owner()` returns a different non-zero
address on each network, also verified with `cast`. Pledrin inherits whatever
powers that role holds over v4 pools. Graduated liquidity is custodied by the
Uniswap v4 contracts, not by Pledrin.

**Chain operation.** Robinhood Chain is an Arbitrum Nitro chain operated by a
third party. Sequencer censorship, a chain halt or a reorg beyond the protocol's
control can delay any transaction, including `graduate()` and `expire()`.
Deadlines use `block.timestamp`, which the sequencer sets within protocol-defined
bounds. No logic depends on `block.number` or on precise gas accounting, both of
which behave differently on Nitro than on L1.

**Testnet divergence.** Uniswap v4, Permit2 and the PositionManager have
identical code sizes on both networks, but `protocolFeeController` and the
PoolManager owner differ. A testnet graduation can therefore pass while a mainnet
graduation sees a protocol fee. Fee rate is not asserted by any invariant.

---

## 10. What this design does not prevent

Stated plainly. Each of these is a real limitation, not a risk that is mitigated
elsewhere in the document.

### 10.1 Sybil wallets

Addresses are free. Every per-address count the protocol stores — holder counts,
buyer counts, launch counts, graduation counts — can be inflated to any number by
one person for the cost of gas. The protocol has no notion of identity, no proof
of personhood, and no way to acquire one without an oracle, which the design
constraints forbid.

This is the direct reason the holder-protection pool buys locked liquidity rather
than paying holders pro rata. A pro-rata payment pays per address, so splitting
one balance across a thousand wallets before a snapshot costs only gas. Depth
below spot cannot be gamed by address count. The mechanism was chosen because of
this limitation, not in spite of it.

### 10.2 A creator buying their own launch through fresh addresses

The protocol cannot link addresses. A creator can buy any amount of their own
launch through addresses that have no on-chain relationship to the one that
called `createLaunch`, and the protocol will treat those buys as public demand.

Specifically:

- `CREATOR_FIRST_BUY_MAX` caps the **disclosed, vested, badged** allocation at 2%
  of supply. It does not cap what a creator can accumulate. A creator who wants
  20% will buy 20% through fresh addresses, unvested and unlocked, and the
  protocol will not know.
- Volume, buyer count and the appearance of organic demand can all be
  manufactured by a creator trading with themselves. They pay the trading fee on
  every leg, which is the only cost, and part of that fee comes back to them as
  the creator share.
- Reaching the cap can be self-funded. A creator with `R_target` of ETH can
  graduate their own launch alone, recover most of it as the first seller into
  the new pool, get their bond back, and claim their fee share. The bond
  guarantees delivery of a graduation, and a self-funded graduation is a
  graduation.

The vested first buy makes the honest path cheap, visible and locked. It does
not make the dishonest path unavailable.

### 10.3 Coordinated dumping by early buyers

Early curve buyers hold cheap tokens with no lock, no vesting and no transfer
restriction, by design: locking ordinary buyers would make the token unusable.
Nothing stops a group that bought in the first hour from selling together at
graduation. The locked core position and the locked floor position make that exit
cost more price impact than a shallow pool would, and the floor position buys
from them on the way down, which is exactly what it is for. Neither prevents the
dump or protects a holder's entry price.

### 10.4 Social-engineering rugs

The protocol enforces properties of transactions. It cannot enforce properties of
promises. A creator can:

- post a bond, graduate honestly, satisfy every on-chain condition, collect the
  bond and the fee share, and abandon the project the next day;
- promise a product, a team, a listing, a partnership or a burn, and deliver none
  of it;
- impersonate a person or an organisation in the token name, symbol or metadata,
  none of which the protocol validates;
- run the same playbook from a fresh address after a forfeited bond, with no
  reputation attached.

Every bond condition is a transaction condition. The Dev Bond is a **delivery
bond**: it promises that the curve reaches its cap before the deadline or the
creator's ETH goes to the people who bought. It promises nothing about honesty,
competence, intent or follow-through, and no on-chain rule can, because judging
those requires off-chain judgement, which requires an oracle or an admin, both of
which this design refuses on purpose. The honest framing is that the bond and the
reputation counters are priced signals, not guarantees.

### 10.5 Reputation is per-address and therefore resettable

Every counter in section 13 of the spec is keyed by address. A creator with a bad
record creates a new address and has a clean one. What a reader can rely on is
narrow and worth stating exactly: a **non-empty** record is expensive to
fabricate, because `bondWeiForfeited` can only be increased by actually losing
that ETH to holders and `ethRaisedGraduated` only by actually raising it. A
**fresh address has no record**, which is itself the signal — and it is the only
signal the reputation system can honestly provide about a first-time creator.

Reputation measured in counts is nearly free to fake. Reputation measured in wei
is not. A reader should weight the wei-denominated counters and discount the
counts.

### 10.6 The holder-protection pool is not insurance

It does not compensate any individual for any loss. It does not know anyone's
cost basis. It pays nothing to anyone. It buys permanently locked depth below the
opening price, which helps every holder and every future holder a little and no
specific holder a lot. Describing it as protection against loss would be false.

### 10.7 Locked liquidity guarantees a market, not a price

The core and floor positions cannot be withdrawn by anyone, ever. That guarantees
a graduated token is always tradeable against a non-trivial ETH reserve. It does
not guarantee a price. A graduated token can trade down to a small fraction of its
opening price; the locked position simply remains there while it does, and the
floor position absorbs part of the decline. Permanent liquidity is a floor on
*liquidity*, not a floor on *value*.

### 10.8 A launch that never graduates

Most launches will not reach the cap. A buyer in a launch that expires holds
tokens in a curve that is closed to new buyers and permanently open to sellers,
where later sellers receive less than earlier ones. The forfeited bond, the
forfeited creator fees and the protection pool are all donated into the reserve,
which raises every exit price, and the creator receives nothing. That is the full
extent of the remedy. It is not a refund, and a holder who bought near the cap can
still lose most of their ETH.

### 10.9 The claim this design actually makes

Rugging a Pledrin launch is expensive, not impossible.

What is genuinely enforced, without an oracle, an admin or any off-chain input:

- The token has a fixed supply, no mint, no owner and no pause. Supply cannot be
  inflated.
- The creator cannot withdraw a single wei from a launch before it graduates.
- The creator's disclosed token allocation cannot be sold before graduation plus
  a cliff, and is voided entirely if the launch expires.
- The graduated liquidity and all fees it ever earns can never be withdrawn by
  anyone.
- A bonded launch that misses its deadline pays the creator's ETH to holders
  automatically, with no vote, no claim and no discretion.
- Curve reserves always cover every possible sell.

What is not enforced is everything that depends on knowing who someone is or what
they intended. Those are in sections 10.1 through 10.8, and no future version of
this protocol will close them on-chain.
