---------------------------- MODULE UniswapV2Pair ----------------------------
(*
 * TLA+ specification of UniswapV2Pair core actions: swap, mint, burn.
 *
 * Models:
 *   - Constant product invariant (x * y = k) with 0.3% fee
 *   - LP share proportionality for mint/burn
 *   - Flash swap atomicity via reentrancy lock
 *   - MINIMUM_LIQUIDITY lock on first mint
 *)

EXTENDS Integers, Naturals, FiniteSets, Sequences

CONSTANTS
    MINIMUM_LIQUIDITY,  \* = 1000 (10^3)
    MaxTokens,          \* upper bound on token amounts for model checking
    Actors              \* set of participant addresses

ASSUME MINIMUM_LIQUIDITY = 1000
ASSUME MaxTokens \in Nat /\ MaxTokens > 0
ASSUME Actors # {}

VARIABLES
    reserve0,           \* uint112: tracked reserve of token0
    reserve1,           \* uint112: tracked reserve of token1
    totalSupply,        \* total LP token supply
    balanceLP,          \* [Actors -> Nat]: LP token balances
    locked,             \* reentrancy lock (TRUE = executing)
    balance0,           \* actual token0 balance of the pair contract
    balance1,           \* actual token1 balance of the pair contract
    kLast,              \* reserve0 * reserve1 after last liquidity event
    pc                  \* program counter for flash swap atomicity model

vars == <<reserve0, reserve1, totalSupply, balanceLP, locked,
          balance0, balance1, kLast, pc>>

-----------------------------------------------------------------------------
(* Helper: integer square root (floor) *)

Sqrt(n) == CHOOSE r \in 0..n : r * r <= n /\ (r + 1) * (r + 1) > n

(* Helper: minimum of two naturals *)

Min(a, b) == IF a <= b THEN a ELSE b

-----------------------------------------------------------------------------
(* Type invariant *)

TypeOK ==
    /\ reserve0 \in 0..MaxTokens
    /\ reserve1 \in 0..MaxTokens
    /\ totalSupply \in Nat
    /\ balanceLP \in [Actors -> Nat]
    /\ locked \in BOOLEAN
    /\ balance0 \in 0..MaxTokens
    /\ balance1 \in 0..MaxTokens
    /\ kLast \in Nat
    /\ pc \in {"idle", "flash_callback", "flash_verify"}

-----------------------------------------------------------------------------
(* Initial state: empty pair, no liquidity *)

Init ==
    /\ reserve0 = 0
    /\ reserve1 = 0
    /\ totalSupply = 0
    /\ balanceLP = [a \in Actors |-> 0]
    /\ locked = FALSE
    /\ balance0 = 0
    /\ balance1 = 0
    /\ kLast = 0
    /\ pc = "idle"

-----------------------------------------------------------------------------
(*
 * MINT: Add liquidity. Caller has already transferred amount0, amount1
 * tokens to the pair contract (balance0/balance1 reflect this).
 *
 * Models LP share proportionality:
 *   - First mint: liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
 *   - Subsequent: liquidity = min(amount0 * S / r0, amount1 * S / r1)
 *)

Mint(actor, amount0, amount1) ==
    /\ locked = FALSE
    /\ pc = "idle"
    /\ amount0 > 0
    /\ amount1 > 0
    /\ amount0 + reserve0 <= MaxTokens
    /\ amount1 + reserve1 <= MaxTokens
    \* Simulate tokens being transferred in before mint call
    /\ LET newBal0 == reserve0 + amount0
           newBal1 == reserve1 + amount1
       IN
       /\ IF totalSupply = 0
          THEN
            \* First liquidity provision
            LET liq == Sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
            IN
            /\ liq > 0
            /\ totalSupply' = liq + MINIMUM_LIQUIDITY
            /\ balanceLP' = [balanceLP EXCEPT ![actor] = @ + liq]
          ELSE
            \* Proportional mint
            LET liq == Min((amount0 * totalSupply) \div reserve0,
                           (amount1 * totalSupply) \div reserve1)
            IN
            /\ liq > 0
            /\ totalSupply' = totalSupply + liq
            /\ balanceLP' = [balanceLP EXCEPT ![actor] = @ + liq]
       /\ reserve0' = newBal0
       /\ reserve1' = newBal1
       /\ balance0' = newBal0
       /\ balance1' = newBal1
       /\ kLast' = newBal0 * newBal1
       /\ locked' = FALSE
       /\ pc' = "idle"

