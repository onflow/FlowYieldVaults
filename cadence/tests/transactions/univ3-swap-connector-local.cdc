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
    let router = EVM.addressFromString("0x497ad81a7Fe6Be58457475f6A21C70c0Ceddca0B")

    let quoter = EVM.addressFromString("0x8dd92c8d0C3b304255fF9D98ae59c3385F88360C")

    // let usdc  = EVM.addressFromString("0x5e65b6B04fbA51D95409712978Cb91E99d93aE73") // Testnet USDC
    // let wflow = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e") // Testnet WFLOW

    let tokenIn = EVM.addressFromString("0x9a7b1d144828c356ec23ec862843fca4a8ff829e") // MOET
    let tokenOut = EVM.addressFromString("0xaCCF0c4EeD4438Ad31Cd340548f4211a465B6528") // More Vaults mUSDC

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
    let tokenOutStoragePath = /storage/EVMVMBridgedToken_accf0c4eed4438ad31cd340548f4211a465b6528Vault

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
