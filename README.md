# gastown_specWriter

A multi-agent formal verification and security audit pipeline for DeFi protocols, built on [Gas Town](https://github.com/steveyegge/gastown). Uses TLA+ specifications and static analysis tools to find bugs and vulnerabilities in smart contracts.

## What This Does

This project orchestrates multiple Claude Code agents (polecats) to run a structured security audit pipeline against DeFi protocols. The first target is Uniswap v2.

The pipeline has five stages:

1. **Spec Writer** — Formalizes smart contract logic into TLA+ specifications and runs TLC model checking to find invariant violations
2. **Code Auditor** — Compares Solidity implementation against TLA+ specs, supported by Slither and CodeQL, to find where code diverges from specified behavior
3. **Doc Auditor** — Two-way correlation between protocol documentation and TLA+ specs to find where docs promise behavior the spec doesn't capture (or vice versa)
4. **Cross-Correlator** — Merges findings from all agents, identifies bugs where a spec counterexample maps to a real code path, and ranks by exploitability
5. **PoC Writer** — Writes Foundry test cases to demonstrate confirmed vulnerabilities against a mainnet fork

Stages 2 and 3 run in parallel after stage 1 completes. Both feed into the correlator before any PoC generation happens.

## Current Target: Uniswap v2

The `uniswapv2/` directory contains the Uniswap v2 core contracts, TLA+ specs, protocol documentation, and audit findings. Key invariants being formalized:

- Constant product (`x * y = k` minus fees) holds after every swap
- LP share minting/burning preserves proportional ownership
- Flash swap atomicity (repayment within the same transaction)
- TWAP oracle accumulator correctness

## Project Structure

```
.
├── .beads/                  # Bead definitions and audit formula
│   └── formulas/            # Repeatable audit pipeline definitions
├── .claude/
│   └── commands/            # Claude Code custom commands
├── mayor/                   # Mayor (AI coordinator) configuration
├── daemon/                  # Background daemon processes
├── deacon/                  # Deacon agent coordination
├── plugins/                 # Gas Town plugins
├── settings/                # Workspace and runtime configuration
├── logs/                    # Agent and pipeline logs
└── uniswapv2/               # Uniswap v2 rig
    ├── contracts/           # Solidity source (UniswapV2Pair, Factory, ERC20)
    ├── specs/               # TLA+ formal specifications
    ├── docs/                # Protocol documentation (whitepaper, docs site)
    └── findings/            # Audit outputs and PoCs
```

## Prerequisites

- [Gas Town](https://github.com/steveyegge/gastown) v0.5.0+
- [Claude Code CLI](https://claude.ai/code)
- [Beads](https://github.com/steveyegge/beads) v0.44.0+
- [TLA+ Tools](https://github.com/tlaplus/tlaplus) (TLC model checker)
- [Foundry](https://book.getfoundry.sh/) (for PoC execution)
- [Slither](https://github.com/crytic/slither) (Solidity static analysis)
- [CodeQL](https://codeql.github.com/) (optional, for custom query patterns)

## Setup

```bash
# Clone the repo into your Gas Town workspace
cd ~/gt
git clone https://github.com/mssabr01/gastown_specWriter.git

# Initialize beads
cd gastown_specWriter
bd init

# Create the audit beads
bd create --id uni2-spec01 \
  --title "Write TLA+ specs for UniswapV2Pair" \
  --description "Formalize swap(), mint(), burn() as TLA+ actions. Model constant product invariant, LP share proportionality, and flash swap atomicity."

bd create --id uni2-code01 \
  --title "Code-to-spec conformance audit" \
  --description "Compare Solidity implementation against TLA+ specs. Flag where code diverges from spec: missing guards, unchecked edge cases, state transitions the spec doesn't model. Use Slither and CodeQL to support findings."

bd create --id uni2-doc01 \
  --title "Two-way doc/spec correlation audit" \
  --description "Compare protocol documentation against TLA+ specs. Flag where docs promise behavior the spec doesn't capture, and where the spec has invariants the docs don't mention."

bd create --id uni2-corr01 \
  --title "Cross-correlate all findings" \
  --description "Merge outputs from spec checking, code audit, and doc audit. Identify bugs where a TLA+ counterexample maps to a real code path. Rank by exploitability."

bd create --id uni2-poc01 \
  --title "Write exploit PoCs for confirmed bugs" \
  --description "Foundry test cases for confirmed CRITICAL/HIGH findings against a mainnet fork. Only work on cross-correlated findings."

# Create the convoy
gt convoy create "Uniswap v2 Audit" uni2-spec01 uni2-code01 uni2-doc01 uni2-corr01 uni2-poc01

# Start the Mayor
gt mayor attach
```

## Audit Formula

The pipeline is defined as a Beads formula in `.beads/formulas/uni2-audit.formula.toml`:

```
spec-generation ──┬──> code-spec-audit ──┬──> correlate ──> poc-generation
                  └──> doc-spec-audit  ──┘
```

Run it with:

```bash
bd cook uni2-audit
```

## Adding New Targets

To audit a different protocol, create a new rig and follow the same pattern:

```bash
gt rig add <protocol-name> <repo-url>
# Create beads with a new prefix (e.g., aave-, comp-)
# Copy and adapt the formula
```

## Built With

- [Gas Town](https://github.com/steveyegge/gastown) — Multi-agent orchestration
- [TLA+](https://lamport.azurewebsites.net/tla/tla.html) — Formal specification and model checking
- [Foundry](https://book.getfoundry.sh/) — Solidity testing framework
- [Slither](https://github.com/crytic/slither) — Solidity static analysis

## License

MIT
