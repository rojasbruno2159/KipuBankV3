   // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    function run() external returns (KipuBankV3) {
        // ======== Configuration ========
        uint256 bankCapUsd = 10 ether;
        uint256 withdrawLimitPerTxNative = 1 ether;
        address ethUsdFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address uniswapRouter = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
        address usdc = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;

        vm.startBroadcast();
        KipuBankV3 kipuBank = new KipuBankV3(
            bankCapUsd,
            withdrawLimitPerTxNative,
            ethUsdFeed,
            uniswapRouter,
            usdc
        );
        vm.stopBroadcast();

        return kipuBank;
    }
}