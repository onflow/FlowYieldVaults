#!/bin/bash

cp ./local/contracts_local.sh ./solidity/lib/punch-swap-v3-contracts/
cp ./local/flow-emulator.json ./solidity/lib/punch-swap-v3-contracts/script/deployParameters/

cp .env ./solidity/lib/punch-swap-v3-contracts/
cp .env ./solidity/lib/punch-swap-core-contracts/

# deployer
flow transactions send ./cadence/transactions/mocks/amm/transfer_to_evm.cdc 0xC31A5268a1d311d992D637E8cE925bfdcCEB4310 1000.0

# 
#flow transactions send ./cadence/transactions/mocks/amm/transfer_to_evm.cdc 0x4e59b44847b379578588920cA78FbF26c0B4956C 1000.0
# CREATE2
flow transactions send ./cadence/transactions/mocks/amm/transfer_to_evm.cdc 0x3fab184622dc19b6109349b94811493bf2a45362 1000.0

cast rpc eth_sendRawTransaction 0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222 --rpc-url http://localhost:8545

cd ./solidity/lib/punch-swap-core-contracts

forge script ./script/WrappedFlowDeploy.s.sol --broadcast --rpc-url emulator
forge script ./script/Multicall3Deploy.s.sol --broadcast --rpc-url emulator
forge script ./script/PunchSwapV2FactoryDeploy.s.sol --broadcast --rpc-url emulator

cd ../punch-swap-v3-contracts/

./contracts_local.sh

