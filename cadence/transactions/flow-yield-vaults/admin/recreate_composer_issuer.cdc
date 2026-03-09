import "FlowYieldVaultsStrategiesV2"

/// Admin transaction to recreate the StrategyComposerIssuer resource at IssuerStoragePath.
///
/// Use this if the issuer was accidentally destroyed or is missing from storage.
/// Initialises with the default config (MorphoERC4626StrategyComposer / FUSDEVStrategy skeleton)
/// — run upsert_strategy_config / upsert_more_erc4626_config afterwards to repopulate configs.
///
/// Must be signed by the account that deployed FlowYieldVaultsStrategiesV2.
transaction {
    prepare(acct: auth(Storage) &Account) {
        // Destroy any existing issuer so we can replace it cleanly
        if acct.storage.type(at: FlowYieldVaultsStrategiesV2.IssuerStoragePath) != nil {
            let old <- acct.storage.load<@FlowYieldVaultsStrategiesV2.StrategyComposerIssuer>(
                from: FlowYieldVaultsStrategiesV2.IssuerStoragePath
            )
            destroy old
        }

        let issuer <- FlowYieldVaultsStrategiesV2.createIssuer()
        acct.storage.save(<-issuer, to: FlowYieldVaultsStrategiesV2.IssuerStoragePath)
    }
}
