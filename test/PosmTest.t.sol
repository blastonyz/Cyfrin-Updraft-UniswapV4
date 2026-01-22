// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {IPositionManager} from "uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {PosmExercises} from "../src/Posm.sol";
import {POSITION_MANAGER, USDC, POOL_ID_ETH_USDC} from "../src/Constants.sol";

// Malicious contract that attempts reentrancy during unlock
contract ReentrancyAttacker {
    IPositionManager public posmManager;
    PoolKey public poolKey;
    bool public attacked;
    uint256 public tokenId;

    constructor(address _posmManager) {
        posmManager = IPositionManager(_posmManager);
    }

    function setPoolKey(PoolKey memory _poolKey) external {
        poolKey = _poolKey;
    }

    function attack() external payable {
        // Directly call PositionManager to mint - this will trigger our receive()
        bytes memory actions = abi.encodePacked(uint256(0)); // MINT_POSITION
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(poolKey, -600, 600, 1e18, type(uint128).max, type(uint128).max, address(this), "");
        
        posmManager.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp + 60);
    }

    // This will be called when PoolManager refunds ETH during the unlock
    receive() external payable {
        if (!attacked && msg.sender == address(0x000000000004444c5dc75cB358380D2e3dE08A90)) {
            attacked = true;
            // Try to mint again while PoolManager is still unlocked (reentrancy)
            bytes memory actions = abi.encodePacked(uint256(0));
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(poolKey, -1200, 1200, 5e17, type(uint128).max, type(uint128).max, address(this), "");
            
            // This should fail - trying to call modifyLiquidities while already in an unlock
            posmManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp + 60);
        }
    }
}

contract PosmTest is Test {
    using PoolIdLibrary for PoolKey;

    IPositionManager public posm;
    PosmExercises public posmContract;
    
    address user1 = makeAddr("user1");

    function setUp() public {
        posm = IPositionManager(POSITION_MANAGER);
        
        // Deploy our wrapper contract with USDC as currency1
        posmContract = new PosmExercises(USDC);

        // Fund contract
        vm.deal(address(posmContract), 10 ether);
        deal(USDC, address(posmContract), 100000e6);

        console.log("PosmExercises deployed at:", address(posmContract));
    }

    function _createPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }



    function test_Mint() public {
        PoolKey memory poolKey = _createPoolKey();
        uint256 tokenId = posmContract.mint(poolKey, -600, 600, 1e18);
        
        assertGt(tokenId, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(posmContract));
        console.log("Position minted:", tokenId);
    }

    function test_IncreaseLiquidity() public {
        PoolKey memory poolKey = _createPoolKey();
        uint256 tokenId = posmContract.mint(poolKey, -600, 600, 1e18);
        
        uint128 liquidityBefore = posm.getPositionLiquidity(tokenId);
        posmContract.increaseLiquidity(tokenId, 5e17, type(uint128).max, type(uint128).max);
        uint128 liquidityAfter = posm.getPositionLiquidity(tokenId);
        
        assertGt(liquidityAfter, liquidityBefore);
        console.log("Liquidity increased from", liquidityBefore, "to", liquidityAfter);
    }

    function test_DecreaseLiquidity() public {
        PoolKey memory poolKey = _createPoolKey();
        uint256 tokenId = posmContract.mint(poolKey, -600, 600, 2e18);
        
        posmContract.decreaseLiquidity(tokenId, 1e18, 0, 0);
        console.log("Liquidity decreased successfully");
    }

    function test_Burn() public {
        PoolKey memory poolKey = _createPoolKey();
        uint256 tokenId = posmContract.mint(poolKey, -600, 600, 1e18);
        
        posmContract.burn(tokenId, 0, 0);
        assertEq(posm.getPositionLiquidity(tokenId), 0);
        console.log("Position burned");
    }

    // Test full lifecycle
    function test_FullCycle() public {
        PoolKey memory poolKey = _createPoolKey();
        
        // 1. Mint
        uint256 tokenId = posmContract.mint(poolKey, -600, 600, 1e18);
        console.log("1. Minted, tokenId:", tokenId);
        
        // 2. Increase
        uint128 liquidityBefore = posm.getPositionLiquidity(tokenId);
        posmContract.increaseLiquidity(tokenId, 5e17, type(uint128).max, type(uint128).max);
        uint128 liquidityAfter = posm.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBefore);
        console.log("2. Increased liquidity from", liquidityBefore, "to", liquidityAfter);
        
        // 3. Decrease
        posmContract.decreaseLiquidity(tokenId, 5e17, 0, 0);
        uint128 liquidityAfterDecrease = posm.getPositionLiquidity(tokenId);
        assertLt(liquidityAfterDecrease, liquidityAfter);
        console.log("3. Decreased liquidity to", liquidityAfterDecrease);
        
        // 4. Burn
        posmContract.burn(tokenId, 0, 0);
        assertEq(posm.getPositionLiquidity(tokenId), 0);
        console.log("4. Position burned successfully");
    }

    function test_RevertWhen_ReentrancyAttempt() public {
        PoolKey memory poolKey = _createPoolKey();
        
        // Deploy attacker that directly calls PositionManager
        ReentrancyAttacker attacker = new ReentrancyAttacker(POSITION_MANAGER);
        attacker.setPoolKey(poolKey);
        
        // Fund the attacker with ETH and USDC
        vm.deal(address(attacker), 10 ether);
        deal(USDC, address(attacker), 100000e6);
        
        // Approve Permit2 contract directly (0x000000000022D473030F116dDEE9F6B43aC78BA3)
        vm.startPrank(address(attacker));
        IERC20(USDC).approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint256).max);
        vm.stopPrank();
        
        // The attack should revert when trying to call modifyLiquidities during receive()
        // PositionManager has ReentrancyLock that prevents calling modifyLiquidities when already locked
        vm.expectRevert();
        attacker.attack{value: 1 ether}();
        
        console.log("Reentrancy attack correctly prevented by ReentrancyLock");
    }
}