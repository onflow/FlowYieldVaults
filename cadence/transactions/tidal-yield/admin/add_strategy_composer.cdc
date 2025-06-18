import "Tidal"
import "StrategyComposer"

/// Adds the provided Strategy type to the Tidal contract
///
/// @param strategyIdentifier: The Type identifier of the Strategy to add to Tidal contract
/// @param enable: Whether the Strategy type should be immediately enabled or not
///
transaction(strategyIdentifier: String, enable: Bool) {

    /// The Strategy Type to add
    let strategyType: Type
    /// Authorized reference to the Admin through which the Strategy Type will be added to the Tidal contract
    let admin: auth(Tidal.Add) &Tidal.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        // construct the types
        self.strategyType = CompositeType(strategyIdentifier) ?? panic("Invalid Strategy type \(strategyIdentifier)")

        // assign Admin
        self.admin = signer.storage.borrow<auth(Tidal.Add) &Tidal.Admin>(from: Tidal.AdminStoragePath)
            ?? panic("Could not borrow reference to StrategyFactory from \(Tidal.AdminStoragePath)")
    }

    execute {
        // add the Strategy Type as supported
        self.admin.addStrategy(self.strategyType, enable: enable)
    }

    post {
        Tidal.getSupportedStrategies()[self.strategyType] == enable:
        "Strategy \(strategyIdentifier) was not correctly added to Tidal"
    }
}
