import "FungibleToken"
import "EVM"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"
import "MOET"

/// Performs a UniswapV3 swap from Cadence using the swap connector
///
/// @param factoryAddressHex: V3 Factory address (e.g., "0x986Cb42b0557159431d48fE0A40073296414d410")
/// @param routerAddressHex: V3 Router address
/// @param quoterAddressHex: V3 Quoter address
/// @param tokenInAddressHex: Input token EVM address
/// @param tokenOutAddressHex: Output token EVM address
/// @param feeTier: Fee tier in basis points (e.g., 3000 for 0.3%)
/// @param amountIn: Amount of input token to swap
///
transaction(
    factoryAddressHex: String,
    routerAddressHex: String,
    quoterAddressHex: String,
    tokenInAddressHex: String,
    tokenOutAddressHex: String,
    feeTier: UInt32,
    amountIn: UFix64
) {

  prepare(acct: auth(Storage, Capabilities) &Account) {
    // COA capability: either issue from storage (owner) or use a published public cap.
    let coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> =
      acct.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

    let factory = EVM.addressFromString(factoryAddressHex)
    let router = EVM.addressFromString(routerAddressHex)
    let quoter = EVM.addressFromString(quoterAddressHex)
    let tokenIn = EVM.addressFromString(tokenInAddressHex)
    let tokenOut = EVM.addressFromString(tokenOutAddressHex)

    // Get vault types for in/out tokens
    let inType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenIn) 
        ?? panic("No Cadence type associated with tokenIn ".concat(tokenInAddressHex))
    let outType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenOut) 
        ?? panic("No Cadence type associated with tokenOut ".concat(tokenOutAddressHex))

    let swapper = UniswapV3SwapConnectors.Swapper(
      factoryAddress: factory,
      routerAddress: router,
      quoterAddress: quoter,
      tokenPath: [tokenIn, tokenOut],
      feePath: [feeTier],
      inVault: inType,
      outVault: outType,
      coaCapability: coaCap,
      uniqueID: nil
    )

    // Construct storage paths
    // For MOET (native Cadence token), use MOET.VaultStoragePath
    // For bridged tokens, construct the EVMVMBridgedToken path
    let tokenInStoragePath: StoragePath
    if inType == Type<@MOET.Vault>() {
        tokenInStoragePath = MOET.VaultStoragePath
    } else {
        let inAddr = EVM.addressFromString(tokenInAddressHex)
        tokenInStoragePath = StoragePath(identifier: "EVMVMBridgedToken_".concat(
            inAddr.toString()
        ).concat("Vault"))!
    }
    
    let tokenOutStoragePath: StoragePath
    if outType == Type<@MOET.Vault>() {
        tokenOutStoragePath = MOET.VaultStoragePath
    } else {
        let outAddr = EVM.addressFromString(tokenOutAddressHex)
        tokenOutStoragePath = StoragePath(identifier: "EVMVMBridgedToken_".concat(
            outAddr.toString()
        ).concat("Vault"))!
    }

    // Withdraw
    let withdrawRef = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: tokenInStoragePath)
      ?? panic("Missing TokenIn vault at ".concat(tokenInStoragePath.toString()))

    let vaultIn <- withdrawRef.withdraw(amount: amountIn)

    // Quote how much we'll get
    let q = swapper.quoteOut(forProvided: amountIn, reverse: false)
    log("Quote out for provided ".concat(amountIn.toString()).concat(" TokenIn → TokenOut: ").concat(q.outAmount.toString()))

    // Perform the swap
    let vaultOut <- swapper.swap(quote: q, inVault: <-vaultIn)
    log("TokenOut received: ".concat(vaultOut.balance.toString()))

    // Deposit
    let tokenOutReceiver = acct.storage
      .borrow<&{FungibleToken.Receiver}>(from: tokenOutStoragePath)
      ?? panic("Missing TokenOut vault at ".concat(tokenOutStoragePath.toString()))
    tokenOutReceiver.deposit(from: <-vaultOut)
  }
}

