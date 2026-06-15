// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title IMetricOmmPoolSwapper
/// @notice Pool swapper interface: swaps, native wrappers, and quote passthrough.
/// @dev Error signatures are external API and must remain stable once integrated.
/// @dev The caller is responsible for supplying a legitimate pool address. This contract does not verify the pool
///      against the factory; interacting with a malicious pool can cause loss of approved tokens or incidental
///      ETH/WETH held by the router.
interface IMetricOmmPoolSwapper is IMetricOmmSwapCallback {
  // ============ Errors ============

  /// @notice Swap deadline is in the past.
  /// @param deadline User-provided deadline.
  /// @param timestamp Current block timestamp.
  error TransactionExpired(uint256 deadline, uint256 timestamp);
  /// @notice Swap callback caller is not the active pool in transient context.
  error InvalidCallbackCaller();
  /// @notice Swapper context is already active (nested/reentrant swap attempt).
  error SwapInProgress();
  /// @notice Exact-input output amount is below user minimum.
  /// @param amountOut Actual output amount.
  /// @param minAmountOut Minimum required output.
  error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
  /// @notice Exact-output input amount exceeded user maximum.
  /// @param amountIn Actual input used.
  /// @param maxAmountIn Maximum allowed input.
  error InputTooHigh(uint256 amountIn, uint256 maxAmountIn);
  /// @notice Returned swap deltas do not match expected sign/shape.
  error InvalidSwapDeltas();
  /// @notice Constructor received zero WETH address.
  error InvalidWETH();
  /// @notice ETH was sent to a function that does not accept native input.
  error NativeValueNotExpected();
  /// @notice Native-input mode attempted to pay non-WETH token.
  /// @param token Input token requested by pool callback.
  error NativeInputNotSupported(address token);
  /// @notice Swapper native balance is insufficient to wrap and settle callback.
  /// @param required Required native amount.
  /// @param available Available native balance.
  error InsufficientNativeValue(uint256 required, uint256 available);
  /// @notice Native transfer or unwrap payout failed.
  error NativeTransferFailed();
  /// @notice Native-output mode requested unwrap for non-WETH output token.
  /// @param token Output token returned by pool direction.
  error NativeOutputNotSupported(address token);
  /// @notice Specified side delta does not equal `amountSpecified`.
  /// @param expectedAmountSpecified User requested signed amount.
  /// @param actualDelta Actual signed delta on specified side.
  error AmountSpecifiedMismatch(int128 expectedAmountSpecified, int128 actualDelta);
  /// @notice Price-limit sentinel is invalid for selected direction.
  /// @param zeroForOne Swap direction.
  /// @param priceLimitX64 Provided price limit.
  error InvalidPriceLimitForDirection(bool zeroForOne, uint128 priceLimitX64);
  /// @notice Provided unsigned amount does not fit into signed int128 representation.
  /// @param amount Provided amount that exceeded int128 range.
  error AmountTooLarge(uint128 amount);

  // ============ Mutating: Spot Swap ============

  /// @notice Execute a direct pool swap using swapper callback settlement.
  /// @dev Advanced path: enforces only a marginal price limit (priceLimitX64), not a minimum output or maximum
  ///      input amount. Pending transactions can receive less output than expected while staying within the limit.
  ///      Prefer swapExactInput / swapExactOutput for amount-based slippage protection.
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline
  ) external payable returns (int128 amount0Delta, int128 amount1Delta);

  /// @notice Execute a direct pool swap with custom callback data.
  /// @dev Advanced path: no amount-based slippage protection; see swap() NatSpec. Pass empty `data` and non-empty
  ///      `hookData` to forward only hook data.
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline,
    bytes memory data
  ) external payable returns (int128 amount0Delta, int128 amount1Delta);

  /// @notice Execute a direct pool swap with custom callback data and hook data.
  /// @dev Advanced path: no amount-based slippage protection; see swap() NatSpec.
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline,
    bytes memory data,
    bytes calldata hookData
  ) external payable returns (int128 amount0Delta, int128 amount1Delta);

  // ============ Mutating: Token Swap ============

  /// @notice Swap exact token input for token output.
  function swapExactInput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap exact token input for token output, forwarding hook data to pool hooks.
  function swapExactInput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline,
    bytes calldata hookData
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input for exact token output target.
  function swapExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input for exact token output target, forwarding hook data to pool hooks.
  function swapExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline,
    bytes calldata hookData
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  // ============ Mutating: Native <-> Token Swap ============

  /// @notice Swap exact native ETH input for token output.
  function swapExactInputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap exact native ETH input for token output, forwarding hook data to pool hooks.
  function swapExactInputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline,
    bytes calldata hookData
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap native ETH (bounded by `maxAmountIn`) for exact token output.
  function swapExactOutputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap native ETH for exact token output, forwarding hook data to pool hooks.
  function swapExactOutputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline,
    bytes calldata hookData
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap exact token input for native ETH output.
  function swapExactInputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap exact token input for native ETH output, forwarding hook data to pool hooks.
  function swapExactInputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline,
    bytes calldata hookData
  ) external returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input (bounded by `maxAmountIn`) for exact native ETH output.
  function swapExactOutputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input for exact native ETH output, forwarding hook data to pool hooks.
  function swapExactOutputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline,
    bytes calldata hookData
  ) external returns (uint256 amountOut, uint256 amountInUsed);
}
