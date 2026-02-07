import "FungibleToken"
import "EVM"
import "FlowYieldVaultsStrategiesV1_1"

/// Admin tx to (re)configure Uniswap paths for the mUSDFStrategy
/// 
/// NOTE:
/// - Must be signed by the account that deployed FlowYieldVaultsStrategies
/// - You can omit some collaterals by passing empty arrays and guarding in prepare{}
transaction(
    // e.g. "A.0x...FlowYieldVaultsStrategiesV1_1.mUSDFStrategy"
    strategyTypeIdentifier: String,

    // collateral vault type (e.g. "A.0x...FlowToken.Vault")
    tokenTypeIdentifier: String,

    // yield token (EVM) address
    yieldTokenEVMAddress: String,

    // collateral path/fees: [YIELD, ..., <COLLATERAL>]
    swapPath: [String],
    fees: [UInt32]
) {

    prepare(acct: auth(Storage, Capabilities, BorrowValue) &Account) {
        let strategyType = CompositeType(strategyTypeIdentifier)
            ?? panic("Invalid strategyTypeIdentifier \(strategyTypeIdentifier)")
        let tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        // This tx must run on the same account that stores the issuer
        // otherwise this borrow will fail.
        let issuer = acct.storage.borrow<
            auth(FlowYieldVaultsStrategiesV1_1.Configure) &FlowYieldVaultsStrategiesV1_1.StrategyComposerIssuer
        >(from: FlowYieldVaultsStrategiesV1_1.IssuerStoragePath)
            ?? panic("Missing StrategyComposerIssuer at IssuerStoragePath")

        let yieldEVM = EVM.addressFromString(yieldTokenEVMAddress)

        // helper to map [String] -> [EVM.EVMAddress]
        fun toEVM(_ hexes: [String]): [EVM.EVMAddress] {
            let out: [EVM.EVMAddress] = []
            for h in hexes {
                out.append(EVM.addressFromString(h))
            }
            return out
        }

        let composerType = Type<@FlowYieldVaultsStrategiesV1_1.mUSDFStrategyComposer>()

        if swapPath.length > 0 {
            issuer.addOrUpdateCollateralConfig(
                composer: composerType,
                strategyType: strategyType,
                collateralVaultType: tokenType,
                yieldTokenEVMAddress: yieldEVM,
                yieldToCollateralAddressPath: toEVM(swapPath),
                yieldToCollateralFeePath: fees 
            )
        }
    }
}
