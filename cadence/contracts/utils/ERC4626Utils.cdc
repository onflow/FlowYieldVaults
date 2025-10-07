import "EVM"
import "FlowEVMBridgeUtils"

/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
/// THIS CONTRACT IS IN BETA AND IS NOT FINALIZED - INTERFACES MAY CHANGE AND/OR PENDING CHANGES MAY REQUIRE REDEPLOYMENT
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// ERC4626Utils
///
/// Utility methods commonly used across ERC4626 integrating contracts
///
access(all) contract ERC4626Utils {

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
    /// Returns the total shares issued by the ERC4626 vault
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    ///
    /// @return The total shares issued by the ERC4626 vault
    access(all) fun totalShares(coa: &EVM.CadenceOwnedAccount, vault: EVM.EVMAddress): UInt256? {
        let callRes = coa.dryCall(
                to: vault,
                data: EVM.encodeABIWithSignature("totalSupply()", []),
                gasLimit: 100_000,
                value: EVM.Balance(attoflow: 0)
            )
        if callRes.status != EVM.Status.successful || callRes.data.length == 0 {
            return nil
        }
        let totalShares = EVM.decodeABI(types: [Type<UInt256>()], data: callRes.data)
        return totalShares[0] as! UInt256
    }
    /// Returns the total assets managed by the ERC4626 vault
    ///
    /// @param coa The COA used to call the ERC4626 vault
    /// @param vault The address of the ERC4626 vault
    ///
    /// @return The total assets managed by the ERC4626 vault. Callers should anticipate the address of the asset and
    ///         the decimals of the asset being returned.
    access(all) fun totalAssets(coa: &EVM.CadenceOwnedAccount, vault: EVM.EVMAddress): UInt256? {
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
}
