# Documentation ↔ TLA+/PlusCal Spec Consistency Checker Skill

## Purpose
Compare project documentation (READMEs, technical specs, architecture docs, protocol descriptions, whitepapers, user guides, API docs) against TLA+/PlusCal specifications to identify inconsistencies — places where the docs describe behavior the spec doesn't model, where the spec models behavior the docs don't describe, or where the two directly contradict each other.

## Why This Matters
Documentation is the human-facing contract. The TLA+ spec is the formal, model-checked contract. When they diverge:
- Developers implement what the docs say, not what the spec proves safe.
- Auditors review docs but miss spec-only edge cases.
- Users expect behavior described in docs that the spec explicitly forbids or doesn't guarantee.
- Proven invariants in the spec may not match the guarantees the docs promise.

## Workflow

1. **Read the documentation** — Extract claims: behavioral guarantees, state machines, process descriptions, ordering, safety/liveness promises, failure handling, access control, and numerical constraints.
2. **Read the PlusCal spec** — Extract the formal model: processes, variables, labels, transitions, guards, nondeterminism, invariants, and temporal properties.
3. **Build the mapping** — Match each doc claim to its spec counterpart (and vice versa).
4. **Check each consistency dimension** — Walk through every check category systematically.
5. **Report findings** — Output a structured inconsistency report.

## Step 1: Extract Claims from Documentation

Read all documentation and extract every verifiable claim into a structured list. Claims fall into these categories:

| Claim Type | What to extract | Example from docs |
|---|---|---|
| **State descriptions** | Named states, enums, status values | "An order can be in PENDING, ACTIVE, FILLED, or CANCELLED state" |
| **State transitions** | What triggers transitions, valid transition paths | "An order moves from PENDING to ACTIVE when the keeper executes it" |
| **Process / actor descriptions** | Named actors, their roles, how many | "Three types of actors: Users, Keepers, and the Admin" |
| **Ordering guarantees** | Sequence of operations, before/after relationships | "Funds are locked before the swap executes" |
| **Safety guarantees** | Things that must never happen | "A user can never withdraw more than their deposited balance" |
| **Liveness guarantees** | Things that must eventually happen | "All pending orders will eventually be executed or expire" |
| **Atomicity claims** | What happens as a single unit | "Deposit and credit update happen atomically" |
| **Access control** | Who can do what | "Only the admin can pause the protocol" |
| **Numerical constraints** | Bounds, limits, thresholds | "Maximum 100 open orders per user" |
| **Failure handling** | What happens on errors, timeouts, reverts | "If the oracle is unavailable, the system falls back to the last known price" |
| **Concurrency behavior** | Parallel execution, interleaving, race handling | "Multiple users can deposit simultaneously without conflict" |
| **Invariants (informal)** | Stated conservation laws, consistency rules | "Total supply always equals the sum of all balances" |
| **Nondeterminism / choice** | Where the system can go multiple ways | "The keeper may choose any eligible order to execute next" |
| **Timing / deadlines** | Timeouts, expiry, time-based behavior | "Orders expire after 24 hours if not filled" |

**Tag each claim with its source location** (file, section, page, line) for the report.

## Step 2: Extract the Spec Model

Parse the PlusCal spec and extract these elements:

| Element | What to extract |
|---|---|
| **Global variables** | Name, type, initial value, domain |
| **Constants** | Name, intended domain, suggested model values |
| **Processes** | Name/set, cardinality, fairness (`fair`/`fair+`), local variables |
| **Labels per process** | Sequence of atomic steps — the process's control flow |
| **Statements per label** | Reads, writes, guards (`await`), assignments |
| **`await` guards** | Blocking/enabling conditions |
| **`either/or` blocks** | All nondeterministic branches |
| **`with x \in S` blocks** | Nondeterministic selection from sets |
| **Macros and procedures** | Reusable operations and their semantics |
| **`define` block invariants** | Safety properties (checked at every state) |
| **Temporal properties** | Liveness properties (after translation block) |
| **Comments in spec** | Informal intent annotations — these should align with docs |

## Step 3: Build the Mapping

Create an explicit bidirectional mapping. Every doc claim should map to spec elements, and every spec element should map to doc descriptions.

