# UniswapV2 Cross-Correlated Findings

**Bead:** uni2-corr01
**Date:** 2026-02-16
**Correlator:** uniswapv2/polecats/fury
**Sources:**
- uni2-code01 (code-spec-audit.md) — code-to-spec conformance + Slither
- uni2-doc01 (doc-audit-report.md) — doc/spec gap analysis
- PoC test suite — Foundry tests against deployed bytecode
- TLA+ specs (uni2-spec01) — **not yet written** (specs/ directory empty)

---

## Methodology

Each finding below is a **correlated cluster**: a set of observations from different sources that describe the same underlying issue. Correlation confirms that the issue is real (not a false positive from a single tool) and maps it to a concrete exploit path. Findings are ranked by exploitability — the combination of (a) whether a code path exists, (b) whether a PoC confirms it, (c) whether documentation gaps obscure the risk from integrators.

**Exploitability Scale:**
- **EXPLOITABLE** — PoC-confirmed code path, actively dangerous to integrators or LPs
- **LATENT** — Code path exists and audit tools flag it, but economic mitigations or preconditions make exploitation impractical
- **INTEGRATOR-RISK** — Safe at the core protocol level, but integrators who misunderstand the behavior will build vulnerable systems
- **SPEC-GAP** — No exploit, but formal verification coverage is missing; a future code change could introduce a bug undetected

---

## CORR-01: Spot Price Oracle Manipulation [EXPLOITABLE]

**Exploitability rank: 1 (highest)**

| Source | Finding |
|--------|---------|
| PoC suite | Finding 2 — Sandwich attack extracts ~144 ETH from 500 ETH victim trade in 10k ETH pool |
| code-spec-audit | §2.3, §6.1 — CONFORMS: code uses cached reserves for TWAP, but `getReserves()` returns instantaneous spot price |
| doc-audit | C-07 — docs say oracle uses cached reserves, but docs do NOT warn that `getReserves()` is NOT a safe price oracle |
| doc-audit | M-02 — swap output strictly < reserves is undocumented, enabling large-ratio swaps |

**Correlated analysis:**

The core issue is that UniswapV2 exposes two "prices": the TWAP accumulator (manipulation-resistant) and the spot reserve ratio via `getReserves()` (trivially manipulable). The code is correct — the TWAP oracle uses cached reserves (`UniswapV2Pair.sol:77-80`), preventing intra-block manipulation. However:

1. **Doc gap (C-07):** Documentation describes the TWAP oracle's manipulation resistance but does not explicitly warn against using `getReserves()` as a price feed. The Pair reference docs list `getReserves()` without a security caveat.

2. **PoC confirmation:** A single swap of 50% of reserves moves spot price by 124%+. A sandwich attack on a 500 ETH trade extracts ~144 ETH. This is the most economically impactful attack vector against UniswapV2 integrators.

3. **Code path:** `getReserves()` (`UniswapV2Pair.sol:38-42`) is a view function returning cached `reserve0`/`reserve1`. These are updated at the END of each swap (`_update` at line 185), so within the same transaction, they reflect the post-manipulation state. Any protocol reading these values as a "fair price" is vulnerable.

**Real-world code path:**
```
Attacker tx: swap(large) → victim protocol reads getReserves() → attacker swap(reverse)
```

**Impact:** Any DeFi protocol using `getReserves()` as a price oracle (lending protocols for collateral valuation, options protocols for strike pricing, etc.) is vulnerable to flash-loan-amplified price manipulation. This has been the root cause of numerous real-world exploits (bZx, Harvest Finance, etc.).

**Recommendation:** Integrators MUST use the TWAP oracle (`price0CumulativeLast`/`price1CumulativeLast`) with multi-block sampling, never spot reserves.

---

## CORR-02: Fee-on-Transfer / Rebasing Token Incompatibility [EXPLOITABLE]

**Exploitability rank: 2**

