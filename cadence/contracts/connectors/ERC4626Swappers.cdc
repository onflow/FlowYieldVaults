import "Burner"
import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "DeFiActions"
import "DeFiActionsUtils"
import "ERC4626SinkConnectors"
import "SwapConnectors"
import "EVMTokenConnectors"
import "ERC4626Utils"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// ERC4626Swappers
///
/// Implements the DeFiActions.Swapper interface to swap asset tokens to 4626 shares, integrating the connector with an
/// EVM ERC4626 Vault.
///
access(all) contract ERC4626Swappers {

    /// Swapper
    ///
    /// An implementation of the DeFiActions.Swapper interface to swap assets to 4626 shares where the input token is
    /// underlying asset in the 4626 vault. Both the asset & the 4626 shares must be onboarded to the VM bridge in order
    /// for liquidity to flow between Cadnece & EVM. These "swaps" are performed by depositing the input asset into the
    /// ERC4626 vault and withdrawing the resulting shares from the ERC4626 vault.
    ///
    /// NOTE: Since ERC4626 vaults typically do not support synchronous withdrawals, this Swapper only supports the
    ///     default inType -> outType path via swap() and reverts on swapBack() since the withdrawal cannot be returned
    ///     synchronously.
    ///
    access(all) struct Swapper : DeFiActions.Swapper {
        /// The asset type serving as the price basis in the ERC4626 vault
        access(self) let asset: Type
        /// The EVM address of the asset ERC20 asset underlying the ERC4626 vault
        access(self) let assetEVMAddress: EVM.EVMAddress
        /// The address of the ERC4626 vault
        access(self) let vault: EVM.EVMAddress
        /// The type of the bridged ERC4626 vault
        access(self) let vaultType: Type
        /// The token sink to use for the ERC4626 vault
        access(self) let assetSink: ERC4626SinkConnectors.AssetSink
        /// The token source to use for the ERC4626 vault
        access(self) let shareSource: EVMTokenConnectors.Source
        /// The optional UniqueIdentifier of the ERC4626 vault
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            asset: Type,
            vault: EVM.EVMAddress,
            coa: Capability<auth(EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount>,
            feeSource: {DeFiActions.Sink, DeFiActions.Source},
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            pre {
                DeFiActionsUtils.definingContractIsFungibleToken(asset):
                "Provided asset \(asset.identifier) is not a Vault type"
                coa.check():
                "Provided COA Capability is invalid - need Capability<&EVM.CadenceOwnedAccount>"
            }
            self.asset = asset
            self.assetEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset)
                ?? panic("Provided asset \(asset.identifier) is not associated with ERC20 - ensure the type & ERC20 contracts are associated via the VM bridge")
            self.vault = vault
            self.vaultType = FlowEVMBridgeConfig.getTypeAssociated(with: vault)
                ?? panic("Provided ERC4626 Vault \(vault.toString()) is not associated with a Cadence FungibleToken - ensure the type & ERC4626 contracts are associated via the VM bridge")

            self.assetSink = ERC4626SinkConnectors.AssetSink(
                asset: asset,
                vault: vault,
                coa: coa,
                feeSource: feeSource,
                uniqueID: uniqueID
            )
            self.shareSource = EVMTokenConnectors.Source(
                min: nil,
                withdrawVaultType: self.vaultType,
                coa: coa,
                feeSource: feeSource,
                uniqueID: uniqueID
            )
            
            self.uniqueID = uniqueID
        }

        /// The type of Vault this Swapper accepts when performing a swap
        access(all) view fun inType(): Type {
            return self.asset
        }
        /// The type of Vault this Swapper provides when performing a swap
        access(all) view fun outType(): Type {
            return self.vaultType
        }
        /// The estimated amount required to provide a Vault with the desired output balance
        access(all) fun quoteIn(forDesired: UFix64, reverse: Bool): {DeFiActions.Quote} {
            let uintForDesired = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(forDesired, erc20Address: self.vault)
            if let uintRequired = ERC4626Utils.previewMint(vault: self.vault, shares: uintForDesired) {
                let ufixRequired = FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(uintRequired, erc20Address: self.assetEVMAddress)
                return SwapConnectors.BasicQuote(
                    inType: self.asset,
                    outType: self.vaultType,
                    inAmount: 0.0,
                    outAmount: ufixRequired
                )
            }
            return SwapConnectors.BasicQuote(
                inType: self.asset,
                outType: self.vaultType,
                inAmount: 0.0,
                outAmount: 0.0
            )
        }
        /// The estimated amount delivered out for a provided input balance
        access(all) fun quoteOut(forProvided: UFix64, reverse: Bool): {DeFiActions.Quote} {
            let uintForProvided = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(forProvided, erc20Address: self.assetEVMAddress)
            if let uintShares = ERC4626Utils.previewDeposit(vault: self.vault, assets: uintForProvided) {
                let ufixShares = FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(uintShares, erc20Address: self.vault)
                return SwapConnectors.BasicQuote(
                    inType: self.asset,
                    outType: self.vaultType,
                    inAmount: 0.0,
                    outAmount: ufixShares
                )
            }
            return SwapConnectors.BasicQuote(
                inType: self.asset,
                outType: self.vaultType,
                inAmount: 0.0,
                outAmount: 0.0
            )
        }
        /// Performs a swap taking a Vault of type inVault, outputting a resulting outVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        access(all) fun swap(quote: {DeFiActions.Quote}?, inVault: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            if inVault.balance == 0.0 {
                // nothing to swap - burn the inVault and return an empty outVault
                Burner.burn(<-inVault)
                return <- DeFiActionsUtils.getEmptyVault(self.vaultType)
            }

            // assign or get the quote for the swap
            let _quote = quote ?? self.quoteOut(forProvided: inVault.balance, reverse: false)

            // get the before available shares
            let beforeAvailable = self.shareSource.minimumAvailable()

            // deposit the inVault into the asset sink
            self.assetSink.depositCapacity(from: &inVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            assert(self.assetSink.minimumCapacity() > 0.0, message: "Expected ERC4626 Asset Sink to have capacity after depositing")
            Burner.burn(<-inVault)

            // get the after available shares
            let afterAvailable = self.shareSource.minimumAvailable()
            assert(afterAvailable > beforeAvailable, message: "Expected ERC4626 Vault \(self.vault.toString()) to have more shares after depositing")

            // withdraw the available difference in shares
            let availableDiff = afterAvailable - beforeAvailable
            let sharesVault <- self.shareSource.withdrawAvailable(maxAmount: availableDiff)
            return <- sharesVault
        }
        /// Performs a swap taking a Vault of type outVault, outputting a resulting inVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        // TODO: Impl detail - accept quote that was just used by swap() but reverse the direction assuming swap() was just called
        access(all) fun swapBack(quote: {DeFiActions.Quote}?, residual: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            panic("ERC4626Swappers.Swapper.swapBack() is not supported - ERC4626 Vaults do not support synchronous withdrawals")
        }
        /// Returns a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        /// each inner component in the stack.
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: [
                    self.assetSink.getComponentInfo(),
                    self.shareSource.getComponentInfo()
                ]
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
