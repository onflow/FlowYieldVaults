import "SwapPair"
import "SwapFactory"
import "SwapConfig"
import "MOET"
import "YieldToken"

access(all) fun main(): AnyStruct? {
    let token0Key = SwapConfig.SliceTokenTypeIdentifierFromVaultType(vaultTypeIdentifier: Type<@MOET.Vault>().identifier)
    let token1Key = SwapConfig.SliceTokenTypeIdentifierFromVaultType(vaultTypeIdentifier: Type<@YieldToken.Vault>().identifier)
    return SwapFactory.getPairInfo(token0Key: token0Key, token1Key: token1Key)
}
