// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IMulticall} from "./IMulticall.sol";
import {ISelfPermit} from "./ISelfPermit.sol";
import {IPeripheryPayments} from "./IPeripheryPayments.sol";

/// @title IMetricOmmSimpleRouter
/// @notice ERC-20 exact-input and exact-output swaps through one or more MetricOmm pools.
/// @dev Scope: ERC-20 routes only. No native ETH, WETH wrap/unwrap, on-chain quotes, sweep, or refund helpers.
///      Only pools registered on the configured factory may be used. Path token connectivity and single-hop
///      tokenIn / tokenOut against pool immutables remain the caller's obligation off-chain.
///      `pools[i]` is intended to connect `tokens[i]` and `tokens[i+1]`; `extensionDatas[i]` is passed to `pools[i]`.
///      Multihop exact-output executes `pools` from last to first; `amountOut` is `tokens[tokens.length - 1]`.
///      Multihop paths omit per-hop price limits; slippage is controlled solely by `amountOutMinimum` (exact input)
///      or `amountInMaximum` (exact output).
interface IMetricOmmSimpleRouter is IMetricOmmSwapCallback, ISelfPermit, IMulticall, IPeripheryPayments {
  // ============ Errors ============

  /// @notice Swap deadline is in the past.
  /// @param deadline User-provided deadline.
  /// @param timestamp Current block timestamp.
  error TransactionExpired(uint256 deadline, uint256 timestamp);
  /// @notice Swap callback caller is not the active pool in transient context.
  error InvalidCallbackCaller();
  /// @notice Constructor received zero factory address.
  error InvalidFactory();
  /// @notice Pool is not registered on the configured factory.
  /// @param pool Address that failed factory provenance validation.
  error InvalidPool(address pool);
  /// @notice Returned swap deltas do not match expected sign/shape.
  error InvalidSwapDeltas();
  /// @notice Route arrays are inconsistent or too short for a multihop path.
  /// @dev Does not validate that each pool connects the adjacent path tokens; that is the caller's obligation.
  error InvalidPath();
  /// @notice Price-limit sentinel is invalid for the selected direction.
  /// @param zeroForOne Swap direction.
  /// @param priceLimitX64 Provided price limit.
  error InvalidPriceLimitForDirection(bool zeroForOne, uint128 priceLimitX64);
  /// @notice Exact-input output amount is below user minimum.
  /// @param amountOut Actual output amount.
  /// @param minAmountOut Minimum required output.
  error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
  /// @notice Exact-output input amount exceeded user maximum.
  /// @param amountIn Actual input used.
  /// @param maxAmountIn Maximum allowed input.
  error InputTooHigh(uint256 amountIn, uint256 maxAmountIn);
  /// @notice Final hop output does not match the requested exact output amount.
  /// @param amountOut Actual output from the swap.
  /// @param expectedAmountOut Requested exact output amount.
  error InvalidOutputAmount(int128 amountOut, uint128 expectedAmountOut);
  /// @notice Intermediate hop output does not match the next hop's specified input.
  /// @param hop Hop index where the mismatch occurred.
  /// @param amountOut Actual output from the hop.
  /// @param amount Expected output for the next hop.
  error InvalidOutputAmountAtHop(uint8 hop, int128 amountOut, int256 amount);
  /// @notice Exact-input hop consumed less input than requested (partial fill).
  /// @param hop Hop index where the partial fill occurred.
  /// @param amountIn Actual input consumed by the hop.
  /// @param expected Requested input for the hop.
  error InvalidInputAmountAtHop(uint8 hop, int128 amountIn, int256 expected);
  /// @notice Swap amount exceeds the maximum representable as a signed pool delta.
  /// @param amount Amount that does not fit in int128.
  error AmountTooLarge(uint128 amount);

  // ============ Types ============

  /// @notice Single-hop exact-input swap parameters.
  /// @param pool MetricOmm pool address for this hop.
  /// @param tokenIn ERC-20 the router pulls from the swap initiator during the swap callback; caller must set correctly off-chain.
  /// @param tokenOut Output token for this hop; informational for integrators, unused on-chain.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountIn Exact input amount.
  /// @param amountOutMinimum Minimum output amount required.
  /// @param recipient Address that receives the output token.
  /// @param deadline Timestamp after which the swap reverts.
  /// @param priceLimitX64 Q64.64 execution bound. `zeroForOne`: `0` is unconstrained lower bound.
  ///        `!zeroForOne`: `type(uint128).max` is unconstrained upper bound. Opposite sentinels revert.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  struct ExactInputSingleParams {
    address pool;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    address recipient;
    uint256 deadline;
    uint128 priceLimitX64;
    bytes extensionData;
  }

  /// @notice Multihop exact-input swap parameters.
  /// @dev Slippage protection is `amountOutMinimum` only; each hop uses an open price limit.
  ///      The caller must ensure `tokens` and `pools` describe a valid connected route.
  /// @param tokens Path tokens `[t0, t1, …, tn]`.
  /// @param pools Pool between each adjacent token pair; length must be `tokens.length - 1`.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`; supports up to 256 hops.
  /// @param amountIn Exact input amount of `tokens[0]`.
  /// @param amountOutMinimum Minimum output amount of `tokens[tokens.length - 1]`.
  /// @param recipient Address that receives the final output token.
  /// @param deadline Timestamp after which the swap reverts.
  struct ExactInputParams {
    address[] tokens;
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountIn;
    uint128 amountOutMinimum;
    address recipient;
    uint256 deadline;
  }

  /// @notice Single-hop exact-output swap parameters.
  /// @param pool MetricOmm pool address for this hop.
  /// @param tokenIn ERC-20 the router pulls from the swap initiator during the swap callback; caller must set correctly off-chain.
  /// @param tokenOut Output token for this hop; informational for integrators, unused on-chain.
  /// @param zeroForOne `true` sells token0 for token1.
  /// @param amountOut Exact output amount.
  /// @param amountInMaximum Maximum input amount allowed.
  /// @param recipient Address that receives the output token.
  /// @param deadline Timestamp after which the swap reverts.
  /// @param priceLimitX64 Q64.64 execution bound. `zeroForOne`: `0` is unconstrained lower bound.
  ///        `!zeroForOne`: `type(uint128).max` is unconstrained upper bound. Opposite sentinels revert.
  /// @param extensionData Opaque bytes forwarded to the pool swap extension.
  struct ExactOutputSingleParams {
    address pool;
    address tokenIn;
    address tokenOut;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    address recipient;
    uint256 deadline;
    uint128 priceLimitX64;
    bytes extensionData;
  }

  /// @notice Multihop exact-output swap parameters.
  /// @dev Slippage protection is `amountInMaximum` only; each hop uses an open price limit.
  ///      The caller must ensure `tokens` and `pools` describe a valid connected route.
  ///      Execution starts at `pools[pools.length - 1]` and walks toward `pools[0]`.
  /// @param tokens Path tokens `[t0, t1, …, tn]`.
  /// @param pools Pool between each adjacent token pair; length must be `tokens.length - 1`.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`; supports up to 256 hops.
  /// @param amountOut Exact output amount of `tokens[tokens.length - 1]`.
  /// @param amountInMaximum Maximum input amount of `tokens[0]`.
  /// @param recipient Address that receives the final output token.
  /// @param deadline Timestamp after which the swap reverts.
  struct ExactOutputParams {
    address[] tokens;
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountOut;
    uint128 amountInMaximum;
    address recipient;
    uint256 deadline;
  }

  // ============ Mutating: exact input ============

  function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

  function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

  // ============ Mutating: exact output ============

  function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

  function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
