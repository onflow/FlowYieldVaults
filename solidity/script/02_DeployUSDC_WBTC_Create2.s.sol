// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/tokens/USDC6.sol";
import "../src/tokens/WBTC8.sol";

contract DeployUSDC_WBTC_Create2 is Script {
    // Foundry's CREATE2 deployer used during broadcast
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Fixed salts → stable addresses for a given initcode
    bytes32 constant SALT_USDC = keccak256("FLOW-USDC-001");
    bytes32 constant SALT_WBTC = keccak256("FLOW-WBTC-001");

    function run() external {
        uint256 pk     = vm.envUint("PK_ACCOUNT");
        address eoa    = vm.addr(pk);
        address owner  = vm.envOr("TOKENS_OWNER", eoa);

        // Build full initcode (creationCode + constructor args)
        bytes memory usdcInit = abi.encodePacked(type(USDC6).creationCode, abi.encode(owner));
        bytes memory wbtcInit = abi.encodePacked(type(WBTC8).creationCode, abi.encode(owner));

        address predictedUSDC = _predict(CREATE2_DEPLOYER, SALT_USDC, usdcInit);
        address predictedWBTC = _predict(CREATE2_DEPLOYER, SALT_WBTC, wbtcInit);

        console2.log("Predicted USDC:", predictedUSDC);
        console2.log("Predicted WBTC:", predictedWBTC);

        vm.startBroadcast(pk);

        // Deploy if missing
        if (predictedUSDC.code.length == 0) {
            USDC6 usdc = new USDC6{salt: SALT_USDC}(owner);
            require(address(usdc) == predictedUSDC, "USDC addr mismatch");
            console2.log("Deployed USDC at", address(usdc));
        } else {
            console2.log("USDC already at", predictedUSDC);
        }

        if (predictedWBTC.code.length == 0) {
            WBTC8 wbtc = new WBTC8{salt: SALT_WBTC}(owner);
            require(address(wbtc) == predictedWBTC, "WBTC addr mismatch");
            console2.log("Deployed WBTC at", address(wbtc));
        } else {
            console2.log("WBTC already at", predictedWBTC);
        }

        // Optional mints (env-driven)
        uint256 usdcMint = vm.envOr("USDC_MINT", uint256(0)); // 6 decimals
        uint256 wbtcMint = vm.envOr("WBTC_MINT", uint256(0)); // 8 decimals
        if (usdcMint > 0) USDC6(predictedUSDC).mint(owner, usdcMint);
        if (wbtcMint > 0) WBTC8(predictedWBTC).mint(owner, wbtcMint);

        vm.stopBroadcast();
    }

    function _predict(address deployer, bytes32 salt, bytes memory initcode)
        internal pure returns (address)
    {
        bytes32 initHash = keccak256(initcode);
        return address(uint160(uint(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, initHash)
        ))));
    }
}
