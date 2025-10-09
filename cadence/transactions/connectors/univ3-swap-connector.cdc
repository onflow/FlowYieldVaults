import "FungibleToken"
import "EVM"
import "FlowEVMBridgeUtils"
import "UniswapV3SwapConnectors3"
import "FlowEVMBridgeConfig"

transaction() {

  prepare(acct: auth(Storage, Capabilities) &Account) {
    // COA capability: either issue from storage (owner) or use a published public cap.
    let coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> =
      acct.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

    let router = EVM.addressFromString("0x2Db6468229F6fB1a77d248Dbb1c386760C257804")

    let quoter = EVM.addressFromString("0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c")

    // let usdc  = EVM.addressFromString("0x5e65b6B04fbA51D95409712978Cb91E99d93aE73")
    // let wflow = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e") // WFLOW on EVM side

    let tokenIn = EVM.addressFromString("0xd431955D55a99EF69BEb96BA34718d0f9fBc91b1")
    let tokenOut = EVM.addressFromString("0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95")

    // Vault types for in/out
    // let inType: Type = Type<@FlowToken.Vault>() // FLOW in
    // let outType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: usdc) ?? panic("invalid USDC out type")

    let inType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenIn) ?? panic("invalid mockUSDC in type") // FLOW in
    let outType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: tokenOut) ?? panic("invalid moreVaultUSDC out type")
    // Swapper: tokenPath must be [WFLOW, USDC] for FLOW → USDC
    let swapper = UniswapV3SwapConnectors3.Swapper(
      routerAddress: router,
      quoterAddress: quoter,
      //tokenPath: [wflow, usdc],
      tokenPath: [tokenIn, tokenOut],
      feePath: [3000], // 0.3%
      inVault: inType,
      outVault: outType,
      coaCapability: coaCap,
      uniqueID: nil
    )

    let tokenInStoragePath = /storage/EVMVMBridgedToken_d431955d55a99ef69beb96ba34718d0f9fbc91b1Vault
    let tokenOutStoragePath = /storage/EVMVMBridgedToken_4154d5b0e2931a0a1e5b733f19161aa7d2fc4b95Vault
    // Withdraw FLOW
    let withdrawRef = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: tokenInStoragePath)
      ?? panic("Missing FLOW vault at /storage/flowTokenVault")

    let amountIn: UFix64 = 1.0
    let vaultIn <- withdrawRef.withdraw(amount: amountIn)

    // Quote how much USDC we’ll get
    let q = swapper.quoteOut(forProvided: amountIn, reverse: false)
    log("Quote out for provided ".concat(amountIn.toString()).concat(" FLOW → USDC: ").concat(q.outAmount.toString()))

    // Perform the swap
    let vaultOut <- swapper.swap(quote: q, inVault: <-vaultIn)
    log("USDC received: ".concat(vaultOut.balance.toString()))

    // Deposit USDC
    let usdcReceiver = acct.storage
      .borrow<&{FungibleToken.Receiver}>(from: tokenOutStoragePath)
      ?? panic("Missing USDC vault at ".concat(tokenOutStoragePath.toString()))
    usdcReceiver.deposit(from: <-vaultOut)
  }
}
