// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ========= IMPORTS =========
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AccessControl as OZAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import "./Types.sol";
import "./Decimals.sol";

/* ============================================================
 *                UNISWAP V2 MINIMAL INTERFACES
 * ============================================================
 */
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    // Views
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);

    // Swaps
    function swapExactETHForTokens(
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);
}

/* ============================================================
 *                       KIPUBANK V3
 * ============================================================
 */

/// @title KipuBankV3
/// @notice Multi-asset vault with a USD-denominated global bank cap; preserves V2 features (Chainlink feeds API kept) and extends deposits/withdrawals using Uniswap V2 swaps.
/// @dev Strict layout: variables → events → errors → functions. Preserves V2 public surface and storage.
///      New Uniswap-based entrypoints are additive: they do not modify V2 behavior.
///      All balances are accounted in USDC units (6 decimals) per token key, consistent with V2 (nested mapping).
contract KipuBankV3 is OZAccessControl {
    using SafeERC20 for IERC20;

    // ========= STATE VARIABLES =========

    /// @notice Role identifier for privileged administrators.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Global bank cap in USD scaled to USDC decimals (6).
    /// @dev Immutable to save gas.
    uint256 public immutable bankCapUsd;

    /// @notice Per-transaction withdrawal limit for native ETH, in wei (legacy V2 behavior).
    uint256 public immutable withdrawLimitPerTxNative;

    /// @notice Chainlink price feed for ETH/USD (kept for V2 compatibility and views).
    AggregatorV3Interface public immutable ethUsdFeed;

    /// @notice Asset registry mapping: token address → configuration (price feed + enabled flag).
    mapping(address => Types.AssetConfig) private assetConfigs;

    /// @notice Nested balances in USDC decimals (6): token → user → balance in USDC units.
    /// @dev Preserved from V2. In V3, Uniswap-based deposits credit under the USDC token key.
    mapping(address => mapping(address => uint256)) private balancesUSDC;

    /// @notice Total successful deposit operations performed.
    uint128 public totalDepositCount;

    /// @notice Total successful withdraw operations performed.
    uint128 public totalWithdrawCount;

    /// @notice Global total of user deposits valued in USD (USDC 6 decimals).
    uint256 public totalUsdDeposits;

    /// @dev Simple reentrancy lock flag.
    bool private locked;

    /// @notice Uniswap V2 router used for on-chain swaps.
    IUniswapV2Router02 public uniswapRouter;

    /// @notice WETH address resolved from the router.
    address public weth;

    /// @notice USDC token used as the accounting unit (6 decimals).
    address public usdc;

    // ========= EVENTS =========

    /// @notice Emitted when a user deposits native ETH (legacy V2 path, priced by feed).
    event DepositedNative(address indexed user, uint256 amountWei, uint256 creditedUSDC);

    /// @notice Emitted when a user deposits an ERC20 token (legacy V2 path, priced by feed).
    event DepositedToken(address indexed user, address indexed token, uint256 amount, uint256 creditedUSDC);

    /// @notice Emitted when a user withdraws native ETH (legacy V2 path, debiting NATIVE token bucket).
    event WithdrawnNative(address indexed user, uint256 amountWei, uint256 debitedUSDC);

    /// @notice Emitted when a user withdraws an ERC20 token (legacy V2 path).
    event WithdrawnToken(address indexed user, address indexed token, uint256 amount, uint256 debitedUSDC);

    /// @notice Emitted when an asset configuration is created or updated.
    event AssetConfigured(address indexed token, address indexed priceFeed, bool enabled);

    /// @notice Emitted when a user deposits via Uniswap V2 swap (credits under USDC bucket).
    event DepositedViaUniswap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcCredited);

    /// @notice Emitted when a user withdraws ETH via Uniswap V2 (USDC → ETH).
    event WithdrawnNativeViaUniswap(address indexed user, uint256 amountWei, uint256 usdcSpent);

    /// @notice Emitted when admin changes the Uniswap router.
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    /// @notice Emitted when admin changes the USDC token address.
    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);

    // ========= ERRORS =========

    /// @notice Thrown when a provided value is zero or otherwise invalid.
    error InvalidValue();

    /// @notice Thrown on reentrancy attempts.
    error Reentrancy();

    /// @notice Thrown when a deposit would exceed the global USD cap.
    error BankCapExceeded(uint256 currentTotalUsd, uint256 attemptedUsd, uint256 capUsd);

    /// @notice Thrown when an asset is disabled.
    error AssetDisabled(address token);

    /// @notice Thrown when a user attempts to withdraw more than their balance.
    error InsufficientBalance(uint256 availableUSDC, uint256 requestedUSDC);

    /// @notice Thrown when a native-asset withdrawal exceeds the per-transaction limit.
    error WithdrawLimitExceeded(uint256 requested, uint256 limit);

    /// @notice Thrown when a native transfer fails.
    error TransferFailed(address to, uint256 amount);

    /// @notice Thrown when an asset lacks a configured price feed (kept for V2 compatibility).
    error MissingPriceFeed(address token);

    /// @notice Thrown when no direct path token <-> USDC is available in Uniswap V2.
    error NoDirectUSDCPath(address token);

    /// @notice Thrown on excessive slippage or user-provided bounds not met.
    error SlippageTooHigh();

    // ========= MODIFIERS (WRAPPED) & HELPERS =========

    /// @dev Non-reentrancy guard for state-changing entry points (wrapped).
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    /// @dev Ensures the asset is enabled. For V2 legacy functions also checks price feed presence (wrapped).
    modifier assetEnabled(address token) {
        _assetEnabled(token);
        _;
    }

    /// @dev Pure-style validation against a provided snapshot (no storage read) (wrapped).
    modifier withinBankCapGiven(uint256 currentTotalUsd, uint256 additionalUsd, uint256 capUsd) {
        _withinBankCapGiven(currentTotalUsd, additionalUsd, capUsd);
        _;
    }

    /// @dev Per-transaction limit validation for native withdrawals (legacy V2) (wrapped).
    modifier withinWithdrawalLimit(uint256 amountWei) {
        _withinWithdrawalLimit(amountWei);
        _;
    }

    /// @dev Reentrancy pre-hook.
    function _nonReentrantBefore() internal {
        if (locked) revert Reentrancy();
        locked = true;
    }

    /// @dev Reentrancy post-hook.
    function _nonReentrantAfter() internal {
        locked = false;
    }

    /// @dev Asserts that a given token is enabled in the registry.
    /// @param token Asset address to check.
    function _assetEnabled(address token) internal view {
        Types.AssetConfig memory cfg = assetConfigs[token];
        if (!cfg.enabled) revert AssetDisabled(token);
    }

    /// @dev Asserts that adding `additionalUsd` to `currentTotalUsd` does not exceed `capUsd`.
    /// @param currentTotalUsd Snapshot of current total in USDC units.
    /// @param additionalUsd Amount to add in USDC units.
    /// @param capUsd Global bank cap in USDC units.
    function _withinBankCapGiven(
        uint256 currentTotalUsd,
        uint256 additionalUsd,
        uint256 capUsd
    ) internal pure {
        uint256 newTotal = currentTotalUsd + additionalUsd;
        if (newTotal > capUsd) revert BankCapExceeded(currentTotalUsd, additionalUsd, capUsd);
    }

    /// @dev Asserts that a native withdrawal does not exceed the per-tx limit.
    /// @param amountWei ETH amount in wei requested for withdrawal.
    function _withinWithdrawalLimit(uint256 amountWei) internal view {
        if (amountWei > withdrawLimitPerTxNative) {
            revert WithdrawLimitExceeded(amountWei, withdrawLimitPerTxNative);
        }
    }

    // ----- CONSTRUCTOR -----

    /**
     * @notice Initializes the vault with V2-compatible state and V3 Uniswap router/USDC addresses.
     * @dev Native ETH is registered as an enabled asset using the provided ETH/USD feed (for V2 views).
     * @param _bankCapUsd Global cap in USDC units (6 decimals).
     * @param _withdrawLimitPerTxNative Per-transaction native withdraw limit in wei (legacy V2).
     * @param _ethUsdFeed Chainlink ETH/USD price feed (kept for V2 compatibility).
     * @param _uniswapRouter Uniswap V2 router address. 
     * @param _usdc USDC token address (6 decimals). 
     */
    constructor(
        uint256 _bankCapUsd,
        uint256 _withdrawLimitPerTxNative,
        address _ethUsdFeed,
        address _uniswapRouter, 
        address _usdc 
    ) {
        bankCapUsd = _bankCapUsd;
        withdrawLimitPerTxNative = _withdrawLimitPerTxNative;
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // Register native ETH and USDC as enabled assets.
        assetConfigs[Types.NATIVE_TOKEN] = Types.AssetConfig({
            priceFeed: AggregatorV3Interface(_ethUsdFeed),
            enabled: true
        });
        assetConfigs[_usdc] = Types.AssetConfig({
            priceFeed: AggregatorV3Interface(address(0)),
            enabled: true
        });

        // V3 router & tokens
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        weth = IUniswapV2Router02(_uniswapRouter).WETH();
        usdc = _usdc;

        emit AssetConfigured(Types.NATIVE_TOKEN, _ethUsdFeed, true);
        emit AssetConfigured(_usdc, address(0), true);
        emit RouterUpdated(address(0), _uniswapRouter);
        emit UsdcUpdated(address(0), _usdc);
    }

    // ----- ADMIN FUNCTIONS -----

    /**
     * @notice Updates Uniswap V2 router (admin only).
     * @dev Allows switching between local Foundry router and testnet/mainnet router without redeploy.
     * @param newRouter New router address.
     */
    function setUniswapRouter(address newRouter) external onlyRole(ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidValue();
        address old = address(uniswapRouter);
        uniswapRouter = IUniswapV2Router02(newRouter);
        weth = IUniswapV2Router02(newRouter).WETH();
        emit RouterUpdated(old, newRouter);
    }

    /**
     * @notice Updates USDC token address (admin only).
     * @dev Useful for local/mock USDC in Foundry vs real USDC on testnet.
     * @param newUsdc New USDC token address (6 decimals).
     */
    function setUSDC(address newUsdc) external onlyRole(ADMIN_ROLE) {
        if (newUsdc == address(0)) revert InvalidValue();
        address old = usdc;
        usdc = newUsdc;
        // Ensure USDC is enabled as asset (if not already).
        assetConfigs[newUsdc].enabled = true;
        emit UsdcUpdated(old, newUsdc);
        emit AssetConfigured(newUsdc, address(0), true);
    }

    /**
     * @notice Configures or updates a token’s Chainlink feed and enablement (admin only).
     * @dev Kept for V2 compatibility; feeds are not used by Uniswap swap paths.
     * @param token ERC20 token address (use address(0) for native ETH).
     * @param priceFeed Chainlink AggregatorV3Interface for TOKEN/USD.
     * @param enabled Whether to allow deposits/withdrawals for the asset.
     */
    function setAssetConfig(
        address token,
        address priceFeed,
        bool enabled
    ) external onlyRole(ADMIN_ROLE) {
        assetConfigs[token] = Types.AssetConfig({
            priceFeed: AggregatorV3Interface(priceFeed),
            enabled: enabled
        });
        emit AssetConfigured(token, priceFeed, enabled);
    }

    // ----- EXTERNAL (STATE-CHANGING) — V2 LEGACY PATHS -----

    /**
     * @notice Deposits native ETH and credits the sender in USDC units (6 decimals) using the ETH/USD feed (legacy V2).
     * @dev Preserved from V2 for compatibility. Uses price feed, not Uniswap swap. Subject to bank cap.
     */
    function depositNative()
        external
        payable
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
    {
        if (msg.value == 0) revert InvalidValue();

        uint256 creditedUSDC = _quoteWeiToUSDC(msg.value);
        uint256 currentTotal = totalUsdDeposits;

        _depositNative(creditedUSDC, currentTotal);
    }

    /**
     * @notice Deposits an ERC20 token and credits in USDC units (6 decimals) using TOKEN/USD feed (legacy V2).
     * @dev Preserved from V2 for compatibility. Uses price feed, not Uniswap swap. Subject to bank cap.
     * @param token The ERC20 token to deposit.
     * @param amount The token amount to deposit (token decimals).
     */
    function depositToken(address token, uint256 amount)
        external
        nonReentrant
        assetEnabled(token)
    {
        if (amount == 0) revert InvalidValue();

        uint256 creditedUSDC = _quoteTokenToUSDC(token, amount);
        uint256 currentTotal = totalUsdDeposits;

        _depositToken(token, amount, creditedUSDC, currentTotal);
    }

    /**
     * @notice Withdraws native ETH; debits the sender’s USDC-accounting bucket for native (legacy V2).
     * @dev Preserved from V2. Does not use Uniswap swap; sends ETH from contract balance.
     * @param amountWei The ETH amount to withdraw in wei.
     */
    function withdrawNative(uint256 amountWei)
        external
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
        withinWithdrawalLimit(amountWei)
    {
        if (amountWei == 0) revert InvalidValue();

        uint256 debitUSDC = _quoteWeiToUSDC(amountWei);
        uint256 availableUSDC = balancesUSDC[Types.NATIVE_TOKEN][msg.sender];
        uint256 currentTotal = totalUsdDeposits;

        _withdrawNative(amountWei, debitUSDC, availableUSDC, currentTotal);
    }

    /**
     * @notice Withdraws an ERC20 token; debits the sender’s USDC-accounting bucket for that token (legacy V2).
     * @dev Preserved from V2. Does not use Uniswap.
     * @param token The ERC20 token address to withdraw.
     * @param amountToken The token amount to withdraw (token decimals).
     */
    function withdrawToken(address token, uint256 amountToken)
        external
        nonReentrant
        assetEnabled(token)
    {
        if (amountToken == 0) revert InvalidValue();

        uint256 debitUSDC = _quoteTokenToUSDC(token, amountToken);
        uint256 availableUSDC = balancesUSDC[token][msg.sender];
        uint256 currentTotal = totalUsdDeposits;

        _withdrawToken(token, amountToken, debitUSDC, availableUSDC, currentTotal);
    }

    // ----- EXTERNAL (STATE-CHANGING) — V3 UNISWAP EXTENSIONS -----

    /**
     * @notice Deposits native ETH and swaps to USDC via Uniswap V2, then credits under the USDC bucket.
     * @dev Bank cap is enforced using a pre-swap expectedOut check and capping the credited amount if needed.
     * @param minUSDCOut Minimum acceptable USDC out to protect against slippage.
     */
    function depositNativeViaUniswapV2(uint256 minUSDCOut)
        external
        payable
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
    {
        if (msg.value == 0) revert InvalidValue();

        address[] memory path = _makePath(weth, usdc);

        uint256 expectedOut = _getAmountsOut(msg.value, path);
        if (expectedOut == 0 || minUSDCOut > expectedOut) revert SlippageTooHigh();

        uint256 capRemaining = bankCapUsd - totalUsdDeposits;
        if (expectedOut > capRemaining) {
            revert BankCapExceeded(totalUsdDeposits, expectedOut, bankCapUsd);
        }

        uint[] memory amounts = uniswapRouter.swapExactETHForTokens{value: msg.value}(
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 usdcOut = amounts[amounts.length - 1];
        uint256 credit = usdcOut > capRemaining ? capRemaining : usdcOut;

        // Credit under USDC bucket
        balancesUSDC[usdc][msg.sender] += credit;
        totalUsdDeposits += credit;
        totalDepositCount++;

        emit DepositedViaUniswap(msg.sender, Types.NATIVE_TOKEN, msg.value, credit);
    }

    /**
     * @notice Deposits an ERC20 token (with a direct pair to USDC in Uniswap V2), swaps to USDC, and credits under USDC bucket.
     * @dev If the token is USDC itself, use depositUSDC() instead for clarity.
     * @param tokenIn ERC20 token to deposit.
     * @param amountIn Amount in token decimals.
     * @param minUSDCOut Minimum acceptable USDC out to protect against slippage.
     */
    function depositTokenViaUniswapV2(address tokenIn, uint256 amountIn, uint256 minUSDCOut)
        external
        nonReentrant
        assetEnabled(tokenIn)
    {
        if (tokenIn == address(0) || amountIn == 0) revert InvalidValue();
        if (tokenIn == usdc) revert InvalidValue(); // direct path for USDC is depositUSDC

        address[] memory path = _makePath(tokenIn, usdc);
        if (path.length != 2 || path[0] != tokenIn || path[1] != usdc) revert NoDirectUSDCPath(tokenIn);

        uint256 expectedOut = _getAmountsOut(amountIn, path);
        if (expectedOut == 0 || minUSDCOut > expectedOut) revert SlippageTooHigh();

        uint256 capRemaining = bankCapUsd - totalUsdDeposits;
        if (expectedOut > capRemaining) {
            revert BankCapExceeded(totalUsdDeposits, expectedOut, bankCapUsd);
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Reset + set allowance to be safe with ERC20s that require zero-first
        IERC20(tokenIn).forceApprove(address(uniswapRouter), 0);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        uint[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 usdcOut = amounts[amounts.length - 1];
        uint256 credit = usdcOut > capRemaining ? capRemaining : usdcOut;

        balancesUSDC[usdc][msg.sender] += credit;
        totalUsdDeposits += credit;
        totalDepositCount++;

        emit DepositedViaUniswap(msg.sender, tokenIn, amountIn, credit);
    }

    /**
     * @notice Deposits USDC directly (credits under USDC bucket).
     * @dev Convenience helper for V3 symmetry; equivalent to V2 token deposit priced at 1:1 for USDC.
     * @param amountUSDC Amount in USDC (6 decimals).
     */
    function depositUSDC(uint256 amountUSDC)
        external
        nonReentrant
        assetEnabled(usdc)
        withinBankCapGiven(totalUsdDeposits, amountUSDC, bankCapUsd)
    {
        if (amountUSDC == 0) revert InvalidValue();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amountUSDC);

        balancesUSDC[usdc][msg.sender] += amountUSDC;
        totalUsdDeposits += amountUSDC;
        totalDepositCount++;

        // Reuse V2 event semantics via DepositedToken or emit dedicated? We keep V3 clarity:
        emit DepositedViaUniswap(msg.sender, usdc, amountUSDC, amountUSDC);
    }

    /**
     * @notice Withdraws native ETH by swapping the caller's USDC balance to ETH via Uniswap V2, enforcing per-tx native limit.
     * @dev Debits under the USDC bucket. This is the V3 symmetric path to deposit via Uniswap.
     * @param amountWei ETH amount to receive (wei).
     * @param maxUSDCIn Maximum USDC the user is willing to spend to obtain the requested ETH (slippage bound).
     */
    function withdrawNativeViaUniswapV2(uint256 amountWei, uint256 maxUSDCIn)
        external
        nonReentrant
        assetEnabled(Types.NATIVE_TOKEN)
        withinWithdrawalLimit(amountWei)
    {
        if (amountWei == 0) revert InvalidValue();

        address[] memory path = _makePath(usdc, weth);

        uint256 neededUSDC = _getAmountsIn(amountWei, path);
        if (neededUSDC == 0 || neededUSDC > maxUSDCIn) revert SlippageTooHigh();

        uint256 bal = balancesUSDC[usdc][msg.sender];
        if (bal < neededUSDC) revert InsufficientBalance(bal, neededUSDC);

        // Effects
        balancesUSDC[usdc][msg.sender] = bal - neededUSDC;
        totalUsdDeposits -= neededUSDC;
        totalWithdrawCount++;

        // Interactions
        IERC20(usdc).forceApprove(address(uniswapRouter), 0);
        IERC20(usdc).forceApprove(address(uniswapRouter), neededUSDC);

        uint[] memory amounts = uniswapRouter.swapExactTokensForETH(
            neededUSDC,
            amountWei,
            path,
            msg.sender,
            block.timestamp + 15 minutes
        );
        uint256 ethOut = amounts[amounts.length - 1];
        if (ethOut < amountWei) revert TransferFailed(msg.sender, amountWei);

        emit WithdrawnNativeViaUniswap(msg.sender, ethOut, neededUSDC);
    }

    // ----- EXTERNAL (RECEIVE/FALLBACK) -----

    /// @notice Explicitly rejects plain ETH transfers without calling the intended entrypoints.
    receive() external payable { revert InvalidValue(); }

    /// @notice Explicitly rejects unexpected calls or ETH sent to unknown selectors.
    fallback() external payable { revert InvalidValue(); }

    // ----- VIEW FUNCTIONS -----

    /**
     * @notice Returns the user balance for a token bucket, in USDC units (6 decimals).
     * @dev For V3 Uniswap-based deposits, balances accumulate under the USDC token bucket.
     * @param token The token bucket address (use address(0) for native; USDC bucket is {usdc}).
     * @param user The user address to query.
     */
    function getBalanceUSDC(address token, address user) external view returns (uint256 balanceUSDC) {
        return balancesUSDC[token][user];
    }

    /**
     * @notice Previews ETH→USDC using Chainlink feed (legacy V2 informational view).
     * @param amountWei ETH amount in wei.
     */
    function previewWeiToUSDC(uint256 amountWei) external view returns (uint256 creditedUSDC) {
        return _quoteWeiToUSDC(amountWei);
    }

    /**
     * @notice Previews TOKEN→USDC using Chainlink feed (legacy V2 informational view).
     * @param token ERC20 token.
     * @param amount Amount in token decimals.
     */
    function previewTokenToUSDC(address token, uint256 amount) external view returns (uint256 creditedUSDC) {
        return _quoteTokenToUSDC(token, amount);
    }

    /**
     * @notice Router-based preview: ETH→USDC expected out via Uniswap V2 path (wETH→USDC).
     * @param amountWei ETH amount in wei.
     */
    function previewWeiToUSDCByRouter(uint256 amountWei) external view returns (uint256) {
        address[] memory path = _makePath(weth, usdc);
        return _getAmountsOut(amountWei, path);
    }

    /**
     * @notice Router-based preview: TOKEN→USDC expected out via Uniswap V2 path (token→USDC).
     * @param tokenIn ERC20 token.
     * @param amountIn Amount in token decimals.
     */
    function previewTokenToUSDCByRouter(address tokenIn, uint256 amountIn) external view returns (uint256) {
        address[] memory path = _makePath(tokenIn, usdc);
        return _getAmountsOut(amountIn, path);
    }

    // ----- INTERNAL STATE-CHANGING (LEGACY V2) -----

    /**
     * @dev Internal native deposit (V2) after pre-calculation and snapshotting.
     * @param creditedUSDC Amount to credit in USDC units (6 decimals).
     * @param currentTotal Snapshot of totalUsdDeposits (USDC 6 decimals).
     */
    function _depositNative(
        uint256 creditedUSDC,
        uint256 currentTotal
    )
        internal
        withinBankCapGiven(currentTotal, creditedUSDC, bankCapUsd)
    {
        balancesUSDC[Types.NATIVE_TOKEN][msg.sender] += creditedUSDC;
        totalUsdDeposits = currentTotal + creditedUSDC;
        totalDepositCount++;

        emit DepositedNative(msg.sender, msg.value, creditedUSDC);
    }

    /**
     * @dev Internal token deposit (V2) after pre-calculation and snapshotting.
     * @param token The ERC20 token address.
     * @param amountToken The token amount to transfer in (token decimals).
     * @param creditedUSDC Amount to credit in USDC units (6 decimals).
     * @param currentTotal Snapshot of totalUsdDeposits (USDC 6 decimals).
     */
    function _depositToken(
        address token,
        uint256 amountToken,
        uint256 creditedUSDC,
        uint256 currentTotal
    )
        internal
        withinBankCapGiven(currentTotal, creditedUSDC, bankCapUsd)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);

        balancesUSDC[token][msg.sender] += creditedUSDC;
        totalUsdDeposits = currentTotal + creditedUSDC;
        totalDepositCount++;

        emit DepositedToken(msg.sender, token, amountToken, creditedUSDC);
    }

    /**
     * @dev Internal native withdraw (V2) after pre-calculation and snapshotting.
     * @param amountWei The ETH amount to send in wei.
     * @param debitUSDC The USDC units (6 decimals) to debit from the user.
     * @param availableUSDC Snapshot of the available user balance (USDC 6 decimals).
     * @param currentTotal Snapshot of totalUsdDeposits (USDC 6 decimals).
     */
    function _withdrawNative(
        uint256 amountWei,
        uint256 debitUSDC,
        uint256 availableUSDC,
        uint256 currentTotal
    )
        internal
    {
        if (availableUSDC < debitUSDC) revert InsufficientBalance(availableUSDC, debitUSDC);

        balancesUSDC[Types.NATIVE_TOKEN][msg.sender] = availableUSDC - debitUSDC;
        totalUsdDeposits = currentTotal - debitUSDC;
        totalWithdrawCount++;

        (bool success, ) = msg.sender.call{value: amountWei}("");
        if (!success) revert TransferFailed(msg.sender, amountWei);

        emit WithdrawnNative(msg.sender, amountWei, debitUSDC);
    }

    /**
     * @dev Internal token withdraw (V2) after pre-calculation and snapshotting.
     * @param token The ERC20 token address to transfer out.
     * @param amountToken The token amount to send (token decimals).
     * @param debitUSDC The USDC units (6 decimals) to debit from the user.
     * @param availableUSDC Snapshot of the available user balance (USDC 6 decimals).
     * @param currentTotal Snapshot of totalUsdDeposits (USDC 6 decimals).
     */
    function _withdrawToken(
        address token,
        uint256 amountToken,
        uint256 debitUSDC,
        uint256 availableUSDC,
        uint256 currentTotal
    )
        internal
    {
        if (availableUSDC < debitUSDC) revert InsufficientBalance(availableUSDC, debitUSDC);

        balancesUSDC[token][msg.sender] = availableUSDC - debitUSDC;
        totalUsdDeposits = currentTotal - debitUSDC;
        totalWithdrawCount++;

        IERC20(token).safeTransfer(msg.sender, amountToken);

        emit WithdrawnToken(msg.sender, token, amountToken, debitUSDC);
    }

    // ----- INTERNAL HELPERS (V2 FEED PRICING) -----

    /**
     * @dev Quotes an ETH amount in USDC units (6 decimals) using the configured ETH/USD feed.
     * @custom:warning Does not validate feed freshness or non-negativity of answer (kept for V2 parity).
     * @param amountWei ETH amount in wei.
     * @return quotedUSDC USD value scaled to USDC decimals (6).
     */
    function _quoteWeiToUSDC(uint256 amountWei) internal view returns (uint256 quotedUSDC) {
        (, int256 answer,,,) = ethUsdFeed.latestRoundData();
        uint8 pdec = ethUsdFeed.decimals();
        uint8 usdcDec = Decimals.USDC_DECIMALS;

        // (wei * price) / 1e18 -> USD with pdec decimals
        uint256 usdP = (amountWei * uint256(answer)) / 1e18;

        if (pdec > usdcDec) {
            return usdP / (10 ** (pdec - usdcDec));
        } else {
            return usdP * (10 ** (usdcDec - pdec));
        }
    }

    /**
     * @dev Quotes a token amount in USDC units (6 decimals) using the configured TOKEN/USD feed.
     * @custom:warning Does not validate feed freshness or non-negativity of answer (kept for V2 parity).
     * @param token The ERC20 token address.
     * @param amount The token amount (token decimals).
     * @return quotedUSDC USD value scaled to USDC decimals (6).
     **/
    function _quoteTokenToUSDC(address token, uint256 amount) internal view returns (uint256 quotedUSDC) {
        AggregatorV3Interface feed = assetConfigs[token].priceFeed;
        if (address(feed) == address(0)) revert MissingPriceFeed(token);
        (, int256 answer,,,) = feed.latestRoundData();
        uint8 pdec = feed.decimals();
        uint8 tdec = IERC20Metadata(token).decimals();
        uint8 usdcDec = Decimals.USDC_DECIMALS;

        uint256 amountUSDCscale = Decimals.toUSDC(amount, tdec);

        if (pdec > usdcDec) {
            return (amountUSDCscale * uint256(answer)) / (10 ** (pdec - usdcDec));
        } else {
            return amountUSDCscale * uint256(answer) * (10 ** (usdcDec - pdec));
        }
    }

    // ----- INTERNAL HELPERS (V3 UNISWAP) -----

    /**
     * @notice Builds a 2-hop swap path for Uniswap V2.
     * @dev Creates an in-memory array [a, b] where `a` is the input token and `b` is the output token.
     *      This helper does not perform any validation on token addresses.
     * @param a The first token address in the path (input token).
     * @param b The second token address in the path (output token).
     * @return path The in-memory array representing the swap path [a, b].
     */
    function _makePath(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }

    /**
     * @notice Previews the expected output amount for a given input and path on Uniswap V2.
     * @dev Thin wrapper around router.getAmountsOut(amountIn, path).
     * @param amountIn The input token amount, in the decimals of path[0].
     * @param path The swap path (must be a valid Uniswap V2 path).
     * @return amountOut The quoted output amount for the last token in `path`.
     */
    function _getAmountsOut(uint256 amountIn, address[] memory path) internal view returns (uint256 amountOut) {
        uint[] memory amts = IUniswapV2Router02(uniswapRouter).getAmountsOut(amountIn, path);
        return amts[amts.length - 1];
    }

    /**
     * @notice Previews the required input amount to receive a target output on Uniswap V2.
     * @dev Thin wrapper around router.getAmountsIn(amountOut, path).
     * @param amountOut The desired output token amount, in the decimals of the last token in `path`.
     * @param path The swap path (must be a valid Uniswap V2 path).
     * @return amountIn The quoted input amount required in the first token of `path`.
     */
    function _getAmountsIn(uint256 amountOut, address[] memory path) internal view returns (uint256 amountIn) {
        uint[] memory amts = IUniswapV2Router02(uniswapRouter).getAmountsIn(amountOut, path);
        return amts[0];
    }
}
