// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import { PositionInfo, PositionInfoLibrary } from "uniswap-v4-periphery/libraries/PositionInfoLibrary.sol";
import {Actions} from "uniswap-v4-periphery/libraries/Actions.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

contract Reposition {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPositionManager public immutable posm;

    constructor(address _posm) {
        posm = IPositionManager(_posm);
    }

    receive() external payable {}

    function reposition(uint256 tokenId, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 newTokenId)
    {
        require(tickLower < tickUpper, "tick lower >= tick upper");

        address owner = IERC721(address(posm)).ownerOf(tokenId);

        // Get pool key
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);

        // Write your code here
                bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.MINT_POSITION_FROM_DELTAS),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](3);

        // BURN_POSITION params
        params[0] = abi.encode(
            tokenId,
            // amount0Min
            0,
            // amount1Min
            0,
            // hook data
            ""
        );

        // MINT_POSITION_FROM_DELTAS params
        params[1] = abi.encode(
            key,
            tickLower,
            tickUpper,
            // amount0Max
            type(uint128).max,
            // amount1Max
            type(uint128).max,
            // owner
            owner,
            // hook data
            ""
        );

        // TAKE_PAIR params
        // currency 0, currency 1, recipient
        params[2] = abi.encode(key.currency0, key.currency1, owner);

        newTokenId = posm.nextTokenId();

        posm.modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, params), block.timestamp
        );

    }
}