// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {Router} from "../src/Router.sol";
import {POOL_MANAGER, WETH, USDC, USDT, WBTC} from "../src/Constants.sol";

contract RouterTest is Test {
    Router public router;
    
    address user = makeAddr("user");
    
    function setUp() public {
        router = new Router(POOL_MANAGER);
        console.log("Router contract deployed at:", address(router));
    }
    
    function test_SwapExactInputSingle_ETHtoUSDC() public {
        uint128 amountIn = 1 ether;
        uint128 amountOutMin = 0;
        
        // Create PoolKey for ETH/USDC pool
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),       // USDC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        Router.ExactInputSingleParams memory params = Router.ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            hookData: ""
        });
        
        console.log("=== Testing Swap Exact Input Single: ETH -> USDC ===");
        console.log("Amount in (ETH):", amountIn);
        
        vm.deal(user, 10 ether);
        
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User ETH balance before:", userETHBefore);
        console.log("User USDC balance before:", userUSDCBefore);
        
        vm.prank(user);
        uint256 amountOut = router.swapExactInputSingle{value: amountIn}(params);
        
        uint256 userUSDCAfter = IERC20(USDC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User ETH balance after:", userETHAfter);
        console.log("User USDC balance after:", userUSDCAfter);
        console.log("Amount out (USDC):", amountOut);
        
        assertLt(userETHAfter, userETHBefore, "ETH should decrease");
        assertGt(userUSDCAfter, userUSDCBefore, "USDC should increase");
        assertEq(userUSDCAfter - userUSDCBefore, amountOut, "USDC received should match amountOut");
    }
    
    function test_SwapExactOutputSingle_USDCtoETH() public {
        uint128 amountOut = 0.1 ether;
        uint128 amountInMax = 1000e6; // Max 1000 USDC
        
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),       // USDC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        Router.ExactOutputSingleParams memory params = Router.ExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: false, // USDC -> ETH
            amountOut: amountOut,
            amountInMax: amountInMax,
            hookData: ""
        });
        
        console.log("=== Testing Swap Exact Output Single: USDC -> ETH ===");
        console.log("Amount out (ETH):", amountOut);
        
        deal(USDC, user, 10000e6);
        
        uint256 userUSDCBefore = IERC20(USDC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User USDC balance before:", userUSDCBefore);
        console.log("User ETH balance before:", userETHBefore);
        
        vm.prank(user);
        IERC20(USDC).approve(address(router), amountInMax);
        
        vm.prank(user);
        uint256 amountIn = router.swapExactOutputSingle(params);
        
        uint256 userUSDCAfter = IERC20(USDC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User USDC balance after:", userUSDCAfter);
        console.log("User ETH balance after:", userETHAfter);
        console.log("Amount in (USDC):", amountIn);
        
        assertLt(userUSDCAfter, userUSDCBefore, "USDC should decrease");
        assertGt(userETHAfter, userETHBefore, "ETH should increase");
        assertEq(userETHAfter - userETHBefore, amountOut, "ETH received should match amountOut");
    }
    
    function test_SwapExactInput_MultiHop() public {
        // Swap ETH -> USDC -> WBTC (using existing pools)
        uint128 amountIn = 1 ether;
        uint128 amountOutMin = 0;
        
        Router.PathKey[] memory path = new Router.PathKey[](2);
        
        // First hop: ETH -> USDC
        path[0] = Router.PathKey({
            currency: USDC,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0),
            hookData: ""
        });
        
        // Second hop: USDC -> WBTC
        path[1] = Router.PathKey({
            currency: WBTC,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0),
            hookData: ""
        });
        
        Router.ExactInputParams memory params = Router.ExactInputParams({
            currencyIn: address(0), // ETH
            path: path,
            amountIn: amountIn,
            amountOutMin: amountOutMin
        });
        
        console.log("=== Testing Swap Exact Input Multi-Hop: ETH -> USDC -> WBTC ===");
        console.log("Amount in (ETH):", amountIn);
        
        vm.deal(user, 10 ether);
        
        uint256 userWBTCBefore = IERC20(WBTC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User ETH balance before:", userETHBefore);
        console.log("User WBTC balance before:", userWBTCBefore);
        
        vm.prank(user);
        uint256 amountOut = router.swapExactInput{value: amountIn}(params);
        
        uint256 userWBTCAfter = IERC20(WBTC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User ETH balance after:", userETHAfter);
        console.log("User WBTC balance after:", userWBTCAfter);
        console.log("Amount out (WBTC):", amountOut);
        
        assertLt(userETHAfter, userETHBefore, "ETH should decrease");
        assertGt(userWBTCAfter, userWBTCBefore, "WBTC should increase");
    }
    
    function test_SwapExactOutput_MultiHop() public {
        // Swap WBTC -> USDC -> ETH (using existing pools)
        uint128 amountOut = 0.1 ether;
        uint128 amountInMax = 0.01e8; // Max 0.01 WBTC
        
        Router.PathKey[] memory path = new Router.PathKey[](2);
        
        // path[0] pairs with path[1] for first swap (WBTC -> USDC)
        path[0] = Router.PathKey({
            currency: WBTC,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0),
            hookData: ""
        });
        
        // path[1] pairs with currencyOut for last swap (USDC -> ETH)
        path[1] = Router.PathKey({
            currency: USDC,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0),
            hookData: ""
        });
        
        Router.ExactOutputParams memory params = Router.ExactOutputParams({
            currencyOut: address(0), // ETH
            path: path,
            amountOut: amountOut,
            amountInMax: amountInMax
        });
        
        console.log("=== Testing Swap Exact Output Multi-Hop: WBTC -> USDC -> ETH ===");
        console.log("Amount out (ETH):", amountOut);
        
        deal(WBTC, user, 1e8); // Give user 1 WBTC
        
        uint256 userWBTCBefore = IERC20(WBTC).balanceOf(user);
        uint256 userETHBefore = user.balance;
        
        console.log("User WBTC balance before:", userWBTCBefore);
        console.log("User ETH balance before:", userETHBefore);
        
        vm.prank(user);
        IERC20(WBTC).approve(address(router), amountInMax);
        
        vm.prank(user);
        uint256 amountIn = router.swapExactOutput(params);
        
        uint256 userWBTCAfter = IERC20(WBTC).balanceOf(user);
        uint256 userETHAfter = user.balance;
        
        console.log("User WBTC balance after:", userWBTCAfter);
        console.log("User ETH balance after:", userETHAfter);
        console.log("Amount in (WBTC):", amountIn);
        
        assertLt(userWBTCAfter, userWBTCBefore, "WBTC should decrease");
        assertGt(userETHAfter, userETHBefore, "ETH should increase");
        assertEq(userETHAfter - userETHBefore, amountOut, "ETH received should match amountOut");
    }
}
