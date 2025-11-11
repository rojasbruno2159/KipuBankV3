// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Decimals conversion library (to USDC 6 decimals)
/// @notice Helpers to normalize token amounts to USDC scale (6 decimals).
/// @dev Pure math; no state. Keeps naming and logic unchanged.
library Decimals {
    /// @notice Canonical decimals used across the project for accounting (USDC = 6).
    uint8 public constant USDC_DECIMALS = 6;

    /// @notice Converts an `amount` expressed in `tokenDecimals` to USDC scale (6).
    /// @param amount Amount in the source token's decimals.
    /// @param tokenDecimals Decimals of the source token.
    /// @return Amount rescaled to 6 decimals (USDC units).
    function toUSDC(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == USDC_DECIMALS) return amount;
        if (tokenDecimals > USDC_DECIMALS) {
            unchecked { return amount / (10 ** (tokenDecimals - USDC_DECIMALS)); }
        } else {
            unchecked { return amount * (10 ** (USDC_DECIMALS - tokenDecimals)); }
        }
    }
}