| Documentation Claim | Spec Element | Status |
|---|---|---|
| "Orders can be PENDING, ACTIVE, FILLED, CANCELLED" | `orderStatus \in {"pending", "active", "filled", "cancelled"}` | ✅ Matched |
| "Admin can pause the protocol" | `process Admin` has `Pause` label | ✅ Matched |
| "Deposits are atomic" | `Deposit` label contains both `receive` and `credit` | ✅ Matched |
| "Orders expire after 24 hours" | — | ❌ NOT IN SPEC |
| — | `process Liquidator` | ❌ NOT IN DOCS |
| "Maximum 10 validators" | `NumValidators \in 1..5` | ⚠️ CONTRADICTS (10 vs 5) |

**Flag all three mismatch types immediately:**
1. **Doc claim with no spec counterpart** — doc says something the spec doesn't model
2. **Spec element with no doc counterpart** — spec models something the docs don't mention
3. **Direct contradiction** — both address the same concept but disagree

## Step 4: Consistency Check Dimensions

Run through EVERY category below systematically.

---

### 4.1 State Space Mismatches

The set of possible states described in docs must match the spec's variable domains.

**Check procedure:**
1. For each state/enum/status described in docs, find the corresponding spec variable.
2. Compare the set of possible values.
3. Check initial values match.

**Common violations:**

| Issue | Example |
|---|---|
| Doc has extra states | Docs: "PENDING, ACTIVE, FILLED, CANCELLED, EXPIRED". Spec: `{"pending", "active", "filled", "cancelled"}` — no `expired`. |
| Spec has extra states | Spec has `"liquidated"` status. Docs never mention liquidation. |
| Different naming | Docs: "completed". Spec: `"filled"`. May be intentional aliasing or a real mismatch. |
| Initial value mismatch | Docs: "Orders start in CREATED state". Spec: `orderStatus = "pending"`. |
| Domain mismatch | Docs: "Balance can be any positive number". Spec: `balance \in 0..MAX_BAL` (includes zero). |
| Missing variable entirely | Docs describe a "reputation score" concept. Spec has no corresponding variable. |

---

### 4.2 State Transition Mismatches

The documented transition graph must match the spec's process control flow.

**Check procedure:**
1. From the docs, draw the state machine (states + labeled transitions).
2. From the spec, trace all possible state variable changes per label.
3. Compare the two graphs edge by edge.

**Common violations:**

| Issue | Example |
|---|---|
| Doc allows transition spec forbids | Docs: "Users can cancel a FILLED order". Spec: `cancel` label has `await status = "pending"` — only pending orders cancellable. |
| Spec allows transition doc doesn't mention | Spec: `Liquidate` label can transition `"active"` → `"liquidated"`. Docs never describe liquidation. |
| Missing transition | Docs describe order expiry (`ACTIVE` → `EXPIRED`). Spec has no expiry mechanism. |
| Extra transition | Spec allows `"pending"` → `"cancelled"` via `AdminCancel` label. Docs only describe user-initiated cancel. |
| Trigger mismatch | Docs: "Order fills when price matches". Spec: `Fill` label has `await oraclePrice <= limitPrice /\ balance >= amount` — additional balance check not in docs. |
| Direction mismatch | Docs imply bidirectional transitions. Spec enforces one-way only. |

---

### 4.3 Process / Actor Mismatches

The documented actors must match the spec's processes.

**Check procedure:**
1. List all actors/roles described in docs.
2. List all `process` declarations in spec.
3. Compare one-to-one.

**Common violations:**

| Issue | Example |
|---|---|
| Doc actor not in spec | Docs describe "Governance Council" that votes on parameters. Spec has no governance process. |
| Spec process not in docs | Spec has `process Liquidator \in 1..NumLiquidators`. Docs never mention liquidators. |
| Cardinality mismatch | Docs: "Up to 100 keepers". Spec: `process Keeper \in 1..3` (models only 3). May be intentional abstraction — flag for review. |
| Role conflation | Docs describe "Admin" and "Operator" as separate roles. Spec has single `process Admin` that does both. |
| Capability mismatch | Docs: "Keepers can execute and cancel orders". Spec: `process Keeper` only has `Execute` label — no cancel capability. |
| Fairness mismatch | Docs: "The system guarantees every user's order will eventually be processed" (implies strong fairness). Spec: `fair process Keeper` (weak fairness only — not the same guarantee). |

