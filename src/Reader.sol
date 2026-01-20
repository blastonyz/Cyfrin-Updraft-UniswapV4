// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {TransientStateLibrary} from "uniswap-v4-core/libraries/TransientStateLibrary.sol";
import {DeltaResolver} from "uniswap-v4-periphery/base/DeltaResolver.sol";

contract Reader {
    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    function computeSlot(address target, address currency)
        public
        pure
        returns (bytes32 slot)
    {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(
                32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            slot := keccak256(0, 64)
        }
    }

    function getCurrencyDelta(address target, address currency)
        public
        view
        returns (int256 delta)
    {
        // Convert address to Currency type
        Currency currencyWrapped = Currency.wrap(currency);
        
        // Get the delta from poolManager using TransientStateLibrary
        delta = TransientStateLibrary.currencyDelta(poolManager, target, currencyWrapped);
    }
}