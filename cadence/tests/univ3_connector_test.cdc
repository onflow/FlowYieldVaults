import Test
import BlockchainHelpers
import "EVM"

import "test_helpers.cdc"


access(all) fun setup() {
    deployContracts()
}

access(self)
fun mint(_ target: String, _ recepient: String, _ amount: UInt256) {
    evmCall(
        serviceAccount,
        target,
        String.encodeHex(EVM.encodeABIWithSignature("mint(address,uint256)", [recepient, amount])),
    )
}

access(self)
fun approve(_ target: EVM.EVMAddress, _ approvee: EVM.EVMAddress, _ amount: UInt256) {
    evmCall(
        serviceAccount,
        target.toString(),
        String.encodeHex(EVM.encodeABIWithSignature("approve(address,uint256)", [approvee.toString(), amount])),
    )
}

access(all)
fun test_Univ3Connector() {
    log("deploy USDC6")
    let bridgeCOA = getCOA(serviceAccount.address)!
    let usdc6Address = evmDeploy(
		serviceAccount,
        usdc6Bytecode,
        [bridgeCOA]
    )
    log("USDC6 address \(usdc6Address)")

    let args = String.encodeHex(EVM.encodeABIWithSignature("owner()(address)",[]))
    let checkOwner = evmScriptCall(
        EVM.addressFromString(usdc6Address),
        args,
        [Type<EVM.EVMAddress>().identifier]
    )
    log("checkOwner")
    log(checkOwner)

    log("checkCode")
    let checkCode = _executeScript(
        "./scripts/get_evm_code.cdc",
        [usdc6Address]
    )
    log(checkCode)

    let onboardUSDC6 = _executeTransaction(
        "../../lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_evm_address.cdc",
        [usdc6Address],
        serviceAccount
    )
    Test.expect(onboardUSDC6, Test.beSucceeded())
    log("USDC6 onboarded")
    
    let usdc6Type = _executeScript(
        "../../lib/flow-evm-bridge/cadence/scripts/bridge/get_associated_type.cdc",
        [usdc6Address]
    )
    log(usdc6Type)

    mint(usdc6Address, "0x".concat(bridgeCOA), 1_000_000_000_000) 

}
