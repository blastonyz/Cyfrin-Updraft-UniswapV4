// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Create2} from "openzeppelin/utils/Create2.sol";
import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "uniswap-v4-core/libraries/Hooks.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {HookMiner} from "uniswap-v4-periphery/utils/HookMiner.sol";
import {POOL_MANAGER, WETH, USDC} from "../src/Constants.sol";
import {CounterHook} from "../src/CounterHook.sol";

contract CounterHookTest is Test {
    using PoolIdLibrary for PoolKey;
    
    IPoolManager poolManager = IPoolManager(POOL_MANAGER);
    CounterHook hook;
    
    function setUp() public {
        // Find a valid salt for deploying the hook
        // The hook address must match the permissions set in getHookPermissions()
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        console.log("flags: ",flags);
        // Mine for a salt that creates a valid hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(CounterHook).creationCode,
            abi.encode(address(poolManager))
        );
        
        // Deploy the hook using Create2 with the found salt
        hook = new CounterHook{salt: salt}(address(poolManager));
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        
        console.log("Hook deployed at:", address(hook));
    }
    
    function test_CounterIncrementsOnSwap() public {
        // Create a pool key with our hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        PoolId poolId = key.toId();
        
        // Check initial counts
        assertEq(hook.counts(poolId, "beforeSwap"), 0);
        assertEq(hook.counts(poolId, "afterSwap"), 0);
        assertEq(hook.counts(poolId, "beforeAddLiquidity"), 0);
        assertEq(hook.counts(poolId, "beforeRemoveLiquidity"), 0);
        
        console.log("Initial counts verified - all zero");
    }
}
