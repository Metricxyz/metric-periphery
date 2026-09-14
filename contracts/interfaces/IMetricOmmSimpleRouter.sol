// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSwapCallback} from "@metric-core/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IMulticall} from "./IMulticall.sol";
import {ISelfPermit} from "./ISelfPermit.sol";
import {IPeripheryPayments} from "./IPeripheryPayments.sol";

/// @title IMetricOmmSimpleRouter
/// @notice ERC-20 exact-input and exact-output swaps through one or more MetricOmm pools.
/// @dev Scope: supports native ETH (auto-wrapped to WETH in payment) and pre-wrapped WETH/ERC-20 as swap
///      input/output. `unwrapWETH9`, `sweepToken`, and `refundETH` are available via IPeripheryPayments.
///      On-chain quotes are not part of this interface.
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
  /// @notice Neither the primary nor the fallback route completed.
  /// @param primaryReason Revert data returned by the primary route, truncated to at most 4096 bytes.
  /// @param fallbackReason Fallback error; external target revert data is truncated to at most 4096 bytes.
  error BothRoutesFailed(bytes primaryReason, bytes fallbackReason);
  /// @notice Attempt entrypoint was reached by a caller other than the router itself.
  error OnlySelf();
  /// @notice The fallback target is this router or has no deployed code.
  error InvalidFallbackRouter(address target);
  /// @notice Fallback route carried empty calldata.
  error EmptyFallbackCallData();
  /// @notice External fallback router reverted without returning any reason data.
  error FallbackCallFailed();
  /// @notice Fallback accounting requires distinct input and output tokens.
  error SameTokenFallback();
  /// @notice A nonzero primary attempt budget is required.
  error InvalidPrimaryGasLimit();

  /// @notice Gas remaining cannot cover the primary budget, fallback reserve, and call overhead.
  /// @param gasReserve Gas the caller asked to hold back for the fallback route.
  /// @param gasAvailable Gas remaining when the reserve was checked.
  error InsufficientGasReserve(uint256 gasReserve, uint256 gasAvailable);

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

  /// @notice Exact-input swap through MetricOmm pools, falling back to an external aggregator router.
  /// @dev For routes that are not executable against the state a simulation sees, because the state they depend
  ///      on lands earlier in the same block. `primary` is attempted first and the external leg runs only if it
  ///      reverts, so exactly one leg settles. A reverted attempt rolls back its own transfers, approvals, and
  ///      transient callback context, so the fallback starts from entry state.
  ///      Token pair, input amount, minimum output, and recipient are all taken from `primary`, so both legs are
  ///      bound by one slippage figure by construction. The original `primary.amountOutMinimum`
  ///      is never lowered for the fallback. Do not attach a fallback quote that cannot meet it.
  ///      `fallbackCallData` must be encoded to spend `primary.amountIn` of `primary.tokens[0]` and to deliver the
  ///      output to this router, which forwards it to `primary.recipient`. It is not decoded or validated: the
  ///      approval is capped at `primary.amountIn` and the measured output delta is checked against
  ///      `primary.amountOutMinimum`, which bounds the leg whatever the calldata says.
  /// @param primary MetricOmm route preferred when it is executable. Its deadline applies to both routes
  ///        and is checked before either attempt.
  /// @param fallbackRouter Caller-selected contract that both receives the call and spends the approved input.
  ///        Must have deployed code and differ from this router. Separate approval and execution targets require an adapter.
  /// @param fallbackCallData Pre-encoded call for the external fallback router, run only when `primary` reverts.
  /// @param gasReserve Gas retained for fallback execution and wrapper settlement.
  /// @param primaryGasLimit Fixed, nonzero gas forwarded to the primary attempt. Estimate against updated state.
  ///        The outer call must cover this budget, the reserve, EIP-150 retention and wrapper overhead.
  struct ExactInputWithFallbackParams {
    ExactInputParams primary;
    address fallbackRouter;
    bytes fallbackCallData;
    uint256 gasReserve;
    uint256 primaryGasLimit;
  }

  /// @notice Terms for the external fallback leg; all amount limits and the deadline come from the primary route.
  /// @dev The fallback rejects identical input and output tokens before funding or approval.
  /// @param fallbackRouter Caller-selected approval and execution target.
  /// @param tokenIn Input token pulled from `payer` and approved to the fallback router.
  /// @param tokenOut Output token whose balance delta on this router is measured and forwarded.
  /// @param recipient Address that receives the measured output.
  /// @param payer Address the input is pulled from, and the leftover input is refunded to.
  /// @param amountIn Input pulled from `payer`, and the cap on the approval granted to the fallback router.
  ///        Exact-input legs set this to the exact spend; exact-output legs set it to the maximum spend, and any
  ///        part the leg does not consume is refunded to `payer`.
  /// @param amountOutMinimum Minimum measured output. Exact-output legs set this to the exact output required.
  /// @param deadline Original primary deadline, also enforced by the fallback leg.
  struct FallbackSwapTerms {
    address fallbackRouter;
    address tokenIn;
    address tokenOut;
    address recipient;
    address payer;
    uint128 amountIn;
    uint128 amountOutMinimum;
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

  /// @notice Exact-output swap through MetricOmm pools, falling back to an external aggregator router.
  /// @dev The exact-output counterpart of `ExactInputWithFallbackParams`; the same one-leg-settles rule applies.
  ///      Token pair, recipient, exact output, and maximum input are all taken from `primary`, so both legs are
  ///      bound by one set of limits by construction. the original `primary.amountInMaximum` is never raised for
  ///      the fallback. Do not attach a quote that requires more input.
  ///      `fallbackCallData` must be encoded to deliver exactly `primary.amountOut` of the final path token to this
  ///      router, spending no more than `primary.amountInMaximum` of `primary.tokens[0]`. It is not decoded or
  ///      validated: the approval is capped at `primary.amountInMaximum` and the measured output delta is checked
  ///      against `primary.amountOut`, which bounds the leg whatever the calldata says. Input the leg leaves
  ///      unspent is refunded to the payer.
  /// @param primary MetricOmm route preferred when it is executable. Its deadline applies to both routes
  ///        and is checked before either attempt.
  /// @param fallbackRouter Caller-selected contract that both receives the call and spends the approved input.
  ///        Must have deployed code and differ from this router. Separate approval and execution targets require an adapter.
  /// @param fallbackCallData Pre-encoded call for the external fallback router, run only when `primary` reverts.
  /// @param gasReserve Gas retained for fallback execution and wrapper settlement.
  /// @param primaryGasLimit Fixed, nonzero gas forwarded to the primary attempt. Estimate against updated state.
  ///        The outer call must cover this budget, the reserve, EIP-150 retention and wrapper overhead.
  struct ExactOutputWithFallbackParams {
    ExactOutputParams primary;
    address fallbackRouter;
    bytes fallbackCallData;
    uint256 gasReserve;
    uint256 primaryGasLimit;
  }

  // ============ Mutating: exact input ============

  function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

  function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

  function exactInputWithFallback(ExactInputWithFallbackParams calldata params)
    external
    payable
    returns (uint256 amountOut, bool usedFallback);

  function exactInputAttempt(ExactInputParams calldata params, address payer) external returns (uint256 amountOut);

  function fallbackSwapAttempt(FallbackSwapTerms calldata terms, bytes calldata callData)
    external
    returns (uint256 amountOut, uint256 amountSpent);

  // ============ Mutating: exact output ============

  function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

  function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);

  function exactOutputWithFallback(ExactOutputWithFallbackParams calldata params)
    external
    payable
    returns (uint256 amountIn, bool usedFallback);

  function exactOutputAttempt(ExactOutputParams calldata params, address payer) external returns (uint256 amountIn);
}
