# Uniswap V2 Doc/Spec Correlation Audit

**Audit date:** 2026-02-16
**Auditor:** uniswapv2/polecats/guzzle (bead uni2-doc01)
**Scope:** Whitepaper + docs site vs. TLA+ specs in `hooks/protocol-context/specs/`
**Spec status:** The `specs/` directory is **empty** — no TLA+ specifications exist.

---

## Executive Summary

The Uniswap V2 protocol documentation (whitepaper and docs site) makes numerous behavioral claims, safety guarantees, and invariant assertions. **Zero** of these are captured in any formal TLA+ specification. Every documented safety property is therefore uncovered. This audit catalogs each gap bidirectionally.

Since no specs exist, the "spec has invariants the docs don't mention" direction is vacuously empty. All findings flow from **docs → spec** (docs promise behavior the spec doesn't capture).

---

## Findings

### CRITICAL — Docs Promise Safety Properties Not in Spec

These are behavioral guarantees that, if violated, could lead to loss of funds or protocol-breaking states. Each requires a corresponding TLA+ safety invariant.

---

#### C-01: Constant Product Invariant Preservation

- **Source:** Whitepaper §3.2.1 (eq. 10–11); docs "How Uniswap Works"; docs "Swaps"
- **Claim:** Every swap must satisfy `(1000·x₁ − 3·xᵢₙ) · (1000·y₁ − 3·yᵢₙ) >= 1000000·x₀·y₀`, ensuring the fee-adjusted product of reserves never decreases.
- **Contract reference:** `UniswapV2Pair.sol:180-182` — the `require` on `balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2)`
- **Spec gap:** No TLA+ invariant asserts that post-swap reserves (fee-adjusted) maintain the constant product. This is the core safety property of the AMM.
- **Severity:** **CRITICAL**

---

#### C-02: Reentrancy Lock Guarantees Atomicity

- **Source:** Whitepaper §3.3 ("lock" that prevents reentrancy); docs "Security"
- **Claim:** All public state-changing functions (`swap`, `mint`, `burn`, `skim`, `sync`) are protected by a reentrancy lock. No reentrant call can mutate pair state mid-execution.
- **Contract reference:** `UniswapV2Pair.sol:30-36` — the `lock` modifier with `unlocked` flag
- **Spec gap:** No TLA+ spec models the lock/unlock state machine or proves mutual exclusion of state-changing operations within a single transaction.
- **Severity:** **CRITICAL**

---

#### C-03: Reserves Cannot Exceed uint112 Maximum

- **Source:** Whitepaper §3.7; docs "Pair" reference (getReserves returns uint112)
- **Claim:** Reserve balances are bounded at `2^112 − 1`. If either balance exceeds this, swaps fail and `skim()` must be used to recover.
- **Contract reference:** `UniswapV2Pair.sol:74` — `require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW')`
- **Spec gap:** No TLA+ invariant bounds reserve state variables or models the overflow-revert-skim recovery path.
- **Severity:** **CRITICAL**

---

#### C-04: Flash Swap Callback Must Satisfy Invariant

- **Source:** Whitepaper §2.3; docs "Flash Swaps"
- **Claim:** Users can receive tokens before paying, but the invariant is enforced after the callback. If the contract does not have sufficient funds post-callback, the entire transaction reverts.
- **Contract reference:** `UniswapV2Pair.sol:170-182` — optimistic transfer, callback, then invariant check
- **Spec gap:** No TLA+ spec models the optimistic-transfer → callback → invariant-check sequence or proves that all execution paths either satisfy the invariant or revert atomically.
- **Severity:** **CRITICAL**

---

#### C-05: Minimum Liquidity Burn Prevents Share Manipulation

- **Source:** Whitepaper §3.4; docs "Pools" (initial mint = sqrt(x·y))
- **Claim:** First `MINIMUM_LIQUIDITY` (1000) tokens are permanently burned to the zero address, preventing an attacker from inflating share value to exclude small LPs.
- **Contract reference:** `UniswapV2Pair.sol:119-121` — `if (_totalSupply == 0)` branch burns `MINIMUM_LIQUIDITY`
- **Spec gap:** No TLA+ spec asserts that initial mint always burns minimum liquidity or proves the anti-manipulation property (share value inflation attack cost).
- **Severity:** **CRITICAL**

---

#### C-06: Protocol Fee Calculated as 1/6 of sqrt(k) Growth

- **Source:** Whitepaper §2.4 (eq. 4–7); docs "Fees" (protocol charge calculation)
- **Claim:** When `feeTo != address(0)`, the protocol collects exactly 1/6th of LP fee growth (0.05% of trade volume), computed as `(√k₂ − √k₁) / (5·√k₂ + √k₁) · totalSupply` new LP tokens minted to `feeTo`. This is only computed at mint/burn events, not on every swap.
- **Contract reference:** `UniswapV2Pair.sol:88-107` — `_mintFee` function
- **Spec gap:** No TLA+ spec models the fee accumulation mechanism, the mint-time collection trigger, or proves the 1/6 ratio holds across arbitrary sequences of swaps and liquidity events.
- **Severity:** **CRITICAL**

---

#### C-07: Price Oracle Uses Cached Reserves, Not Current Balances

- **Source:** Whitepaper §2.2 (manipulation resistance); docs "Oracles"
- **Claim:** The price oracle accumulates prices derived from **cached reserves** (updated at end of last interaction), not from current token balances. This prevents manipulation via direct token transfers to the pair.
- **Contract reference:** `UniswapV2Pair.sol:77-80` — `_update` uses `_reserve0`/`_reserve1` (cached) for price accumulation
- **Spec gap:** No TLA+ spec distinguishes between cached reserves and actual balances, or proves that the oracle cannot be manipulated by sending tokens directly to the contract.
- **Severity:** **CRITICAL**

---

#### C-08: Price Accumulator Overflow Safety

- **Source:** Whitepaper §2.2.1 (precision section)
- **Claim:** The cumulative price accumulator is designed to be overflow-safe. Oracles compute deltas using overflow arithmetic, and the system remains correct as long as prices are checkpointed at least once per ~136 years (2^32 seconds).
- **Contract reference:** `UniswapV2Pair.sol:75-76` — `uint32 blockTimestamp = uint32(block.timestamp % 2**32)` with "overflow is desired" comment
- **Spec gap:** No TLA+ spec models the UQ112.112 fixed-point arithmetic, accumulator overflow behavior, or proves correctness of delta computation across overflow boundaries.
- **Severity:** **CRITICAL**

---

#### C-09: Only Factory Can Initialize a Pair

- **Source:** Whitepaper §1 (factory instantiates pairs); docs "Factory" reference
- **Claim:** The `initialize` function can only be called once, by the factory, setting `token0` and `token1`. After initialization, token addresses are immutable.
- **Contract reference:** `UniswapV2Pair.sol:66-69` — `require(msg.sender == factory)`
- **Spec gap:** No TLA+ spec models the factory→pair initialization lifecycle or proves that token addresses cannot change post-initialization.
- **Severity:** **CRITICAL**

---

#### C-10: Pair Uniqueness Per Token Pair

- **Source:** Docs "Factory" reference (createPair); Whitepaper §3.6
- **Claim:** The factory enforces at most one pair per unordered token pair. CREATE2 with deterministic salt ensures the pair address is derivable off-chain.
- **Contract reference:** `UniswapV2Factory.sol:27` — `require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS')`
- **Spec gap:** No TLA+ spec models the uniqueness constraint or proves that `createPair(A,B)` and `createPair(B,A)` cannot create duplicate pairs.
- **Severity:** **CRITICAL**

---

### MEDIUM — Spec Would Model Undocumented Assumptions

These are properties implicit in the contract logic or mentioned only obliquely in docs, which a formal spec should capture but docs don't explicitly promise as guarantees.

> **Note:** Since no specs exist, these are **hypothetical** — properties that a future spec *should* model, where the docs are silent or vague.

---

#### M-01: Pro-Rata Burn Distribution

- **Implicit in:** `UniswapV2Pair.sol:144-145` — `amount0 = liquidity.mul(balance0) / _totalSupply`
- **Doc coverage:** Docs "Pools" mentions "proportional share" informally but does not state the exact formula or prove that rounding always favors the pool (never over-distributes).
- **Spec need:** Invariant that sum of all burn withdrawals never exceeds total deposited + fees. Rounding direction must favor the pool.
- **Severity:** **MEDIUM**

---

#### M-02: Swap Output Strictly Less Than Reserves

- **Implicit in:** `UniswapV2Pair.sol:162` — `require(amount0Out < _reserve0 && amount1Out < _reserve1)`
- **Doc coverage:** Not explicitly documented that output amounts must be *strictly less than* reserves (not less-than-or-equal).
- **Spec need:** Safety invariant that a swap can never drain an entire reserve to zero.
- **Severity:** **MEDIUM**

---

#### M-03: Swap Destination Cannot Be Token Addresses

- **Implicit in:** `UniswapV2Pair.sol:169` — `require(to != _token0 && to != _token1)`
- **Doc coverage:** Not documented anywhere. This prevents sending tokens to themselves, which could confuse balance accounting.
- **Spec need:** Model that `to` address in swap/burn is never one of the pair's own token addresses.
- **Severity:** **MEDIUM**

---

#### M-04: Non-Standard ERC-20 Transfer Handling

- **Implicit in:** `UniswapV2Pair.sol:44-47` — `_safeTransfer` accepts empty return data as success
- **Doc coverage:** Whitepaper §3.3 documents this, but docs site does not mention it in the "Pair" reference or integration guides.
- **Spec need:** Model that transfer success is defined as `(success && (data.length == 0 || abi.decode(data, (bool))))`.
- **Severity:** **MEDIUM**

---

#### M-05: EIP-712 Permit Signature Validation

- **Implicit in:** `UniswapV2ERC20.sol:81-93` — `permit` function with EIP-712 digest
- **Doc coverage:** Whitepaper §2.5 mentions meta transactions briefly. Docs "Pair (ERC-20)" reference lists the function signature but doesn't describe validation semantics or replay protection (nonce incrementing).
- **Spec need:** Model that `permit` only succeeds with valid signature from `owner`, nonce increments atomically, and expired deadlines are rejected.
- **Severity:** **MEDIUM**

---

#### M-06: kLast Reset When Fee Toggled Off

- **Implicit in:** `UniswapV2Pair.sol:104-106` — `else if (_kLast != 0) { kLast = 0; }`
- **Doc coverage:** Not documented. When the protocol fee is turned off (`feeTo == address(0)`), `kLast` is reset to zero to stop accumulating phantom fee debt.
- **Spec need:** Model the state transition when fee toggles off and prove no stale fee minting occurs.
- **Severity:** **MEDIUM**

---

#### M-07: Infinite Allowance Optimization

- **Implicit in:** `UniswapV2ERC20.sol:74` — `if (allowance[from][msg.sender] != uint(-1))`
- **Doc coverage:** Not documented. If allowance is set to `uint(-1)` (max uint256), it is treated as infinite and not decremented on `transferFrom`.
- **Spec need:** Model the two-branch allowance deduction logic and prove it cannot lead to unintended over-spending.
- **Severity:** **MEDIUM**

---

#### M-08: Token Sorting Invariant

- **Implicit in:** `UniswapV2Factory.sol:25` — tokens are sorted by address before pair creation
- **Doc coverage:** Factory docs mention `token0 < token1` in PairCreated event description, but don't formally state this as a system-wide invariant.
- **Spec need:** Invariant that for every pair, `token0 < token1` always holds, ensuring canonical ordering for deterministic address computation.
- **Severity:** **MEDIUM**

---

#### M-09: sync() and skim() Recovery Semantics

- **Implicit in:** `UniswapV2Pair.sol:189-200`
- **Doc coverage:** Whitepaper §3.2.2 describes sync/skim as "bail-out functions" but the exact pre/post conditions are informal. Docs "Pair" reference just says "See the whitepaper."
- **Spec need:** Model that `sync()` sets reserves = balances (potentially changing oracle state), and `skim()` sends excess tokens without modifying reserves. Prove both maintain system consistency.
- **Severity:** **MEDIUM**

---

#### M-10: Dual Price Accumulator Symmetry

- **Implicit in:** `UniswapV2Pair.sol:79-80` — both `price0CumulativeLast` and `price1CumulativeLast` are updated
- **Doc coverage:** Whitepaper §2.2 explains why both directions are tracked (arithmetic mean of A/B ≠ reciprocal of arithmetic mean of B/A). Docs "Oracles" mentions TWAP but doesn't discuss the dual-accumulator property.
- **Spec need:** Invariant that both accumulators are always updated simultaneously and that neither can be manipulated independently.
- **Severity:** **MEDIUM**

---

## Summary Table

| ID | Severity | Property | Docs | Spec |
|----|----------|----------|------|------|
| C-01 | CRITICAL | Constant product invariant (fee-adjusted) | Yes (WP §3.2.1, docs) | Missing |
| C-02 | CRITICAL | Reentrancy lock mutual exclusion | Yes (WP §3.3, docs) | Missing |
| C-03 | CRITICAL | Reserve overflow bound (uint112) | Yes (WP §3.7, docs) | Missing |
| C-04 | CRITICAL | Flash swap callback → invariant enforcement | Yes (WP §2.3, docs) | Missing |
| C-05 | CRITICAL | Minimum liquidity burn anti-manipulation | Yes (WP §3.4, docs) | Missing |
| C-06 | CRITICAL | Protocol fee = 1/6 of sqrt(k) growth | Yes (WP §2.4, docs) | Missing |
| C-07 | CRITICAL | Oracle uses cached reserves not balances | Yes (WP §2.2, docs) | Missing |
| C-08 | CRITICAL | Price accumulator overflow arithmetic | Yes (WP §2.2.1) | Missing |
| C-09 | CRITICAL | Factory-only pair initialization | Yes (WP §1, docs) | Missing |
| C-10 | CRITICAL | Pair uniqueness per token pair | Yes (WP §3.6, docs) | Missing |
| M-01 | MEDIUM | Pro-rata burn rounding favors pool | Partial | Missing |
| M-02 | MEDIUM | Swap output strictly < reserves | No | Missing |
| M-03 | MEDIUM | Swap `to` ≠ token addresses | No | Missing |
| M-04 | MEDIUM | Non-standard ERC-20 safe transfer | Partial (WP only) | Missing |
| M-05 | MEDIUM | EIP-712 permit replay protection | Partial | Missing |
| M-06 | MEDIUM | kLast reset on fee toggle-off | No | Missing |
| M-07 | MEDIUM | Infinite allowance optimization | No | Missing |
| M-08 | MEDIUM | Token sorting canonical invariant | Partial | Missing |
| M-09 | MEDIUM | sync/skim recovery pre/post conditions | Partial (WP only) | Missing |
| M-10 | MEDIUM | Dual price accumulator symmetry | Partial (WP only) | Missing |

---

## Recommendations

1. **Prioritize TLA+ specs for C-01 through C-04** — These are the core safety invariants. The constant product invariant (C-01) and flash swap atomicity (C-04) should be the first specs written, as they directly protect LP funds.

2. **Model the state machine** — A single TLA+ module could capture the pair lifecycle (uninitialized → initialized → operational) with `swap`, `mint`, `burn`, `sync`, `skim` as actions, proving C-01 through C-10 as invariants.

3. **Separate oracle spec** — The price oracle accumulation (C-07, C-08, M-10) involves subtle overflow arithmetic that warrants a dedicated TLA+ module with explicit uint256/UQ112.112 arithmetic modeling.

4. **Update docs for undocumented contract behaviors** — Properties M-02, M-03, M-06, and M-07 are enforced by code but absent from all documentation. Either document them or accept them as implementation details the spec should capture.

5. **Fee module spec** — The protocol fee (C-06) involves interaction between factory state (`feeTo`) and pair state (`kLast`), with the toggle-off reset (M-06). A TLA+ module should prove fee correctness across arbitrary sequences of swaps, mints, burns, and fee toggle events.
