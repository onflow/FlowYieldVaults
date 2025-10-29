// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {FlowBridgeFactory} from "../../lib/flow-evm-bridge/solidity/src/FlowBridgeFactory.sol";

/// @title FactoryC2Deployer
/// @notice Deterministically deploys FlowBridgeFactory via CREATE2 *and* fixes ownership in the same tx.
/// @dev Deploy this contract itself *deterministically* (e.g. with EIP-2470 0x4e59... and a salt).
/// Then call deployFactory(salt, owner). The resulting FlowBridgeFactory address will be stable across runs
/// as long as this deployer lives at the same address and you reuse the same salt and bytecode.
contract FactoryC2Deployer {
	event FactoryDeployed(address factory, bytes32 salt, address owner);


	/// @notice Deploy FlowBridgeFactory with CREATE2 and transfer ownership to `newOwner` in the same tx.
	/// @param salt Salt for CREATE2 (choose once and keep it stable)
	/// @param newOwner Final owner for FlowBridgeFactory
	function deployFactory(bytes32 salt, address newOwner) external returns (address factory) {
		// CREATE2 init code is just the creationCode since FlowBridgeFactory has an empty constructor
		bytes memory code = type(FlowBridgeFactory).creationCode;


		assembly {
			let data := add(code, 0x20)
			let size := mload(code)
			factory := create2(0, data, size, salt)
			if iszero(factory) { revert(0, 0) }
		}


		// Ownable(msg.sender) means the owner is *this* deployer at construction time.
		// Transfer to the requested owner now:
		FlowBridgeFactory(factory).transferOwnership(newOwner);


		emit FactoryDeployed(factory, salt, newOwner);
	}


	/// @notice Helper to compute the address beforehand.
	function predictFactory(bytes32 salt) external view returns (address predicted) {
		bytes32 codeHash = keccak256(type(FlowBridgeFactory).creationCode);
		predicted = address(uint160(uint(keccak256(abi.encodePacked(
			bytes1(0xff), address(this), salt, codeHash
		)))));
	}
}

contract DeployFactoryStaticLocal is Script {
    uint256 constant PK_ACCOUNT =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant OWNER =
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    bytes32 constant SALT_DEPLOYER = bytes32("FLOW-DEPLOYER-DEPLOYER");
    bytes32 constant SALT_FACTORY  = bytes32("FLOW-FACTORY-DETERMINI");

    // from forge-std Base.sol (don’t redeclare)
    // address internal constant CREATE2_FACTORY = 0x4e59...B4956C;

    function run() external {
        vm.startBroadcast(PK_ACCOUNT);

        // 1) Predict helper address
        address predictedDeployer = _computeCreate2Address(
            CREATE2_FACTORY,
            SALT_DEPLOYER,
            keccak256(type(FactoryC2Deployer).creationCode)
        );

        // 2) Deploy helper if missing, then WAIT until code exists
        FactoryC2Deployer deployer;
        if (predictedDeployer.code.length == 0) {
            deployer = new FactoryC2Deployer{salt: SALT_DEPLOYER}();
            require(address(deployer) == predictedDeployer, "deployer addr mismatch");
            _waitForCode(predictedDeployer); // <- IMPORTANT
        } else {
            deployer = FactoryC2Deployer(predictedDeployer);
        }
        console2.log("Deployer:", address(deployer));

        // 3) Predict & deploy factory
        address predictedFactory = deployer.predictFactory(SALT_FACTORY);
        console2.log("Predicted FlowBridgeFactory:", predictedFactory);

        if (predictedFactory.code.length == 0) {
            address actual = deployer.deployFactory(SALT_FACTORY, OWNER);
            require(actual == predictedFactory, "factory addr mismatch");
        }
        console2.log("FlowBridgeFactory:", predictedFactory);

        vm.stopBroadcast();
    }

    function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 codeHash
    ) internal pure returns (address) {
        return address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff), deployer, salt, codeHash
        )))));
    }

    /// Poll RPC until bytecode is present at `addr`
    function _waitForCode(address addr) internal {
        // use json-rpc directly to avoid sending another tx too soon
        for (uint i = 0; i < 60; i++) {
            // eth_getCode(addr, "latest")
            bytes memory req = abi.encodePacked(
                '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["',
                vm.toString(addr),
                '","latest"]}'
            );
            bytes memory resp = vm.rpc("eth_getCode", string(
                abi.encodePacked('["', vm.toString(addr), '","latest"]')
            ));
            // resp is raw hex bytes of the code, e.g. 0x...
            if (keccak256(resp) != keccak256(bytes("0x"))) return;
            vm.sleep(1); // wait 1s and try again
        }
        revert("timeout waiting for helper code");
    }
}
