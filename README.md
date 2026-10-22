# Liar's Game

**The question:** how do you enforce fair exchange between two parties without a referee?

This repository is a design, an implementation and a write-up of how far one answer got and where it
breaks. There is no arbiter, no oracle and no verification of who is telling the truth. The contract
settles disputes with bonds and a clock.

## Deployment (Sepolia testnet)

| | |
|---|---|
| **Network** | Sepolia (chain ID `11155111`) |
| **Contract** | [`0x6F6cc27ACDFf5b6Ae9F42611e85621E31B598CA9`](https://sepolia.etherscan.io/address/0x6F6cc27ACDFf5b6Ae9F42611e85621E31B598CA9) (source verified) |
| **Compiler** | Solidity 0.8.24 |

### Approved tokens

Escrows can only be created with a token the owner has whitelisted. The following tokens are approved:

| Token | Address |
|---|---|
| USDC | [`0x1c7d4b196cb0c7b01d743fbc6116a902379c7238`](https://sepolia.etherscan.io/address/0x1c7d4b196cb0c7b01d743fbc6116a902379c7238) |
| WETH | [`0xfff9976782d46cc05630d1f6ebab18b2324d6b14`](https://sepolia.etherscan.io/address/0xfff9976782d46cc05630d1f6ebab18b2324d6b14) |

**Native ETH is not supported.** The contract moves funds with ERC20 `transferFrom`, has no `payable`
functions, and rejects the zero address as a token. To escrow ETH, wrap it into WETH first.

Tokens must be plain ERC20s: no fee-on-transfer, no rebasing. The owner can add or remove tokens with
`addApprovedToken` and `removeApprovedToken`. Removing a token does not affect existing escrows or
withdrawals.

### Protocol parameters

All parameters are constants in `src/Liars_Game.sol`. Changing one means redeploying.

| Parameter | Value |
|---|---|
| Protocol fee | 2% (`PROTOCOL_FEE_BPS = 200`) |
| Fee split | 70% integrator, 30% treasury |
| Seller bond share | 50% of each nominal bond (`SELLER_BOND_BPS = 5000`) |
| Evaluation window | 1 hour to 90 days |
| Settlement overwrite window | 2 hours |
| Escalation open window | 1 day |
| Turn deadline | 1 day |
| Event horizon | turn 5 |

### Using the deployed contract

1. **Buyer** approves the contract to spend the token, then calls
   `createEscrow(seller, integrator, token, amount, evaluationWindow, lifetimeDuration)`.
   `lifetimeDuration` is an absolute timestamp, not an offset.
2. **Seller** calls `submitWork(escrowId, workPointer)`.
3. **Buyer** calls `settlePartial(escrowId, alphaBps)` during the evaluation window to set the settlement
   share. It can be overwritten until the 2-hour settlement window closes. If the buyer stays silent past
   the evaluation deadline, the **seller** calls `claimDefault` and is paid in full, minus the fee.
4. Once the settlement window closes, the **buyer or seller** finalizes with `finalizeSettlementFull`,
   `finalizeSettlementPartial` or `finalizeSettlementRejected`.
5. If part of the amount is contested, either party calls `openDispute` within the escalation window and
   posts the first bond. The parties then alternate with `advanceTurn`. A party can `fold`. If nobody opens
   a dispute in time, `claimEscalationTimeout` refunds the contested amount to the buyer. If a turn deadline
   lapses, `claimTurnTimeout` resolves the dispute in favor of the last actor.
6. Everyone collects what they are owed with `withdraw(token)`.

Before the seller submits any work, the buyer can `cancelEscrow` for a full refund.

## 1. The design

An escrow for digital goods, in three parts.

- **Settlement phase.** The buyer locks the amount, the seller submits a pointer to the delivered work,
  and the buyer sets a settlement share `alphaBps`: `10000` pays the seller in full, `1`–`9999` pays a
  share and contests the rest, `0` contests everything. If the buyer stays silent, the seller claims in full.
- **Bond escalation.** Either party can open a dispute by posting a bond. Parties then alternate, each
  posting a larger bond, and a party can fold or lose by missing its turn deadline. The last actor wins; the
  loser's collateral goes to the treasury. Nominal bonds are 0.5%, 2%, 6%, 15%, 35%, then +20% of the
  contested amount per turn. The seller posts `SELLER_BOND_BPS` (50%) of each nominal bond.
- **The horizon.** Up to turn 5 the winner recovers all their own collateral. After that, recovery is capped
  (41.5% of the contested amount as challenger, 17% as defender; the seller's caps are scaled by its bond
  share) and the rest goes to the treasury. So very long disputes cost the winner too.

Everything is paid out through a single pull-payment `withdraw`.


## 2. What the seller discount changes, and what no setting can fix

The seller discount makes contesting cheaper for the seller. The capital a seller needs scales linearly with
it. The equilibrium path and payoffs do not change.

| Seller bond share | 100% (none) | 40% | **50% (deployed)** | 60% |
|---|---|---|---|---|
| Seller's cost to open | 0.50% | 0.20% | **0.25%** | 0.30% |
| Capital needed to contest | 2.315× | 0.926× | **1.158×** | 1.389× |

It lowers the barrier for every seller, honest or not. No setting changes the underlying limit: without
something that can verify the truth, bonds can price a dispute but cannot decide it.

## Run it

Requires [Foundry](https://book.getfoundry.sh/) (solc 0.8.24) and the OpenZeppelin contracts.

```bash
forge build
forge test                                   # all tests
forge test -vvv                              # traces for failures
forge test --match-contract LiarsGame_Invariant
forge test --fuzz-runs 5000                  # harder fuzzing
```

### Compiler settings

`foundry.toml` enables the optimizer (`optimizer_runs = 200`) and `via_ir`. Without them the contract
compiles to about 25.4 KB, which is over Ethereum's 24,576-byte deployment limit. Check the size with
`forge build --sizes`.

The contract imports OpenZeppelin, so Etherscan's single-file verification will not resolve the imports.
Verify with `forge verify-contract`, upload a Standard-Json-Input, or flatten first with
`forge flatten src/Liars_Game.sol -o flat.sol`.

### Analysis (Python 3, no dependencies)

```bash
python3 script/horizon_analysis.py                          # deployed settings
python3 script/horizon_analysis.py --capital-threshold      # capital a seller needs
python3 script/horizon_analysis.py --seller-bond-bps 10000  # no seller discount
```

The script mirrors the contract by hand and does not read it. All options, how to read the output and its
modelling assumptions are in [`script/README.md`](script/README.md).

## Layout

```
src/Liars_Game.sol           the contract
test/Liars_Game.t.sol        unit, fuzz and invariant tests
script/horizon_analysis.py   analysis of the escalation game
script/README.md             how to use the model
```

## License

[MIT](LICENSE) © 2026 Mayowa Akande