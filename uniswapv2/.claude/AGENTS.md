# Uniswap v2 Security Audit

## Project Context
- Target: Uniswap v2 core contracts (UniswapV2Pair, Factory)
- Protocol docs: hooks/protocol-context/docs/
- TLA+ specs: hooks/protocol-context/specs/
- Findings go in: hooks/protocol-context/findings/

## Conventions
- All findings use severity: CRITICAL/HIGH/MEDIUM/LOW
- Reference functions by contract:function format (e.g. UniswapV2Pair:swap)
- DO NOT modify source code, only specs and findings
- DO NOT modify documentation, only specs and findings
- Check mailbox before starting work
