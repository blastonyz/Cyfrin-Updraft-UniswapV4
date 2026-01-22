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
import {POSITION_MANAGER, USDC, PERMIT2, POOL_MANAGER, POOL_ID_ETH_USDC} from "../src/Constants.sol";
import {Reposition} from "../src/Reposition.sol";
import {Actions} from "uniswap-v4-periphery/libraries/Actions.sol";

contract RepositionTest is Test {
    using PoolIdLibrary for PoolKey;

    IPositionManager public posm;
    IPoolManager public poolManager;
    Reposition public reposition;
    
    // Pool parameters from mainnet
    PoolKey public poolKey;
    int24 public tickSpacing;
    
    address user1 = makeAddr("user1");

    function setUp() public {
        posm = IPositionManager(POSITION_MANAGER);
        poolManager = IPoolManager(POOL_MANAGER);
        
        // Get existing pool info from mainnet
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        tickSpacing = 60;
        
        // Deploy reposition contract
        reposition = new Reposition(POSITION_MANAGER);

        // Fund contract (like PosmTest does)
        vm.deal(address(reposition), 10 ether);
        deal(USDC, address(reposition), 100000e6);

        // Approve USDC to Permit2 and then Permit2 to PositionManager (like PosmExercises does)
        vm.startPrank(address(reposition));
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            USDC,
            address(posm),
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();

        console.log("Reposition deployed at:", address(reposition));
        console.log("Using pool with tickSpacing:", uint256(int256(tickSpacing)));
    }

    function _createPoolKey() internal view returns (PoolKey memory) {
        return poolKey;
    }

    function _getValidTickRange() internal pure returns (int24 tickLower, int24 tickUpper) {
        // Use the same tick range as PosmTest that we know works on mainnet fork
        tickLower = -600;
        tickUpper = 600;
    }

    function _mintPosition(int24 tickLower, int24 tickUpper, uint256 liquidity) 
        internal 
        returns (uint256 tokenId) 
    {
        // Get current tick from pool to validate range
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        
        console.log("Current pool tick:", currentTick);
        console.log("Requested tickLower:", tickLower);
        console.log("Requested tickUpper:", tickUpper);
        
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(reposition), "");
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(USDC));
        params[2] = abi.encode(Currency.wrap(address(0)), address(reposition));
        
        vm.prank(address(reposition));
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 60);
        
        tokenId = posm.nextTokenId() - 1;
    }

    function test_Reposition() public {
        // Get valid tick range based on current pool state
        (int24 tickLower, int24 tickUpper) = _getValidTickRange();
        
        // Mint initial position with ticks aligned to tickSpacing
        uint256 tokenId = _mintPosition(tickLower, tickUpper, 1e18);
        
        console.log("Initial tokenId:", tokenId);
        console.log("Initial owner:", IERC721(address(posm)).ownerOf(tokenId));
        
        // Reposition to wider range
        int24 newTickLower = tickLower - (tickSpacing * 5);
        int24 newTickUpper = tickUpper + (tickSpacing * 5);
        
        vm.prank(address(reposition));
        uint256 newTokenId = reposition.reposition(tokenId, newTickLower, newTickUpper);
        
        console.log("New tokenId:", newTokenId);
        console.log("New owner:", IERC721(address(posm)).ownerOf(newTokenId));
        
        // Verify old position is burned
        vm.expectRevert();
        IERC721(address(posm)).ownerOf(tokenId);
        
        // Verify new position exists and is owned by reposition contract
        assertEq(IERC721(address(posm)).ownerOf(newTokenId), address(reposition), "New position should be owned by reposition contract");
        
        console.log("Reposition successful - old position burned, new position created");
    }

    function test_RevertWhen_InvalidTickRange() public {
        (int24 tickLower, int24 tickUpper) = _getValidTickRange();
        uint256 tokenId = _mintPosition(tickLower, tickUpper, 1e18);
        
        // Try to reposition with invalid tick range (tickLower >= tickUpper)
        vm.prank(address(reposition));
        vm.expectRevert("tick lower >= tick upper");
        reposition.reposition(tokenId, tickUpper, tickLower);
        
        console.log("Correctly reverted on invalid tick range");
    }

    function test_RevertWhen_NotApproved() public {
        (int24 tickLower, int24 tickUpper) = _getValidTickRange();
        uint256 tokenId = _mintPosition(tickLower, tickUpper, 1e18);
        
        // Transfer to user1 so reposition contract no longer owns it
        vm.prank(address(reposition));
        IERC721(address(posm)).transferFrom(address(reposition), user1, tokenId);
        
        // Now reposition doesn't own it - should fail
        int24 newTickLower = tickLower - (tickSpacing * 5);
        int24 newTickUpper = tickUpper + (tickSpacing * 5);
        
        vm.prank(address(reposition));
        vm.expectRevert();
        reposition.reposition(tokenId, newTickLower, newTickUpper);
        
        console.log("Correctly reverted when not owner");
    }

    function test_MultipleRepositions() public {
        (int24 tickLower, int24 tickUpper) = _getValidTickRange();
        
        // Mint initial position
        uint256 tokenId = _mintPosition(tickLower, tickUpper, 1e18);
        
        // First reposition - wider range
        int24 tickLower2 = tickLower - (tickSpacing * 5);
        int24 tickUpper2 = tickUpper + (tickSpacing * 5);
        
        vm.prank(address(reposition));
        uint256 tokenId2 = reposition.reposition(tokenId, tickLower2, tickUpper2);
        
        console.log("First reposition - tokenId:", tokenId2);
        
        // Second reposition - narrower range
        int24 tickLower3 = tickLower - (tickSpacing * 2);
        int24 tickUpper3 = tickUpper + (tickSpacing * 2);
        
        vm.prank(address(reposition));
        uint256 tokenId3 = reposition.reposition(tokenId2, tickLower3, tickUpper3);
        
        console.log("Second reposition - tokenId:", tokenId3);
        
        // Verify final position is owned by reposition contract
        assertEq(IERC721(address(posm)).ownerOf(tokenId3), address(reposition), "Final position should be owned by reposition contract");
        
        console.log("Multiple repositions successful");
    }
               
}
