// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Reader} from "../src/Reader.sol";
import {POOL_MANAGER, WETH, USDC} from "../src/Constants.sol";

contract ReaderTest is Test {
    Reader public reader;
    
    address user = makeAddr("user");
    
    function setUp() public {
        reader = new Reader(POOL_MANAGER);
        console.log("Reader contract deployed at:", address(reader));
    }
    
    function test_ComputeSlot() public view {
        bytes32 slot = reader.computeSlot(user, USDC);
        
        console.log("Computed slot:");
        console.logBytes32(slot);
        
        // Verify slot is not zero
        assertTrue(slot != bytes32(0), "Slot should not be zero");
    }
    
    function test_GetCurrencyDelta() public view {
        // Test getting delta for ETH
        int256 deltaETH = reader.getCurrencyDelta(address(reader), address(0));
        console.log("=== Currency Delta for ETH ===");
        console.logInt(deltaETH);
        
        // Test getting delta for USDC
        int256 deltaUSDC = reader.getCurrencyDelta(address(reader), USDC);
        console.log("=== Currency Delta for USDC ===");
        console.logInt(deltaUSDC);
        
        // Initially deltas should be 0 since no transactions have occurred
        assertEq(deltaETH, 0, "Initial ETH delta should be 0");
        assertEq(deltaUSDC, 0, "Initial USDC delta should be 0");
    }
    
    function test_GetCurrencyDeltaForUser() public view {
        // Test getting delta for a specific user
        int256 deltaUser = reader.getCurrencyDelta(user, USDC);
        console.log("=== Currency Delta for User ===");
        console.logInt(deltaUser);
        
        assertEq(deltaUser, 0, "User delta should be 0 initially");
    }
}
