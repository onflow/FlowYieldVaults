// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// ---------- Adjust imports to your repo layout ----------
import {FlowBridgeFactory} from "../../lib/flow-evm-bridge/solidity/src/FlowBridgeFactory.sol";
import {FlowBridgeDeploymentRegistry} from "../../lib/flow-evm-bridge/solidity/src/FlowBridgeDeploymentRegistry.sol";
import {FlowEVMBridgedERC20Deployer} from "../../lib/flow-evm-bridge/solidity/src/FlowEVMBridgedERC20Deployer.sol";
import {FlowEVMBridgedERC721Deployer} from "../../lib/flow-evm-bridge/solidity/src/FlowEVMBridgedERC721Deployer.sol";

// ----------------- Minimal interfaces for wiring -----------------
interface IFlowBridgeFactory {
    function setDeploymentRegistry(address) external;
    function addDeployer(string calldata tag, address deployer) external;
    function transferOwnership(address) external;
}
interface IDeploymentRegistry {
    function setRegistrar(address) external;
}
interface IHasDelegatedDeployer {
    function setDelegatedDeployer(address) external;
}
interface IOwnable {
    function transferOwnership(address) external;
}
// For ownership verification / 2-step accept
interface IOwned {
    function owner() external view returns (address);
}
interface IOwnable2Step {
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

// ----------------- Your existing helper (unchanged) -----------------
contract FactoryC2Deployer {
    event FactoryDeployed(address factory, bytes32 salt, address owner);
    function deployFactory(bytes32 salt, address newOwner) external returns (address factory) {
        bytes memory code = type(FlowBridgeFactory).creationCode;
        assembly {
            let data := add(code, 0x20)
            let size := mload(code)
            factory := create2(0, data, size, salt)
            if iszero(factory) { revert(0, 0) }
        }
        FlowBridgeFactory(factory).transferOwnership(newOwner);
        emit FactoryDeployed(factory, salt, newOwner);
    }
    function predictFactory(bytes32 salt) external view returns (address predicted) {
        bytes32 codeHash = keccak256(type(FlowBridgeFactory).creationCode);
        predicted = address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, codeHash
        )))));
    }
}

// ----------------- Generic helper to deploy Ownable contracts via CREATE2 and set owner -----------------
contract OwnableC2Deployer {
    event Deployed(address deployed, bytes32 salt, address owner);

    function deploy(bytes32 salt, bytes memory creationCode, address newOwner)
        external
        returns (address deployed)
    {
        assembly {
            let data := add(creationCode, 0x20)
            let size := mload(creationCode)
            deployed := create2(0, data, size, salt)
            if iszero(deployed) { revert(0, 0) }
        }
        IOwnable(deployed).transferOwnership(newOwner);
        emit Deployed(deployed, salt, newOwner);
    }

    function predict(bytes32 salt, bytes memory creationCode)
        external
        view
        returns (address predicted)
    {
        bytes32 codeHash = keccak256(creationCode);
        predicted = address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, codeHash
        )))));
    }
}

