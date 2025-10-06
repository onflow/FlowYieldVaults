import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "DeFiActions"

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
        /// The COA capability to use for the ERC4626 vault
        access(self) let coa: Capability<&EVM.CadenceOwnedAccount>
        /// The UniqueIdentifier of this component
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(asset: Type, vault: EVM.EVMAddress, coa: Capability<&EVM.CadenceOwnedAccount>, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                asset.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Provided asset \(asset.identifier) is not a Vault type"
                FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset) != nil:
                "Provided asset \(asset.identifier) is not associated with ERC20 - ensure the type & ERC20 contracts are associated via the VM bridge"
                coa.check():
                "Provided COA Capability is invalid - need Capability<&EVM.CadenceOwnedAccount>"
            }
            self.asset = asset
            self.vault = vault
            self.coa = coa
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
            let totalAssets = self.totalAssets()
            let totalShares = self.totalShares()
            if totalAssets == nil || totalShares == nil {
                return nil
            }
            var price = totalAssets! / totalShares!

            price = ERC4626PriceOracles.normalizeDecimals(amount: price, originalDecimals: 0, targetDecimals: 24)
            return FlowEVMBridgeUtils.uint256ToUFix64(value: price, decimals: 24)
        }
        /// Returns the total shares issued by the ERC4626 vault
        ///
        /// @return The total shares issued by the ERC4626 vault
        access(all) fun totalShares(): UInt256? {
            let callRes = self._dryCall(to: self.vault, signature: "totalSupply()", args: [], gasLimit: 1000000)
            if callRes?.status != EVM.Status.successful {
                return nil
            }
            let totalShares = EVM.decodeABI(types: [Type<UInt256>()], data: callRes!.data) as! [AnyStruct]
            if totalShares.length != 1 {
                return nil
            }
            return totalShares[0] as! UInt256
        }
        /// Returns the total assets managed by the ERC4626 vault
        ///
        /// @return The total assets managed by the ERC4626 vault
        access(all) fun totalAssets(): UInt256? {
            let callRes = self._dryCall(to: self.vault, signature: "totalAssets()", args: [], gasLimit: 1000000)
            if callRes?.status != EVM.Status.successful {
                return nil
            }
            let totalAssets = EVM.decodeABI(types: [Type<UInt256>()], data: callRes!.data) as! [AnyStruct]
            if totalAssets.length != 1 {
                return nil
            }
            return totalAssets[0] as! UInt256
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
            return nil
        }
        /// Sets the UniqueIdentifier of this component to the provided UniqueIdentifier, used in extending a stack to
        /// identify another connector in a DeFiActions stack. See DeFiActions.align() for more information.
        ///
        /// @param id: the UniqueIdentifier to set for this component
        ///
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            // do nothing
        }
        /// Performs a dry call to the ERC4626 vault
        ///
        /// @param to The address of the ERC4626 vault
        /// @param signature The signature of the function to call
        /// @param args The arguments to pass to the function
        /// @param gasLimit The gas limit to use for the call
        ///
        /// @return The result of the dry call or `nil` if the COA capability is invalid
        access(self)
        fun _dryCall(to: EVM.EVMAddress, signature: String, args: [AnyStruct], gasLimit: UInt64): EVM.Result? {
            let calldata = EVM.encodeABIWithSignature(signature, args)
            let valueBalance = EVM.Balance(attoflow: 0)
            if let coa = self.coa.borrow() {
                return coa.dryCall(to: to, data: calldata, gasLimit: gasLimit, value: valueBalance)
            }
            return nil
        }
    }

    /// Normalizes decimals of the given amount to the target decimals
    ///
    /// @param amount The amount to normalize
    /// @param originalDecimals The original decimals of the amount
    /// @param targetDecimals The target decimals to normalize to
    ///
    /// @return The normalized amount
    access(all) fun normalizeDecimals(amount: UInt256, originalDecimals: UInt8, targetDecimals: UInt8): UInt256 {
        var res = amount
        if originalDecimals > targetDecimals {
            // decimals is greater than targetDecimals - truncate the fractional part
            res = amount / FlowEVMBridgeUtils.pow(base: 10, exponent: originalDecimals - targetDecimals)
        } else if originalDecimals < targetDecimals {
            // decimals is less than targetDecimals - scale the amount up to targetDecimals
            res = amount * FlowEVMBridgeUtils.pow(base: 10, exponent: targetDecimals - originalDecimals)
        }
        return res
    }
}