---

### 4.4 Safety Guarantee Mismatches

Every safety claim in docs must correspond to a spec invariant. Every spec invariant should be documented.

**Check procedure:**
1. For each safety claim in docs, find the matching invariant in the `define` block.
2. Verify the invariant actually formalizes the doc claim (same semantics, not just similar name).
3. Check for spec invariants with no documentation.

**Common violations:**

| Issue | Example |
|---|---|
| Doc guarantee not formalized | Docs: "Users can never lose funds". Spec has no fund conservation invariant. |
| Invariant stronger than doc claim | Docs: "Balances stay non-negative". Spec: `balance[u] >= minReserve` (stronger — maintains a minimum reserve, not just non-negative). Docs should reflect the actual guarantee. |
| Invariant weaker than doc claim | Docs: "Total supply is always exactly backed 1:1". Spec: `totalSupply <= totalCollateral` (allows over-collateralization but not exact 1:1). |
| Undocumented invariant | Spec has `NoDoubleExecution == \A o \in Orders : execCount[o] <= 1`. Docs never mention double-execution protection. |
| Informal guarantee, no invariant | Docs: "The protocol is always solvent". No corresponding spec invariant — vague claim never formalized. |
| Invariant contradiction | Docs: "Maximum 10 open orders per user". Spec: `\A u \in Users : openOrders[u] <= 5`. Limit disagrees (10 vs 5). |

---

### 4.5 Liveness Guarantee Mismatches

Every "eventually" or "always eventually" claim in docs must correspond to a temporal property in the spec.

**Check procedure:**
1. Identify all liveness claims in docs (keywords: "eventually", "guaranteed to", "will always", "must complete", "timeout ensures").
2. Find matching temporal properties after the spec's translation block.
3. Verify semantic equivalence.

**Common violations:**

| Issue | Example |
|---|---|
| Doc promise not formalized | Docs: "All pending orders will eventually be executed or expire". Spec has no corresponding `<>` property. |
| Fairness assumption mismatch | Docs imply unconditional liveness ("orders always get processed"). Spec uses `fair process` which only guarantees progress if the step is continuously enabled — starvation still possible if steps are intermittently disabled. |
| Stronger doc claim | Docs: "Withdrawals complete within 24 hours". Spec: `<>(status = "completed")` — eventually, but no time bound. |
| Weaker doc claim | Docs: "Users can eventually withdraw". Spec: `[]<>(withdrawEnabled)` — stronger guarantee that withdrawal is repeatedly available, not just once. |
| Missing temporal property | Docs describe timeout/expiry behavior. Spec has no liveness property and no timeout mechanism. |
| Undocumented liveness | Spec proves `<>(Len(queue) = 0)` (queue always drains). Docs don't mention this guarantee — users might not know to rely on it. |

---

### 4.6 Atomicity and Ordering Mismatches

Docs describe what happens "as one step" or "before/after". The spec's labels define the actual atomicity.

**Check procedure:**
1. Find all atomicity claims in docs ("atomic", "single transaction", "in one step", "indivisible").
2. Verify the spec puts all described operations within one label.
3. Find all ordering claims ("A happens before B", "first X then Y").
4. Verify the spec's label sequence enforces that order.

**Common violations:**

| Issue | Example |
|---|---|
| Doc claims atomicity, spec splits | Docs: "Deposit and credit happen atomically". Spec: `Receive` label and `Credit` label are separate — an interleaving point exists between them. |
| Doc claims ordering, spec allows reorder | Docs: "Collateral is always locked before the loan is issued". Spec: `LockCollateral` and `IssueLoan` are in separate `either/or` branches — ordering not enforced. |
| Spec is more atomic than docs suggest | Spec puts 5 operations in one label. Docs describe them as separate steps. Not a safety issue but misleading — users may think there are intermediate observable states that don't exist. |
| Doc omits interleaving point | Docs describe a "withdraw" flow as one step. Spec has `Check` and `Transfer` as separate labels — between them, another process can act. Docs should warn about this. |

