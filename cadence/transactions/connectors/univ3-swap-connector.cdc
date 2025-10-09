import "FungibleToken"
import "EVM"
import "FlowToken"
import "FlowEVMBridgeUtils"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"

transaction() {

  prepare(acct: auth(Storage, Capabilities) &Account) {
    // COA capability: either issue from storage (owner) or use a published public cap.
    let coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> =
      acct.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

    let router = EVM.addressFromString("0x2Db6468229F6fB1a77d248Dbb1c386760C257804")

    let quoter = EVM.addressFromString("0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c")

    let usdc  = EVM.addressFromString("0x5e65b6B04fbA51D95409712978Cb91E99d93aE73")
    let wflow = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e") // WFLOW on EVM side

    // Vault types for in/out
    let inType: Type = Type<@FlowToken.Vault>() // FLOW in
    let outType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: usdc) ?? panic("invalid USDC out type")

    // Swapper: tokenPath must be [WFLOW, USDC] for FLOW → USDC
    let swapper = UniswapV3SwapConnectors.Swapper(
      routerAddress: router,
      quoterAddress: quoter,
      tokenPath: [wflow, usdc],
      feePath: [3000], // 0.3%
      inVault: inType,
      outVault: outType,
      coaCapability: coaCap,
      uniqueID: nil
    )

    let flowStoragePath = /storage/flowTokenVault
    let usdcStoragePath = /storage/EVMVMBridgedToken_5e65b6b04fba51d95409712978cb91e99d93ae73Vault
    // ---- Swap FLOW → USDC (quoteOut + swap) ----
    // Withdraw FLOW
    let flowWithdrawRef = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: flowStoragePath)
      ?? panic("Missing FLOW vault at /storage/flowTokenVault")

    let flowIn: UFix64 = 100.0
    let flowVaultIn <- flowWithdrawRef.withdraw(amount: flowIn)

    // Quote how much USDC we’ll get
    let q = swapper.quoteOut(forProvided: flowIn, reverse: false)
    log("Quote out for provided ".concat(flowIn.toString()).concat(" FLOW → USDC: ").concat(q.outAmount.toString()))

    // Perform the swap
    let usdcOut <- swapper.swap(quote: q, inVault: <-flowVaultIn)
    log("USDC received: ".concat(usdcOut.balance.toString()))

    // Deposit USDC
    let usdcReceiver = acct.storage
      .borrow<&{FungibleToken.Receiver}>(from: usdcStoragePath)
      ?? panic("Missing USDC vault at ".concat(usdcStoragePath.toString()))
    usdcReceiver.deposit(from: <-usdcOut)
  }
}
