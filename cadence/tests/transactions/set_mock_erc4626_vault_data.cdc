import "ERC4626PriceOracles"
import "EVM"

transaction(vaultAddress: String, price: UFix64?) {
    prepare(acct: auth(Storage, SaveValue) &Account) {
        // Create Controller if it doesn't exist
        if acct.storage.borrow<&ERC4626PriceOracles.Controller>(from: /storage/MockERC4626PriceOraclesController) == nil {
            acct.storage.save(<-ERC4626PriceOracles.createController(), to: /storage/MockERC4626PriceOraclesController)
        }
        let vault = EVM.addressFromString(vaultAddress)
        let controller = acct.storage.borrow<&ERC4626PriceOracles.Controller>(from: /storage/MockERC4626PriceOraclesController)!
        controller.setMockPrice(vault: vault, price: price)
    }
}

