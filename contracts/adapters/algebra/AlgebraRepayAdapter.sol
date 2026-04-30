// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {SafeERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {BaseAlgebraBuyAdapter} from './BaseAlgebraBuyAdapter.sol';
import {IAlgebraSwapRouter} from './interfaces/IAlgebraSwapRouter.sol';
import {ReentrancyGuard} from '../../dependencies/openzeppelin/ReentrancyGuard.sol';

/**
 * @title AlgebraRepayAdapter
 * @notice Adapter that repays an Aave debt by swapping the user's collateral on the Algebra
 *         Integral DEX. Mirrors `ParaSwapRepayAdapter` but routes the buy-side swap through
 *         the Algebra SwapRouter instead of ParaSwap Augustus.
 * @dev Two flows are supported:
 *      1. Flash-loan-based repay (`executeOperation`): the flash-borrowed asset is the
 *         user's collateral, used to buy the debt asset and repay the debt.
 *      2. Direct repay (`swapAndRepay`): the adapter pulls aTokens, withdraws collateral,
 *         buys the debt asset and repays — used when the temporary collateral move does
 *         not affect the user's health factor.
 */
contract AlgebraRepayAdapter is BaseAlgebraBuyAdapter, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  struct RepayParams {
    address collateralAsset;
    uint256 collateralAmount;
    uint256 rateMode;
    PermitSignature permitSignature;
    bool useEthPath;
  }

  constructor(
    IPoolAddressesProvider addressesProvider,
    IAlgebraSwapRouter swapRouter,
    address owner
  ) BaseAlgebraBuyAdapter(addressesProvider, swapRouter) {
    transferOwnership(owner);
  }

  /**
   * @dev Aave flash-loan callback. Uses the borrowed collateral to buy the debt asset on
   *      Algebra, repays the user's debt, then pulls aTokens from the user to settle the
   *      flash-loan principal + premium.
   *
   * `params` ABI: (
   *   IERC20Detailed debtAsset,
   *   uint256 debtRepayAmount,
   *   bool buyAllBalance,        // if true, repay the user's entire current debt
   *   uint256 rateMode,          // 1 = stable, 2 = variable
   *   bytes algebraData,         // see BaseAlgebraBuyAdapter._buyOnAlgebra
   *   PermitSignature permitSig
   * )
   */
  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external override nonReentrant returns (bool) {
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');

    uint256 collateralAmount = amount;
    address initiatorLocal = initiator;
    IERC20Detailed collateralAsset = IERC20Detailed(asset);

    _swapAndRepay(params, premium, initiatorLocal, collateralAsset, collateralAmount);

    return true;
  }

  /**
   * @dev Repay-with-collateral without using a flash loan. Caller must have approved the
   *      adapter to pull their aToken collateral.
   * @param collateralAsset Asset to be swapped (collateral side).
   * @param debtAsset Asset of the debt to be repaid.
   * @param collateralAmount Max amount of collateral to spend.
   * @param debtRepayAmount Amount of debt to repay (or upper bound when `buyAllBalance`).
   * @param debtRateMode Rate mode of the debt (1 = stable, 2 = variable).
   * @param buyAllBalance If true, repay the user's entire current debt of `debtAsset`.
   * @param algebraData abi-encoded swap params consumed by `_buyOnAlgebra`.
   * @param permitSignature aToken permit signature; pass an all-zero struct to skip.
   */
  function swapAndRepay(
    IERC20Detailed collateralAsset,
    IERC20Detailed debtAsset,
    uint256 collateralAmount,
    uint256 debtRepayAmount,
    uint256 debtRateMode,
    bool buyAllBalance,
    bytes calldata algebraData,
    PermitSignature calldata permitSignature
  ) external nonReentrant {
    debtRepayAmount = getDebtRepayAmount(
      debtAsset,
      debtRateMode,
      buyAllBalance,
      debtRepayAmount,
      msg.sender
    );

    // Pull aTokens from user and withdraw the underlying.
    _pullATokenAndWithdraw(address(collateralAsset), msg.sender, collateralAmount, permitSignature);

    // Buy the debt asset using the withdrawn collateral.
    uint256 amountSold = _buyOnAlgebra(
      algebraData,
      collateralAsset,
      debtAsset,
      collateralAmount,
      debtRepayAmount
    );

    uint256 collateralBalanceLeft = collateralAmount - amountSold;

    // Re-deposit any leftover collateral on behalf of the user.
    if (collateralBalanceLeft > 0) {
      IERC20(address(collateralAsset)).safeApprove(address(POOL), 0);
      IERC20(address(collateralAsset)).safeApprove(address(POOL), collateralBalanceLeft);
      POOL.deposit(address(collateralAsset), collateralBalanceLeft, msg.sender, 0);
    }

    // Repay the debt. Approve 0 first to satisfy anti-frontrunning approval semantics.
    IERC20(address(debtAsset)).safeApprove(address(POOL), 0);
    IERC20(address(debtAsset)).safeApprove(address(POOL), debtRepayAmount);
    POOL.repay(address(debtAsset), debtRepayAmount, debtRateMode, msg.sender);
  }

  function _swapAndRepay(
    bytes calldata params,
    uint256 premium,
    address initiator,
    IERC20Detailed collateralAsset,
    uint256 collateralAmount
  ) private {
    (
      IERC20Detailed debtAsset,
      uint256 debtRepayAmount,
      bool buyAllBalance,
      uint256 rateMode,
      bytes memory algebraData,
      PermitSignature memory permitSignature
    ) = abi.decode(params, (IERC20Detailed, uint256, bool, uint256, bytes, PermitSignature));

    debtRepayAmount = getDebtRepayAmount(
      debtAsset,
      rateMode,
      buyAllBalance,
      debtRepayAmount,
      initiator
    );

    uint256 amountSold = _buyOnAlgebra(
      algebraData,
      collateralAsset,
      debtAsset,
      collateralAmount,
      debtRepayAmount
    );

    IERC20(address(debtAsset)).safeApprove(address(POOL), 0);
    IERC20(address(debtAsset)).safeApprove(address(POOL), debtRepayAmount);
    POOL.repay(address(debtAsset), debtRepayAmount, rateMode, initiator);

    uint256 neededForFlashLoanRepay = amountSold.add(premium);

    // Pull aTokens from the user to cover the flash-loan repayment.
    _pullATokenAndWithdraw(
      address(collateralAsset),
      initiator,
      neededForFlashLoanRepay,
      permitSignature
    );

    // Approve the Aave POOL to take back the flash-loaned amount + premium.
    IERC20(address(collateralAsset)).safeApprove(address(POOL), 0);
    IERC20(address(collateralAsset)).safeApprove(address(POOL), collateralAmount.add(premium));
  }

  function getDebtRepayAmount(
    IERC20Detailed debtAsset,
    uint256 rateMode,
    bool buyAllBalance,
    uint256 debtRepayAmount,
    address initiator
  ) private view returns (uint256) {
    DataTypes.ReserveData memory debtReserveData = _getReserveData(address(debtAsset));

    address debtToken = DataTypes.InterestRateMode(rateMode) == DataTypes.InterestRateMode.STABLE
      ? debtReserveData.stableDebtTokenAddress
      : debtReserveData.variableDebtTokenAddress;

    uint256 currentDebt = IERC20(debtToken).balanceOf(initiator);

    if (buyAllBalance) {
      require(currentDebt <= debtRepayAmount, 'INSUFFICIENT_AMOUNT_TO_REPAY');
      debtRepayAmount = currentDebt;
    } else {
      require(debtRepayAmount <= currentDebt, 'INVALID_DEBT_REPAY_AMOUNT');
    }

    return debtRepayAmount;
  }
}
