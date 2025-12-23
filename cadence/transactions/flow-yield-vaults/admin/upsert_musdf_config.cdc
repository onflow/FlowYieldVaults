import "FlowYieldVaultsStrategiesV1_1"
import "EVM"

/// Upserts the config for mUSDFStrategy under mUSDFStrategyComposer.
///
/// Args (in order):
/// 0: collateralVaultTypeIdentifier        (String) - e.g. "A.1654653399040a61.FlowToken.Vault"
/// 1: yieldTokenEVMAddress                 (String) - e.g. "0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c"
/// 2: yieldToCollateralUniV3AddressPath    ([String]) - e.g. ["0xYield...", "0xIntermediate...", "0xCollateral..."]
/// 3: yieldToCollateralUniV3FeePath        ([UInt32]) - e.g. [100, 3000]
///
/// Example:
/// flow transactions send ./cadence/transactions/flow-yield-vaults/admin/upsert_musdf_config.cdc \
///   'A.1654653399040a61.FlowToken.Vault' \
///   "0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c" \
///   '["0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c","0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED","0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"]' \
///   '[100,3000]' \
///   --network mainnet --signer mainnet-admin
///
transaction(
    collateralVaultTypeIdentifier: String,
    yieldTokenEVMAddress: String,
    yieldToCollateralUniV3AddressPath: [String],
    yieldToCollateralUniV3FeePath: [UInt32]
) {

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the StrategyComposerIssuer with Configure entitlement
        let issuerRef = signer.storage.borrow<
            auth(FlowYieldVaultsStrategiesV1_1.Configure) &FlowYieldVaultsStrategiesV1_1.StrategyComposerIssuer
        >(from: FlowYieldVaultsStrategiesV1_1.IssuerStoragePath)
            ?? panic("Could not borrow StrategyComposerIssuer from IssuerStoragePath")

        // Convert collateral type identifier string to Type
        let collateralVaultType: Type = CompositeType(collateralVaultTypeIdentifier)
            ?? panic("Invalid collateral vault type identifier: ".concat(collateralVaultTypeIdentifier))

        // Build the Uniswap V3 address path as [EVM.EVMAddress]
        var addressPath: [EVM.EVMAddress] = []
        for hex in yieldToCollateralUniV3AddressPath {
            addressPath.append(EVM.addressFromString(hex))
        }

        // Call the addOrUpdateCollateralConfig function
        issuerRef.addOrUpdateCollateralConfig(
            composer: Type<@FlowYieldVaultsStrategiesV1_1.mUSDFStrategyComposer>(),
            strategyType: Type<@FlowYieldVaultsStrategiesV1_1.mUSDFStrategy>(),
            collateralVaultType: collateralVaultType,
            yieldTokenEVMAddress: EVM.addressFromString(yieldTokenEVMAddress),
            yieldToCollateralAddressPath: addressPath,
            yieldToCollateralFeePath: yieldToCollateralUniV3FeePath
        )
    }

    execute {
        log("Updated mUSDFStrategy config for collateral type: ".concat(collateralVaultTypeIdentifier))
    }
}
