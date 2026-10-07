#!/usr/bin/env python3
"""
Section 5.2 helper: stopping-point analysis for the Liar's Game bond-escalation dispute.

Mirrors the contract exactly:
  - bond(n)      = delta * turn_bps(n) // 10000           (_calculateTurnBond)
                   seller turns only: bond = bond * SELLER_BOND_BPS // 10000
                   (default 5000 = the deployed constant; 10000 reproduces the undiscounted design)
  - turn_bps     = 50, 200, 600, 1500, then 3500 + (n-5)*2000 (_getTurnBps)
  - winner       = actor of the last turn played (fold / turn timeout)
  - routing      : loser's collateral -> treasury
                   n <= horizon : winner recovers all own collateral
                   n >  horizon : winner recovers min(cap * delta, own collateral)
                                  cap = 4150 bps if n is odd (challenger), 1700 bps if even
                                  (the seller's cap is scaled by SELLER_BOND_BPS too)
                   remainder    -> treasury
  - outcome of delta: seller wins -> delta - fee ; buyer wins -> delta refunded in full
  - fee          = ceil(delta * fee_bps / 10000), treasury_cut = ceil(fee * share / 10000)

Payoffs are measured against the NO-DISPUTE baseline (buyer gets delta back, seller gets 0),
so every number is "what the dispute adds or costs a party".

Modelling choices (change them here if the paper needs different ones):
  - Turn 1 is the opener's choice to open or not. Not opening = escalation timeout = baseline.
  - On every later turn the mover chooses: post the next bond, or fold (loser forfeits all).
  - Backward induction on a game truncated at --n-max turns (the mover at n-max+1 must fold).
    The script reruns with larger caps and warns if the result depends on the cap.
  - Optional per-party capital budgets (in multiples of delta) model "whale vs shrimp".
  - Ties (a player gets exactly the same payoff from two choices) are resolved toward
    folding / not opening unless --tie-posts is set. This only matters when the buyer is the opener.
  - Value of the data: the buyer consumes the data on delivery, so its value V is the same
    whether the buyer wins or loses the dispute. V therefore shifts the buyer's absolute payoff
    but cannot change any decision inside the escalation game. The "Ex-post payoffs" section
    shows what the parties end up with in Game 1 (honest exchange), Game 2 (invalid data)
    and Game 3 (valid data, false rejection). Assumes the whole escrow is contested (alpha = 0),
    so delta = E. --seller-cost is the seller's sunk cost of producing the data.

Defaults for --fee-bps, --treasury-share-bps and --seller-bond-bps are the deployed contract
constants (200 / 3000 / 5000). --capital-threshold finds the smallest seller budget (in multiples
of delta) at which a dispute is opened against an unlimited-capital buyer.

Usage (run from the repo root, Python 3.8+, no packages needed except matplotlib for --plot):
  python3 scripts/horizon_analysis.py
  python3 scripts/horizon_analysis.py --opener buyer
  python3 scripts/horizon_analysis.py --seller-bond-bps 10000        # undiscounted baseline
  python3 scripts/horizon_analysis.py --capital-threshold
  python3 scripts/horizon_analysis.py --data-value 2 --seller-cost 0.1
  python3 scripts/horizon_analysis.py --budget-buyer 2.0 --budget-seller 0.05
  python3 scripts/horizon_analysis.py --csv out.csv --plot out.png
"""
import argparse
import copy
import csv
import sys

BPS = 10_000
# Bond schedule. Defaults are the contract's _getTurnBps: turns 1-4 fixed, then START + (n-5)*STEP.
# Change it with configure_schedule() or the --fixed-bps / --start-bps / --step-bps options.
SCHEDULE = {"fixed": [50, 200, 600, 1500], "start": 3500, "step": 2000}


def configure_schedule(fixed, start, step):
    SCHEDULE["fixed"] = list(fixed)
    SCHEDULE["start"] = start
    SCHEDULE["step"] = step


def turn_bps(n: int) -> int:
    if n < 1:
        raise ValueError("turn must be >= 1")
    fixed = SCHEDULE["fixed"]
    if n <= len(fixed):
        return fixed[n - 1]
    return SCHEDULE["start"] + (n - len(fixed) - 1) * SCHEDULE["step"]


def default_caps(horizon: int):
    """Cumulative bps of the turns up to the horizon: challenger = odd turns, defender = even turns.
    For the contract schedule and horizon 5 this gives 4150 and 1700."""
    c = sum(turn_bps(n) for n in range(1, horizon + 1) if n % 2 == 1)
    d = sum(turn_bps(n) for n in range(1, horizon + 1) if n % 2 == 0)
    return c, d


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def other(p: str) -> str:
    return "buyer" if p == "seller" else "seller"


