set -euo pipefail

cp ./local/punchswap/contracts_local.sh ./solidity/lib/punch-swap-v3-contracts/
cp ./local/punchswap/flow-emulator.json ./solidity/lib/punch-swap-v3-contracts/script/deployParameters/

cp ./local/punchswap/punchswap.env ./solidity/lib/punch-swap-v3-contracts/.env

echo "fund PunchSwap deployer"
flow transactions send ./cadence/transactions/mocks/transfer_to_evm.cdc 0xC31A5268a1d311d992D637E8cE925bfdcCEB4310 1000.0

echo "fund CREATE2 deployer"
flow transactions send ./cadence/transactions/mocks/transfer_to_evm.cdc 0x3fab184622dc19b6109349b94811493bf2a45362 1000.0

echo "Deploy CREATE2"
cast rpc eth_sendRawTransaction 0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222 --rpc-url http://localhost:8545

cd ./solidity/lib/punch-swap-v3-contracts/

./contracts_local.sh

