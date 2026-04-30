// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

/**
 * @title IAlgebraSwapRouter
 * @notice Minimal interface for Algebra Integral SwapRouter used by the repay adapter.
 * @dev Algebra Integral pools are identified by (deployer, tokenA, tokenB) — `deployer`
 *      is the per-pool customization deployer (can be address(0) for default deployer).
 */
interface IAlgebraSwapRouter {
  struct ExactOutputSingleParams {
    address tokenIn;
    address tokenOut;
    address deployer;
    address recipient;
    uint256 deadline;
    uint256 amountOut;
    uint256 amountInMaximum;
    uint160 limitSqrtPrice;
  }

  struct ExactOutputParams {
    bytes path;
    address recipient;
    uint256 deadline;
    uint256 amountOut;
    uint256 amountInMaximum;
  }

  function exactOutputSingle(
    ExactOutputSingleParams calldata params
  ) external payable returns (uint256 amountIn);

  function exactOutput(
    ExactOutputParams calldata params
  ) external payable returns (uint256 amountIn);
}