| Source | Finding |
|--------|---------|
| PoC suite | Finding 3 — Fee-on-transfer tokens cause 2% LP value leakage per withdrawal |
| PoC suite | Finding 4 — Rebase front-running extracts ~90 tokens from 10% rebase event |
| code-spec-audit | §5.2-5.3 — `sync()` can decrease k without LP consent; MEDIUM severity |
| code-spec-audit | §5.4 — Donations change balances without spec-modeled action |
| doc-audit | M-09 — sync/skim recovery semantics only partially documented |
| doc-audit | M-04 — Non-standard ERC-20 handling documented in whitepaper but not on docs site |

**Correlated analysis:**

Three independent sources converge on the same root cause: UniswapV2 assumes token balances change ONLY through pair-initiated transfers. When tokens autonomously modify balances (fee-on-transfer, rebase, deflationary burn), the reserve/balance invariant breaks.

1. **Fee-on-transfer (`UniswapV2Pair.sol:170-171, 148-149`):** The pair calls `_safeTransfer` for the full amount, but the recipient receives less. The pair's `balanceOf` check post-transfer sees the actual (reduced) balance, so the K invariant holds — but reserves track nominal amounts, creating a persistent `balance < reserve` discrepancy. On burn, LPs receive the actual (lower) balance pro-rata, losing the fee delta. **PoC confirms: 2% loss per withdrawal for 2% fee token.**

2. **Positive rebase (`UniswapV2Pair.sol:198-200`):** After a positive rebase, `balance > reserve`. Until `sync()` is called, swaps execute at the stale (pre-rebase) price. An attacker who detects the rebase event can front-run `sync()` and swap at the favorable stale price. **PoC confirms: ~90 tokens extracted from 10% rebase.**

3. **Deflationary burn (`UniswapV2Pair.sol:198-200`):** External burn reduces balance below reserve. `sync()` updates reserves downward, shifting the price by `(old_reserve / new_reserve - 1)`. **PoC confirms: 20% balance reduction → 25% price shift, front-runnable.**

**Real-world code paths:**
```
Fee-on-transfer: mint() → swap() → burn() → LP receives less than pro-rata share
Rebase front-run: rebase event → attacker swap() at stale price → sync()
Deflation front-run: external burn → attacker swap() → sync()
```

**Impact:** Direct LP value extraction for fee-on-transfer tokens. Arbitrage extraction for rebasing tokens. Both are active attack vectors on mainnet.

**Recommendation:** UniswapV2 pairs with non-standard tokens require wrapper contracts or Router02's `*SupportingFeeOnTransferTokens` methods. TLA+ spec should model `Donate` and `Rebase` as environment actions (per code-spec-audit §11.3).

---

## CORR-03: First-Depositor Share Inflation Attack [LATENT]

**Exploitability rank: 3**

| Source | Finding |
|--------|---------|
| PoC suite | Finding 1 — Attack confirmed but cost-prohibitive: 10 ETH donation yields 0.009 ETH extractable |
| code-spec-audit | §3.5 — First depositor can manipulate initial share price; LOW severity |
| code-spec-audit | §3.4 — Integer rounding in mint favors existing LPs; MEDIUM severity |
| doc-audit | C-05 — MINIMUM_LIQUIDITY burn documented in whitepaper §3.4 but no spec proves anti-manipulation property |

**Correlated analysis:**

All three sources identify the same attack vector at `UniswapV2Pair.sol:119-124`:

1. Attacker provides minimal initial liquidity (e.g., 1 wei of each token)
2. Receives `sqrt(1*1) - 1000` shares — **reverts** because `sqrt(1) = 1 < 1000 = MINIMUM_LIQUIDITY`
3. Attacker must provide at least `1001^2 = 1,002,001` wei product to get 1 share beyond minimum
4. After getting shares, attacker donates tokens to inflate value-per-share
5. Subsequent depositors' `amount * totalSupply / reserve` rounds to 0 for small deposits

**Mitigation confirmed by PoC:** The 1000 dead shares burned to `address(0)` capture `1000/1001 ≈ 99.9%` of any donated value. The PoC shows 10 ETH donation yields only 0.009 ETH extractable — the attack costs ~10 ETH to steal ~0.009 ETH.

**Code path (`UniswapV2Pair.sol:119-123`):**
```solidity
if (_totalSupply == 0) {
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    _mint(address(0), MINIMUM_LIQUIDITY);
} else {
    liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
}
```

