# Boba d-01 PoC — LayerZero bridge bricked by empty adapter params (ULNv301)

Every Boba LayerZero bridge forces empty adapter params
(`useCustomAdapterParams == false`, enforced by
`require(_adapterParams.length == 0)` in `EthBridge` and
`AltL1Bridge`). On 2026-08-04 LayerZero switched the Endpoint v1
default message library from ULNv2 to ULNv301, and ULNv301 rejects
empty options with `LZ_ULN_InvalidWorkerOptions(0)`. LayerZero
announced this on 2026-08-07 and told applications to set
`useCustomAdapterParams` to true and set a minimum destination gas.
Boba never applied that fix.

Result: 7 of the 8 bridge directions revert on every call. About
4,774,305 BOBA (roughly $67,000-$86,000) is frozen: holders of BSC,
Avalanche and Fantom BOBA cannot bridge back to Ethereum, and the
matching BOBA locked in the Ethereum bridges can never be released.
Only Moonbeam withdrawals still work (its endpoint still runs the old
ULNv2 library), and that route breaks on 2026-12-15 when LayerZero
deprecates the ULNv2 relayer.

## Run

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).
Each test contract runs against its own chain fork, so each needs its
own `--fork-url` and `--fork-block-number`. All 9 tests pass.

```sh
forge install foundry-rs/forge-std

# BSC withdrawals (block 134081699)
forge test --fork-url https://bsc.publicnode.com \
  --fork-block-number 134081699 --match-contract BscWithdrawTest

# ETH deposits (block 26433408)
forge test --fork-url https://eth-mainnet.public.blastapi.io \
  --fork-block-number 26433408 --match-contract EthDepositTest

# Avalanche withdrawals (block 100546228)
forge test --fork-url https://api.avax.network/ext/bc/C/rpc \
  --fork-block-number 100546228 --match-contract AvaxWithdrawTest

# Fantom withdrawals (block 124098365)
forge test --fork-url https://fantom.drpc.org \
  --fork-block-number 124098365 --match-contract FantomWithdrawTest

# Moonbeam withdrawals, control case (block 16796699)
forge test --fork-url https://moonbeam.api.onfinality.io/public \
  --fork-block-number 16796699 --match-contract MoonbeamWithdrawTest
```

Expected result: the revert tests assert the exact error
`LZ_ULN_InvalidWorkerOptions(0)` and assert the frozen balances
(BSC total supply 4,126,452 BOBA, same amount locked in the Ethereum
BNB bridge). The fix tests prove the root cause: after the owner calls
`setUseCustomAdapterParams(true, 200000)`, the same withdrawal or
deposit with proper V1 adapter params succeeds. The Moonbeam control
test passes with empty params, because that endpoint still runs ULNv2.

## Notes

- The BSC fork needs an archive-capable endpoint. The default
  `bsc-dataseed.binance.org` prunes state and fails with
  "missing trie node"; `bsc.publicnode.com` works.
- The Fantom test attaches 25 FTM (the quoted fee is about 20 FTM)
  and the Moonbeam test attaches 300 GLMR (quoted fee about 262
  GLMR). With smaller amounts the calls revert for insufficient
  fees, which is a different error.
- The "owner fix" tests use `vm.prank(owner)` only to prove the
  root cause and the fix. No privileged account is needed for the
  revert assertions, which are the actual proof of the outage.

## Files

- `test/BrickedBridge.t.sol`: 9 tests in 5 contracts, one per chain.
- `foundry.toml`: solc 0.8.28, cancun. No pinned fork in the config
  because each contract needs its own chain and block.