// =======================================================
// ============= Generalized Deployment Script ===========
// =======================================================
// NOTE: CREATE2_FACTORY constant comes from forge-std/Base via Script inheritance.
contract DeployBridge is Script {
    // Gas/value (value = 0 like in your Cadence tests). We leave gas to RPC estimation.
    uint256 constant TX_VALUE_WEI = 0;

    // Defaults (can be overridden by env)
    uint256 constant DEFAULT_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant DEFAULT_OWNER =
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    enum Mode {
        FACTORY_HELPER,   // deploy FlowBridgeFactory via FactoryC2Deployer (ownership fix)
        OWNABLE_HELPER    // deploy Ownable via OwnableC2Deployer (ownership fix)
    }

    struct DeploySpec {
        string   name;         // label for logs
        bytes    creation;     // creation bytecode
        bytes32  salt;         // 32-byte salt
        Mode     mode;         // helper used
        address  predicted;    // filled at runtime
        address  addr;         // filled at runtime
    }

    // ----- Salts (edit once, keep stable for deterministic addresses) -----
    bytes32 constant SALT_FACTORY_HELPER   = bytes32("FLOW-DEPLOYER-DEPLOYER"); // FactoryC2Deployer (via 0x4e59)
    bytes32 constant SALT_OWNABLE_HELPER   = bytes32("FLOW-OWNABLE-C2-HELPER"); // OwnableC2Deployer (via 0x4e59)

    bytes32 constant SALT_FACTORY   = bytes32("FLOW-FACTORY-DETERMINI"); // FlowBridgeFactory
    bytes32 constant SALT_REGISTRY  = bytes32("FLOW-DEPLOYMENT-REGIS");  // DeploymentRegistry
    bytes32 constant SALT_ERC20DPL  = bytes32("FLOW-ERC20-DEPLOYER-");   // ERC20 deployer
    bytes32 constant SALT_ERC721DPL = bytes32("FLOW-ERC721-DEPLOYER");   // ERC721 deployer

    function run() external {
        // Inputs from env (optional)
        uint256 pk    = _envUintOr("PK_ACCOUNT", DEFAULT_PK);
        address owner = _envAddrOr("OWNER",       DEFAULT_OWNER);
        // Optional pre-existing factory (must match predicted if set)
        address factoryEnv = _envAddrOr("FACTORY", address(0));

        // If any target is Ownable2Step, accept requires msg.sender == OWNER:
        require(vm.addr(pk) == owner, "PRIVATE_KEY must equal OWNER for acceptOwnership");

        vm.startBroadcast(pk);

        // 0) Ensure helpers exist deterministically (deployed once via EIP-2470 factory 0x4e59…)
        address factoryHelperPred = _computeCreate2(CREATE2_FACTORY, SALT_FACTORY_HELPER, keccak256(type(FactoryC2Deployer).creationCode));
        if (factoryHelperPred.code.length == 0) {
            _deployVia2470(SALT_FACTORY_HELPER, type(FactoryC2Deployer).creationCode);
            _waitForCode(factoryHelperPred);
        }
        FactoryC2Deployer factoryHelper = FactoryC2Deployer(factoryHelperPred);
        console2.log("Helper (FactoryC2Deployer):", factoryHelperPred);

        address ownableHelperPred = _computeCreate2(CREATE2_FACTORY, SALT_OWNABLE_HELPER, keccak256(type(OwnableC2Deployer).creationCode));
        if (ownableHelperPred.code.length == 0) {
            _deployVia2470(SALT_OWNABLE_HELPER, type(OwnableC2Deployer).creationCode);
            _waitForCode(ownableHelperPred);
        }
        OwnableC2Deployer ownableHelper = OwnableC2Deployer(ownableHelperPred);
        console2.log("Helper (OwnableC2Deployer):", ownableHelperPred);

        // 1) Build the deployment table for ALL FOUR contracts (generalized)
        DeploySpec[] memory specs = new DeploySpec[](4);

        // 1. FlowBridgeFactory (use FactoryC2Deployer so owner -> OWNER)
        specs[0] = DeploySpec({
            name: "FlowBridgeFactory",
            creation: type(FlowBridgeFactory).creationCode,
            salt: SALT_FACTORY,
            mode: Mode.FACTORY_HELPER,
            predicted: address(0),
            addr: address(0)
        });

        // 2. FlowBridgeDeploymentRegistry (use OwnableC2Deployer so owner -> OWNER)
        specs[1] = DeploySpec({
            name: "FlowBridgeDeploymentRegistry",
            creation: type(FlowBridgeDeploymentRegistry).creationCode,
            salt: SALT_REGISTRY,
            mode: Mode.OWNABLE_HELPER,
            predicted: address(0),
            addr: address(0)
        });

        // 3. FlowEVMBridgedERC20Deployer (use OwnableC2Deployer so owner -> OWNER)
        specs[2] = DeploySpec({
            name: "FlowEVMBridgedERC20Deployer",
            creation: type(FlowEVMBridgedERC20Deployer).creationCode,
            salt: SALT_ERC20DPL,
            mode: Mode.OWNABLE_HELPER,
            predicted: address(0),
            addr: address(0)
        });

        // 4. FlowEVMBridgedERC721Deployer (use OwnableC2Deployer so owner -> OWNER)
        specs[3] = DeploySpec({
            name: "FlowEVMBridgedERC721Deployer",
            creation: type(FlowEVMBridgedERC721Deployer).creationCode,
            salt: SALT_ERC721DPL,
            mode: Mode.OWNABLE_HELPER,
            predicted: address(0),
            addr: address(0)
        });

        // 2) Predict addresses for all, deploy if missing (generalized)
        for (uint256 i = 0; i < specs.length; i++) {
            if (specs[i].mode == Mode.FACTORY_HELPER) {
                // predict & deploy Factory via FactoryC2Deployer
                address pred = factoryHelper.predictFactory(specs[i].salt);
                specs[i].predicted = pred;

                if (factoryEnv != address(0)) {
                    require(factoryEnv == pred, "FACTORY env != predicted");
                    specs[i].addr = factoryEnv;
                } else {
                    if (pred.code.length == 0) {
                        address actual = factoryHelper.deployFactory(specs[i].salt, owner);
                        require(actual == pred, "factory addr mismatch");
                        _waitForCode(pred);
                    }
                    specs[i].addr = pred;
                }
            } else {
                // predict & deploy Ownable via OwnableC2Deployer (sets owner to OWNER)
                address pred = ownableHelper.predict(specs[i].salt, specs[i].creation);
                specs[i].predicted = pred;

                if (pred.code.length == 0) {
                    ownableHelper.deploy(specs[i].salt, specs[i].creation, owner);
                    _waitForCode(pred);
                }
                specs[i].addr = pred;
            }

            console2.log(
                string.concat("Deployed (or existing) ", specs[i].name, ":"),
                specs[i].addr
            );
        }

        // 3) Finalize ownership if targets are Ownable2Step (acceptOwnership as OWNER)
        address factoryAddr = specs[0].addr;
        address registry    = specs[1].addr;
        address erc20D      = specs[2].addr;
        address erc721D     = specs[3].addr;

        _finalizeOwnershipIfNeeded(factoryAddr, owner);
        _finalizeOwnershipIfNeeded(registry,    owner);
        _finalizeOwnershipIfNeeded(erc20D,      owner);
        _finalizeOwnershipIfNeeded(erc721D,     owner);

        // 4) Post-deploy wiring (mirrors Cadence tests)
        IDeploymentRegistry(registry).setRegistrar(factoryAddr);
        console2.log("registry.setRegistrar(factory)");

        IFlowBridgeFactory(factoryAddr).setDeploymentRegistry(registry);
        console2.log("factory.setDeploymentRegistry(registry)");

        IHasDelegatedDeployer(erc20D).setDelegatedDeployer(factoryAddr);
        IHasDelegatedDeployer(erc721D).setDelegatedDeployer(factoryAddr);
        console2.log("deployers.setDelegatedDeployer(factory)");

        IFlowBridgeFactory(factoryAddr).addDeployer("ERC20",  erc20D);
        IFlowBridgeFactory(factoryAddr).addDeployer("ERC721", erc721D);
        console2.log("factory.addDeployer('ERC20'/'ERC721', ...)");

        vm.stopBroadcast();

        // 5) Summary
        console2.log("============ FINAL ADDRESSES (deterministic) ============");
        for (uint256 i = 0; i < specs.length; i++) {
            console2.log(specs[i].name, specs[i].addr);
        }
        console2.log("Owner   :", owner);
        console2.log("=========================================================");
    }

    // ----------------- helpers -----------------

    function _computeCreate2(address deployer, bytes32 salt, bytes32 codeHash)
        internal pure returns (address)
    {
        return address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff), deployer, salt, codeHash
        )))));
    }

    // Deploy via EIP-2470 factory: calldata = salt (32B) || creationCode
    function _deployVia2470(bytes32 salt, bytes memory creationCode) internal {
        // Script inherits CREATE2_FACTORY from forge-std/Base.sol
        bytes memory callData = abi.encodePacked(salt, creationCode);
        (bool ok, ) = CREATE2_FACTORY.call{value: TX_VALUE_WEI}(callData);
        require(ok, "CREATE2 deploy failed (0x4e59)");
    }

    // Wait for code to appear at addr
    function _waitForCode(address addr) internal {
        for (uint256 i = 0; i < 120; i++) {
            if (addr.code.length > 0) return;
            vm.sleep(1);
        }
        revert("timeout waiting for code");
    }

    // Accept ownership if target is Ownable2Step; assert final owner if available
    function _finalizeOwnershipIfNeeded(address target, address owner) internal {
        // If contract exposes owner(), check it
        try IOwned(target).owner() returns (address current) {
            if (current == owner) return;
        } catch { /* ignore if no view */ }

        // If Ownable2Step, accept as OWNER (must be broadcasting with OWNER's key)
        try IOwnable2Step(target).pendingOwner() returns (address pending) {
            if (pending == owner) {
                IOwnable2Step(target).acceptOwnership();
            }
        } catch { /* ignore if not 2-step */ }

        // Assert if we can read owner()
        try IOwned(target).owner() returns (address afterOwner) {
            require(afterOwner == owner, "ownership not finalized to OWNER");
        } catch { /* ignore if not present */ }
    }

    // Env helpers with defaults (non-reverting)
    function _envUintOr(string memory key, uint256 deflt) internal view returns (uint256 v) {
        (bool ok, bytes memory data) = address(vm).staticcall(abi.encodeWithSignature("envOr(string,uint256)", key, deflt));
        require(ok && data.length == 32, "envOr(uint) failed");
        v = abi.decode(data, (uint256));
    }
    function _envAddrOr(string memory key, address deflt) internal view returns (address a) {
        (bool ok, bytes memory data) = address(vm).staticcall(abi.encodeWithSignature("envOr(string,address)", key, deflt));
        require(ok && data.length == 32, "envOr(addr) failed");
        a = abi.decode(data, (address));
    }
}