**Cross-validation:** The code-spec-audit (D1, D5) correctly identifies that integer rounding always favors existing LPs and that the attack cost scales with MINIMUM_LIQUIDITY. The doc-audit (C-05) correctly flags that no formal spec proves this property. All sources agree the mitigation is effective.

**Impact:** Latent — economically irrational to exploit on UniswapV2 due to MINIMUM_LIQUIDITY. However, forks that reduce or remove MINIMUM_LIQUIDITY are vulnerable (this has been exploited on ERC-4626 vaults without similar protection).

**Recommendation:** TLA+ spec should model attack cost as `donation * MINIMUM_LIQUIDITY / (MINIMUM_LIQUIDITY + attacker_shares)` and prove it exceeds extractable value for all parameter ranges.

---

## CORR-04: Skim Extraction of Unprotected Donations [INTEGRATOR-RISK]

**Exploitability rank: 4**

| Source | Finding |
|--------|---------|
| PoC suite | Finding 4.1 — 10 ETH donation fully extracted by first `skim()` caller |
| code-spec-audit | §5.1 — `skim()` documented as external balance correction; INFO severity |
| code-spec-audit | §5.4 — Donations change balances without spec-modeled action |
| doc-audit | M-09 — sync/skim recovery semantics only partially documented |

**Correlated analysis:**

`skim()` (`UniswapV2Pair.sol:190-195`) allows ANYONE to extract the difference between actual token balances and cached reserves. This is by design — it's a recovery mechanism. But the documentation gap (M-09) means integrators may not realize that:

1. Tokens sent directly to a pair (not via `mint()`/`swap()`) are extractable by anyone
2. Revenue-sharing or fee-distribution contracts that send tokens to pairs lose those tokens to MEV bots
3. The "donation" accounting in swap (where excess balance counts as `amountIn`) only works if no one calls `skim()` first

**Code path:**
```solidity
function skim(address to) external lock {
    _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
    _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
}
```

**Impact:** Not a vulnerability in UniswapV2 itself, but a trap for integrating protocols. Any contract that sends tokens to a pair expecting them to be "in the pool" (without calling `mint()` or `sync()`) loses them to the first `skim()` caller. MEV bots actively monitor for this.

**Recommendation:** Document explicitly: tokens sent to a pair outside of `mint()`/`swap()` are NOT protected and can be extracted by anyone via `skim()`.

---

## CORR-05: Integer Rounding Asymmetry in Mint/Burn [SPEC-GAP]

**Exploitability rank: 5**

| Source | Finding |
|--------|---------|
| code-spec-audit | §3.4, D1 — Rounding in mint favors existing LPs; MEDIUM |
| code-spec-audit | §4.3, D1 — Rounding in burn favors the pool; MEDIUM |
| doc-audit | M-01 — Pro-rata burn rounding only partially documented |
| doc-audit | C-06 — Protocol fee sqrt precision loss not formally verified |

**Correlated analysis:**

Integer division in Solidity always truncates (rounds toward zero). In UniswapV2:

- **Mint (`line 123`):** `amount * totalSupply / reserve` rounds DOWN → minter gets fewer shares → existing LPs benefit
- **Burn (`lines 144-145`):** `liquidity * balance / totalSupply` rounds DOWN → burner gets less → remaining LPs benefit
- **Protocol fee (`line 100`):** `numerator / denominator` rounds DOWN → protocol gets fewer fee shares → LPs benefit

All three rounding directions consistently favor the pool/existing LPs over the acting party. This is a safe, coherent design. However:

1. **No formal proof exists** (doc-audit C-06, code-spec-audit D1) that this rounding direction is invariant — a code change could accidentally reverse it
2. The whitepaper uses real-number arithmetic and does not discuss integer rounding at all
3. The `_mintFee` sqrt precision loss (code-spec-audit §8.3, D6) could theoretically cause `rootK - rootKLast` to be off by 1, but the impact is sub-wei for typical pool sizes

**Impact:** No exploit — the rounding is consistent and safe. But the absence of formal verification means a future code modification (e.g., in a V2 fork) could introduce rounding in the wrong direction without detection.

