# Horizon analysis script

`script/horizon_analysis.py` is a model of the escalation game. It answers one question:

> Given the bond schedule, the horizon, the fee and the seller discount, at which turn does it stop
> being worth it to keep playing, who ends up with what, and how much capital does each side need?

It supports the analysis in the write-up and helps choose `SELLER_BOND_BPS`. It is **not** a
test of the contract and it does not read the contract. It mirrors the contract's rules by hand, so
if you change the contract, change the script's parameters too.

## Requirements

Python 3.8 or later. No packages are needed. `matplotlib` is needed only for `--plot`.

```bash
python3 script/horizon_analysis.py            # run from the repository root
```

With no arguments, every default is the deployed constant: fee 200 bps, treasury share 3000 bps,
horizon 5, seller bond share 5000 bps, the contract's bond schedule, the seller as the opener,
and unlimited capital for both sides.

## What the model does

- **Mirrors the contract.** Bond schedule, seller scaling, event horizon, capped recovery, winner =
  last actor, loser's collateral to the treasury, ceil-rounded fee split. Value conservation is
  asserted: nothing is created or destroyed.
- **Backward induction.** Starting from a game truncated at `--n-max` turns, the mover at each turn
  chooses between posting the next bond and folding. The solution is the subgame-perfect outcome.
  The script re-solves with larger caps and warns if the answer depends on the cap.
- **Baseline.** Payoffs are measured against the no-dispute outcome (the buyer gets `δ` back, the seller
  gets 0), so every number is "what the dispute adds or costs a party", in percent of `δ`.
- **Turn 1 is a choice.** The opener decides whether to open. Not opening is the escalation-timeout
  outcome, which equals the baseline.

## Reading the output

A default run prints four blocks.

**1. Per-turn table**

```
turn   mover      bond   cum.dep  win if opp folds  if I fold  best-case gain  note
   1  seller     0.25%     0.25%            98.00%      0.00%          98.00%
   9  seller    57.50%   115.75%             3.00%    -58.25%          61.25%  post-horizon
  10   buyer   135.00%   302.00%          -285.00%   -267.00%         -18.00%  post-horizon, POSTING DOMINATED
```

| Column | Meaning |
|---|---|
| `bond` | What the mover deposits on this turn (already seller-scaled), as % of `δ`. |
| `cum.dep` | The mover's cumulative deposits through this turn. |
| `win if opp folds` | The mover's payoff if the opponent folds immediately after this turn. |
| `if I fold` | The mover's payoff if they fold instead of posting this turn. |
| `best-case gain` | The difference between the two columns above. |
| `note` | `post-horizon` when the turn is past the horizon. `POSTING DOMINATED` when the best-case gain is negative. |

**2. The two stopping thresholds.** Do not mix them up.

1. **Winning is net-negative.** The first turn where `win if opp folds` is below zero. Even a
   guaranteed win loses money relative to not disputing at all.
2. **Posting is dominated.** The first turn where `best-case gain` is below zero. Posting loses to
   folding even if the opponent folds at once. The script prints this for each side after the table.

**3. The subgame-perfect outcome.** The end turn, the winner, and the final payoffs of the buyer, the seller, the
treasury and the integrator. With the default settings the game ends at turn 1: the seller opens, the buyer
folds, and the payoffs are buyer −100%, seller +98%, treasury +0.6%, integrator +1.4%. A line
confirms the result is stable across truncation caps.

**4. Ex-post payoffs for the three scenarios** (see `--data-value` and `--seller-cost`):

| Scenario | Meaning |
|---|---|
| Game 1 | Valid data, the buyer pays, no dispute. |
| Game 2 | Invalid data, the buyer rejects, the seller contests. |
| Game 3 | Valid data, the buyer falsely rejects, the seller contests. |
| "does NOT contest in time" | Game 2 and Game 3 when the seller lets the escalation window lapse. |

It also prints the buyer's gain from falsely rejecting valid data, and the seller's profit from
delivering invalid data. The key result: the escalation game never looks at which party is honest or
what the data is worth, so truth and data value cannot change any decision.

## Options

