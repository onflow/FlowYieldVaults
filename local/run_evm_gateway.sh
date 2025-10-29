EMULATOR_COINBASE=0xFACF71692421039876a5BB4F10EF7A439D8ef61E
EMULATOR_COA_ADDRESS=e03daebed8ca0615
EMULATOR_COA_KEY=$(cat ./local/evm-gateway.pkey)
PORT=8545

rm -rf db/

flow evm gateway \
	--flow-network-id=emulator \
	--evm-network-id=preview \
	--coinbase=$EMULATOR_COINBASE \
	--coa-address=$EMULATOR_COA_ADDRESS  \
	--coa-key=$EMULATOR_COA_KEY  \
	--gas-price=0 \
	--rpc-port $PORT & 
#
# Wait for port to be available
echo "Waiting for port $PORT to be ready..."
while ! nc -z localhost $PORT; do
  sleep 1
done
