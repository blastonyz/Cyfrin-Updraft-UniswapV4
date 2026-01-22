// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "uniswap-v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "uniswap-v4-core/types/BalanceDelta.sol";
import {SafeCast} from "uniswap-v4-core/libraries/SafeCast.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "../src/Constants.sol";

contract Swap is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLib for address;

    IPoolManager public immutable poolManager;

    struct SwapExactInputSingleHop {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        // Write your code here
        (address caller,SwapExactInputSingleHop memory params ) = abi.decode(data,(address, SwapExactInputSingleHop));
        
        BalanceDelta delta = poolManager.swap({
            key: params.poolKey,
            params: IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                // amountSpecified < 0 = amount in
                // amountSpecified > 0 = amount out
                amountSpecified: -(params.amountIn.toInt256()),
                // price = Currency 1 / currency 0
                // 0 for 1 = price decreases
                // 1 for 0 = price increases
                sqrtPriceLimitX96: params.zeroForOne
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            hookData: ""
        });
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        (
            Currency currencyIn,
            Currency currencyOut,
            uint256 amountIn,
            uint256 amountOut
        ) = params.zeroForOne?
             (
                params.poolKey.currency0,
                params.poolKey.currency1,
                uint256((-amount0).toUint128()),
                uint256(amount1.toUint128())
            )
            : (
                params.poolKey.currency1,
                params.poolKey.currency0,
                uint256((-amount1).toUint128()),
                uint256(amount0.toUint128())
            );

        require(amountOut >= params.amountOutMin, "amount out < min");

        poolManager.take({
            currency: currencyOut,
            to: caller,
            amount: amountOut
        });

        poolManager.sync(currencyIn);

        if (Currency.unwrap(currencyIn) == address(0)) {
            poolManager.settle{value: amountIn}();
        } else {
            IERC20(Currency.unwrap(currencyIn)).transfer(address(poolManager), amountIn);
            poolManager.settle();
        }

        return "";
    }

    function swap(SwapExactInputSingleHop calldata params) external payable {
        Currency currencyInCurrency = params.zeroForOne
            ? params.poolKey.currency0
            : params.poolKey.currency1;
        address currencyIn = Currency.unwrap(currencyInCurrency);

        currencyIn.transferIn(msg.sender, uint256(params.amountIn));
        poolManager.unlock(abi.encode(msg.sender, params));

        // Refund
        uint256 bal = currencyIn.balanceOf(address(this));
        if (bal > 0) {
            currencyIn.transferOut(msg.sender, bal);
        }
       
    }
}

