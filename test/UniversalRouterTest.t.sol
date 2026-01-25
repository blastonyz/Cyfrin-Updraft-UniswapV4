// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {UniversalRouterExercises} from "../src/UniversalRouter.sol";
import {POOL_MANAGER, WETH, USDC, UNIVERSAL_ROUTER, PERMIT2} from "../src/Constants.sol";

contract UniversalRouterTest is Test {
    UniversalRouterExercises public universalRouter;

    address user = makeAddr("user");
    
    // Pool key for ETH/USDC - the only initialized pool we can use
    PoolKey poolKey;
    
    function setUp() public {
        universalRouter = new UniversalRouterExercises();
        console.log("UniversalRouter contract deployed at:", address(universalRouter));
        
        // Create PoolKey for ETH/USDC pool (address(0) for native ETH)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),       // USDC
            fee: 3000,                             // 0.3% fee
            tickSpacing: 60,                       // Standard tick spacing for 0.3% fee
            hooks: IHooks(address(0))              // No hooks
        });
    }

    function test_SwapETHtoUSDC() public {
        // Amount to swap: 1 ETH
        uint128 amountIn = 1 ether;
        uint128 amountOutMin = 0; // Set to 0 for testing, in production calculate minimum
        
        console.log("=== Testing UniversalRouter Swap ETH to USDC ===");
        console.log("Amount in (ETH):", amountIn);
        
        // Fund user with ETH
        vm.deal(user, 10 ether);
        
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User ETH balance before:", userETHBefore);
        console.log("User USDC balance before:", userUSDCBefore);
        
        // Execute swap
        vm.prank(user);
        universalRouter.swap{value: amountIn}(
            poolKey,
            amountIn,
            amountOutMin,
            true // zeroForOne: swapping ETH (currency0) for USDC (currency1)
        );
        
        uint256 userUSDCAfter = IERC20(USDC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User ETH balance after:", userETHAfter);
        console.log("User USDC balance after:", userUSDCAfter);
        console.log("USDC received:", userUSDCAfter - userUSDCBefore);
        
        // Assertions
        assertLt(userETHAfter, userETHBefore, "ETH should decrease");
        assertGt(userUSDCAfter, userUSDCBefore, "USDC should increase");
    }
    
    function test_SwapUSDCtoETH() public {
        // Amount to swap: 1000 USDC
        uint128 amountIn = 1000e6;
        uint128 amountOutMin = 0;
        
        console.log("=== Testing UniversalRouter Swap USDC to ETH ===");
        console.log("Amount in (USDC):", amountIn);
        
        // Fund user with USDC
        deal(USDC, user, 10000e6);
        
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User USDC balance before:", userUSDCBefore);
        console.log("User ETH balance before:", userETHBefore);
        
        // Approve universalRouter contract to spend USDC
        vm.prank(user);
        IERC20(USDC).approve(address(universalRouter), amountIn);
        
        // Execute swap
        vm.prank(user);
        universalRouter.swap(
            poolKey,
            amountIn,
            amountOutMin,
            false // zeroForOne: swapping USDC (currency1) for ETH (currency0)
        );
        
        uint256 userUSDCAfter = IERC20(USDC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User USDC balance after:", userUSDCAfter);
        console.log("User ETH balance after:", userETHAfter);
        console.log("ETH received:", userETHAfter - userETHBefore);
        
        // Assertions
        assertLt(userUSDCAfter, userUSDCBefore, "USDC should decrease");
        assertGt(userETHAfter, userETHBefore, "ETH should increase");
        assertEq(userUSDCBefore - userUSDCAfter, amountIn, "Should spend exact USDC amount");
    }
}
