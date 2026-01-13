import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "DeFiActions"
import "ERC4626Utils"

/// ERC4626PriceOracles (Mock Version)
///
/// A mock version of ERC4626PriceOracles that allows manual control of totalAssets and totalShares
/// for testing purposes. This enables testing of rebalancing logic without relying on real EVM state.
///
access(all) contract ERC4626PriceOracles {

    /// Controller resource that allows setting mock vault prices
    /// Only holders of this resource can mutate mock data
    /// Stored at: /storage/MockERC4626PriceOraclesController
    access(all) resource Controller {
        /// Stores mock prices for each vault (keyed by vault address string)
        /// Price is in UFix64, normalized to 18 decimals
        access(self) var prices: {String: UFix64}

        init() {
            self.prices = {}
        }

        access(all) fun setMockPrice(vault: EVM.EVMAddress, price: UFix64?) {
            let vaultKey = vault.toString()
            if price == nil {
                self.prices.remove(key: vaultKey)
            } else {
                self.prices[vaultKey] = price!
            }
        }

        access(all) fun clearMockData() {
            self.prices = {}
        }

        access(all) fun getMockPrice(vault: EVM.EVMAddress): UFix64? {
            return self.prices[vault.toString()]
        }
    }

    /// PriceOracle
    ///
    /// A mock implementation of the DeFiActions.PriceOracle interface that allows manual control
    /// of totalAssets and totalShares values for testing.
    ///
    access(all) struct PriceOracle : DeFiActions.PriceOracle {
        /// The address of the ERC4626 vault
        access(all) let vault: EVM.EVMAddress
        /// The asset type serving as the price basis in the ERC4626 vault
        access(self) let asset: Type
        /// The EVM address of the asset ERC20 asset underlying the ERC4626 vault
        access(self) let assetEVMAddress: EVM.EVMAddress
        /// The UniqueIdentifier of this component
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(vault: EVM.EVMAddress, asset: Type, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                asset.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Provided asset \(asset.identifier) is not a Vault type"
            }
            // Skip validation in mock version to allow testing without real EVM state
            self.asset = asset
            self.assetEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset)
                ?? panic("Provided asset \(asset.identifier) is not associated with ERC20 - ensure the type & ERC20 contracts are associated via the VM bridge")
            self.vault = vault
            self.uniqueID = uniqueID
        }

        /// Returns the asset type serving as the price basis in the ERC4626 vault
        ///
        /// @return The asset type serving as the price basis in the ERC4626 vault
        ///
        access(all) view fun unitOfAccount(): Type {
            return self.asset
        }

        /// Returns the current price of the ERC4626 vault denominated in the underlying asset type
        /// This mock version returns the price set in the Controller
        ///
        /// @param ofToken The token type to get the price of
        ///
        /// @return The mock price if set, nil otherwise
        access(all) fun price(ofToken: Type): UFix64? {
            if let controller = ERC4626PriceOracles.account.storage.borrow<&Controller>(from: /storage/MockERC4626PriceOraclesController) {
                return controller.getMockPrice(vault: self.vault)
            }
            return nil
        }

        /// Returns a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        /// each inner component in the stack.
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        /// Returns a copy of the struct's UniqueIdentifier, used in extending a stack to identify another connector in
        /// a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @return a copy of the struct's UniqueIdentifier
        ///
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @param id: the UniqueIdentifier to set for this component
        ///
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// Creates a new Controller resource
    access(all) fun createController(): @Controller {
        return <-create Controller()
    }

    init() {
        self.account.storage.save(<-create Controller(), to: /storage/MockERC4626PriceOraclesController)
    }
}

