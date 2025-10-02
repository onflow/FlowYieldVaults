EMULATOR_COINBASE=FACF71692421039876a5BB4F10EF7A439D8ef61E
EMULATOR_COA_ADDRESS=e03daebed8ca0615
EMULATOR_COA_KEY=$(cat ./local/evm-gateway.pkey)

cd ./lib/flow-evm-gateway/
rm -rf db/
rm -rf metrics/data/
CGO_ENABLED=1 go run cmd/main.go run \
	--flow-network-id=flow-emulator \
	--coinbase=$EMULATOR_COINBASE \
	--coa-address=$EMULATOR_COA_ADDRESS  \
	--coa-key=$EMULATOR_COA_KEY  \
	--wallet-api-key=2619878f0e2ff438d17835c2a4561cb87b4d24d72d12ec34569acd0dd4af7c21 \
	--gas-price=1 \
	--log-writer=console \
	--tx-state-validation=local-index \
	--profiler-enabled=true \
	--profiler-port=6060 \
	--ws-enabled=true &

# Port to check
PORT=8545

# Wait for port to be available
echo "Waiting for port $PORT to be ready..."
while ! nc -z localhost $PORT; do
  sleep 1
done
