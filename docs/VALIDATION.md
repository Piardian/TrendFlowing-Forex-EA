# Validation Notes

## Test design

The repository includes four out-of-sample style checks across two major Forex pairs and two non-overlapping 2024 windows:

- EURUSD M15: 2024-01-01 to 2024-06-30
- EURUSD M15: 2024-06-01 to 2024-12-01
- GBPUSD M15: 2024-01-01 to 2024-06-30
- GBPUSD M15: 2024-06-01 to 2024-12-01

Each profile starts with USD 10,000. The Strategy Tester profiles specify real ticks (`Model=4`). Broker feed, spreads, commissions, and execution assumptions remain material to any interpretation.

## How to interpret the snapshot

The result set is mixed. It shows why a single favorable run is insufficient: performance varied between EURUSD and GBPUSD and between periods. The validation matrix exists to surface this variation early and reduce the temptation to tune a strategy to one selected market window.

## Research limitations

- Historical results do not represent live performance.
- No claim of profitability, Sharpe ratio, or execution quality is made here.
- Further work should include walk-forward tests, spread/commission stress tests, parameter stability checks, and forward paper trading.
- Risk limits are safeguards, not guarantees against loss.
