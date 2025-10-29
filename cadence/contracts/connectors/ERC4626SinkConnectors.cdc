import "Burner"
import "FungibleToken"
import "EVM"
import "FlowEVMBridgeConfig"
import "FlowEVMBridgeUtils"
import "DeFiActions"
import "EVMTokenConnectors"
import "ERC4626Utils"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// ERC4626SinkConnectors
///
access(all) contract ERC4626SinkConnectors {

    /// AssetSink
    ///
    /// Deposits assets to an ERC4626 vault (which accepts the asset as a deposit denomination) to the contained COA's
    /// vault share balance
    ///
    access(all) struct AssetSink : DeFiActions.Sink {
        /// The asset type serving as the price basis in the ERC4626 vault
        access(self) let asset: Type
        /// The EVM address of the asset ERC20 contract
        access(self) let assetEVMAddress: EVM.EVMAddress
        /// The address of the ERC4626 vault
        access(self) let vault: EVM.EVMAddress
        /// The COA capability to use for the ERC4626 vault
        access(self) let coa: Capability<auth(EVM.Call) &EVM.CadenceOwnedAccount>
        /// The token sink to use for the ERC4626 vault
        access(self) let tokenSink: EVMTokenConnectors.Sink
        /// The optional UniqueIdentifier of the ERC4626 vault
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(
            asset: Type,
            vault: EVM.EVMAddress,
            coa: Capability<auth(EVM.Call) &EVM.CadenceOwnedAccount>,
            feeSource: {DeFiActions.Sink, DeFiActions.Source},
            uniqueID: DeFiActions.UniqueIdentifier?
        ) {
            pre {
                asset.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Provided asset \(asset.identifier) is not a Vault type"
                coa.check():
                "Provided COA Capability is invalid - need Capability<&EVM.CadenceOwnedAccount>"
            }
            self.asset = asset
            self.assetEVMAddress = FlowEVMBridgeConfig.getEVMAddressAssociated(with: asset)
                ?? panic("Provided asset \(asset.identifier) is not associated with ERC20 - ensure the type & ERC20 contracts are associated via the VM bridge")
            self.vault = vault
            self.coa = coa
            self.tokenSink = EVMTokenConnectors.Sink(
                max: nil,
                depositVaultType: asset,
                address: coa.borrow()!.address(),
                feeSource: feeSource,
                uniqueID: uniqueID
            )
            self.uniqueID = uniqueID
        }

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.asset
        }
        /// Returns an estimate of how much can be withdrawn from the depositing Vault for this Sink to reach capacity
        access(all) fun minimumCapacity(): UFix64 {
            // Check the EVMTokenConnectors Sink has capacity to bridge the assets to EVM
            // TODO: Update EVMTokenConnector.Sink to return 0.0 if it doesn't have fees to pay for the bridge call
            let coa = self.coa.borrow()
            if coa == nil || self.tokenSink.minimumCapacity() == 0.0 {
                return 0.0
            }
            // Check the ERC4626 vault has capacity to deposit the assets
            let max = ERC4626Utils.maxDeposit(vault: self.vault, receiver: coa!.address())
            return max != nil ? FlowEVMBridgeUtils.convertERC20AmountToCadenceAmount(max!, erc20Address: self.assetEVMAddress) : 0.0
        }
        /// Deposits up to the Sink's capacity from the provided Vault
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            // check capacity & early return if none
            let capacity = self.minimumCapacity()
            if capacity == 0.0 {
                return
            }

            // withdraw the appropriate amount from the referenced vault & deposit to the EVMTokenConnectors Sink
            var amount = capacity <= from.balance ? capacity : from.balance
            let deposit <- from.withdraw(amount: amount)
            self.tokenSink.depositCapacity(from: &deposit as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            if deposit.balance > 0.0 {
                // update deposit amount & deposit the residual
                amount = amount - deposit.balance
                from.deposit(from: <-deposit)
            } else {
                Burner.burn(<-deposit) // nothing left - burn & execute vault's burnCallback()
            }

            // approve the ERC4626 vault to spend the assets on deposit
            let uintAmount = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(amount, erc20Address: self.assetEVMAddress)
            let approveRes = self._call(
                    dry: false,
                    to: self.assetEVMAddress,
                    signature: "approve(address,uint256)",
                    args: [self.vault, uintAmount],
                    gasLimit: 100_000
                )
            if approveRes?.status != EVM.Status.successful {
                // TODO: consider more graceful handling of this error
                panic("Failed to approve ERC4626 vault to spend assets")
            }

            // deposit the assets to the ERC4626 vault
            let depositRes = self._call(
                dry: false,
                to: self.vault,
                signature: "deposit(address,uint256)",
                args: [self.assetEVMAddress, uintAmount],
                gasLimit: 250_000
            )
            if depositRes?.status != EVM.Status.successful {
                // TODO: Consider unwinding the deposit & returning to the from vault
                //      - would require {Sink, Source} instead of just Sink
                return
            }
        }
        /// Returns a ComponentInfo struct containing information about this component and a list of ComponentInfo for
        /// each inner component in the stack.
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: [
                    self.tokenSink.getComponentInfo()
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
        /// Performs a dry call to the ERC4626 vault
        ///
        /// @param to The address of the ERC4626 vault
        /// @param signature The signature of the function to call
        /// @param args The arguments to pass to the function
        /// @param gasLimit The gas limit to use for the call
        ///
        /// @return The result of the dry call or `nil` if the COA capability is invalid
        access(self)
        fun _call(dry: Bool, to: EVM.EVMAddress, signature: String, args: [AnyStruct], gasLimit: UInt64): EVM.Result? {
            let calldata = EVM.encodeABIWithSignature(signature, args)
            let valueBalance = EVM.Balance(attoflow: 0)
            if let coa = self.coa.borrow() {
                return dry
                    ? coa.dryCall(to: to, data: calldata, gasLimit: gasLimit, value: valueBalance)
                    : coa.call(to: to, data: calldata, gasLimit: gasLimit, value: valueBalance)
            }
            return nil
        }
    }
}
