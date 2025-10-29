import "FungibleToken"
import "EVM"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"
import "MOET"

transaction() {

  prepare(acct: auth(Storage, Capabilities) &Account) {
    // COA capability: either issue from storage (owner) or use a published public cap.
    let coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> =
      acct.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

    let factory = EVM.addressFromString("0x986Cb42b0557159431d48fE0A40073296414d410")

    let router = EVM.addressFromString("0x2Db6468229F6fB1a77d248Dbb1c386760C257804")

    let quoter = EVM.addressFromString("0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c")

    // Note: Update these addresses based on actual deployment
    // To get MOET EVM address: flow scripts execute ./cadence/scripts/helpers/get_moet_evm_address.cdc
    // To get USDC address: check local/deployed_addresses.env
    
    let tokenIn = EVM.addressFromString("0x9a7b1d144828c356ec23ec862843fca4a8ff829e") // MOET (update after bridging)
    let tokenOut = EVM.addressFromString("0x8C7187932B862F962f1471c6E694aeFfb9F5286D") // USDC (update after deployment)

    // Vault types for in/out

    //let inType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenIn) ?? panic("invalid MOET out type")
    let inType: Type = Type<@MOET.Vault>()
    let outType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenOut) ?? panic("invalid moreVaultUSDC out type")

    let swapper = UniswapV3SwapConnectors.Swapper(
      factoryAddress: factory,
      routerAddress: router,
      quoterAddress: quoter,
      tokenPath: [tokenIn, tokenOut],
      feePath: [3000], // 0.3%
      inVault: inType,
      outVault: outType,
      coaCapability: coaCap,
      uniqueID: nil
    )

    let tokenInStoragePath = MOET.VaultStoragePath
    // Construct USDC vault path dynamically from tokenOut address
    let usdcPathId = "EVMVMBridgedToken_".concat(tokenOut.toString()).concat("Vault")
    let tokenOutStoragePath = StoragePath(identifier: usdcPathId)!

    // Withdraw
    let withdrawRef = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: tokenInStoragePath)
      ?? panic("Missing TokenIn vault at ".concat(tokenInStoragePath.toString()))

    let amountIn: UFix64 = 1.0
    let vaultIn <- withdrawRef.withdraw(amount: amountIn)

    // Quote how much we’ll get
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
