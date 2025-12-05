set -euo pipefail

echo $(date) > local_deploy.txt
source .env

NETWORK=emulator
CHECK_UNISWAP_V3_POOL_INIT_CODE_HASH=true
DEPLOY_CORE=true
DEPLOY_PERIPHERY_1=true
DEPLOY_PERIPHERY_2=true
DEPLOY_PERIPHERY_3=true
DEPLOY_SWAP_ROUTER=true
DEPLOY_UNIVERSAL_ROUTER=true
DEPLOY_STAKER=true
DEPLOY_FEE_COLLECTOR=true
UNIVERSAL_ROUTER_JSON_FILE=flow-$NETWORK.json

DO_BROADCAST=true
BROADCAST_FLAG=""

if [ "$DO_BROADCAST" = true ]; then
    BROADCAST_FLAG="--broadcast"
fi

echo 'NETWORK: '$NETWORK
echo 'RPC_URL: '$RPC_URL
echo 'OWNER: '$OWNER
echo 'SALT: '$SALT
echo 'WETH9: '$WETH9
echo 'V2_FACTORY: '$V2_FACTORY
echo 'ETH_NATIVE_CURRENCY_LABEL_BYTES: '$ETH_NATIVE_CURRENCY_LABEL_BYTES
echo 'DO_BROADCAST: '$DO_BROADCAST
echo 'BROADCAST_FLAG: '$BROADCAST_FLAG
echo 'V3_POOL_DEPLOYER: '${V3_POOL_DEPLOYER:-}
echo 'TOKEN_DESCRIPTOR: '$TOKEN_DESCRIPTOR
echo 'POSITION_MANAGER: '$POSITION_MANAGER
echo 'V3_FACTORY: '$V3_FACTORY
echo 'MAX_INCENTIVE_START_LEAD_TIME: '$MAX_INCENTIVE_START_LEAD_TIME
echo 'MAX_INCENTIVE_DURATION: '$MAX_INCENTIVE_DURATION
echo 'FEE_OWNER: '$FEE_OWNER
echo 'UNIVERSAL_ROUTER: '$UNIVERSAL_ROUTER
echo 'PERMIT2: '$PERMIT2
echo 'FEE_TOKEN: '$FEE_TOKEN
echo 'UNIVERSAL_ROUTER_JSON_FILE: '$UNIVERSAL_ROUTER_JSON_FILE

export PK_ACCOUNT=$PK_ACCOUNT
export RPC_URL=$RPC_URL
export OWNER=$OWNER
export SALT=$SALT
export WETH9=$WETH9
export V2_FACTORY=$V2_FACTORY
export ETH_NATIVE_CURRENCY_LABEL_BYTES=$ETH_NATIVE_CURRENCY_LABEL_BYTES
export V3_FACTORY=$V3_FACTORY
export V3_POOL_DEPLOYER=${V3_POOL_DEPLOYER:-}
export TOKEN_DESCRIPTOR=$TOKEN_DESCRIPTOR
export POSITION_MANAGER=$POSITION_MANAGER
export V3_FACTORY=$V3_FACTORY
export MAX_INCENTIVE_START_LEAD_TIME=$MAX_INCENTIVE_START_LEAD_TIME
export MAX_INCENTIVE_DURATION=$MAX_INCENTIVE_DURATION
export FEE_OWNER=$FEE_OWNER
export UNIVERSAL_ROUTER=$UNIVERSAL_ROUTER
export PERMIT2=$PERMIT2
export FEE_TOKEN=$FEE_TOKEN
export UNIVERSAL_ROUTER_JSON_FILE=$UNIVERSAL_ROUTER_JSON_FILE

echo '**************************'
echo '* DEPLOYER ETHER BALANCE *'
echo '**************************'
echo 'Balance (eth) ['$OWNER']: '$(cast balance $OWNER -e --rpc-url $RPC_URL)

echo '**********************'
echo '* BUILDING CONTRACTS *'
echo '**********************'
if [ "${1:-}" = "clean" ]; then
    forge clean && forge cache clean all && forge build --force
else
    forge build
fi

if [ "$CHECK_UNISWAP_V3_POOL_INIT_CODE_HASH" = true ]; then
    forge script script/00_PunchSwapV3PoolInitBytecodeHash.s.sol --rpc-url $RPC_URL --slow --legacy | tee -a ../local_deploy.txt
fi

echo '***************'
echo '* CORE Module *'
echo '***************'

if [ "$DEPLOY_CORE" = true ]; then
    forge script script/01_PunchSwapV3Factory.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
    # forge script script/02_PunchSwapV3PoolDeployer.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
else
    echo 'SKIPPING CORE MODULE DEPLOYMENT'
fi

echo '********************'
echo '* PERIPHERY Module *'
echo '********************'