class Model:
    def __init__(self, a):
        self.delta = a.delta
        self.horizon = a.horizon
        self.cap_c = a.cap_challenger
        self.cap_d = a.cap_defender
        self.seller_bps = getattr(a, "seller_bond_bps", BPS)
        self.opener = a.opener
        self.tie_folds = not a.tie_posts
        self.budget = {"buyer": a.budget_buyer, "seller": a.budget_seller}
        self.fee = ceil_div(self.delta * a.fee_bps, BPS)
        self.tcut = ceil_div(self.fee * a.treasury_share_bps, BPS)
        assert self.fee <= self.delta and self.tcut <= self.fee

    # ---- schedule -------------------------------------------------------
    def bond(self, n: int) -> int:
        b = self.delta * turn_bps(n) // BPS
        if self.actor(n) == "seller":
            b = b * self.seller_bps // BPS   # seller posts a fraction of the nominal bond
        return b

    def actor(self, n: int) -> str:
        return self.opener if n % 2 == 1 else other(self.opener)

    def deposits(self, player: str, n: int) -> int:
        return sum(self.bond(k) for k in range(1, n + 1) if self.actor(k) == player)

    # ---- payoff when the game ends with the last actor of turn n winning ---
    def terminal(self, n: int) -> dict:
        if n == 0:
            return dict(buyer=0, seller=0, treasury=0, integrator=0, winner=None, end=0)
        winner = self.actor(n)
        loser = other(winner)
        d_w = self.deposits(winner, n)
        d_l = self.deposits(loser, n)
        if n <= self.horizon:
            recovered = d_w
        else:
            cap = (self.cap_c if n % 2 == 1 else self.cap_d) * self.delta // BPS
            if winner == "seller":
                cap = cap * self.seller_bps // BPS   # the seller's recovery cap scales with its bond
            recovered = min(cap, d_w)
        remainder = d_w - recovered

        if winner == "seller":
            pay_s = self.delta - self.fee + recovered - d_w
            pay_b = -self.delta - d_l
            treasury = d_l + remainder + self.tcut
            integrator = self.fee - self.tcut
        else:
            pay_b = recovered - d_w
            pay_s = -d_l
            treasury = d_l + remainder
            integrator = 0

        # value conservation: nothing created or destroyed
        assert pay_b + pay_s + treasury + integrator == 0, "conservation broken"
        return dict(buyer=pay_b, seller=pay_s, treasury=treasury,
                    integrator=integrator, winner=winner, end=n)

    # ---- backward induction -------------------------------------------------
    def _can_afford(self, player: str, n: int) -> bool:
        return self.deposits(player, n) <= self.budget[player] * self.delta

    def solve(self, n_max: int) -> dict:
        node = {n_max + 1: self.terminal(n_max)}  # mover at n_max+1 is forced to fold
        for n in range(n_max, 1, -1):
            mover = self.actor(n)
            fold = self.terminal(n - 1)
            post = node[n + 1]
            better = post[mover] > fold[mover] or (post[mover] == fold[mover] and not self.tie_folds)
            node[n] = post if (better and self._can_afford(mover, n)) else fold
        opener = self.actor(1)
        opened, baseline = node[2], self.terminal(0)
        better = opened[opener] > baseline[opener] or (
            opened[opener] == baseline[opener] and not self.tie_folds)
        return opened if (better and self._can_afford(opener, 1)) else baseline

    # ---- per-turn table -----------------------------------------------------
    def table(self, turns: int):
        rows = []
        for n in range(1, turns + 1):
            mover = self.actor(n)
            win = self.terminal(n)[mover]          # opponent folds right after my turn n
            stop = self.terminal(n - 1)[mover]     # I fold instead of posting turn n
            rows.append(dict(
                turn=n, mover=mover,
                bond_bps=turn_bps(n),
                bond_pct=self.bond(n) / self.delta * 100,
                cum_deposit_pct=self.deposits(mover, n) / self.delta * 100,
                win_if_opponent_folds_pct=win / self.delta * 100,
                payoff_if_i_fold_pct=stop / self.delta * 100,
                best_case_gain_from_posting_pct=(win - stop) / self.delta * 100,
                posting_dominated=(win < stop),
                post_horizon=(n > self.horizon),
            ))
        return rows


