// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {

    // MAINNET / TESTNET addresses reales (se detecta automáticamente)
    address constant ROUTER = 0xC53211616719c136A9a8075aEe7C5482A188AE50; // Uniswap v2 router Sepolia
    address constant WETH   = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC   = 0x1c7D4B196cB0c7b01D743FBC6330e9f9E1Eca96f;
    address constant ORACLE = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    uint256 constant BANK_CAP = 1_000_000 * 1e6;

    function run() external returns (KipuBankV3 kipu) {
        uint256 deployer = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployer);

        kipu = new KipuBankV3(
            ORACLE,
            USDC,
            BANK_CAP,
            ROUTER,
            WETH
        );

        vm.stopBroadcast();
    }
}
