# Verified chain facts

Every address and parameter here was verified directly against the chain with
`cast` on 2026-11-11, and cross-checked against the official Uniswap deployment
pages. Nothing in this file is from memory.

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

## Uniswap v4 — present on BOTH mainnet and testnet

This is the graduation target. The full v4 stack is deployed at the same
addresses on both networks, which means graduation is testable on the public
testnet.

| Contract | Address |
|---|---|
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |
| PositionDescriptor | `0x9639443158e8c5efa35bd45287bf2effd3d8dc06` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| UniversalRouter | `0x8876789976decbfcbbbe364623c63652db8c0904` |

Wiring verified on mainnet and testnet:

```
cast call 0x58daec3116aae6d93017baaea7749052e8a04fa7 "poolManager()(address)" --rpc-url <rpc>
# 0x8366a39CC670B4001A1121B8F6A443A643e40951   (both networks)
cast call 0x58daec3116aae6d93017baaea7749052e8a04fa7 "permit2()(address)" --rpc-url <mainnet>
# 0x000000000022D473030F116dDEE9F6B43aC78BA3
cast call 0x58daec3116aae6d93017baaea7749052e8a04fa7 "name()(string)" --rpc-url <mainnet>
# "Uniswap v4 Positions NFT"
```

Two properties matter for Pledrin:

1. v4 supports **native ETH as a pool currency** (`currency0 = address(0)`), so
   graduation needs no WETH wrapping step.
2. v4 liquidity positions minted through PositionManager are **ERC-721 tokens**,
   so a position can be transferred to a lock contract and made permanent.

## Uniswap v3 — mainnet only

| Contract | Address |
|---|---|
| UniswapV3Factory | `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` |
| NonfungiblePositionManager | `0x73991a25c818bf1f1128deaab1492d45638de0d3` |
| SwapRouter02 | `0xcaf681a66d020601342297493863e78c959e5cb2` |
| QuoterV2 | `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` |
| TickLens | `0x7dfd4f31be6814d2906bde155c3e1b146eac1468` |
| UniswapInterfaceMulticall | `0x282a3c4d320cc7f0d5eaf56b8029e4b88338f0a3` |
| NonfungibleTokenPositionDescriptor | `0x6f84dae9c064ff453e5c8af51efb819f8f610225` |
| NFTDescriptor | `0x2e9d45bb7b30549f5216813ada9a6b7982c5b3ed` |

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
cast call 0x73991a25c818bf1f1128deaab1492d45638de0d3 "WETH9()(address)" --rpc-url <mainnet>
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
