# Verified chain facts

Every address and parameter here was verified directly against the chain with
`cast` on 2026-11-11, and cross-checked against the official Uniswap deployment
pages. Nothing in this file is from memory.

All addresses here are EIP-55 checksummed, which is the form
Solidity requires in a literal.

**Rule for the whole team: never introduce an external address that is not in
this file. If you need one, verify it on-chain first and add it here with the
command you used.**

## Networks

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | `4663` | `46630` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` | `https://explorer.testnet.chain.robinhood.com` |
| Gas token | ETH | ETH |

Verified:

```
cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com   # 4663
cast chain-id --rpc-url https://rpc.testnet.chain.robinhood.com   # 46630
```

## Node implementation: Arbitrum Nitro

```
cast client --rpc-url https://rpc.mainnet.chain.robinhood.com
# nitro/v3.12.4-rc.3+960ca0a-20261110T061047Z/linux-arm64/go1.25.12
```

Robinhood Chain is an Arbitrum Nitro chain, not an OP Stack chain. Consequences
that bind our contracts:

- `ArbSys` precompile is live at `0x0000000000000000000000000000000000000064`;
  `arbChainID()` returns `4663`.
- On this chain `block.number` tracks the L2 block number closely
  (`block.number` 111410584 vs `arbBlockNumber()` 111410579 in the same second),
  but Nitro does not guarantee this relationship. **All time-dependent logic
  (vesting, timelocks, bond windows) must use `block.timestamp`, never
  `block.number`.**
- Gas is dominated by L1 data posting, not L2 execution. Calldata size matters
  more than opcode count. Observed `gas-price` on testnet: 0.01 gwei.
- `gasleft()` and the 63/64 rule behave differently from L1. Do not build
  logic that depends on precise gas accounting.

## Block time and finality tags — measured, mainnet

```
cast block latest    --rpc-url https://rpc.mainnet.chain.robinhood.com --field number
# 111735270
cast block safe      --rpc-url https://rpc.mainnet.chain.robinhood.com --field number
# 111727515
cast block finalized --rpc-url https://rpc.mainnet.chain.robinhood.com --field number
# 111723654
```

Both `safe` and `finalized` are served. Converted to wall-clock time from the
timestamps of the same three blocks, with the block time measured over a
10,000-block span:

| Tag | Lag in blocks | Lag in time |
|---|---|---|
| `safe` | 7,755 | 13.3 min |
| `finalized` | 11,616 | 20.1 min |

Block time is **0.104 s**, so roughly ten blocks a second.

The consequence for the read side, and the reason this measurement exists:
**there is no confirmation depth that is both safe and usable.** An indexer
following `finalized` shows a price twenty minutes stale, which is unusable for
a trading interface on a curve whose whole lifetime may be hours. One following
`latest` is exposed to reorgs. So the answer is not a depth: the indexer follows
`latest` and every handler is written to be reorg-safe — each row a pure function
of the canonical log set, no handler storing the result of an `eth_call`, and
every handler idempotent. `docs/DATA_MODEL.md` section 7 states those as
requirements and decision 19 of `docs/OPEN_DECISIONS.md` records why a depth was
not chosen.

The lags are also not a safety claim about this chain's finality. They are what
the endpoint reported at one moment; a sequencer or batch-posting change moves
them, and nothing in the protocol depends on them.

## Uniswap v4 — present on BOTH mainnet and testnet

This is the graduation target. The full v4 stack is deployed at the same
addresses on both networks, which means graduation is testable on the public
testnet.

| Contract | Address |
|---|---|
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| PositionDescriptor | `0x9639443158E8C5efa35Bd45287bf2EFfd3D8dC06` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |

Wiring verified on mainnet and testnet:

```
cast call 0x58daec3116aae6D93017bAAea7749052E8a04fA7 "poolManager()(address)" --rpc-url <rpc>
# 0x8366a39CC670B4001A1121B8F6A443A643e40951   (both networks)
cast call 0x58daec3116aae6D93017bAAea7749052E8a04fA7 "permit2()(address)" --rpc-url <mainnet>
# 0x000000000022D473030F116dDEE9F6B43aC78BA3
cast call 0x58daec3116aae6D93017bAAea7749052E8a04fA7 "name()(string)" --rpc-url <mainnet>
# "Uniswap v4 Positions NFT"
```

Two properties matter for Pledrin:

1. v4 supports **native ETH as a pool currency** (`currency0 = address(0)`), so
   graduation needs no WETH wrapping step.
2. v4 liquidity positions minted through PositionManager are **ERC-721 tokens**,
   so a position can be transferred to a lock contract and made permanent.

### v4 governance surface

Neither value is referenced by any Pledrin contract. Both are recorded so the
external governance exposure in `docs/THREAT_MODEL.md` section 9 is auditable
against a named source rather than an assertion.

| | Mainnet 4663 | Testnet 46630 |
|---|---|---|
| `PoolManager.protocolFeeController()` | `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` | `0x0000000000000000000000000000000000000000` |
| `PoolManager.owner()` | `0x2BAD8182C09F50c8318d769245beA52C32Be46CD` | `0x9701fb0aDe1E269c8f64Ec0C7b3cfADB31A13A52` |

```
cast call 0x8366a39CC670B4001A1121B8F6A443A643e40951 "protocolFeeController()(address)" --rpc-url <rpc>
cast call 0x8366a39CC670B4001A1121B8F6A443A643e40951 "owner()(address)" --rpc-url <rpc>
```

A protocol fee on a v4 pool is set by the controller and is capped by the
protocol at a fraction of the pool's swap fee. It reduces what a locked
position earns; it cannot touch the position itself. The mainnet controller is
live, so Pledrin's locked positions are exposed to a Uniswap governance
decision on fee switching, and nothing in Pledrin can or should prevent that.

## Uniswap v3 — mainnet only

| Contract | Address |
|---|---|
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` |
| TickLens | `0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468` |
| UniswapInterfaceMulticall | `0x282A3C4D320Cc7f0d5eaf56B8029e4B88338f0a3` |
| NonfungibleTokenPositionDescriptor | `0x6F84dAE9c064ff453E5C8af51EfB819f8f610225` |
| NFTDescriptor | `0x2E9D45Bb7b30549F5216813aDA9a6b7982C5B3ED` |

Factory identity confirmed by its canonical fee tiers:

```
cast call <factory> "feeAmountTickSpacing(uint24)(int24)" 100 500 3000 10000
# 1, 10, 60, 200
```

`NonfungiblePositionManager`, `SwapRouter02` and `QuoterV2` all return this
factory from `factory()`.

**None of these v3 addresses have any code on testnet 46630.** Choosing v3 as
the graduation venue would make graduation impossible to test on the public
testnet.

### Wrapped native (v3 only)

```
cast call 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3 "WETH9()(address)" --rpc-url <mainnet>
# 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
```

`name()` = "WETH", `symbol()` = "WETH", `decimals()` = 18. This address has **no
code on testnet**; the testnet wrapped-native address is still unknown and is an
open question. v4 with native ETH avoids needing it at all.

## Uniswap v2 — mainnet only

| Contract | Address |
|---|---|
| UniswapV2Factory | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |

`allPairsLength()` returned 147953, so v2 is live and heavily used on mainnet.
No code on testnet.

## Not verified / do not use yet

- Testnet wrapped-native address.
- Testnet faucet endpoint.
- Any Uniswap "Liquidity Launchpad" contracts: not yet confirmed for this chain.
- The `UniversalRouter 2.1.2` address `0x204FAca1764B154221e35c0d20aBb3c525710498`
  appears in the Uniswap swapping-API docs and has code on mainnet but **none on
  testnet**. The v3/v4 docs list `0x8876...0904` instead, which is on both. Use
  `0x8876...0904`.
