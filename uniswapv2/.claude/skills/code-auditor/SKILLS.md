# TLA+/PlusCal ↔ Source Code Consistency Checker Skill

## Purpose
Compare a TLA+/PlusCal specification against its corresponding source code implementation to identify inconsistencies — places where the code diverges from the spec's assumptions, atomicity boundaries, state transitions, or safety/liveness guarantees.

## Workflow

1. **Read the PlusCal spec** — Extract the formal model: processes, variables, labels (atomicity), transitions, channels, invariants, and temporal properties.
2. **Read the source code** — Identify the corresponding implementation components: threads/goroutines/actors, shared state, locks, queues, API calls, retry logic, error handling.
3. **Build the mapping** — Match spec elements to code elements using the mapping table below.
4. **Check each consistency dimension** — Walk through every check category systematically.
5. **Report findings** — Output a structured inconsistency report.

## Step 1: Extract the Spec Model

Parse the PlusCal spec and extract these elements into a mental model:

| Element | What to extract |
|---|---|
| **Global variables** | Name, type, initial value |
| **Constants** | Name, intended domain |
| **Processes** | Name/set, local variables, fairness (fair/fair+) |
| **Labels** | Sequence per process — these define atomicity boundaries |
| **Statements per label** | What reads/writes happen atomically together |
| **`await` guards** | Blocking conditions — what must be true before proceeding |
| **`either/or`** | Nondeterministic branches — all paths the spec considers possible |
| **Macros/Procedures** | Reusable blocks and their atomicity properties |
| **`define` block** | Invariants and safety properties |
| **Temporal properties** | Liveness guarantees (after translation block) |

## Step 2: Extract the Code Model

Parse the source code and extract:

| Element | What to extract |
|---|---|
| **Solidity functions / TypeScript async functions** | Entry points, visibility, modifiers |
| **On-chain state variables** | Contract storage slots, mappings, arrays |
| **Off-chain shared mutable state** | Module-level variables, singletons, caches, database rows |
| **Synchronization primitives** | Solidity: reentrancy guards, access control modifiers. TypeScript: DB transactions, mutex libraries, atomic operations |
| **Critical sections** | Solidity: code before external calls. TypeScript: code between `await` points |
| **Queues / buffers** | Solidity: arrays, mappings used as queues. TypeScript: in-memory queues, Redis, message brokers |
| **Retry / error handling** | Solidity: `require`, `revert`, `try/catch`. TypeScript: `try/catch`, retry loops, timeout logic |
| **State transitions** | Solidity: enum state changes, status mappings. TypeScript: state machines, status fields |
| **External calls** | Solidity: `.call()`, `.transfer()`, interface calls. TypeScript: `fetch`, ethers.js/viem contract calls, API calls |
| **Transaction boundaries** | Solidity: entire external function call is atomic. TypeScript: DB transaction blocks, batched blockchain calls |

## Step 3: Build the Mapping

Create an explicit mapping between spec and code. Every spec element should have a code counterpart (and vice versa).

