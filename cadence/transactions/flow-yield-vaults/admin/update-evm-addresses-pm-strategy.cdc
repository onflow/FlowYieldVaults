import "PMStrategies"

transaction(factory: String, router: String, quoter: String, yieldToken: String) {

    prepare(signer: auth(BorrowValue) &Account) {
        let issuer = signer.storage.borrow<
            auth(PMStrategies.Configure) &PMStrategies.StrategyComposerIssuer
        >(from: PMStrategies.IssuerStoragePath)
            ?? panic("Missing StrategyComposerIssuer at IssuerStoragePath")

        issuer.updateEVMAddresses(
            factory: factory,
            router: router,
            quoter: quoter,
            yieldToken: yieldToken
        )
    }
}
