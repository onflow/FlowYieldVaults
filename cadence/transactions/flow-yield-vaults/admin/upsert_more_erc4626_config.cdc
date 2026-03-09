import "FungibleToken"
import "EVM"
import "FlowYieldVaultsStrategiesV2"

/// Admin tx to configure a MoreERC4626CollateralConfig entry for a strategy in FlowYieldVaultsStrategiesV2.
///
/// Used for strategies that borrow the ERC4626 vault's own underlying asset directly
/// (e.g. syWFLOWvStrategy: collateral → borrow FLOW → deposit into More ERC4626 vault).
///
/// Must be signed by the account that deployed FlowYieldVaultsStrategiesV2.
transaction(
    /// e.g. "A.0x...FlowYieldVaultsStrategiesV2.syWFLOWvStrategy"
    strategyTypeIdentifier: String,

    /// collateral vault type (e.g. "A.0x...SomeToken.Vault")
    tokenTypeIdentifier: String,

    /// yield token EVM address (the More ERC4626 vault, e.g. syWFLOWv)
    yieldTokenEVMAddress: String,

    /// UniV3 path for yield token → underlying (e.g. [syWFLOWv, WFLOW])
    yieldToUnderlyingPath: [String],
    yieldToUnderlyingFees: [UInt32],

    /// UniV3 path for debt token → collateral (used for dust conversion on close)
    debtToCollateralPath: [String],
    debtToCollateralFees: [UInt32]
) {
    prepare(acct: auth(Storage) &Account) {
        let strategyType = CompositeType(strategyTypeIdentifier)
            ?? panic("Invalid strategyTypeIdentifier \(strategyTypeIdentifier)")
        let tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

        let issuer = acct.storage.borrow<
            auth(FlowYieldVaultsStrategiesV2.Configure) &FlowYieldVaultsStrategiesV2.StrategyComposerIssuer
        >(from: FlowYieldVaultsStrategiesV2.IssuerStoragePath)
            ?? panic("Missing StrategyComposerIssuer at IssuerStoragePath")

        fun toEVM(_ hexes: [String]): [EVM.EVMAddress] {
            let out: [EVM.EVMAddress] = []
            for h in hexes { out.append(EVM.addressFromString(h)) }
            return out
        }

        issuer.addOrUpdateMoreERC4626CollateralConfig(
            strategyType: strategyType,
            collateralVaultType: tokenType,
            yieldTokenEVMAddress: EVM.addressFromString(yieldTokenEVMAddress),
            yieldToUnderlyingAddressPath: toEVM(yieldToUnderlyingPath),
            yieldToUnderlyingFeePath: yieldToUnderlyingFees,
            debtToCollateralAddressPath: toEVM(debtToCollateralPath),
            debtToCollateralFeePath: debtToCollateralFees
        )
    }
}
