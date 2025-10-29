import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "DeFiActions"
import "ERC4626Utils"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// ERC4626PriceOracles
///
/// Implements the DeFiActions.PriceOracle interface to get share prices of ERC4626 vaults denominated in the underlying
/// asset type.
///
access(all) contract ERC4626PriceOracles {

    /// PriceOracle
    ///
    /// An implementation of the DeFiActions.PriceOracle interface to get share prices of ERC4626 vaults denominated in
    /// the underlying asset type. The calculated price is normalized to 24 decimals and represents the current net 
    /// asset value (NAV) per share.
    ///
    access(all) struct PriceOracle : DeFiActions.PriceOracle {
        /// The address of the ERC4626 vault
        access(all) let vault: EVM.EVMAddress
        /// The asset type serving as the price basis in the ERC4626 vault
        access(self) let asset: Type
        /// The UniqueIdentifier of this component
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(asset: Type, vault: EVM.EVMAddress, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                asset.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Provided asset \(asset.identifier) is not a Vault type"
                FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset) != nil:
                "Provided asset \(asset.identifier) is not associated with ERC20 - ensure the type & ERC20 contracts are associated via the VM bridge"
            }
            assert(
                ERC4626Utils.underlyingAssetEVMAddress(vault: vault)
                    ?.equals(FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset)!)
                    ?? false,
                message: "Provided asset \(asset.identifier) does not underly vault \(vault.toString())"
            )

            self.asset = asset
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
        ///
        /// @param ofToken The token type to get the price of
        ///
        /// @return The current price of the ERC4626 vault denominated in the underlying asset type
        access(all) fun price(ofToken: Type): UFix64? {
            let totalAssets = ERC4626Utils.totalAssets(vault: self.vault)
            let totalShares = ERC4626Utils.totalShares(vault: self.vault)
            if totalAssets == nil || totalShares == nil || totalShares == UInt256(0) {
                return nil
            }
            var price = totalAssets! / totalShares!

            price = ERC4626Utils.normalizeDecimals(amount: price, originalDecimals: 0, targetDecimals: 24)
            return FlowEVMBridgeUtils.uint256ToUFix64(value: price, decimals: 24)
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
}