def scenarios(a, m):
    """Ex-post absolute payoffs (as % of delta) for Games 1-3. The seller is the party who
    contests a rejection, so the contested games are solved with the seller as opener."""
    d = m.delta
    V = a.data_value * d
    c = a.seller_cost * d
    a_s = copy.copy(a)
    a_s.opener = "seller"
    ms = Model(a_s)
    res = ms.solve(a.n_max)
    contested = res["end"] != 0

    def row(name, buyer, seller, treasury, integrator):
        f = lambda x: f"{x / d * 100:9.2f}%"
        print(f"  {name:<52}{f(buyer)}{f(seller)}{f(treasury)}{f(integrator)}")

    print(f"\nEx-post payoffs, % of delta (data value V = {a.data_value}x delta, seller cost = {a.seller_cost}x delta)")
    print(f"  {'':<52}{'buyer':>10}{'seller':>10}{'treasury':>10}{'integr.':>10}")
    row("Game 1: valid data, buyer pays (no dispute)", V - d, d - m.fee - c, m.tcut, m.fee - m.tcut)
    if contested:
        row("Game 2: invalid data, buyer rejects, seller contests", 0 + res["buyer"], res["seller"] - c,
            res["treasury"], res["integrator"])
        row("Game 3: valid data, buyer rejects, seller contests", V + res["buyer"], res["seller"] - c,
            res["treasury"], res["integrator"])
    else:
        print("  (the seller does not find it worthwhile to contest; see the no-contest rows)")
    row("Game 2, seller does NOT contest in time", 0, 0 - c, 0, 0)
    row("Game 3, seller does NOT contest in time", V, 0 - c, 0, 0)

    g1_buyer = V - d
    g3_buyer = (V + res["buyer"]) if contested else V
    print(f"\n  Gain to a buyer from falsely rejecting valid data:")
    print(f"    if the seller contests:          {(g3_buyer - g1_buyer) / d * 100:8.2f}% of delta")
    print(f"    if the seller does not contest:  {(V - g1_buyer) / d * 100:8.2f}% of delta")
    if contested:
        print(f"  Seller's profit from delivering invalid data, if it contests and wins: "
              f"{(res['seller'] - c) / d * 100:8.2f}% of delta")
    print("  (the escalation game never looks at which party is honest or what the data is worth;")
    print("   only capital, order of play and the clock decide the winner)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--fee-bps", type=int, default=200, help="PROTOCOL_FEE_BPS (default 200)")
    p.add_argument("--treasury-share-bps", type=int, default=3000, help="TREASURY_SHARE_BPS (default 3000)")
    p.add_argument("--data-value", type=float, default=1.5,
                   help="buyer's value of valid data, in multiples of delta (default 1.5)")
    p.add_argument("--seller-cost", type=float, default=0.0,
                   help="seller's sunk cost of producing the data, in multiples of delta (default 0)")
    p.add_argument("--horizon", type=int, default=5, help="EVENT_HORIZON_TURN")
    p.add_argument("--cap-challenger", type=int, default=None,
                   help="horizon recovery cap, challenger, bps of delta (default: cumulative bps of odd turns up to the horizon, 4150)")
    p.add_argument("--cap-defender", type=int, default=None,
                   help="horizon recovery cap, defender, bps of delta (default: cumulative bps of even turns up to the horizon, 1700)")
    p.add_argument("--seller-bond-bps", type=int, default=5000,
                   help="share of each nominal bond the SELLER actually posts, in bps (10000 = 1:1 as in the contract, "
                        "5000 = half). The turn counter, prize and buyer bonds are unchanged.")
    p.add_argument("--fixed-bps", default="50,200,600,1500",
                   help="comma-separated bond bps for the first turns (default: contract schedule)")
    p.add_argument("--start-bps", type=int, default=3500, help="bond bps on the first turn after the fixed ones")
    p.add_argument("--step-bps", type=int, default=2000, help="bps added to the bond each turn after that")
    p.add_argument("--delta", type=int, default=10**18, help="contested amount, integer units")
    p.add_argument("--opener", choices=["buyer", "seller"], default="seller",
                   help="who plays turn 1 (default seller: the party who must contest a rejection)")
    p.add_argument("--n-max", type=int, default=30)
    p.add_argument("--turns-shown", type=int, default=12)
    p.add_argument("--budget-buyer", type=float, default=float("inf"), help="in multiples of delta")
    p.add_argument("--budget-seller", type=float, default=float("inf"), help="in multiples of delta")
    p.add_argument("--capital-threshold", action="store_true",
                   help="also find the minimum seller budget that opens a dispute vs an unlimited buyer")
    p.add_argument("--tie-posts", action="store_true", help="break ties toward posting (default: fold)")
    p.add_argument("--csv", help="write the per-turn table to this CSV")
    p.add_argument("--plot", help="write a PNG plot (needs matplotlib)")
    a = p.parse_args()
    configure_schedule([int(x) for x in a.fixed_bps.split(",")], a.start_bps, a.step_bps)
    dc, dd = default_caps(a.horizon)
    if a.cap_challenger is None:
        a.cap_challenger = dc
    if a.cap_defender is None:
        a.cap_defender = dd

    if not (0 <= a.fee_bps <= BPS and 0 <= a.treasury_share_bps <= BPS):
        sys.exit("fee-bps and treasury-share-bps must be within 0..10000")

    m = Model(a)
    pct = lambda x: f"{x / m.delta * 100:8.2f}%"

    print(f"delta = {m.delta}  fee = {m.fee / m.delta * 100:.4f}% of delta  "
          f"opener = {a.opener}  horizon = {a.horizon}")
    print(f"budgets (x delta): buyer={a.budget_buyer}, seller={a.budget_seller}\n")

    rows = m.table(a.turns_shown)
    hdr = f"{'turn':>4} {'mover':>7} {'bond':>9} {'cum.dep':>9} {'win if opp folds':>17} " \
          f"{'if I fold':>10} {'best-case gain':>15}  note"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        note = []
        if r["post_horizon"]:
            note.append("post-horizon")
        if r["posting_dominated"]:
            note.append("POSTING DOMINATED")
        print(f"{r['turn']:>4} {r['mover']:>7} {r['bond_pct']:8.2f}% {r['cum_deposit_pct']:8.2f}% "
              f"{r['win_if_opponent_folds_pct']:16.2f}% {r['payoff_if_i_fold_pct']:9.2f}% "
              f"{r['best_case_gain_from_posting_pct']:14.2f}%  {', '.join(note)}")

    print("\nFirst turn where posting is dominated even in the best case (opponent folds at once):")
    for who in ("buyer", "seller"):
        first = next((r["turn"] for r in m.table(a.n_max) if r["mover"] == who and r["posting_dominated"]), None)
        print(f"  {who:>6}: {first if first else f'none within {a.n_max} turns'}")

    print("\nSubgame-perfect outcome (backward induction):")
    results = {}
    for cap in (a.n_max, a.n_max + 1, a.n_max + 2, a.n_max + 3):
        results[cap] = m.solve(cap)
    r = results[a.n_max]
    if r["end"] == 0:
        print("  The opener does not open a dispute (escalation timeout, buyer refunded delta).")
    else:
        print(f"  Game ends at turn {r['end']}, winner = {r['winner']}")
    print(f"  buyer    {pct(r['buyer'])} of delta")
    print(f"  seller   {pct(r['seller'])} of delta")
    print(f"  treasury {pct(r['treasury'])} of delta")
    print(f"  integr.  {pct(r['integrator'])} of delta")
    ends = {c: res["end"] for c, res in results.items()}
    if len(set(ends.values())) > 1 or r["end"] >= a.n_max - 3:
        print(f"\n  WARNING: result depends on the truncation cap {ends}; raise --n-max.")
    else:
        print(f"  (stable across caps {list(ends)}: end turn {r['end']})")

    scenarios(a, m)

    if a.capital_threshold:
        lo, hi = 0.0, 50.0
        for _ in range(60):
            mid = (lo + hi) / 2
            b = copy.copy(a); b.opener = "seller"; b.budget_seller = mid; b.budget_buyer = float("inf")
            if Model(b).solve(a.n_max)["end"] == 0:
                lo = mid
            else:
                hi = mid
        b = copy.copy(a); b.opener = "seller"; b.budget_seller = float("inf"); b.budget_buyer = float("inf")
        mm = Model(b)
        buyer_stop = next((r["turn"] for r in mm.table(a.n_max) if r["mover"] == "buyer" and r["posting_dominated"]), None)
        print("\nCapital threshold (unlimited-capital buyer):")
        print(f"  minimum seller budget to contest: {hi:.3f} x delta")
        if buyer_stop:
            need = mm.deposits("seller", buyer_stop - 1) / mm.delta
            print(f"  buyer's posting is dominated at turn {buyer_stop}; the seller's cumulative deposits "
                  f"through turn {buyer_stop - 1} = {need:.3f} x delta")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(m.table(a.n_max))
        print(f"\nwrote {a.csv}")

    if a.plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            sys.exit("matplotlib not installed: pip install matplotlib")
        t = m.table(a.turns_shown)
        fig, ax = plt.subplots(figsize=(7, 4))
        for who, style in (("buyer", "o-"), ("seller", "s--")):
            xs = [r["turn"] for r in t if r["mover"] == who]
            ys = [r["best_case_gain_from_posting_pct"] for r in t if r["mover"] == who]
            ax.plot(xs, ys, style, label=f"{who} (best-case gain from posting)")
        ax.axhline(0, color="black", linewidth=0.8)
        ax.axvline(a.horizon + 0.5, color="grey", linestyle=":", label="event horizon")
        ax.set_xlabel("turn")
        ax.set_ylabel("% of delta")
        ax.legend()
        fig.tight_layout()
        fig.savefig(a.plot, dpi=200)
        print(f"wrote {a.plot}")


if __name__ == "__main__":
    main()