---

### 4.7 Nondeterminism and Failure Handling Mismatches

Docs describe failure modes and choices. The spec's `either/or` and `with` blocks define what the model considers possible.

**Check procedure:**
1. Find all failure/error descriptions in docs.
2. Verify each has a corresponding `either/or` branch in the spec.
3. Check for spec nondeterminism not described in docs.

**Common violations:**

| Issue | Example |
|---|---|
| Doc failure mode not in spec | Docs: "If the oracle is down, the system uses stale prices". Spec has no oracle-failure branch — models oracle as always available. |
| Spec failure mode not in docs | Spec: `either success or networkPartition` at `Sync` label. Docs never mention network partitions. |
| Nondeterministic choice undocumented | Spec: `with order \in eligibleOrders do execute(order)` — keeper picks any eligible order. Docs say "keeper executes the oldest order first" (deterministic — contradicts spec). |
| Error recovery mismatch | Docs: "Failed transactions are automatically retried". Spec: failed transactions go to `"failed"` terminal state — no retry loop. |
| Missing adversarial model | Docs: "The protocol is secure against front-running". Spec has no adversary process and no `either/or` modeling front-running. Claim is unsubstantiated by the spec. |

---

### 4.8 Access Control Mismatches

Docs describe who can do what. The spec's process structure and guards define actual permissions.

**Check procedure:**
1. List all access control statements from docs ("only X can Y", "X requires permission Z").
2. For each, verify the spec enforces it — the action must only appear in the correct process with appropriate guards.
3. Check for spec-side restrictions not in docs.

**Common violations:**

| Issue | Example |
|---|---|
| Doc restriction not enforced in spec | Docs: "Only admin can pause". Spec: `Pause` label exists in `process User` as well — any user can pause. |
| Spec restriction not documented | Spec: `await role[self] = "admin"` guard on `UpdateFee` label. Docs describe fee updates but don't mention admin-only restriction. |
| Role set mismatch | Docs define 4 roles: User, Keeper, Admin, Governance. Spec has 3 processes: User, Keeper, Admin. Governance role missing. |
| Permission granularity | Docs: "Admin can update protocol parameters". Spec: Admin can only update `feeRate` — not all parameters. |

---

### 4.9 Numerical and Constraint Mismatches

Docs state numerical limits, thresholds, and bounds. The spec's constants and variable domains must match.

**Check procedure:**
1. Extract all numbers, limits, thresholds from docs.
2. Match to spec constants and variable bounds.
3. Flag any disagreement.

**Common violations:**

| Issue | Example |
|---|---|
| Value mismatch | Docs: "Maximum 100 open positions". Spec: `MaxPositions = 50`. |
| Bound type mismatch | Docs: "At least 3 confirmations". Spec: `confirmations \in 0..10` — allows 0, which violates the doc's "at least 3". |
| Missing constant | Docs reference a "30-minute timeout". Spec has no time-related constant. |
| Implicit vs explicit | Docs: "Unlimited deposits". Spec: `deposit \in 0..MAX_DEPOSIT` — bounded. |
| Unit mismatch | Docs: "Fee is 0.3%". Spec: `fee = 30` (basis points? or 30%?). Ambiguous and potentially wrong. |

---

### 4.10 Abstraction Gap Documentation

The spec intentionally abstracts. Docs should acknowledge what the spec does and does not cover.

**Check procedure:**
1. Identify what the spec abstracts away (no gas, no time, simplified message passing, finite process sets, etc.).
2. Check if docs mention these abstractions and their implications.
3. Flag cases where docs make claims about things the spec doesn't model.

**Common violations:**

| Issue | Example |
|---|---|
| Doc claims unverified property | Docs: "The protocol handles chain reorgs gracefully". Spec has no reorg model — claim is not backed by formal analysis. |
| Doc assumes spec coverage | Docs: "Formally verified to be safe against all attacks". Spec only models 3 processes with bounded state — doesn't cover all attack surfaces. |
| Missing abstraction note | Docs don't mention that the spec models time abstractly (no real deadlines) — readers may assume the spec verifies timing guarantees it doesn't. |
| Scope overstatement | Docs: "Mathematically proven correct". Spec only checks safety invariants with TLC (model checking over finite state), not full theorem proving. |

