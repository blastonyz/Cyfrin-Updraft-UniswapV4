// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {ISubscriber} from "uniswap-v4-periphery/interfaces/ISubscriber.sol";
import {PoolKey} from "uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "uniswap-v4-core/types/PoolId.sol";
import {BalanceDelta} from "uniswap-v4-core/types/BalanceDelta.sol";
import {PositionInfo} from "uniswap-v4-periphery/libraries/PositionInfoLibrary.sol";
import {POSITION_MANAGER, USDC, PERMIT2} from "./Constants.sol";

contract Token {
    // Pool id => owner => uint256
    mapping(bytes32 => mapping(address => uint256)) public balanceOf;

    function _mint(bytes32 poolId, address dst, uint256 amount) internal {
        balanceOf[poolId][dst] += amount;
    }

    function _burn(bytes32 poolId, address src, uint256 amount) internal {
        balanceOf[poolId][src] -= amount;
    }
}

contract Subscriber is ISubscriber, Token {
    using PoolIdLibrary for PoolKey;

    IPositionManager public immutable posm;
    mapping(uint256 tokenId => bytes32 poolId) private poolIds;
    mapping(uint256 tokenId => address owner) private ownerOf;

    modifier onlyPositionManager() {
        require(msg.sender == address(posm), "not PositionManager");
        _;
    }

    constructor(address _posm) {
        posm = IPositionManager(_posm);
    }

    receive() external payable {}

    function getInfo(uint256 tokenId)
        public
        view
        returns (bytes32 poolId, address owner, uint128 liquidity)
    {
        // NOTE: data are deleted before notifyUnsubscribe and notifyBurn
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        poolId = PoolId.unwrap(key.toId());
        // NOTE: ownerOf reverts if tokenId doesn't exist - cast to IERC721
        owner = IERC721(address(posm)).ownerOf(tokenId);
        liquidity = posm.getPositionLiquidity(tokenId);
    }

    function notifySubscribe(uint256 tokenId, bytes memory data)
        external
        onlyPositionManager
    {
        (bytes32 poolId, address owner, uint128 liquidity) = getInfo(tokenId);
        _mint(poolId, owner, liquidity);
        poolIds[tokenId] = poolId;
        ownerOf[tokenId] = owner;
    }

    function notifyUnsubscribe(uint256 tokenId) external onlyPositionManager {
        bytes32 poolId = poolIds[tokenId];
        address owner = ownerOf[tokenId];
        _burn(poolId, owner, balanceOf[poolId][owner]);
        delete poolIds[tokenId];
        delete ownerOf[tokenId];
    }

    function notifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) external onlyPositionManager {
        bytes32 poolId = poolIds[tokenId];
        // NOTE: Position liquidity may be > balanceOf[poolId][owner]
        // since positions accumulate fees
        _burn(poolId, owner, balanceOf[poolId][owner]);
        delete poolIds[tokenId];
        delete ownerOf[tokenId];
    }

    function notifyModifyLiquidity(
        uint256 tokenId,
        int256 liquidityChange,
        BalanceDelta feesAccrued
    ) external onlyPositionManager {
        bytes32 poolId = poolIds[tokenId];
        address owner = ownerOf[tokenId];
        if (liquidityChange > 0) {
            _mint(poolId, owner, uint256(liquidityChange));
        } else {
            _burn(
                poolId,
                owner,
                min(uint256(-liquidityChange), balanceOf[poolId][owner])
            );
        }
    }

    function min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}