| PlusCal | Solidity / TypeScript |
|---|---|
| `process P \in 1..N` | Solidity: external callers (EOAs, contracts), distinct contracts. TypeScript: async tasks, worker threads, concurrent users |
| Global variable `x` | Solidity: contract storage variable (`uint256 public x`). TypeScript: module-level variable, database row, Redis key |
| Local variable | Solidity: function-local variable (memory). TypeScript: function-scoped variable |
| Label boundary | Solidity: external call (`.call()`, `.transfer()`, cross-contract call) — reentrancy point. TypeScript: `await` expression |
| `await condition` | Solidity: `require(condition)` (reverts if false, doesn't block/wait). TypeScript: `while (!condition) await sleep()`, event listener, channel receive |
| `either/or` | Solidity: `try/catch` on external calls, transaction success/revert. TypeScript: `try/catch`, `Promise.race`, timeout branches |
| `send(msg, chan)` | Solidity: `emit Event(...)`, external call with data. TypeScript: `fetch`/`axios` POST, WebSocket send, queue push |
| `recv(var, chan)` | Solidity: function parameter (received via calldata). TypeScript: `await fetch()` response, event listener callback, queue consumer |
| Sequence `<<>>` | Solidity: dynamic array (`uint[] storage`). TypeScript: `Array`, queue |
| Function `[k \in S \|-> v]` | Solidity: `mapping(KeyType => ValueType)`. TypeScript: `Map`, `Record`, database table |
| Invariant in `define` | Solidity: `require` checks, contract invariant assertions. TypeScript: runtime assertions, DB constraints |

**Flag unmapped elements immediately** — an unmapped spec process or an unmapped code thread is itself an inconsistency.

## Step 4: Consistency Check Dimensions

Run through EVERY category below. Each is a class of bugs that can exist between spec and implementation.

---

### 4.1 Atomicity Violations

**The #1 source of spec↔code divergence.**

In PlusCal, everything within a single label executes atomically. In code, atomicity requires explicit enforcement (locks, transactions, CAS).

**Check procedure:**
1. For each label in the spec, identify all reads and writes within that label.
2. Find the corresponding code section.
3. Verify the code enforces atomicity over ALL those reads and writes together.

**Common violations:**

| Spec assumes | Code does | Bug |
|---|---|---|
| Read + write in one label | Solidity: state update after external `.call()` | Reentrancy — attacker re-enters before state update |
| Check + act in one label | TypeScript: `await getState()` then `await act()` as separate txs | TOCTOU — state changes between read tx and write tx |
| Multi-field update in one label | TypeScript: separate contract calls for each field | Partial update visible to other callers between txs |
| Channel send is atomic | TypeScript: HTTP POST to RPC node (can timeout, retry, duplicate) | Non-atomic transaction submission |

**Example inconsistency:**
```
\* Spec (one label = atomic):
Withdraw:
    await balances[sender] >= amount;
    balances[sender] := balances[sender] - amount;

// Solidity (reentrancy vulnerability — NOT effectively atomic):
function withdraw(uint amount) external {
    require(balances[msg.sender] >= amount);
    (bool ok, ) = msg.sender.call{value: amount}("");  // attacker re-enters here
    require(ok);
    balances[msg.sender] -= amount;  // too late — already re-entered
}

// TypeScript (NOT atomic — two separate transactions):
const balance = await contract.balances(user);  // read tx
if (balance >= amount) {
    await contract.withdraw(amount);  // write tx — balance may have changed
}
```

**Fix patterns to suggest:**
- Solidity: checks-effects-interactions pattern (state update before external call)
- Solidity: `ReentrancyGuard` / `nonReentrant` modifier
- TypeScript: batch read+write into a single contract call
- TypeScript: use on-chain `require` as the source of truth, not off-chain pre-checks

---

### 4.2 Missing Nondeterminism

PlusCal `either/or` models ALL possible outcomes. Code may only handle a subset.

**Check procedure:**
1. For each `either/or` in the spec, list all branches.
2. Verify the code handles every branch — especially failure paths.

**Common violations:**

| Spec models | Code missing |
|---|---|
| `either success or timeout or crash` | No timeout handling |
| `either commit or rollback` | No rollback path on partial failure |
| `either deliver or drop` (message loss) | Assumes reliable delivery |
| `with x \in S` (any value from set) | Code hardcodes a single value or subset |

---

### 4.3 State Space Mismatches

Variables may have different domains in spec vs code.

**Check procedure:**
1. For each spec variable, identify its type/domain.
2. Verify the code variable can hold the same range of values.
3. Check for values the code can produce that the spec doesn't model.

**Common violations:**

| Issue | Example |
|---|---|
| Spec bounds tighter than code | Spec: `x \in 0..10`, Code: `x` is unbounded int |
| Code has extra states | Code has `PENDING` status not in spec |
| Spec missing error state | Spec has `{INIT, RUNNING, DONE}`, code also has `FAILED`, `TIMEOUT` |
| Type mismatch | Spec: boolean flag, Code: enum with 3+ values |
| Initial value mismatch | Spec: `x = 0`, Code: `x = null` or uninitialized |

---

### 4.4 Process/Concurrency Mismatches

The number and behavior of concurrent entities must match.

**Check procedure:**
1. Count distinct process types in spec. Match to code threads/actors/goroutines.
2. Check cardinality: `process P \in 1..N` — does code actually run N instances?
3. Check lifecycle: does the code process terminate/loop matching the spec?

**Common violations:**

| Issue | Example |
|---|---|
| Missing process | Spec models an oracle updater process, code relies on external keeper with no guarantee |
| Extra process | Code has a TypeScript cron job rebalancing state not modeled in spec |
| Wrong cardinality | Spec: exactly 3 validators, Code: dynamic validator set |
| Lifecycle mismatch | Spec process loops forever, TypeScript service crashes and doesn't restart |
| Missing fairness | Spec: `fair process` (always eventually runs), Code: keeper bot can go offline indefinitely |

---

### 4.5 Ordering and Sequencing Violations

PlusCal labels impose a strict order of atomic steps. Code may reorder.

**Check procedure:**
1. Trace the label sequence for each process.
2. Verify the code follows the same ordering.
3. Check for async scheduling or transaction ordering that breaks the spec's assumed order.

**Common violations:**

| Issue | Example |
|---|---|
| Transaction ordering | Spec: user A acts then user B acts. Code: miners can reorder transactions (MEV). |
| Async callback ordering | Spec: step after send. TypeScript: `Promise.all` callbacks resolve in nondeterministic order. |
| Event processing order | Spec: FIFO channel. Code: ethers.js event listener may miss or reorder events on reorg. |
| Cross-contract call order | Spec: call X then call Y. Solidity: Y's callback can execute before X's state is finalized (reentrancy). |

---

### 4.6 Guard / Blocking Condition Mismatches

`await` in PlusCal means "block until true." Code must implement equivalent blocking.

**Check procedure:**
1. For each `await` in spec, find the corresponding code wait mechanism.
2. Verify the condition is identical.
3. Verify the code actually blocks (not busy-waits that can miss state changes, or polls that can skip).

**Common violations:**

| Issue | Example |
|---|---|
| Revert vs block | Spec: `await x > 0` (blocks). Solidity: `require(x > 0)` (reverts, doesn't wait). Fundamentally different — spec process waits, contract rejects. |
| Weaker guard | Spec: `await x > 0 /\ y = TRUE`, Code: only checks `x > 0` |
| Polling gap | Spec: `await`, TypeScript: `setInterval` poll every 30s — can miss short-lived state windows |
| Missing guard entirely | Spec: `await Len(queue) > 0`, Solidity: pops from array without length check, reverts on underflow |

---

### 4.7 Invariant Enforcement

Every invariant in the `define` block must hold in the code at every observable state.

**Check procedure:**
1. For each invariant, translate it to a code assertion or constraint.
2. Check if the code enforces it (assertions, DB constraints, validation).
3. Check if any code path can violate it.

**Common violations:**

| Spec invariant | Code issue |
|---|---|
| `MutualExclusion == ...` | Solidity: reentrancy guard missing on critical function |
| `TypeOK == x \in 0..10` | No `require` bounds check on user input |
| `BalanceConservation == sum = const` | Solidity: rounding in fee calculation breaks conservation. TypeScript: `number` precision loss above 2^53 |
| `NoDoubleSpend == ...` | Solidity: state updated after external call — reentrant call bypasses check |

---

### 4.8 Liveness / Progress Violations

Temporal properties (`<>`, `[]<>`) must have code-level guarantees.

**Check procedure:**
1. For each liveness property, identify what code mechanism ensures progress.
2. Check for conditions where progress can stall.

**Common violations:**

| Spec property | Code issue |
|---|---|
| `<>(state = "Done")` (eventually terminates) | TypeScript keeper has infinite retry with no backoff or dead-letter |
| `[]<>(Len(queue) = 0)` (queue always eventually drains) | Keeper bot can crash permanently, no one else processes queue |
| `WF` (weak fairness) assumed | Off-chain bot has no SLA — can go offline indefinitely |
| `<>(funds_returned)` | Solidity: `selfdestruct` or paused contract blocks refund path forever |

---

### 4.9 Abstraction Leaks (Code has complexity the spec ignores)

The spec intentionally abstracts. But if abstracted-away details can affect correctness, that's a gap.

**Check for:**
- MEV / transaction reordering (spec models fair ordering, miners/validators can reorder)
- Front-running (spec doesn't model adversary observing mempool)
- Chain reorgs (spec models finality, code may read pre-finality state)
- Gas limits (spec assumes computations complete, code can run out of gas)
- RPC node inconsistency (spec assumes single consistent state, code may query different nodes)
- Block timestamp manipulation (spec abstracts time, miners can skew `block.timestamp`)
- Resource exhaustion (spec: unbounded mapping iteration, code: gas-bounded loops)
- Upgrade mechanics (spec models one contract, code uses proxy pattern with storage layout risks)
- Cross-chain bridges (spec may model atomic cross-chain transfer, reality involves relayers and latency)

---

## Step 5: Output Report Format

Structure the findings as follows:

```markdown
# Spec ↔ Code Consistency Report

## Summary
- Spec: `ModuleName.tla`
- Code: `contracts/Protocol.sol`, `src/services/`
- Critical issues: X
- Warnings: Y
- Notes: Z

## Mapping
| Spec Element | Code Element | Status |
|---|---|---|
| process User \in Users | External callers to `Protocol.sol` | ✅ Mapped |
| variable balances | `mapping(address => uint256) balances` | ✅ Mapped |
| process Keeper | `src/services/keeper.ts` | ✅ Mapped |
| process Oracle | — | ❌ UNMAPPED (spec only) |
| — | `src/services/healthCheck.ts` | ⚠️ UNMAPPED (code only) |

## Critical Issues

### [C1] Reentrancy in Protocol.withdraw
- **Spec:** Label `Withdraw` reads `balances[user]`, checks sufficiency, and updates `balances[user]` atomically (single label).
- **Code:** `Protocol.sol:87-93` — sends ETH via `.call{value: amount}` BEFORE setting `balances[msg.sender] = 0`. Recipient's `receive()` can re-enter `withdraw()`.
- **Impact:** Balance drained beyond spec's `BalanceConservation` invariant.
- **Suggested fix:** Move `balances[msg.sender] = 0` before the external call, or add `nonReentrant` modifier.

### [C2] Atomicity violation in keeper service
- **Spec:** Label `Execute` reads `orderStatus` and writes `orderStatus` atomically.
- **Code:** `keeper.ts:45-52` — `await contract.getOrderStatus()` then `await contract.executeOrder()` are separate transactions. Another keeper or user can change order status between reads.
- **Impact:** Double execution of orders, violating `NoDoubleExecution` invariant.

## Warnings

### [W1] Extra state not in spec
- **Code:** `Order.status` can be `CANCELLED` — not modeled in spec.
- **Impact:** Spec may miss cancel-related interleavings.

## Notes

### [N1] Abstraction gap — network reliability
- Spec models `send`/`recv` as reliable. Code uses HTTP with retries.
- Acceptable if retry logic is idempotent. Verify idempotency of handlers.
```

## Severity Classification

| Severity | Criteria |
|---|---|
| **Critical** | Code can violate a spec invariant or safety property. Data loss, corruption, or deadlock possible. |
| **Warning** | Code has states/paths not modeled in spec. Spec may be incomplete rather than code being wrong, but should be investigated. |
| **Note** | Abstraction gap acknowledged. Acceptable if documented assumptions hold, but worth flagging. |

## Language-Specific Gotchas

### Solidity (On-Chain)
- **Single-threaded execution within a transaction** — all state changes in one external function call are atomic (all-or-nothing via EVM). This maps cleanly to a single PlusCal label. However, multiple transactions interleave freely between blocks and within blocks (miner/validator ordering). Each top-level external call is its own atomic step.
- **Reentrancy** — the critical concurrency hazard. An external call (`address.call`, `token.transfer`, etc.) hands control to untrusted code that can re-enter your contract. If the spec models an external call and a state update in the same label (atomic), but the code updates state AFTER the external call, a reentrant call sees stale state. Always check: state writes before external calls (checks-effects-interactions pattern) or `ReentrancyGuard`.
- **Cross-contract calls = interleaving points** — every external call is a label boundary in practice. If the spec puts `call contractB.foo()` and `state = updated` in one label, verify the code enforces atomicity (state update first, or reentrancy guard).
- **`block.timestamp` and `block.number`** — if the spec abstracts time, but the code uses these for deadlines, timelocks, or auction endings, miners can manipulate timestamps by ~15 seconds. Flag any spec invariant that depends on precise timing.
- **Gas limits** — spec may assume loops or iterations always complete. In practice, unbounded loops can hit block gas limits and revert. If the spec models `while` over a growing set, verify the code has pagination or bounds.
- **Integer overflow/underflow** — Solidity ≥0.8 reverts on overflow by default. If spec models `x \in 0..MAX_UINT256`, verify no unchecked arithmetic blocks bypass this. For older Solidity or `unchecked {}` blocks, overflow is silent — critical invariant violation risk.
- **`tx.origin` vs `msg.sender`** — spec may model "the caller" as a single entity. If code uses `tx.origin`, phishing attacks allow a different `msg.sender`. Flag if spec's access control invariants assume `msg.sender`.
- **Storage vs memory** — spec variables are persistent. Verify that code state changes are to `storage`, not accidentally to `memory` copies that get discarded.
- **Proxy/upgradeable contracts** — if the code uses delegate call proxies (UUPS, Transparent), the spec may model one contract but the code has two (proxy + implementation). Storage layout mismatches between upgrades can silently corrupt state — flag if spec doesn't model upgradeability.
- **MEV / front-running** — spec's `either/or` nondeterminism may not model that an adversary can observe pending transactions and re-order them. For DEX swaps, auctions, or any price-sensitive operation, flag if the spec doesn't model front-running as a possible interleaving.
- **Events vs state** — Solidity events are logs, not state. If the spec tracks a variable that the code only emits as an event (without storing), off-chain consumers may miss it on reorgs.

### TypeScript (Off-Chain / Backend / Frontend)
- **Single-threaded event loop (Node.js / browser)** — no parallel execution of synchronous code. Interleaving happens at `await` points. Each synchronous block between `await`s maps to one PlusCal label.
- **`await` = yield point = label boundary** — every `await` in an `async` function is a point where other tasks can run. If the spec puts a read and a write in one label (atomic), but the code has an `await` between them, other async tasks can interleave. This is the TypeScript equivalent of a race condition.
- **Example atomicity violation:**
  ```typescript
  // Spec: one label (atomic)
  //   await balance >= amount;
  //   balance := balance - amount;

  // Code: NOT atomic — another async task can modify balance at the await
  const bal = await getBalance(user);      // label boundary
  if (bal >= amount) {
      await setBalance(user, bal - amount); // another task read same bal
  }
  ```
- **`Promise.all` / `Promise.race`** — `Promise.all` runs promises concurrently. If the spec models sequential steps (label A then label B), but code uses `Promise.all([A(), B()])`, the execution order is nondeterministic. `Promise.race` maps to `either/or` — but the losing promise still runs (side effects continue). Verify the spec models this.
- **Database transactions from TypeScript** — if the spec puts multiple DB operations in one label, verify the code uses an actual DB transaction (`BEGIN`/`COMMIT`), not separate queries. ORMs like Prisma and TypeORM have different transaction APIs — check they're actually used.
- **Event emitters / pub-sub** — `EventEmitter.emit()` in Node.js is synchronous — listeners run immediately inline. This is different from a PlusCal `send` to a channel (async). If the spec models async message passing but the code uses sync event emission, listener side effects happen within the sender's "label."
- **Retries and idempotency** — TypeScript code calling external APIs often has retry logic (axios-retry, custom loops). If the spec models `either success or failure`, verify that retried requests are idempotent. Non-idempotent retries can cause duplicate state transitions not in the spec.
- **`setTimeout` / `setInterval`** — these schedule future execution but don't guarantee timing. If the spec models a timeout as `either complete or timeout`, verify the code actually cancels the operation on timeout (not just races a timer alongside it, leaving the original running).
- **Shared mutable state across async contexts** — module-level variables, singleton instances, or in-memory caches can be mutated by any async task. Map these to PlusCal global variables and verify all accesses respect the spec's atomicity labels.
- **Frontend state (React/Vue/Svelte)** — if the spec models UI state transitions, React state updates are batched and asynchronous. `setState` doesn't immediately update — reading state after setting it returns the old value within the same synchronous block. This can violate spec invariants that assume immediate state consistency.
- **Worker threads (Node.js)** — if the code uses `worker_threads`, these ARE parallel (true concurrency, shared `SharedArrayBuffer`). Map each worker to a separate PlusCal process. `Atomics` API provides CAS-like operations — verify they match spec label boundaries.

### Cross-Cutting: Solidity ↔ TypeScript Interactions
- **Transaction submission from TypeScript** — TypeScript sends a transaction, waits for confirmation. Between submission and confirmation, the chain state can change (front-running, reorgs). If the spec models this as one atomic step, flag it.
- **Event listening** — TypeScript reads Solidity events via `ethers.js`/`viem` listeners or polling. Events can be missed on reorgs, WebSocket disconnects, or RPC node lag. If the spec assumes reliable event delivery (`send`/`recv`), flag the gap.
- **Nonce management** — concurrent TypeScript processes sending transactions from the same wallet can produce nonce collisions. If the spec models multiple off-chain processes submitting transactions, verify nonce coordination.
- **Optimistic updates** — TypeScript UI may update state before transaction confirms. If the transaction reverts, UI state diverges from on-chain state. Flag if the spec assumes consistency between on-chain and off-chain state.
- **Read-after-write consistency** — after sending a transaction, immediately reading state from a different RPC node may return stale data. If the spec assumes sequential consistency across write-then-read, flag the RPC consistency gap.
- **ABI encoding/decoding** — type mismatches between Solidity contract and TypeScript client (e.g., `uint256` vs JavaScript `number` losing precision above `2^53`) can silently corrupt data. Flag if spec invariants depend on value precision.

## Checklist Before Submitting Report

- [ ] Every spec process mapped to Solidity contract/function or TypeScript service (or flagged as unmapped)
- [ ] Every Solidity external function and TypeScript async task mapped to spec (or flagged)
- [ ] Every label's atomicity verified — Solidity: reentrancy safety, TypeScript: no `await` splitting atomic operations
- [ ] Every `either/or` branch has corresponding error handling (Solidity `revert`/`try-catch`, TypeScript `catch`)
- [ ] Every `await` has corresponding mechanism — Solidity: `require` (reverts, doesn't block!), TypeScript: actual blocking/polling
- [ ] Every invariant from `define` block checked against Solidity `require` statements and TypeScript validation
- [ ] Every temporal property checked — especially off-chain liveness (keeper uptime, retry limits)
- [ ] Initial values match between spec and contract constructor / TypeScript initialization
- [ ] State domains match (no extra enum values, no missing error states)
- [ ] Solidity ↔ TypeScript interaction gaps documented (reorgs, nonce management, ABI precision)
- [ ] Abstraction gaps documented as Notes (MEV, gas limits, timestamp manipulation)