---

## Step 5: Output Report Format

Structure findings as follows:

```markdown
# Documentation ↔ Spec Consistency Report

## Summary
- Documentation: list of files reviewed
- Spec: `ModuleName.tla`
- Contradictions: X
- Doc-only claims (not in spec): Y
- Spec-only elements (not in docs): Z
- Confirmed matches: W

## Mapping Overview

### Matched Elements
| Doc Claim (source) | Spec Element | Match Quality |
|---|---|---|
| "Orders have 4 states" (README §3.1) | `orderStatus \in {"pending","active","filled","cancelled"}` | ✅ Exact |
| "Admin can pause" (spec.md §5) | `process Admin`, label `Pause` | ✅ Exact |
| "Deposits are atomic" (README §4) | `Deposit` label contains full deposit logic | ✅ Exact |

### Doc Claims Not in Spec
| Doc Claim | Source | Impact |
|---|---|---|
| "Orders expire after 24 hours" | whitepaper §3.4 | ⚠️ Significant — time-based guarantee not formally verified |
| "Protocol handles reorgs" | architecture.md §7 | ⚠️ Significant — no reorg model in spec |

### Spec Elements Not in Docs
| Spec Element | Impact |
|---|---|
| `process Liquidator` with labels `Check`, `Liquidate` | ❌ Critical — undocumented actor can change system state |
| Invariant `NoDoubleExecution` | ⚠️ Moderate — proven guarantee that users don't know about |
| `either/or` network partition branch in `Sync` label | ⚠️ Moderate — spec models failure mode docs don't mention |

## Contradictions

### [C1] State set mismatch
- **Docs (README §3.1):** "Orders can be PENDING, ACTIVE, FILLED, CANCELLED, or EXPIRED"
- **Spec:** `orderStatus \in {"pending", "active", "filled", "cancelled"}`
- **Discrepancy:** EXPIRED state exists in docs but not in spec. Either the spec is incomplete or the docs describe unimplemented behavior.
- **Recommendation:** If expiry is intended behavior, add it to the spec with a timeout mechanism. If not, remove from docs.

### [C2] Numerical limit disagreement
- **Docs (spec.md §4.2):** "Maximum 100 open orders per user"
- **Spec:** `\A u \in Users : Cardinality(openOrders[u]) <= 50`
- **Discrepancy:** Doc says 100, spec enforces 50.
- **Recommendation:** Align on the intended limit and update the inconsistent source.

### [C3] Ordering claim not enforced
- **Docs (architecture.md §6):** "Collateral is always locked before the loan is issued"
- **Spec:** `LockCollateral` and `IssueLoan` are in parallel `either/or` branches — spec does not enforce this order.
- **Discrepancy:** Docs claim a strict ordering the spec doesn't guarantee.
- **Recommendation:** If ordering is required, restructure spec to use sequential labels. If not, soften doc language.

## Uncovered Doc Claims

### [U1] "The protocol is secure against front-running"
- **Source:** whitepaper §8.2
- **Spec gap:** No adversary process, no mempool model, no transaction reordering nondeterminism.
- **Risk:** Security claim has no formal backing. Could mislead auditors and users.

### [U2] "Withdrawals complete within 24 hours"
- **Source:** user-guide.md §3
- **Spec gap:** Spec has `<>(status = "completed")` — eventually completes, but no time bound. TLA+ doesn't natively model real time.
- **Risk:** Users expect time-bounded guarantee that the spec doesn't verify.

## Undocumented Spec Behavior

### [S1] Liquidation process
- **Spec:** `process Liquidator` can transition positions from `"active"` to `"liquidated"` when `collateralRatio < minRatio`.
- **Doc gap:** No documentation mentions liquidation as a concept.
- **Risk:** Users unaware that their positions can be liquidated.

### [S2] Admin emergency shutdown
- **Spec:** `process Admin` has `EmergencyShutdown` label that sets `systemActive = FALSE`, blocking all other processes.
- **Doc gap:** Not mentioned in any user-facing or developer documentation.
- **Risk:** Users unaware of centralization risk.
```

