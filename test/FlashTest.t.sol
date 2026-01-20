// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {Flash} from "../src/Flash.sol";
import {POOL_MANAGER} from "../src/Constants.sol";
import {USDC} from "../src/Constants.sol";

contract FlashTester {
    uint256 public flashLoanAmount;
    address public flashContract;
    uint256 private initialBalance;
    
    fallback() external {
        // Capture the initial balance and the borrowed amount
        uint256 currentBalance = flashContract.balance;
        if (initialBalance == 0) {
            initialBalance = currentBalance;
        }
        flashLoanAmount = currentBalance - initialBalance;
        // Reset for next test
        initialBalance = 0;
    }
    
    function setFlashContract(address _flash) external {
        flashContract = _flash;
    }
    
    function resetBalance() external {
        initialBalance = flashContract.balance;
    }
}

contract FlashTest is Test {
    Flash public flash;
    FlashTester public tester;
    
    address user = makeAddr("user");
    
    function setUp() public {
        // Deploy tester contract
        tester = new FlashTester();
        
        // Deploy Flash contract
        flash = new Flash(POOL_MANAGER, address(tester));
        
        // Set flash contract address in tester
        tester.setFlashContract(address(flash));
        
        console.log("Flash contract deployed at:", address(flash));
        console.log("Tester contract deployed at:", address(tester));
    }
    
    function testFlashETH() public {
        uint256 amount = 1 ether;
        
        console.log("=== Testing Flash Loan with ETH ===");
        console.log("Amount to borrow:", amount);
        
        // Fund the flash contract with some ETH for fees
        vm.deal(address(flash), 0.1 ether);
        
        // Reset balance tracker before flash loan
        tester.resetBalance();
        
        // Execute flash loan
        vm.prank(user);
        flash.flash(address(0), amount);
        
        console.log("Flash loan executed successfully!");
        console.log("Amount borrowed by tester:", tester.flashLoanAmount());
        
        assertEq(tester.flashLoanAmount(), amount, "Flash loan amount mismatch");
    }
    
    function testFlashUSDC() public {
        uint256 amount = 1000e6; // 1000 USDC
        
        console.log("=== Testing Flash Loan with USDC ===");
        console.log("Amount to borrow:", amount);
        
        // Fund the flash contract with some USDC for fees
        deal(USDC, address(flash), 10e6);
        
        // Execute flash loan
        vm.prank(user);
        flash.flash(USDC, amount);
        
        console.log("Flash loan executed successfully!");
    }
    
    function testFlashMultipleTimes() public {
        uint256 amount = 0.5 ether;
        
        console.log("=== Testing Multiple Flash Loans ===");
        
        vm.deal(address(flash), 1 ether);
        
        for (uint i = 0; i < 3; i++) {
            console.log("Flash loan iteration:", i + 1);
            vm.prank(user);
            flash.flash(address(0), amount);
        }
        
        console.log("All flash loans executed successfully!");
    }
}
