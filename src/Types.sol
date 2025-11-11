// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title Types Library
/// @notice Contains shared data structures and constants used by KipuBank contracts.
/// @dev Provides the `AssetConfig` struct and defines a constant for representing native ETH.
library Types {
    /// @notice Special address used to represent native ETH as a "token" within mappings.
    /// @dev Using address(0) avoids conflict with real ERC20 tokens.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Configuration data for an asset supported by the KipuBank.
    /// @dev Associates a Chainlink price feed and enablement flag with each token.
    struct AssetConfig {
        /// @notice Chainlink price feed for TOKEN/USD (or ETH/USD when token == NATIVE_TOKEN).
        AggregatorV3Interface priceFeed;
        /// @notice Indicates whether deposits and withdrawals are enabled for this asset.
        bool enabled;
    }
}