## Severity Classification

| Severity | Criteria |
|---|---|
| **Contradiction** | Docs and spec directly disagree on the same concept. One must be wrong. |
| **Critical gap** | Doc makes safety/security claim with no spec backing, or spec models dangerous behavior docs don't mention. |
| **Moderate gap** | Doc claim not modeled in spec (or vice versa), but doesn't directly endanger users. Spec may be intentionally abstract. |
| **Minor gap** | Naming differences, documentation of spec abstractions, cosmetic mismatches. |

## Doc-Type-Specific Guidance

### Whitepapers / Protocol Descriptions
- Heaviest source of safety and liveness claims. Cross-reference EVERY guarantee with spec invariants and temporal properties.
- Watch for vague language ("secure", "trustless", "decentralized") — flag any such claim that isn't backed by a specific spec property.
- Adversarial/threat model sections must map to spec nondeterminism (`either/or`, adversary processes).

### READMEs / Developer Docs
- Focus on state machines, API descriptions, and architectural claims.
- Check that described function signatures and parameters align with spec process labels and variable types.
- Watch for "how it works" sections that describe a flow — verify every step matches spec label ordering.

### API Documentation
- Each documented endpoint/function should map to a spec label or macro.
- Parameter constraints (types, ranges, required fields) should match spec variable domains and `await` guards.
- Documented error responses should match spec `either/or` failure branches.
- Documented preconditions should match spec `await` guards exactly.

### User Guides / Tutorials
- Highest risk of oversimplification. Users form expectations from these.
- "You can always do X" → verify no spec guard blocks X.
- "X will happen within Y time" → verify spec has corresponding liveness property (it usually won't have time bounds).
- Step-by-step flows → verify spec label ordering matches every step.

### Architecture / Design Documents
- Most likely to describe systems the spec abstracts away (infrastructure, monitoring, deployment).
- Flag any architectural component described as critical for correctness that has no spec counterpart.
- Concurrency and scaling claims must map to spec process structure and fairness assumptions.

### NatSpec / Inline Code Comments
- If the codebase has NatSpec (Solidity) or JSDoc (TypeScript) comments that describe behavior, these are also documentation.
- Cross-reference `@notice`, `@dev`, `@param` comments against spec labels and invariants.
- Inline comments like "// This is safe because X" should have spec-backed justification.

## Common Patterns of Divergence

These are the most frequently observed categories of doc↔spec inconsistency, ordered by frequency:

1. **Scope creep in docs** — Docs describe features added after the spec was written. Spec was never updated.
2. **Spec abstracts, docs don't acknowledge** — Spec intentionally omits time, gas, network. Docs make claims about these omitted concepts as if they're verified.
3. **Vague doc guarantees** — Docs use words like "secure", "safe", "reliable" without precision. Spec has specific invariants that may or may not match the vague intent.
4. **Numerical drift** — Constants change during development. Docs say one number, spec says another, code says a third.
5. **Undocumented spec processes** — Spec adds processes for completeness (adversary, liquidator, oracle) that docs never describe to users.
6. **Fairness assumption gaps** — Docs promise liveness ("will always eventually happen"). Spec uses weak fairness, which is a weaker guarantee. Or spec has no fairness and liveness is unproven.
7. **State machine evolution** — States added to docs or spec independently. One has states the other doesn't.

## Checklist Before Submitting Report

- [ ] Every doc safety/security claim mapped to a spec invariant (or flagged as uncovered)
- [ ] Every doc liveness claim mapped to a spec temporal property (or flagged)
- [ ] Every spec invariant and temporal property mapped to doc description (or flagged as undocumented)
- [ ] Every doc-described state matched against spec variable domain
- [ ] Every doc-described transition matched against spec label control flow
- [ ] Every doc-described actor matched against spec process
- [ ] Every doc-described failure mode matched against spec `either/or` branch
- [ ] Every doc numerical constant matched against spec constant
- [ ] Access control claims verified against spec process structure and guards
- [ ] Atomicity and ordering claims verified against spec label structure
- [ ] Abstraction gaps explicitly documented — what the spec doesn't model that docs claim
- [ ] All findings tagged with source locations (doc file + section, spec label/line)
