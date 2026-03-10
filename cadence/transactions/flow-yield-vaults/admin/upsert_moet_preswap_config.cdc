import "FlowYieldVaultsStrategiesV2"
import "FlowYieldVaults"
import "EVM"

/// Configures a stablecoin collateral type to use MOET pre-swap for a given StrategyComposer.
/// Required for stablecoins (e.g. PYUSD0) that FlowALP does not support as direct collateral.
///
/// Parameters:
///   composerTypeIdentifier:       e.g. "A.xxx.FlowYieldVaultsStrategiesV2.MorphoERC4626StrategyComposer"
///   collateralVaultTypeIdentifier: e.g. "A.yyy.EVMVMBridgedToken_99af....Vault"
///   collateralToMoetAddressPath:  array of EVM address hex strings, collateral→MOET path
///                                  e.g. ["0x99af...", "0x02d3..."] (1-hop) or 3+ for multi-hop
///   collateralToMoetFeePath:      array of UInt32 fee tiers, one per hop
///                                  e.g. [100] for 0.01%, [3000] for 0.3%
transaction(
    composerTypeIdentifier: String,
    collateralVaultTypeIdentifier: String,
    collateralToMoetAddressPath: [String],
    collateralToMoetFeePath: [UInt32]
) {
    let issuer: auth(FlowYieldVaultsStrategiesV2.Configure) &FlowYieldVaultsStrategiesV2.StrategyComposerIssuer

    prepare(admin: auth(Storage) &Account) {
        self.issuer = admin.storage.borrow<auth(FlowYieldVaultsStrategiesV2.Configure) &FlowYieldVaultsStrategiesV2.StrategyComposerIssuer>(
            from: FlowYieldVaultsStrategiesV2.IssuerStoragePath
        ) ?? panic("Could not borrow StrategyComposerIssuer from \(FlowYieldVaultsStrategiesV2.IssuerStoragePath)")
    }

    execute {
        let composerType = CompositeType(composerTypeIdentifier)
            ?? panic("Invalid composer type identifier: \(composerTypeIdentifier)")
        let collateralVaultType = CompositeType(collateralVaultTypeIdentifier)
            ?? panic("Invalid collateral vault type identifier: \(collateralVaultTypeIdentifier)")

        var evmPath: [EVM.EVMAddress] = []
        for addr in collateralToMoetAddressPath {
            evmPath.append(EVM.addressFromString(addr))
        }

        self.issuer.upsertMoetPreswapConfig(
            composer: composerType,
            collateralVaultType: collateralVaultType,
            collateralToMoetAddressPath: evmPath,
            collateralToMoetFeePath: collateralToMoetFeePath
        )

        log("Configured MOET pre-swap for composer \(composerTypeIdentifier) collateral \(collateralVaultTypeIdentifier)")
    }
}
