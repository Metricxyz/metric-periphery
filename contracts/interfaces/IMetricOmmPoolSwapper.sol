// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";

/// @title IMetricOmmPoolSwapper
/// @notice Pool swapper interface: swaps, native wrappers, and quote passthrough.
/// @dev Error signatures are external API and must remain stable once integrated.
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
  /// @dev Convenience overload equivalent to calling the data variant with empty `data`.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction (`true`: token0 -> token1, `false`: token1 -> token0).
  /// @param amountSpecified Signed amount semantics from core (`>0` exact input, `<0` exact output).
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amount0Delta Net token0 delta from pool perspective.
  /// @return amount1Delta Net token1 delta from pool perspective.
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline
  ) external payable returns (int128 amount0Delta, int128 amount1Delta);

  /// @notice Execute a direct pool swap with custom callback data.
  /// @dev This is the canonical low-level swap entrypoint. Swapper enforces deadline, directional price-limit
  ///      sentinels, and specified-side delta equality with `amountSpecified`.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction (`true`: token0 -> token1, `false`: token1 -> token0).
  /// @param amountSpecified Signed amount semantics from core (`>0` exact input, `<0` exact output).
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @param data Opaque callback data forwarded into pool callback flow.
  /// @return amount0Delta Net token0 delta from pool perspective.
  /// @return amount1Delta Net token1 delta from pool perspective.
  function swap(
    address pool,
    address recipient,
    bool zeroForOne,
    int128 amountSpecified,
    uint128 priceLimitX64,
    uint256 deadline,
    bytes memory data
  ) external payable returns (int128 amount0Delta, int128 amount1Delta);

  // ============ Mutating: Token Swap ============

  /// @notice Swap exact token input for token output.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction (`true`: token0 input, `false`: token1 input).
  /// @param amountIn Exact input amount.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param minAmountOut Minimum acceptable output amount.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Output amount received.
  /// @return amountInUsed Actual input consumed (can be lower than `amountIn` near price limits).
  function swapExactInput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input for exact token output target.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction (`true`: token0 input, `false`: token1 input).
  /// @param amountOutDesired Exact output target.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param maxAmountIn Maximum acceptable input spend.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Output amount produced (expected to equal `amountOutDesired`).
  /// @return amountInUsed Input amount consumed.
  function swapExactOutput(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  // ============ Mutating: Native <-> Token Swap ============

  /// @notice Swap exact native ETH input for token output.
  /// @dev Native input is wrapped into WETH inside callback settlement.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction where the input side must be WETH.
  /// @param amountIn Exact native input amount.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param minAmountOut Minimum acceptable token output.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Output token amount received.
  /// @return amountInUsed Native input consumed.
  function swapExactInputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap native ETH (bounded by `maxAmountIn`) for exact token output.
  /// @param pool Target pool address.
  /// @param recipient Receiver of output token.
  /// @param zeroForOne Swap direction where the input side must be WETH.
  /// @param amountOutDesired Exact output target.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param maxAmountIn Maximum native ETH spend.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Output token amount produced.
  /// @return amountInUsed Native input consumed.
  function swapExactOutputNativeForTokens(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external payable returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap exact token input for native ETH output.
  /// @dev Output leg is received as WETH then unwrapped and forwarded as native ETH.
  /// @param pool Target pool address.
  /// @param recipient Receiver of native ETH.
  /// @param zeroForOne Swap direction where the output side must be WETH.
  /// @param amountIn Exact token input amount.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param minAmountOut Minimum acceptable native output.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Native ETH output amount received.
  /// @return amountInUsed Token input consumed.
  function swapExactInputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint256 minAmountOut,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed);

  /// @notice Swap token input (bounded by `maxAmountIn`) for exact native ETH output.
  /// @dev Output leg is received as WETH then unwrapped and forwarded as native ETH.
  /// @param pool Target pool address.
  /// @param recipient Receiver of native ETH.
  /// @param zeroForOne Swap direction where the output side must be WETH.
  /// @param amountOutDesired Exact native output target.
  /// @param priceLimitX64 Directional Q64.64 price limit.
  /// @param maxAmountIn Maximum token input spend.
  /// @param deadline Unix timestamp after which the call reverts.
  /// @return amountOut Native ETH output produced.
  /// @return amountInUsed Token input consumed.
  function swapExactOutputTokensForNative(
    address pool,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint256 maxAmountIn,
    uint256 deadline
  ) external returns (uint256 amountOut, uint256 amountInUsed);
}