| Option | Default | Purpose |
|---|---|---|
| `--fee-bps` | 200 | `PROTOCOL_FEE_BPS`. |
| `--treasury-share-bps` | 3000 | `TREASURY_SHARE_BPS`. |
| `--seller-bond-bps` | 5000 | `SELLER_BOND_BPS`. Use `10000` for the undiscounted baseline. |
| `--horizon` | 5 | `EVENT_HORIZON_TURN`. |
| `--cap-challenger`, `--cap-defender` | derived (4150, 1700) | Horizon recovery caps, in bps of `δ`. By default, the cumulative bps of the odd or even turns up to the horizon. |
| `--fixed-bps` | `50,200,600,1500` | Comma-separated bond bps for the first turns. |
| `--start-bps`, `--step-bps` | 3500, 2000 | The bond bps on the first turn after the fixed ones, and the increase per turn after that. |
| `--opener` | `seller` | Who plays turn 1 (`seller` or `buyer`). |
| `--budget-buyer`, `--budget-seller` | unlimited | Capital limits, in multiples of `δ`. |
| `--capital-threshold` | off | Find the smallest seller budget that opens a dispute against an unlimited-capital buyer. |
| `--data-value` | 1.5 | The buyer's value of valid data, in multiples of `δ`. Only shifts absolute payoffs. |
| `--seller-cost` | 0 | The seller's sunk cost of producing the data, in multiples of `δ`. |
| `--tie-posts` | off | Break ties toward posting (default: fold or do not open). |
| `--n-max` | 30 | Truncation depth of the game. |
| `--turns-shown` | 12 | Rows in the per-turn table. |
| `--delta` | `10**18` | The contested amount, in integer units. Rarely worth changing. |
| `--csv FILE` | off | Write the per-turn table (up to `--n-max` turns) to a CSV. |
| `--plot FILE` | off | Write a PNG of best-case gain per turn (needs `matplotlib`). |

## Recipes

**Choose the seller bond share.** Compare candidates and read the capital threshold and the stopping turns:

```bash
for s in 4000 5000 6000; do
  echo "=== SELLER_BOND_BPS = $s"
  python3 script/horizon_analysis.py --seller-bond-bps $s --turns-shown 20 --capital-threshold
done
```

The capital threshold is linear: `2.315 × (s / 10000) × δ` for the contract's schedule. A lower `s`
admits poorer sellers and makes disputes cheaper for every seller, honest or not. A higher `s`
narrows the cost gap between the two sides and brings the seller's own stopping point closer.

**Reproduce the undiscounted design** (for comparison):

```bash
python3 script/horizon_analysis.py --seller-bond-bps 10000 --capital-threshold
```

**Whale versus shrimp.** Give each side a different budget (multiples of `δ`):

```bash
python3 script/horizon_analysis.py --budget-buyer 2.0 --budget-seller 0.8
```

If a player cannot afford the next bond, they must fold. A result of "no dispute opens" means the opener
cannot credibly contest.

**Scan the seller's budget** to produce plot data:

```bash
for b in 0.5 1.0 1.1 1.15 1.16 1.2 2.0; do
  printf "budget %s: " $b
  python3 script/horizon_analysis.py --budget-seller $b | grep -E "Game ends|does not open"
done
```

**Buyer as opener.** The default tie rule makes an indifferent buyer not open, so the result is
"no dispute". Compare with ties broken the other way (with the deployed settings both give
"no dispute", which is the check that the tie rule does not drive the result):

```bash
python3 script/horizon_analysis.py --opener buyer
python3 script/horizon_analysis.py --opener buyer --tie-posts
```

**Change the data value or the seller's cost** to fill a payoff table:

```bash
python3 script/horizon_analysis.py --data-value 2 --seller-cost 0.1
```

**Test a different schedule or horizon** before changing the contract:

```bash
python3 script/horizon_analysis.py --horizon 4
python3 script/horizon_analysis.py --fixed-bps 100,300,800,2000 --start-bps 4000 --step-bps 2500
```

**Export for a spreadsheet or a plot:**

```bash
python3 script/horizon_analysis.py --csv out.csv --plot out.png
```

## Keeping the script and the contract in sync

The script is a hand-written mirror of the contract. When a constant or a rule changes, update it in both places:

| Contract | Script |
|---|---|
| `PROTOCOL_FEE_BPS`, `TREASURY_SHARE_BPS` | `--fee-bps`, `--treasury-share-bps` defaults |
| `SELLER_BOND_BPS` | `--seller-bond-bps` default |
| `EVENT_HORIZON_TURN` | `--horizon` default |
| `_getTurnBps` | `--fixed-bps`, `--start-bps`, `--step-bps` defaults |
| `_computeHorizonSplit` caps | `--cap-challenger`, `--cap-defender` (derived by default) |

Sanity checks: the bond for each turn in the table should equal the contract's
`requiredBondFor`, and the sum of every outcome should be zero (the script asserts this).

## Modelling assumptions and what the script does not tell you

State these whenever you quote its numbers.

- Complete information about budgets and payoffs. Risk-neutral players. Gas costs are ignored.
- No repeated play or reputation. Turn 1 is played by the seller in the contested games.
- The buyer consumes the data on delivery, so its value is the same whether the buyer wins or loses the dispute.
- Ties resolve toward not escalating unless `--tie-posts` is set.
- Time costs (the one-day turn window, so a long dispute lasts days) and irrational or griefing
  behaviour are not modelled. Real disputes can run past the stopping point if a player ignores the incentives.
- It models the *incentives to stop*, not truth. The mechanism cannot tell who is honest; the
  script's output makes that visible, and it should not be read as evidence that honest parties win.