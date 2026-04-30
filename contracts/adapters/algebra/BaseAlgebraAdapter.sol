// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {FlashLoanSimpleReceiverBase} from '@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol';
import {GPv2SafeERC20} from '@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20WithPermit} from '@aave/core-v3/contracts/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from '@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {Ownable} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/Ownable.sol';

/**
 * @title BaseAlgebraAdapter
 * @notice Utility functions for adapters using the Algebra Integral DEX.
 * @dev Mirrors `BaseParaSwapAdapter`, but is decoupled from the ParaSwap Augustus registry.
 */
abstract contract BaseAlgebraAdapter is FlashLoanSimpleReceiverBase, Ownable {
  using SafeMath for uint256;
  using GPv2SafeERC20 for IERC20;
  using GPv2SafeERC20 for IERC20Detailed;
  using GPv2SafeERC20 for IERC20WithPermit;

  struct PermitSignature {
    uint256 amount;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  uint256 public constant MAX_SLIPPAGE_PERCENT = 3000; // 30%

  IPriceOracleGetter public immutable ORACLE;

  event Swapped(
    address indexed fromAsset,
    address indexed toAsset,
    uint256 fromAmount,
    uint256 receivedAmount
  );
  event Bought(
    address indexed fromAsset,
    address indexed toAsset,
    uint256 amountSold,
    uint256 receivedAmount
  );

  constructor(
    IPoolAddressesProvider addressesProvider
  ) FlashLoanSimpleReceiverBase(addressesProvider) {
    ORACLE = IPriceOracleGetter(addressesProvider.getPriceOracle());
  }

  function _getPrice(address asset) internal view returns (uint256) {
    return ORACLE.getAssetPrice(asset);
  }

  function _getDecimals(IERC20Detailed asset) internal view returns (uint8) {
    uint8 decimals = asset.decimals();
    require(decimals <= 77, 'TOO_MANY_DECIMALS_ON_TOKEN');
    return decimals;
  }

  function _getReserveData(address asset) internal view returns (DataTypes.ReserveData memory) {
    return POOL.getReserveData(asset);
  }

  function _pullATokenAndWithdraw(
    address reserve,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal {
    IERC20WithPermit reserveAToken = IERC20WithPermit(
      _getReserveData(address(reserve)).aTokenAddress
    );
    _pullATokenAndWithdraw(reserve, reserveAToken, user, amount, permitSignature);
  }

  function _pullATokenAndWithdraw(
    address reserve,
    IERC20WithPermit reserveAToken,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal {
    if (permitSignature.deadline != 0) {
      reserveAToken.permit(
        user,
        address(this),
        permitSignature.amount,
        permitSignature.deadline,
        permitSignature.v,
        permitSignature.r,
        permitSignature.s
      );
    }

    reserveAToken.safeTransferFrom(user, address(this), amount);

    require(POOL.withdraw(reserve, amount, address(this)) == amount, 'UNEXPECTED_AMOUNT_WITHDRAWN');
  }

  function rescueTokens(IERC20 token) external onlyOwner {
    token.safeTransfer(owner(), token.balanceOf(address(this)));
  }
}
