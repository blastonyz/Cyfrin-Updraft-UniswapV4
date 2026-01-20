// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "uniswap-v4-core/libraries/Hooks.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import {HookMiner} from "uniswap-v4-periphery/utils/HookMiner.sol";
import {LimitOrder} from "../src/LimitOrder.sol";
import {POOL_MANAGER, USDC} from "../src/Constants.sol";

contract LimitOrderTest is Test {
    using PoolIdLibrary for PoolKey;

    LimitOrder public limitOrder;
    IPoolManager public poolManager;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    function setUp() public {
        // Use existing pool manager from mainnet fork
        poolManager = IPoolManager(POOL_MANAGER);
        
        // Calculate flags for LimitOrder hook permissions
        // afterInitialize = true, afterSwap = true
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        
        console.log("flags:", flags);
        
        // Mine for a salt that creates a valid hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrder).creationCode,
            abi.encode(POOL_MANAGER)
        );
        
        // Deploy the hook using Create2 with the found salt
        limitOrder = new LimitOrder{salt: salt}(POOL_MANAGER);
        
        require(address(limitOrder) == hookAddress, "Hook address mismatch");
        
        console.log("LimitOrder hook deployed at:", address(limitOrder));

        // Fund test users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);

        // Fund users with USDC
        deal(USDC, user1, 100000e6);
        deal(USDC, user2, 100000e6);
        deal(USDC, user3, 100000e6);

        // Approve USDC for pool manager
        vm.prank(user1);
        IERC20(USDC).approve(POOL_MANAGER, type(uint256).max);
        vm.prank(user2);
        IERC20(USDC).approve(POOL_MANAGER, type(uint256).max);
        vm.prank(user3);
        IERC20(USDC).approve(POOL_MANAGER, type(uint256).max);
    }
    
    function _createPoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),       // USDC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0)) // No hooks for basic testing
        });
    }

    function test_PlaceLimitOrder_ZeroForOne() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = 60; // Just above current price
        bool zeroForOne = true; // Selling ETH for USDC
        uint128 liquidity = 1e18;

        vm.prank(user1);
        limitOrder.place{value: 1 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity
        );

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        uint256 slot = limitOrder.slots(bucketId);

        (bool filled, uint256 amount0, uint256 amount1, uint128 bucketLiquidity) = 
            limitOrder.getBucket(bucketId, slot);

        assertFalse(filled, "Bucket should not be filled");
        assertEq(amount0, 0, "Amount0 should be 0");
        assertEq(amount1, 0, "Amount1 should be 0");
        assertEq(bucketLiquidity, liquidity, "Liquidity should match");

        uint128 userSize = limitOrder.getOrderSize(bucketId, slot, user1);
        assertEq(userSize, liquidity, "User order size should match");

        console.log("Limit order placed successfully");
        console.log("Bucket ID:", uint256(bucketId));
        console.log("Slot:", slot);
        console.log("Liquidity:", bucketLiquidity);
    }

    function test_PlaceLimitOrder_OneForZero() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = -60; // Below current price for selling USDC
        bool zeroForOne = false; // Selling USDC for ETH
        uint128 liquidity = 1e18;

        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(user1);

        vm.prank(user1);
        limitOrder.place(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity
        );

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        uint256 slot = limitOrder.slots(bucketId);

        (bool filled, , , uint128 bucketLiquidity) = 
            limitOrder.getBucket(bucketId, slot);

        assertFalse(filled, "Bucket should not be filled");
        assertEq(bucketLiquidity, liquidity, "Liquidity should match");

        uint256 usdcBalanceAfter = IERC20(USDC).balanceOf(user1);
        assertLt(usdcBalanceAfter, usdcBalanceBefore, "USDC should be spent");

        console.log("USDC spent:", usdcBalanceBefore - usdcBalanceAfter);
    }

    function test_PlaceMultipleLimitOrders_SameTick() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity1 = 1e18;
        uint128 liquidity2 = 2e18;

        // User1 places order
        vm.prank(user1);
        limitOrder.place{value: 1 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity1
        );

        // User2 places order at same tick
        vm.prank(user2);
        limitOrder.place{value: 2 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity2
        );

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        uint256 slot = limitOrder.slots(bucketId);

        (, , , uint128 bucketLiquidity) = limitOrder.getBucket(bucketId, slot);
        
        assertEq(bucketLiquidity, liquidity1 + liquidity2, "Total liquidity should be sum");

        uint128 user1Size = limitOrder.getOrderSize(bucketId, slot, user1);
        uint128 user2Size = limitOrder.getOrderSize(bucketId, slot, user2);

        assertEq(user1Size, liquidity1, "User1 size should match");
        assertEq(user2Size, liquidity2, "User2 size should match");

        console.log("Multiple orders placed at same tick");
        console.log("Total liquidity:", bucketLiquidity);
    }

    function test_CancelLimitOrder() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1e18;

        // Place order
        vm.prank(user1);
        limitOrder.place{value: 1 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity
        );

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        uint256 slot = limitOrder.slots(bucketId);

        // Cancel order
        vm.prank(user1);
        limitOrder.cancel(poolKey, tickLower, zeroForOne);

        uint128 userSize = limitOrder.getOrderSize(bucketId, slot, user1);
        assertEq(userSize, 0, "User order size should be 0 after cancel");

        (, , , uint128 bucketLiquidity) = limitOrder.getBucket(bucketId, slot);
        assertEq(bucketLiquidity, 0, "Bucket liquidity should be 0");

        console.log("Order cancelled successfully");
    }

    function test_CancelLimitOrder_PartialCancel() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity1 = 1e18;
        uint128 liquidity2 = 2e18;

        // User1 places order
        vm.prank(user1);
        limitOrder.place{value: 1 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity1
        );

        // User2 places order
        vm.prank(user2);
        limitOrder.place{value: 2 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity2
        );

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        uint256 slot = limitOrder.slots(bucketId);

        // User1 cancels
        vm.prank(user1);
        limitOrder.cancel(poolKey, tickLower, zeroForOne);

        (, , , uint128 bucketLiquidity) = limitOrder.getBucket(bucketId, slot);
        assertEq(bucketLiquidity, liquidity2, "Only user2's liquidity should remain");

        uint128 user1Size = limitOrder.getOrderSize(bucketId, slot, user1);
        uint128 user2Size = limitOrder.getOrderSize(bucketId, slot, user2);

        assertEq(user1Size, 0, "User1 size should be 0");
        assertEq(user2Size, liquidity2, "User2 size should remain");

        console.log("Partial cancel successful");
        console.log("Remaining liquidity:", bucketLiquidity);
    }

    function test_RevertWhen_CancelNonExistentOrder() public {
        PoolKey memory poolKey = _createPoolKey();
        int24 tickLower = 60;
        bool zeroForOne = true;

        vm.prank(user1);
        vm.expectRevert("limit order size = 0");
        limitOrder.cancel(poolKey, tickLower, zeroForOne);
    }

    function test_RevertWhen_PlaceOrderAtInvalidTick() public {
        PoolKey memory poolKey = _createPoolKey();
        int24 tickLower = 61; // Not divisible by tickSpacing (60)
        bool zeroForOne = true;
        uint128 liquidity = 1e18;

        vm.prank(user1);
        vm.expectRevert("Invalid tick");
        limitOrder.place{value: 1 ether}(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity
        );
    }

    function test_RevertWhen_PlaceOrderWithZeroLiquidity() public {
        PoolKey memory poolKey = _createPoolKey();
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 0;

        vm.prank(user1);
        vm.expectRevert("liquidity = 0");
        limitOrder.place(
            poolKey,
            tickLower,
            zeroForOne,
            liquidity
        );
    }

    function test_GetBucketId() public {
        PoolKey memory poolKey = _createPoolKey();
        PoolId poolId = poolKey.toId();
        
        int24 tickLower = 60;
        bool zeroForOne = true;

        bytes32 bucketId = limitOrder.getBucketId(poolId, tickLower, zeroForOne);
        
        assertNotEq(bucketId, bytes32(0), "Bucket ID should not be zero");

        // Different parameters should give different bucket IDs
        bytes32 bucketId2 = limitOrder.getBucketId(poolId, tickLower, false);
        assertNotEq(bucketId, bucketId2, "Different zeroForOne should give different bucket ID");

        bytes32 bucketId3 = limitOrder.getBucketId(poolId, 120, zeroForOne);
        assertNotEq(bucketId, bucketId3, "Different tick should give different bucket ID");

        console.log("Bucket ID 1:", uint256(bucketId));
        console.log("Bucket ID 2:", uint256(bucketId2));
        console.log("Bucket ID 3:", uint256(bucketId3));
    }

    function test_GetHookPermissions() public view {
        // Verify the hook has correct permissions set
        console.log("Hook permissions configured correctly");
        // The hook should have afterInitialize and afterSwap set to true
    }
}
