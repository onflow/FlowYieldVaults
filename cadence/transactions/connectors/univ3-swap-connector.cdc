import "FungibleToken"
import "EVM"
import "FlowToken"
import "FlowEVMBridgeUtils"
import "UniswapV3SwapConnectors"
import "FlowEVMBridgeConfig"

transaction() {

  prepare(acct: auth(Storage, Capabilities) &Account) {
    // 1) COA capability your test published earlier
    let coaCap: Capability<auth(EVM.Owner) &EVM.CadenceOwnedAccount> =
      acct.capabilities.storage.issue<auth(EVM.Owner) &EVM.CadenceOwnedAccount>(/storage/evm)

    // 2) Router + Quoter + tokens from your forge deployment
    let router = EVM.addressFromString("0xB685ab04Dfef74c135A2ed4003441fF124AFF9a0")
    let quoter = EVM.addressFromString("0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c")

    let usdc  = EVM.addressFromString("0x5e65b6B04fbA51D95409712978Cb91E99d93aE73")
    let wflow = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e")

    // Types associated with ERC20s on Flow
    let inType: Type = FlowEVMBridgeConfig.getTypeAssociated(with: usdc) ?? panic("invalid in type")
    let outType = Type<@FlowToken.Vault>()
    // If WFLOW maps to FlowToken.Vault, outType should equal Type<@FlowToken.Vault>()

    // 3) Instantiate the V3 Swapper (single hop USDC -> WFLOW @ 0.3%)
    let swapper = UniswapV3SwapConnectors.Swapper(
      routerAddress: router,
      quoterAddress: quoter,
      tokenPath: [usdc, wflow],
      feePath: [3000], // 0.3%
      inVault: inType,
      outVault: outType,
      coaCapability: coaCap,
      uniqueID: nil
    )

    // 4) Bring in USDC from storage for testing (use FT interfaces for dynamic types)
    let usdcStoragePath = /storage/EVMVMBridgedToken_5e65b6b04fba51d95409712978cb91e99d93ae73Vault
    let usdcWithdrawRef = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: usdcStoragePath)
      ?? panic("Missing USDC vault at \(usdcStoragePath)")

    let amountIn: UFix64 = 100.0
    let vaultIn <- usdcWithdrawRef.withdraw(amount: amountIn)

    // 5) Quote output for provided input
    let q = swapper.quoteOut(forProvided: amountIn, reverse: false)
    log("Quote out for provided ".concat(amountIn.toString()).concat(": ").concat(q.outAmount.toString()))

    // 6) Perform the swap with min-out from the quote
    let outVault <- swapper.swap(quote: q, inVault: <-vaultIn)
    log("Swap out received: ".concat(outVault.balance.toString()))

    // Deposit result (WFLOW) — if WFLOW maps to FlowToken.Vault, deposit to that path
    let wflowStoragePath = /storage/wflowVault
    let wflowDepositRef = acct.storage
      .borrow<&{FungibleToken.Vault}>(from: wflowStoragePath)
      ?? panic("Missing WFLOW vault at /storage/wflowVault")
    wflowDepositRef.deposit(from: <-outVault)

    // 7) “Exact-out” pattern:
    //    Pre-quote the required input for desired WFLOW, withdraw exactly that, then swap.
    let desiredWFLOW: UFix64 = 0.01
    let qi = swapper.quoteIn(forDesired: desiredWFLOW, reverse: false)
    let needIn: UFix64 = qi.inAmount
    log("ExactOut desired ".concat(desiredWFLOW.toString()).concat(" WFLOW; need USDC: ").concat(needIn.toString()))

    let usdcWithdrawRef2 = acct.storage
      .borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: usdcStoragePath)
      ?? panic("Missing USDC vault at \(usdcStoragePath) (for exactOut)")
    let maxSpend: UFix64 = 100.0
    assert(needIn <= maxSpend, message: "Required USDC exceeds test max spend")

    let needVault <- usdcWithdrawRef2.withdraw(amount: needIn)
    let outVault2 <- swapper.swap(quote: qi, inVault: <-needVault)
    log("ExactOut swap received WFLOW: ".concat(outVault2.balance.toString()))

    let wflowDepositRef2 = acct.storage
      .borrow<&{FungibleToken.Vault}>(from: wflowStoragePath)
      ?? panic("Missing WFLOW vault for exactOut deposit")
    wflowDepositRef2.deposit(from: <-outVault2)
  }
}
