import "EVM"
import "FlowEVMBridgeUtils"
import "FlowEVMBridgeConfig"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// ERC4626Utils
///
/// Utility methods commonly used across ERC4626 integrating contracts. The included methods are built on top of the 
/// OpenZeppelin ERC4626 implementation and support view methods on the underlying ERC4626 contract.
///
access(all) contract ERC4626Utils {

    /// COA used to make calls to the ERC4626 vault
    access(self) let callingCOA: @EVM.CadenceOwnedAccount

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

    /// Returns the EVM address of the underlying asset for the given ERC4626 vault
    ///
    /// @param vault The address of the ERC4626 vault
    ///
    /// @return The EVM address of the underlying asset for the given ERC4626 vault
    access(all)
    fun underlyingAssetEVMAddress(vault: EVM.EVMAddress): EVM.EVMAddress? {
        let coa = &ERC4626Utils.callingCOA as &EVM.CadenceOwnedAccount
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("asset()", []),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: callRes.data)
        return decoded[0] as! EVM.EVMAddress
    }

    /// Returns the total assets managed by the ERC4626 vault
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    ///
    /// @return The total assets managed by the ERC4626 vault. Callers should anticipate the address of the asset and
    ///         the decimals of the asset being returned.
    access(all) fun totalAssets(vault: EVM.EVMAddress): UInt256? {
        let coa = &ERC4626Utils.callingCOA as &EVM.CadenceOwnedAccount
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("totalAssets()", []),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let totalAssets = EVM.decodeABI(types: [Type<UInt256>()], data: callRes.data)
        return totalAssets[0] as! UInt256
    }

    /// Returns the total shares issued by the ERC4626 vault
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    ///
    /// @return The total shares issued by the ERC4626 vault. Callers should anticipate the address of the asset and
    ///         the decimals of the asset being returned.
    access(all) fun totalShares(vault: EVM.EVMAddress): UInt256? {
        let coa = &ERC4626Utils.callingCOA as &EVM.CadenceOwnedAccount
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("totalSupply()", []),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let totalAssets = EVM.decodeABI(types: [Type<UInt256>()], data: callRes.data)
        return totalAssets[0] as! UInt256
    }

    /// Returns the maximum amount of assets that can be deposited into the ERC4626 vault
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    /// @param receiver The address of the receiver of the deposit
    ///
    /// @return The maximum amount of assets that can be deposited into the ERC4626 vault for the receiver, returned in
    ///         the asset's decimals.
    access(all)
    fun maxDeposit(vault: EVM.EVMAddress, receiver: EVM.EVMAddress): UInt256? {
        let coa = &ERC4626Utils.callingCOA as &EVM.CadenceOwnedAccount
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("maxDeposit(address)", [receiver]),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let maxDeposit = EVM.decodeABI(types: [Type<UInt256>()], data: callRes.data)
        return maxDeposit[0] as! UInt256
    }

    /// Returns the amount of shares that would be minted for the given asset amount under current conditions
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    /// @param assetAmount The amount of assets to deposit denominated in the asset's decimals
    ///
    /// @return The amount of shares that would be minted for the given asset amount under current conditions. Callers
    ///         should anticipate the address of the asset and the decimals of the vault shares being returned.
    access(all)
    fun previewDeposit(vault: EVM.EVMAddress, assetAmount: UInt256): UInt256? {
        let coa = &ERC4626Utils.callingCOA as &EVM.CadenceOwnedAccount
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("previewDeposit(uint256)", [assetAmount]),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let previewDeposit = EVM.decodeABI(types: [Type<UInt256>()], data: callRes.data)
        return previewDeposit[0] as! UInt256
    }

    init() {
        self.callingCOA <- EVM.createCadenceOwnedAccount()
    }
}