**Recommendation:** TLA+ spec should model all arithmetic with `floor()` and assert: `actual_output <= ideal_output` for all mint/burn/fee operations.

---

## CORR-06: Cross-Contract Read Inconsistency During Callbacks [SPEC-GAP]

**Exploitability rank: 6**

| Source | Finding |
|--------|---------|
| code-spec-audit | §7.2, D7 — Slither reentrancy flags are FP due to lock modifier |
| code-spec-audit | §2.5 — Flash swap callback pattern confirmed correct |
| doc-audit | C-02 — Reentrancy lock documented but not formally modeled |
| doc-audit | C-04 — Flash swap callback → invariant enforcement not formally verified |

**Correlated analysis:**

During a flash swap callback (`UniswapV2Pair.sol:172`), the pair has already transferred tokens OUT but has NOT yet verified the K invariant or updated reserves. At this moment:

- `getReserves()` returns **stale** reserves (pre-swap values)
- `balanceOf(pair)` returns the **actual** (post-transfer) balance
- The `lock` modifier prevents reentry into `swap`/`mint`/`burn`/`skim`/`sync`

Slither correctly identifies that external calls (`_safeTransfer`, `uniswapV2Call`) happen before state updates (`_update`). The code-spec-audit correctly classifies these as false positives because the `lock` modifier prevents reentry. However, the read inconsistency is real:

**Code path (`UniswapV2Pair.sol:170-185`):**
```
_safeTransfer (tokens out) → uniswapV2Call (callback) → balanceOf check → K check → _update
```

During the callback, a third-party contract querying `getReserves()` sees stale data while `balanceOf(pair)` reflects the actual state. This is not exploitable because:
1. The pair is locked — no state mutations possible
2. The callback must result in sufficient tokens returned, or the whole tx reverts
3. `getReserves()` being stale during the callback is observable but not actionable within the same transaction

**Impact:** No exploit at the pair level. The spec gap is that no formal model proves the lock + atomicity combination is sufficient.

**Recommendation:** TLA+ spec should model the lock as a global mutex and prove: during any callback, no pair state mutation is possible, and the post-callback invariant check covers all execution paths.

---

## CORR-07: Missing `to == address(this)` Guard in Swap [SPEC-GAP]

**Exploitability rank: 7 (lowest)**

| Source | Finding |
|--------|---------|
| code-spec-audit | §2.6, D3 — No guard against self-swap destination; LOW |
| doc-audit | M-03 — Swap `to` ≠ token addresses documented, but `to` ≠ pair not documented |

**Correlated analysis:**

`swap()` prevents `to == token0` and `to == token1` (`UniswapV2Pair.sol:169`) but allows `to == address(this)` (the pair itself). The code-spec-audit correctly analyzes that this is a non-exploitable edge case:

When `to == pair`:
1. Output tokens are sent TO the pair (increasing its balance)
2. `balanceOf(pair)` post-transfer includes the output
3. `amountIn` is computed as `balance - (reserve - amountOut)`, which now includes the output
4. The net effect: the swapper "pays themselves" — the K invariant holds because the output becomes input
5. The swapper loses gas fees for a no-op

**Impact:** No value extraction possible. The only risk is user confusion (wasted gas). A TLA+ spec should model `to == pair` and prove `K_after >= K_before` still holds.

---

## Uncorrelated Findings (Single-Source, No Cross-Validation)

These findings appear in only one source and lack cross-validation. They are listed for completeness but should not be considered confirmed without further analysis.