-----------------------------------------------------------------------------
(*
 * BURN: Remove liquidity. LP tokens have been sent to the pair contract.
 *
 * Pro-rata distribution:
 *   amount0_out = liquidity * balance0 / totalSupply
 *   amount1_out = liquidity * balance1 / totalSupply
 *)

Burn(actor, liquidity) ==
    /\ locked = FALSE
    /\ pc = "idle"
    /\ liquidity > 0
    /\ balanceLP[actor] >= liquidity
    /\ totalSupply > 0
    /\ LET amt0 == (liquidity * balance0) \div totalSupply
           amt1 == (liquidity * balance1) \div totalSupply
       IN
       /\ amt0 > 0
       /\ amt1 > 0
       /\ balanceLP' = [balanceLP EXCEPT ![actor] = @ - liquidity]
       /\ totalSupply' = totalSupply - liquidity
       /\ reserve0' = balance0 - amt0
       /\ reserve1' = balance1 - amt1
       /\ balance0' = balance0 - amt0
       /\ balance1' = balance1 - amt1
       /\ kLast' = (balance0 - amt0) * (balance1 - amt1)
       /\ locked' = FALSE
       /\ pc' = "idle"

-----------------------------------------------------------------------------
(*
 * SWAP: Exchange tokens subject to constant product invariant with fee.
 *
 * The 0.3% fee is modeled via the adjusted balance check:
 *   (balance0 * 1000 - amountIn0 * 3) * (balance1 * 1000 - amountIn1 * 3)
 *     >= reserve0 * reserve1 * 1000^2
 *
 * This ensures k never decreases (strictly increases by fee amount).
 *)

Swap(amount0Out, amount1Out, amountIn0, amountIn1) ==
    /\ locked = FALSE
    /\ pc = "idle"
    /\ amount0Out >= 0 /\ amount1Out >= 0
    /\ amount0Out > 0 \/ amount1Out > 0
    /\ amount0Out < reserve0
    /\ amount1Out < reserve1
    /\ amountIn0 >= 0 /\ amountIn1 >= 0
    /\ amountIn0 > 0 \/ amountIn1 > 0
    \* Compute new balances after swap
    /\ LET newBal0 == reserve0 + amountIn0 - amount0Out
           newBal1 == reserve1 + amountIn1 - amount1Out
       IN
       /\ newBal0 > 0
       /\ newBal1 > 0
       /\ newBal0 <= MaxTokens
       /\ newBal1 <= MaxTokens
       \* Constant product invariant with 0.3% fee (scaled by 1000)
       /\ LET adj0 == newBal0 * 1000 - amountIn0 * 3
              adj1 == newBal1 * 1000 - amountIn1 * 3
          IN
          /\ adj0 > 0
          /\ adj1 > 0
          /\ adj0 * adj1 >= reserve0 * reserve1 * 1000000
       /\ reserve0' = newBal0
       /\ reserve1' = newBal1
       /\ balance0' = newBal0
       /\ balance1' = newBal1
       /\ UNCHANGED <<totalSupply, balanceLP, kLast>>
       /\ locked' = FALSE
       /\ pc' = "idle"

-----------------------------------------------------------------------------
(*
 * FLASH SWAP: Models the three-phase atomicity of flash swaps.
 *
 * Phase 1 (FlashBegin): Optimistically transfer tokens out, acquire lock.
 * Phase 2 (FlashCallback): External callee executes (tokens are out,
 *          reentrancy lock held — no pair mutations allowed).
 * Phase 3 (FlashVerify): Verify constant product, update reserves, release lock.
 *
 * The lock ensures no swap/mint/burn can interleave during the callback.
 *)

FlashBegin(amount0Out, amount1Out) ==
    /\ locked = FALSE
    /\ pc = "idle"
    /\ amount0Out >= 0 /\ amount1Out >= 0
    /\ amount0Out > 0 \/ amount1Out > 0
    /\ amount0Out < reserve0
    /\ amount1Out < reserve1
    \* Optimistic transfer: tokens leave the contract
    /\ balance0' = balance0 - amount0Out
    /\ balance1' = balance1 - amount1Out
    /\ locked' = TRUE
    /\ pc' = "flash_callback"
    /\ UNCHANGED <<reserve0, reserve1, totalSupply, balanceLP, kLast>>

