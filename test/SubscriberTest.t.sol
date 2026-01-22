// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "uniswap-v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "uniswap-v4-core/types/BalanceDelta.sol";
import {PositionInfo, PositionInfoLibrary} from "uniswap-v4-periphery/libraries/PositionInfoLibrary.sol";
import {Subscriber} from "../src/Subscriber.sol";
import {POSITION_MANAGER, USDC, PERMIT2, POOL_MANAGER, POOL_ID_ETH_USDC} from "../src/Constants.sol";
import {Actions} from "uniswap-v4-periphery/libraries/Actions.sol";

contract SubscriberTest is Test {
    using PoolIdLibrary for PoolKey;

    IPositionManager public posm;
    IPoolManager public poolManager;
    Subscriber public subscriber;
    
    // Pool parameters from mainnet
    PoolKey public poolKey;
    int24 public tickSpacing;
    
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        posm = IPositionManager(POSITION_MANAGER);
        poolManager = IPoolManager(POOL_MANAGER);
        
        // Get existing pool info from mainnet using POOL_ID_ETH_USDC
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        tickSpacing = 60;
        
        // Deploy subscriber contract
        subscriber = new Subscriber(POSITION_MANAGER);

        // Fund contract (like PosmTest does)
        vm.deal(address(subscriber), 10 ether);
        deal(USDC, address(subscriber), 100000e6);

        // Approve USDC to Permit2 and then Permit2 to PositionManager (like PosmExercises does)
        vm.startPrank(address(subscriber));
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            USDC,
            address(posm),
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();

        console.log("Subscriber deployed at:", address(subscriber));
        console.log("Using pool with tickSpacing:", uint256(int256(tickSpacing)));
    }

    function _createPoolKey() internal view returns (PoolKey memory) {
        return poolKey;
    }

    function _mintPosition(uint256 liquidity) internal returns (uint256 tokenId) {
        // Use the same tick range as PosmTest that we know works on mainnet fork
        int24 tickLower = -600;
        int24 tickUpper = 600;
        
        console.log("Using tickLower:", tickLower);
        console.log("Using tickUpper:", tickUpper);
        
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(subscriber), abi.encode(address(subscriber)));
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(USDC));
        params[2] = abi.encode(Currency.wrap(address(0)), address(subscriber));
        
        vm.prank(address(subscriber));
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 60);
        
        // Get the minted tokenId (should be the latest)
        tokenId = posm.nextTokenId() - 1;
        
        // Subscribe to position updates
        vm.prank(address(subscriber));
        posm.subscribe(tokenId, address(subscriber), "");
    }

    function test_Subscribe() public {
        // Mint a position (subscriber is already subscribed via hookData)
        uint256 tokenId = _mintPosition(1e18);
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        
        // Check that tokens were minted during mint
        uint256 balance = subscriber.balanceOf(poolId, address(subscriber));
        assertEq(balance, 1e18, "Balance should equal initial liquidity");
        
        console.log("Subscriber balance after mint:", balance);
    }

    function test_ModifyLiquidity_Increase() public {
        // Mint position with subscriber auto-subscribed
        uint256 tokenId = _mintPosition(1e18);
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        
        uint256 balanceBefore = subscriber.balanceOf(poolId, address(subscriber));
        
        // Increase liquidity
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.SWEEP)
        );
        
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(tokenId, 5e17, type(uint128).max, type(uint128).max, "");
        params[1] = abi.encode(Currency.wrap(address(0)));
        params[2] = abi.encode(Currency.wrap(USDC));
        params[3] = abi.encode(Currency.wrap(address(0)), address(subscriber));
        
        vm.prank(address(subscriber));
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 60);
        
        uint256 balanceAfter = subscriber.balanceOf(poolId, address(subscriber));
        assertGt(balanceAfter, balanceBefore, "Balance should increase");
        
        console.log("Balance increased from", balanceBefore, "to", balanceAfter);
    }

    function test_ModifyLiquidity_Decrease() public {
        // Setup: mint with higher liquidity and auto-subscribe
        uint256 tokenId = _mintPosition(2e18);
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        
        uint256 balanceBefore = subscriber.balanceOf(poolId, address(subscriber));
        
        // Decrease liquidity
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 1e18, 0, 0, "");
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(USDC), address(subscriber));
        
        vm.prank(address(subscriber));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        
        uint256 balanceAfter = subscriber.balanceOf(poolId, address(subscriber));
        assertLt(balanceAfter, balanceBefore, "Balance should decrease");
        
        console.log("Balance decreased from", balanceBefore, "to", balanceAfter);
    }

    function test_Unsubscribe() public {
        // Setup: mint with auto-subscribe
        uint256 tokenId = _mintPosition(1e18);
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        
        uint256 balanceBefore = subscriber.balanceOf(poolId, address(subscriber));
        assertGt(balanceBefore, 0, "Should have balance before unsubscribe");
        
        // Unsubscribe
        vm.prank(address(subscriber));
        posm.unsubscribe(tokenId);
        
        uint256 balanceAfter = subscriber.balanceOf(poolId, address(subscriber));
        assertEq(balanceAfter, 0, "Balance should be zero after unsubscribe");
        
        console.log("Unsubscribed - balance went from", balanceBefore, "to", balanceAfter);
    }

    function test_BurnPosition() public {
        // Setup: mint with auto-subscribe
        uint256 tokenId = _mintPosition(1e18);
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        
        uint256 balanceBefore = subscriber.balanceOf(poolId, address(subscriber));
        assertGt(balanceBefore, 0, "Should have balance before burn");
        
        // Burn the position (must decrease liquidity first)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.TAKE_PAIR)
        );
        
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, "");
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(USDC), address(subscriber));
        
        vm.prank(address(subscriber));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        
        uint256 balanceAfter = subscriber.balanceOf(poolId, address(subscriber));
        assertEq(balanceAfter, 0, "Balance should be zero after burn");
        
        console.log("Position burned - balance cleared");
    }

    function test_RevertWhen_NotPositionManager() public {
        // Try to call notify functions directly (should revert)
        vm.expectRevert("not PositionManager");
        subscriber.notifySubscribe(1, "");
        
        vm.expectRevert("not PositionManager");
        subscriber.notifyUnsubscribe(1);
        
        vm.expectRevert("not PositionManager");
        subscriber.notifyModifyLiquidity(1, 100, BalanceDelta.wrap(0));
        
        vm.expectRevert("not PositionManager");
        subscriber.notifyBurn(1, user1, PositionInfo.wrap(0), 0, BalanceDelta.wrap(0));
        
        console.log("All direct calls correctly reverted");
    }

    function test_GetInfo() public {
        // Mint a position
        uint256 tokenId = _mintPosition(1e18);
        
        // Get info (after subscribing via mint)
        (bytes32 poolId, address owner, uint128 liquidity) = subscriber.getInfo(tokenId);
        
        assertEq(owner, address(subscriber), "Owner should be subscriber contract");
        assertEq(liquidity, 1e18, "Liquidity should match");
        assertGt(uint256(poolId), 0, "Pool ID should be non-zero");
        
        console.log("Position info retrieved successfully");
        console.log("  Owner:", owner);
        console.log("  Liquidity:", liquidity);
    }
}