| ID | Source | Finding | Severity | Notes |
|----|--------|---------|----------|-------|
| doc-audit C-03 | doc-audit only | uint112 overflow bound not in spec | CRITICAL (spec gap) | Code enforces this (line 74); no PoC needed — it's a `require` |
| doc-audit C-08 | doc-audit only | Price accumulator overflow arithmetic not in spec | CRITICAL (spec gap) | Overflow is by design (line 76 comment); formally proving correctness across overflow boundaries is non-trivial |
| doc-audit C-09 | doc-audit only | Factory-only initialization not in spec | CRITICAL (spec gap) | Code enforces `msg.sender == factory` (line 67); straightforward to model |
| doc-audit C-10 | doc-audit only | Pair uniqueness not in spec | CRITICAL (spec gap) | Factory enforces (line 27 of Factory.sol); straightforward to model |
| doc-audit M-05 | doc-audit only | EIP-712 permit replay protection not in spec | MEDIUM (spec gap) | Nonce-based; standard pattern |
| doc-audit M-06 | doc-audit only | kLast reset on fee toggle not in spec | MEDIUM (spec gap) | Code at lines 104-106; edge case when `feeTo` changes |
| doc-audit M-07 | doc-audit only | Infinite allowance optimization not in spec | MEDIUM (spec gap) | Code in ERC20.sol; gas optimization, no security impact |
| doc-audit M-08 | doc-audit only | Token sorting invariant not in spec | MEDIUM (spec gap) | Factory sorts tokens; canonical ordering for CREATE2 |
| doc-audit M-10 | doc-audit only | Dual price accumulator symmetry not in spec | MEDIUM (spec gap) | Both accumulators updated simultaneously at lines 79-80 |
| code-spec-audit D6 | code-spec-audit only | _mintFee sqrt precision loss | LOW | Sub-wei impact for typical pools; see §8.3 |
| code-spec-audit §6.3 | code-spec-audit only | Oracle skips update when reserves zero | INFO | Only at initialization; inconsequential |
| code-spec-audit §8.4 | code-spec-audit only | Self-pair prevented by factory | INFO | `require(tokenA != tokenB)` at factory level |

---

## Summary: Exploitability Ranking

| Rank | ID | Finding | Exploitability | PoC | Code Path | Doc Gap |
|------|----|---------|---------------|-----|-----------|---------|
| 1 | CORR-01 | Spot price oracle manipulation | **EXPLOITABLE** | Yes (144 ETH) | `getReserves()` | Yes (C-07) |
| 2 | CORR-02 | Fee-on-transfer / rebase incompatibility | **EXPLOITABLE** | Yes (2% loss) | `_safeTransfer`, `sync()` | Yes (M-04, M-09) |
| 3 | CORR-03 | First-depositor share inflation | **LATENT** | Yes (mitigated) | `mint()` first branch | Yes (C-05) |
| 4 | CORR-04 | Skim extraction of donations | **INTEGRATOR-RISK** | Yes (full extraction) | `skim()` | Yes (M-09) |
| 5 | CORR-05 | Integer rounding asymmetry | **SPEC-GAP** | N/A | mint/burn/fee div | Yes (M-01, C-06) |
| 6 | CORR-06 | Cross-contract read inconsistency | **SPEC-GAP** | N/A | callback window | Yes (C-02, C-04) |
| 7 | CORR-07 | Self-swap destination | **SPEC-GAP** | N/A | `swap(to=pair)` | Yes (M-03) |

---

## Recommendations for TLA+ Spec (uni2-spec01)

Priority order based on correlated exploitability:

1. **Model `getReserves()` vs TWAP distinction** — The most exploitable finding (CORR-01) stems from integrators confusing spot price with TWAP. The spec should model both and prove TWAP is resistant to single-block manipulation.

2. **Model non-standard token behaviors** — CORR-02 shows real value extraction. Add `Donate`, `Rebase`, and `FeeOnTransfer` as environment actions that modify balances outside of pair control. Prove which invariants break.

3. **Model integer arithmetic throughout** — CORR-05 shows the rounding is safe-by-accident. Use `floor()` for all division and prove `actual_output <= ideal_output` universally.

4. **Model the lock mutex** — CORR-06 depends on the lock preventing reentry. The spec should prove mutual exclusion of all state-changing functions.

5. **Model skim/sync as recovery actions** — CORR-04 shows integrators misunderstand these. The spec should prove: after `skim()`, `balance == reserve`; after `sync()`, `reserve == balance`; and neither creates value from nothing.

6. **Model the complete pair lifecycle** — Uncorrelated findings (C-09, C-10, M-08) describe factory-level invariants that should be part of a system-wide spec, not just the pair spec.