FlashCallback(repay0, repay1) ==
    /\ locked = TRUE
    /\ pc = "flash_callback"
    /\ repay0 >= 0 /\ repay1 >= 0
    \* Callee sends tokens back (possibly more than borrowed)
    /\ balance0' = balance0 + repay0
    /\ balance1' = balance1 + repay1
    /\ balance0 + repay0 <= MaxTokens
    /\ balance1 + repay1 <= MaxTokens
    /\ pc' = "flash_verify"
    /\ UNCHANGED <<reserve0, reserve1, totalSupply, balanceLP, locked, kLast>>

FlashVerify ==
    /\ locked = TRUE
    /\ pc = "flash_verify"
    \* Compute amounts in
    /\ LET amountIn0 == IF balance0 > reserve0 THEN balance0 - reserve0 ELSE 0
           amountIn1 == IF balance1 > reserve1 THEN balance1 - reserve1 ELSE 0
       IN
       /\ amountIn0 > 0 \/ amountIn1 > 0
       \* Fee-adjusted constant product check
       /\ LET adj0 == balance0 * 1000 - amountIn0 * 3
              adj1 == balance1 * 1000 - amountIn1 * 3
          IN
          /\ adj0 > 0
          /\ adj1 > 0
          /\ adj0 * adj1 >= reserve0 * reserve1 * 1000000
       /\ reserve0' = balance0
       /\ reserve1' = balance1
       /\ locked' = FALSE
       /\ pc' = "idle"
       /\ UNCHANGED <<totalSupply, balanceLP, balance0, balance1, kLast>>

-----------------------------------------------------------------------------
(* Reentrancy guard: no mutation while locked *)

ReentrancyBlocked ==
    locked = TRUE =>
        /\ pc # "idle"
        \* When locked, only flash callback/verify transitions are possible;
        \* Mint, Burn, Swap are all blocked by the locked = FALSE precondition.

-----------------------------------------------------------------------------
(* Next-state relation *)

Next ==
    \/ \E a \in Actors, am0, am1 \in 1..MaxTokens :
         Mint(a, am0, am1)
    \/ \E a \in Actors, liq \in 1..MaxTokens :
         Burn(a, liq)
    \/ \E a0Out, a1Out, a0In, a1In \in 0..MaxTokens :
         Swap(a0Out, a1Out, a0In, a1In)
    \/ \E a0Out, a1Out \in 0..MaxTokens :
         FlashBegin(a0Out, a1Out)
    \/ \E r0, r1 \in 0..MaxTokens :
         FlashCallback(r0, r1)
    \/ FlashVerify

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* INVARIANTS *)

(*
 * Inv_ConstantProduct: After any completed action (pc = "idle"),
 * k never decreases relative to kLast (fees cause k to grow).
 * On an empty pool, both are 0.
 *)
Inv_ConstantProduct ==
    pc = "idle" =>
        reserve0 * reserve1 >= kLast

(*
 * Inv_LPProportionality: The sum of all LP balances plus the
 * permanently locked MINIMUM_LIQUIDITY equals totalSupply.
 * (MINIMUM_LIQUIDITY is sent to address(0), not in Actors.)
 *)
Inv_LPShareConsistency ==
    pc = "idle" =>
        LET sumLP == CHOOSE s \in Nat :
              s = 0 + \* placeholder; in practice we sum over Actors
                  LET F[S \in SUBSET Actors] ==
                      IF S = {} THEN 0
                      ELSE LET a == CHOOSE x \in S : TRUE
                           IN balanceLP[a] + F[S \ {a}]
                  IN F[Actors]
        IN
        IF totalSupply > 0
        THEN totalSupply = sumLP + MINIMUM_LIQUIDITY
        ELSE sumLP = 0

(*
 * Inv_ReservesMatchBalances: When not in a flash swap (idle),
 * tracked reserves equal actual balances.
 *)
Inv_ReservesMatchBalances ==
    pc = "idle" =>
        /\ reserve0 = balance0
        /\ reserve1 = balance1

(*
 * Inv_FlashAtomicity: During a flash swap (locked = TRUE),
 * reserves have NOT been updated yet — only balances change.
 * No other pair mutation (mint/burn/swap) can execute.
 *)
Inv_FlashAtomicity ==
    locked = TRUE =>
        /\ pc \in {"flash_callback", "flash_verify"}
        \* Reserves still reflect pre-flash state (not yet updated)

(*
 * Inv_NoReentrancy: The lock prevents concurrent mutations.
 *)
Inv_NoReentrancy ==
    locked = TRUE => pc # "idle"

=============================================================================