if [ "$DEPLOY_PERIPHERY_1" = true ]; then
    forge script script/03_PunchSwapInterfaceMulticall.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
    forge script script/04_TickLens.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
    forge script script/05_Quoter.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # V3 Factory
        # WETH9
    forge script script/05a_PunchSwapV3StaticQuoter.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # V3 Factory
    forge script script/06_SwapRouter.s.sol  --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # V3 Factory
        # WETH9
    forge script script/07_QuoterV2.s.sol  --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # V3 Factory
        # WETH9
    if [ "$NETWORK" = "mainnet" ]; then
        forge script script/08_NonfungibleTokenPositionDescriptor.s.sol  --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
            # ETH_NATIVE_CURRENCY_LABEL_BYTES
    else
        forge script script/08a_TestnetNonfungibleTokenPositionDescriptor.s.sol  --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG --sender $OWNER | tee -a ../local_deploy.txt
            # ETH_NATIVE_CURRENCY_LABEL_BYTES  
    fi
else
    echo 'SKIPPING PERIPHERY 1 MODULE DEPLOYMENT'
fi

if [ "$DEPLOY_PERIPHERY_2" = true ]; then
    forge script script/09_NonfungiblePositionManager.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # WETH9
        # V3FACTORY
        # TOKEN_DESCRIPTOR
else
    echo 'SKIPPING PERIPHERY 2 MODULE DEPLOYMENT'
fi

if [ "$DEPLOY_PERIPHERY_3" = true ]; then
    forge script script/10_V3Migrator.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
        # WETH9
        # V3FACTORY
        # POSITION_MANAGER
else
    echo 'SKIPPING PERIPHERY 3 MODULE DEPLOYMENT'
fi

echo '**********************'
echo '* SWAP ROUTER Module *'
echo '**********************'

if [ "$DEPLOY_SWAP_ROUTER" = true ]; then
    forge script script/11_SwapRouter02.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
else
    echo 'SKIPPING SWAP ROUTER MODULE DEPLOYMENT'
fi

echo '***************************'
echo '* UNIVERSAL ROUTER Module *'
echo '***************************'

if [ "$DEPLOY_UNIVERSAL_ROUTER" = true ]; then
    forge script script/12_UniversalRouter.s.sol --sig "runAndDeployPermit2(string)" script/deployParameters/$UNIVERSAL_ROUTER_JSON_FILE --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
else
    echo 'SKIPPING UNIVERSAL ROUTER MODULE DEPLOYMENT'
fi

echo '********************'
echo '* V3 STAKER Module *'
echo '********************'

if [ "$DEPLOY_STAKER" = true ]; then
    forge script script/13_PunchSwapV3Staker.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
else
    echo 'SKIPPING V3 STAKER MODULE DEPLOYMENT'
fi

echo '************************'
echo '* FEE COLLECTOR Module *'
echo '************************'

if [ "$DEPLOY_FEE_COLLECTOR" = true ]; then
    forge script script/14_FeeCollector.s.sol --rpc-url $RPC_URL --slow --legacy $BROADCAST_FLAG | tee -a ../local_deploy.txt
else
    echo 'SKIPPING FEE COLLECTOR MODULE DEPLOYMENT'
fi

echo 'FINISHED!'


: << 'END'
echo '*************'
echo '* STABLECOINS *'
echo '*************'
echo cd stablecoins
cd stablecoins
if test "clean" = "$1"; then
    forge clean && forge cache clean all && forge build --force
else
    forge build
fi

# DAI
forge script script/DAI.s.sol --fork-url http://localhost:8545 --sender $OWNER --broadcast | tee -a ../local_deploy.txt
cast send --from $OWNER --private-key $PK_ACCOUNT $DAI "mint(address,uint)" $OWNER 1234567890
cast send --from $OWNER --private-key $PK_ACCOUNT $DAI "mint(address,uint)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 1234567890

# WETH
forge script script/WETH.s.sol --fork-url http://localhost:8545 --sender $OWNER --broadcast | tee -a ../local_deploy.txt
cast send --from $OWNER --private-key $PK_ACCOUNT $WETH "deposit()" --value 5000ether

# USDC
forge script script/USDC.s.sol --fork-url http://localhost:8545 --sender $OWNER --broadcast  | tee -a ../local_deploy.txt
# cast send --from $OWNER --private-key $PK_ACCOUNT $WETH "deposit()" --value 5ether

echo '*************'
echo 'CREATE2 deployer: 0x4e59b44847b379578588920ca78fbf26c0b4956c'
echo 'Sender used:' $OWNER '(0xA9564D0B121D01c9F5e2b981A60e698c3434CcB8)'
echo 'Sender default: 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38'
echo '*************'
cd ..
echo 'CHECKING ADDRESSES...'
./check.sh local_addresses.json local_deploy.txt
echo FINISHED!

END
