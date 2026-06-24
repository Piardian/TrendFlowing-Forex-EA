# TrendFlowing Forex EA

TrendFlowing is a modular MetaTrader 5 Expert Advisor for systematic Forex research. It implements a multi-timeframe trend and market-structure workflow, with risk controls, trade management, and repeatable Strategy Tester automation.

> Research software only. This repository is not investment advice and does not guarantee future performance.

## Development approach

This is a Vibe Coding project: the research direction, architecture, risk controls, and validation scope are author-directed, while implementation was developed iteratively with AI-assisted coding tools. The repository is published transparently as a research artifact and remains subject to ongoing testing, review, and refinement.

## What it does

- Detects a higher-timeframe trend using EMA and ADX filters.
- Searches for lower-timeframe liquidity sweeps, order blocks, displacement, and fair value gaps.
- Sizes every position from account risk and the planned stop-loss distance.
- Applies daily loss and maximum drawdown guards before opening new trades.
- Manages open trades through breakeven and ATR-based trailing logic.
- Supports repeatable EURUSD and GBPUSD M15 validation runs from PowerShell.

## Repository layout

```text
src/       MQL5 Expert Advisor and modules
configs/   MT5 Strategy Tester profiles
scripts/   Backtest and validation automation
docs/      Architecture and validation notes
```

## Strategy architecture

```text
H4 trend filter -> H1/M15 setup detection -> risk-based entry
                                        -> execution -> trade management
                                        -> structured event logging
```

The main EA is [`src/TrendFlowing.mq5`](src/TrendFlowing.mq5). Its responsibilities are split into focused modules:

- `TrendDetector`: higher-timeframe market regime and trend state.
- `SetupDetector`: liquidity sweep, order block, displacement, and FVG detection.
- `EntryEngine`: trade eligibility, stop/target construction, and dynamic lot sizing.
- `RiskManager`: daily-loss and drawdown protection.
- `TradeManager`: breakeven and ATR trailing management.
- `ExecutionEngine`: order execution safeguards.
- `Logger`: CSV event journal for test and live-trade investigation.

## Install in MetaTrader 5

1. Open MetaTrader 5 and select `File -> Open Data Folder`.
2. Create `MQL5/Experts/TrendFlowing` if it does not exist.
3. Copy the eight files from this repository's `src/` folder into that folder.
4. Open `TrendFlowing.mq5` in MetaEditor and compile it. This generates `TrendFlowing.ex5` locally; compiled files are intentionally not stored in Git.
5. In Strategy Tester, select `TrendFlowing\\TrendFlowing`, choose a symbol and a test profile from `configs/`.

## Run a validation matrix

After compiling and installing the EA, PowerShell can run the four included validation profiles:

```powershell
Set-Location "$env:USERPROFILE\Desktop\TrendFlowing-Forex-EA"
.\scripts\RunValidationMatrix.ps1
```

If the MT5 data folder cannot be detected automatically, pass it explicitly:

```powershell
.\scripts\RunValidationMatrix.ps1 `
  -TerminalDataPath "$env:APPDATA\MetaQuotes\Terminal\<terminal-id>"
```

JSON summaries are written to `artifacts/`, which is excluded from version control.

## Validation snapshot

The included profiles use an initial USD 10,000 balance, M15 timeframe, and real ticks. The historical research snapshot is deliberately shown as a robustness check rather than a performance claim:

| Symbol | Period | Final balance | Observation |
| --- | --- | ---: | --- |
| EURUSD | 2024 H1 | 10,203.29 | Positive |
| EURUSD | 2024 H2 | 11,157.66 | Positive |
| GBPUSD | 2024 H1 | 10,257.16 | Positive |
| GBPUSD | 2024 H2 | 9,931.01 | Weak / negative |

The uneven result across market and time periods is a useful warning: this is a research project, not a finished production strategy. See [`docs/VALIDATION.md`](docs/VALIDATION.md) for limits and next steps.

## Version

Current EA version: `1.31` (`Time Exit Off`).
