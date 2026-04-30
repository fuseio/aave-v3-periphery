// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {SafeERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IAlgebraSwapRouter} from './interfaces/IAlgebraSwapRouter.sol';
import {BaseAlgebraAdapter} from './BaseAlgebraAdapter.sol';

/**
 * @title BaseAlgebraBuyAdapter
 * @notice Implements exact-output (buy) swaps via the Algebra Integral SwapRouter.
 * @dev Algebra Integral pools are keyed by (deployer, tokenA, tokenB). The default
 *      deployer is address(0); custom-plugin pools use a non-zero deployer.
 */
abstract contract BaseAlgebraBuyAdapter is BaseAlgebraAdapter {
  using PercentageMath for uint256;
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using SafeERC20 for IERC20Detailed;

  IAlgebraSwapRouter public immutable SWAP_ROUTER;

  constructor(
    IPoolAddressesProvider addressesProvider,
    IAlgebraSwapRouter swapRouter
  ) BaseAlgebraAdapter(addressesProvider) {
    require(address(swapRouter) != address(0), 'INVALID_SWAP_ROUTER');
    SWAP_ROUTER = swapRouter;
  }

  /**
   * @dev Buys `amountToReceive` of `assetToSwapTo` by spending up to `maxAmountToSwap` of
   *      `assetToSwapFrom`, executed against the Algebra Integral SwapRouter.
   * @param algebraData abi-encoded `(address deployer, uint256 deadline, uint160 limitSqrtPrice, bytes path)`.
   *        - If `path.length == 0`: single-hop swap, executed via `exactOutputSingle` using `deployer`.
   *        - Else: multi-hop swap, executed via `exactOutput`. `path` follows the Algebra format
   *          `tokenOut, deployer, tokenMid, deployer, tokenIn` (reversed for exact-output).
   * @param assetToSwapFrom Address of the asset to be swapped from (the token spent).
   * @param assetToSwapTo Address of the asset to be received.
   * @param maxAmountToSwap Max amount of `assetToSwapFrom` available for the swap.
   * @param amountToReceive Exact amount of `assetToSwapTo` required.
   * @return amountSold The amount of `assetToSwapFrom` actually spent.
   */
  function _buyOnAlgebra(
    bytes memory algebraData,
    IERC20Detailed assetToSwapFrom,
    IERC20Detailed assetToSwapTo,
    uint256 maxAmountToSwap,
    uint256 amountToReceive
  ) internal returns (uint256 amountSold) {
    (address deployer, uint256 deadline, uint160 limitSqrtPrice, bytes memory path) = abi.decode(
      algebraData,
      (address, uint256, uint160, bytes)
    );

    {
      uint256 fromAssetDecimals = _getDecimals(assetToSwapFrom);
      uint256 toAssetDecimals = _getDecimals(assetToSwapTo);

      uint256 fromAssetPrice = _getPrice(address(assetToSwapFrom));
      uint256 toAssetPrice = _getPrice(address(assetToSwapTo));

      uint256 expectedMaxAmountToSwap = amountToReceive
        .mul(toAssetPrice.mul(10 ** fromAssetDecimals))
        .div(fromAssetPrice.mul(10 ** toAssetDecimals))
        .percentMul(PercentageMath.PERCENTAGE_FACTOR.add(MAX_SLIPPAGE_PERCENT));

      require(maxAmountToSwap <= expectedMaxAmountToSwap, 'maxAmountToSwap exceed max slippage');
    }

    uint256 balanceBeforeAssetFrom = assetToSwapFrom.balanceOf(address(this));
    require(balanceBeforeAssetFrom >= maxAmountToSwap, 'INSUFFICIENT_BALANCE_BEFORE_SWAP');
    uint256 balanceBeforeAssetTo = assetToSwapTo.balanceOf(address(this));

    IERC20(address(assetToSwapFrom)).safeApprove(address(SWAP_ROUTER), 0);
    IERC20(address(assetToSwapFrom)).safeApprove(address(SWAP_ROUTER), maxAmountToSwap);

    if (path.length == 0) {
      amountSold = SWAP_ROUTER.exactOutputSingle(
        IAlgebraSwapRouter.ExactOutputSingleParams({
          tokenIn: address(assetToSwapFrom),
          tokenOut: address(assetToSwapTo),
          deployer: deployer,
          recipient: address(this),
          deadline: deadline,
          amountOut: amountToReceive,
          amountInMaximum: maxAmountToSwap,
          limitSqrtPrice: limitSqrtPrice
        })
      );
    } else {
      amountSold = SWAP_ROUTER.exactOutput(
        IAlgebraSwapRouter.ExactOutputParams({
          path: path,
          recipient: address(this),
          deadline: deadline,
          amountOut: amountToReceive,
          amountInMaximum: maxAmountToSwap
        })
      );
    }

    // Reset allowance — exact-output swaps may leave dust approval if router pulls less than max.
    IERC20(address(assetToSwapFrom)).safeApprove(address(SWAP_ROUTER), 0);

    uint256 balanceAfterAssetFrom = assetToSwapFrom.balanceOf(address(this));
    require(amountSold == balanceBeforeAssetFrom - balanceAfterAssetFrom, 'WRONG_BALANCE_AFTER_SWAP');
    require(amountSold <= maxAmountToSwap, 'WRONG_BALANCE_AFTER_SWAP');
    uint256 amountReceived = assetToSwapTo.balanceOf(address(this)).sub(balanceBeforeAssetTo);
    require(amountReceived >= amountToReceive, 'INSUFFICIENT_AMOUNT_RECEIVED');

    emit Bought(address(assetToSwapFrom), address(assetToSwapTo), amountSold, amountReceived);
  }
}
