# Liar's Game

**The question:** how do you enforce fair exchange between two parties without a referee?

This repository is a design, an implementation and a write-up of how far one answer got and where it
breaks. There is no arbiter, no oracle and no verification of who is telling the truth. The contract
settles disputes with bonds and a clock.

> **Status: experimental and unaudited.**

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

Everything is paid out through a single pull-payment `withdraw`. All parameters are constants in
`src/Liars_Game.sol`; changing one means redeploying.

## 2. What held

- **Solvency:** the contract's token balance always equals locked amounts plus credited balances.
- **Conservation:** fee splits and payouts always sum to the amount; nothing is created or destroyed.
- **Terminal escrows hold nothing**, no stage can be skipped, and withdrawals are reentrancy-safe.
- **The horizon cap:** a winner never recovers more than the cap past the horizon.

These are checked with unit, fuzz and invariant tests. Writing them found real bugs, including a
horizon measured in the wrong unit, an uncapped recovery that could make the contract insolvent, and a
rejection path (`alphaBps = 0`) that was unreachable.

## 3. Where it breaks, and why

- **Capital decides.** The contested game unravels to its first move: the seller opens, the buyer folds, and the
  seller ends at +98% of the contested amount. A seller needs roughly **1.16×** the contested amount in capital to
  contest a buyer with unlimited funds. Below that, no dispute opens and the buyer is refunded.
- **Truth doesn't enter.** Valid or invalid data produce the same escalation path, because the contract never sees
  which party is honest. A seller who delivered bad data can profit from contesting just as an honest one can.
- **The false-rejection gap.** A buyer who falsely rejects valid data gains **nothing** if the seller contests
  and **the full contested amount** if the seller doesn't respond in time. False rejection isn't punished; it
  only risks the seller responding.
- **Other limits.** There is no turn cap, so a long dispute can outlast the escrow's lifetime, and the treasury
  earns more from longer disputes. Whitelisted tokens must be plain ERC20s (no fee-on-transfer, no rebasing).

## 4. What the seller discount changes, and what no setting can fix

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
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test                                   # all tests
forge test -vvv                              # traces for failures
forge test --match-contract LiarsGame_Invariant
forge test --fuzz-runs 5000                  # harder fuzzing
```

### Game-theory model (Python 3, no dependencies)

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
script/horizon_analysis.py  game-theory model of the escalation game
script/README.md            how to use the model
```

## License

[MIT](LICENSE) © 2026 Mayowa Akande