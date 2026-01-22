// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPoolManager} from "uniswap-v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "uniswap-v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {IHooks} from "uniswap-v4-core/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "uniswap-v4-core/types/BalanceDelta.sol";
import {SafeCast} from "uniswap-v4-core/libraries/SafeCast.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "./Constants.sol";
import {TStore} from "./TStore.sol";

contract Router is TStore, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLib for address;

    // Actions
    uint256 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 private constant SWAP_EXACT_IN = 0x07;
    uint256 private constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint256 private constant SWAP_EXACT_OUT = 0x09;

    IPoolManager public immutable poolManager;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
        bytes hookData;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMax;
        bytes hookData;
    }

    struct PathKey {
        address currency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        // First element + currencyIn determines the first pool to swap
        // Last element + previous path element's currency determines the last pool to swap
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    struct ExactOutputParams {
        address currencyOut;
        // Last element + currencyOut determines the last pool to swap
        // First element + second path element's currency determines the first pool to swap
        PathKey[] path;
        uint128 amountOut;
        uint128 amountInMax;
    }

    error UnsupportedAction(uint256 action);

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
        uint256 action = _getAction();
        // Write your code here
        if (action == SWAP_EXACT_IN_SINGLE) {
        (address msgSender,ExactInputSingleParams memory params ) = abi.decode(data,(address, ExactInputSingleParams));
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
        ) = params.zeroForOne ?
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

            _takeAndSettle({
                dst: msgSender,
                currencyIn: Currency.unwrap(currencyIn),
                currencyOut: Currency.unwrap(currencyOut),
                amountIn: amountIn,
                amountOut: amountOut
            });

        return abi.encode(amountOut);    
        
        }else if (action == SWAP_EXACT_OUT_SINGLE){
             (address msgSender, ExactOutputSingleParams memory params) =
                abi.decode(data, (address, ExactOutputSingleParams));

            (int128 amount0, int128 amount1) = _swap(
                params.poolKey,
                params.zeroForOne,
                params.amountOut.toInt256(),
                params.hookData
            );

            (
                Currency currencyIn,
                Currency currencyOut,
                uint256 amountIn,
                uint256 amountOut
            ) = params.zeroForOne ? 
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

            require(amountIn <= params.amountInMax, "amount in > max");

            _takeAndSettle({
                dst: msgSender,
                currencyIn: Currency.unwrap(currencyIn),
                currencyOut: Currency.unwrap(currencyOut),
                amountIn: amountIn,
                amountOut: amountOut
            });

            return abi.encode(amountIn);
        } else if (action == SWAP_EXACT_IN) {
            (address msgSender, ExactInputParams memory params) =
                abi.decode(data, (address, ExactInputParams));

            uint256 n = params.path.length;
            address currencyIn = params.currencyIn;
            int256 amountIn = params.amountIn.toInt256();
            for (uint256 i = 0; i < n; i++) {
                PathKey memory path = params.path[i];
                (address currency0, address currency1) = path.currency
                    < currencyIn
                    ? (path.currency, currencyIn)
                    : (currencyIn, path.currency);

                PoolKey memory key = PoolKey({
                    currency0: Currency.wrap(currency0),
                    currency1: Currency.wrap(currency1),
                    fee: path.fee,
                    tickSpacing: path.tickSpacing,
                    hooks: IHooks(path.hooks)
                });

                bool zeroForOne = currencyIn == currency0;

                (int128 amount0, int128 amount1) =
                    _swap(key, zeroForOne, -amountIn, path.hookData);

                // Next params
                currencyIn = path.currency;
                amountIn = int256(zeroForOne ? amount1 : amount0);
            }
            // currencyIn and amountIn stores currency out and amount out
            require(
                uint256(amountIn) >= uint256(params.amountOutMin),
                "amount out < min"
            );
            _takeAndSettle({
                dst: msgSender,
                currencyIn: params.currencyIn,
                currencyOut: currencyIn,
                amountIn: params.amountIn,
                amountOut: uint256(amountIn)
            });

            return abi.encode(uint256(amountIn));
        } else if (action == SWAP_EXACT_OUT) {
            (address msgSender, ExactOutputParams memory params) =
                abi.decode(data, (address, ExactOutputParams));

            uint256 n = params.path.length;
            address currencyOut = params.currencyOut;
            int256 amountOut = params.amountOut.toInt256();
            for (uint256 i = n; i > 0; i--) {
                PathKey memory path = params.path[i - 1];

                (address currency0, address currency1) = path.currency
                    < currencyOut
                    ? (path.currency, currencyOut)
                    : (currencyOut, path.currency);

                PoolKey memory key = PoolKey({
                    currency0: Currency.wrap(currency0),
                    currency1: Currency.wrap(currency1),
                    fee: path.fee,
                    tickSpacing: path.tickSpacing,
                    hooks: IHooks(path.hooks)
                });

                bool zeroForOne = currencyOut == currency1;

                (int128 amount0, int128 amount1) =
                    _swap(key, zeroForOne, amountOut, path.hookData);

                // Next params
                currencyOut = path.currency;
                amountOut = int256(zeroForOne ? -amount0 : -amount1);
            }

            // currencyOut and amountOut stores currency in and amount in
            require(
                uint256(amountOut) <= uint256(params.amountInMax),
                "amount in > max"
            );
            _takeAndSettle({
                dst: msgSender,
                currencyIn: currencyOut,
                currencyOut: params.currencyOut,
                amountIn: uint256(amountOut),
                amountOut: uint256(params.amountOut)
            });

            return abi.encode(uint256(amountOut));
        }
        revert UnsupportedAction(action);
    }

    function swapExactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN_SINGLE)
        returns (uint256 amountOut)
    {
        // Write your code here
          Currency currencyInCurrency = params.zeroForOne
            ? params.poolKey.currency0
            : params.poolKey.currency1;
        address currencyIn = Currency.unwrap(currencyInCurrency);

        currencyIn.transferIn(msg.sender, uint256(params.amountIn));
        bytes memory res = poolManager.unlock(abi.encode(msg.sender, params));
         amountOut = abi.decode(res, (uint256));
        _refund(currencyIn, msg.sender);
        return amountOut;
    }

    function swapExactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT_SINGLE)
        returns (uint256 amountIn)
    {
        // Write your code here
         Currency currencyInCurrency = params.zeroForOne
            ? params.poolKey.currency0
            : params.poolKey.currency1;
        address currencyIn = Currency.unwrap(currencyInCurrency);

        currencyIn.transferIn(msg.sender, params.amountInMax);
        poolManager.unlock(abi.encode(msg.sender, params));

        uint256 refunded = _refund(currencyIn, msg.sender);
        if (refunded < params.amountInMax) {
            return params.amountInMax - refunded;
        }
        return 0;
    }

    function swapExactInput(ExactInputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_IN)
        returns (uint256 amountOut)
    {
        // Write your code here
         require(params.path.length > 0, "path length = 0");

        params.currencyIn.transferIn(msg.sender, params.amountIn);
        bytes memory res = poolManager.unlock(abi.encode(msg.sender, params));
        amountOut = abi.decode(res, (uint256));
        _refund(params.currencyIn, msg.sender);
        return amountOut;
    }

    function swapExactOutput(ExactOutputParams calldata params)
        external
        payable
        setAction(SWAP_EXACT_OUT)
        returns (uint256 amountIn)
    {
        // Write your code here
          require(params.path.length > 0, "path length = 0");

        PathKey memory path = params.path[0];
        address currencyIn = path.currency;

        currencyIn.transferIn(msg.sender, params.amountInMax);
        poolManager.unlock(abi.encode(msg.sender, params));

        uint256 refunded = _refund(currencyIn, msg.sender);
        if (refunded < params.amountInMax) {
            return params.amountInMax - refunded;
        }
        return 0;

    }

      function _refund(address currency, address dst) private returns (uint256) {
        uint256 bal = currency.balanceOf(address(this));
        if (bal > 0) {
            currency.transferOut(dst, bal);
        }
        return bal;
    }

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) private returns (int128 amount0, int128 amount1) {
        BalanceDelta delta = poolManager.swap({
            key: key,
            params: IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // amountSpecified < 0 = amount in
                // amountSpecified > 0 = amount out
                amountSpecified: amountSpecified,
                // price = Currency 1 / currency 0
                // 0 for 1 = price decreases
                // 1 for 0 = price increases
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            hookData: hookData
        });
        return (delta.amount0(), delta.amount1());
    }

    function _takeAndSettle(
        address dst,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 amountOut
    ) private {
        poolManager.take({currency: Currency.wrap(currencyOut), to: dst, amount: amountOut});

        poolManager.sync(Currency.wrap(currencyIn));

        if (currencyIn == address(0)) {
            poolManager.settle{value: amountIn}();
        } else {
            IERC20(currencyIn).transfer(address(poolManager), amountIn);
            poolManager.settle();
        }
    }
}