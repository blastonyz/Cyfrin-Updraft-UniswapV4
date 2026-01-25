// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "uniswap-universal-router/interfaces/IUniversalRouter.sol";
import {IV4Router} from "uniswap-v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "uniswap-v4-periphery/libraries/Actions.sol";
import {Commands} from "uniswap-universal-router/libraries/Commands.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "uniswap-v4-core/types/Currency.sol";
import {UNIVERSAL_ROUTER, PERMIT2} from "./Constants.sol";
/*Transfer currency to swap from msg.sender into this contract.

Grant Permit2 approvals to UniversalRouter.

Prepare the inputs to call UniversalRouter.execute.

The command to execute is Commands.V4_SWAP.

The input for this command encodes actions and params.

actions are Actions.SWAP_EXACT_IN_SINGLE, Actions.SETTLE_ALL and Actions.TAKE_ALL.

params are inputs corresponding to each action. See _handleAction for the correct inputs.

Call UniverswalRouter.execute

Withdraw both currency 0 and 1 to msg.sender.
 uint256 constant V4_SWAP = 0x10;
 uint256 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
 uint256 internal constant TAKE_ALL = 0x0f;
 uint256 internal constant SETTLE_ALL = 0x0c;

 v4router 
  function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (int128 reciprocalAmount)
    {
*/
contract UniversalRouterExercises {
    IUniversalRouter constant router = IUniversalRouter(UNIVERSAL_ROUTER);
    IPermit2 constant permit2 = IPermit2(PERMIT2);

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        uint128 amountIn,
        uint128 amountOutMin,
        bool zeroForOne
    ) external payable {
        // 1. Transfer currency to swap from msg.sender into this contract
        address currencyIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address currencyOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        transferFrom(currencyIn, msg.sender, amountIn);
        
        // 2. Grant Permit2 approvals to UniversalRouter (only for ERC20 tokens, not ETH)
        if (currencyIn != address(0)) {
            approve(currencyIn, uint160(amountIn), uint48(block.timestamp + 3600));
        }

        // 3. Prepare the inputs to call UniversalRouter.execute
        // V4 actions and params
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        
        // Param 0: ExactInputSingleParams for SWAP_EXACT_IN_SINGLE, de Poolkey
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                hookData: ""
            })
        );
        
        // Param 1: SETTLE_ALL (currency, maxAmount)
        params[1] = abi.encode(currencyIn, amountIn);
        
        // Param 2: TAKE_ALL (currency, minAmount)
        params[2] = abi.encode(currencyOut, amountOutMin);

        // UniversalRouter inputs
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // 4. Call UniversalRouter.execute
        // If swapping ETH, pass the ETH value to the router
        uint256 value = currencyIn == address(0) ? amountIn : 0;
        router.execute{value: value}(commands, inputs, block.timestamp + 60);

        // 5. Withdraw both currency 0 and 1 to msg.sender
        withdraw(currencyIn, msg.sender);
        withdraw(currencyOut, msg.sender);
    }

    function approve(address token, uint160 amount, uint48 expiration)
        private
    {
        IERC20(token).approve(address(permit2), uint256(amount));
        permit2.approve(token, address(router), amount, expiration);
    }

    function transferFrom(address currency, address src, uint256 amt) private {
        if (currency == address(0)) {
            require(msg.value == amt, "not enough ETH sent");
        } else {
            IERC20(currency).transferFrom(src, address(this), amt);
        }
    }

    function withdraw(address currency, address receiver) private {
        if (currency == address(0)) {
            uint256 bal = address(this).balance;
            if (bal > 0) {
                (bool ok,) = receiver.call{value: bal}("");
                require(ok, "Transfer ETH failed");
            }
        } else {
            uint256 bal = IERC20(currency).balanceOf(address(this));
            if (bal > 0) {
                IERC20(currency).transfer(receiver, bal);
            }
        }
    }
}