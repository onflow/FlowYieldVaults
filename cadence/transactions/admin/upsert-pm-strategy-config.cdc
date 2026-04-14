import "PMStrategiesV1"
import "EVM"

/// Upserts configuration for the ERC4626VaultStrategyComposer.
/// This transaction is used to add or update strategy configurations.
///
/// Example usage for syWFLOWvStrategy:
/// - strategyTypeIdentifier: "A.<address>.PMStrategiesV1.syWFLOWvStrategy"
/// - collateralTypeIdentifier: "A.1654653399040a61.FlowToken.Vault"
/// - yieldTokenEVMAddress: "0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597"
/// - swapFeeTier: 100
///
/// Example usage for tauUSDFvStrategy:
/// - strategyTypeIdentifier: "A.<address>.PMStrategiesV1.tauUSDFvStrategy"
/// - collateralTypeIdentifier: "A.1e4aa0b87d10b141.EVMVMBridgedToken_2aabea2058b5ac2d339b163c6ab6f2b6d53aabed.Vault" (USDF)
/// - yieldTokenEVMAddress: "0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c"
/// - swapFeeTier: 100

transaction(
    strategyTypeIdentifier: String,
    collateralTypeIdentifier: String,
    yieldTokenEVMAddress: String,
    swapFeeTier: UInt32
) {
    prepare(signer: auth(BorrowValue) &Account) {
        let issuer = signer.storage.borrow<
            auth(PMStrategiesV1.Configure) &PMStrategiesV1.StrategyComposerIssuer
        >(from: PMStrategiesV1.IssuerStoragePath)
            ?? panic("Missing StrategyComposerIssuer at IssuerStoragePath")

        let composerType = Type<@PMStrategiesV1.ERC4626VaultStrategyComposer>()
        let strategyType = CompositeType(strategyTypeIdentifier)
            ?? panic("Invalid strategy type identifier: \(strategyTypeIdentifier)")
        let collateralType = CompositeType(collateralTypeIdentifier)
            ?? panic("Invalid collateral type identifier: \(collateralTypeIdentifier)")

        let collateralConfig: {String: AnyStruct} = {
            "yieldTokenEVMAddress": EVM.addressFromString(yieldTokenEVMAddress),
            "swapFeeTier": swapFeeTier
        }

        let config: {Type: {Type: {String: AnyStruct}}} = {
            strategyType: {
                collateralType: collateralConfig
            }
        }

        issuer.upsertConfigFor(composer: composerType, config: config)
    }
}

