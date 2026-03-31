import "FungibleToken"
import "FlowToken"
import "EVM"
import "FungibleTokenConnectors"
import "ERC4626SwapConnectors"
import "FlowYieldVaultsAutoBalancersV1"

/// Converts FLOW → syWFLOWv (via ERC4626 deposit on the More vault) and injects the
/// resulting shares directly into the AutoBalancer for the given yield vault ID.
///
/// This simulates accumulated yield in the AutoBalancer, producing a scenario where
/// the yield token (syWFLOWv) balance is greater than the vault's outstanding FLOW debt.
///
/// The signer must hold FLOW in their /storage/flowTokenVault and have a COA at /storage/evm.
///
/// @param vaultID:         The YieldVault ID whose AutoBalancer should receive extra syWFLOWv
/// @param syWFLOWvEVMAddr: EVM address of the syWFLOWv ERC4626 vault (hex with 0x prefix)
/// @param flowAmount:      Amount of FLOW to convert to syWFLOWv and inject
///
transaction(
    vaultID: UInt64,
    syWFLOWvEVMAddr: String,
    flowAmount: UFix64
) {
    prepare(signer: auth(Storage, BorrowValue, IssueStorageCapabilityController) &Account) {
        // Issue a COA capability with EVM.Call and EVM.Bridge entitlements for the ERC4626 deposit
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount>(/storage/evm)

        // Issue a withdraw capability on the signer's FLOW vault to serve as the fee source
        let flowWithdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: flowWithdrawCap,
            uniqueID: nil
        )

        // Build ERC4626 swapper: FLOW (Cadence) → syWFLOWv (ERC4626 deposit via WFLOW bridge)
        // asset = FlowToken.Vault whose EVM counterpart is WFLOW — the underlying of syWFLOWv
        let swapper = ERC4626SwapConnectors.Swapper(
            asset: Type<@FlowToken.Vault>(),
            vault: EVM.addressFromString(syWFLOWvEVMAddr),
            coa: coaCap,
            feeSource: feeSource,
            uniqueID: nil
        )

        // Get a quote for converting flowAmount FLOW → syWFLOWv shares
        let quote = swapper.quoteOut(forProvided: flowAmount, reverse: false)
        assert(
            quote.outAmount > 0.0,
            message: "FLOW → syWFLOWv quote returned zero — syWFLOWv vault may be at capacity"
        )

        // Withdraw FLOW from signer's vault
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("No FLOW vault found at /storage/flowTokenVault")
        let flowIn <- flowVault.withdraw(amount: flowAmount)

        // Swap FLOW → syWFLOWv (bridges to EVM, deposits into syWFLOWv, bridges back to Cadence)
        let syWFLOWvOut <- swapper.swap(quote: quote, inVault: <-flowIn)
        log("Converted ".concat(flowAmount.toString()).concat(" FLOW → ").concat(syWFLOWvOut.balance.toString()).concat(" syWFLOWv shares"))

        // Deposit the syWFLOWv shares directly into the vault's AutoBalancer.
        // AutoBalancers.AutoBalancer.deposit() is access(all) — callable via the public reference.
        let autoBalancer = FlowYieldVaultsAutoBalancersV1.borrowAutoBalancer(id: vaultID)
            ?? panic("No AutoBalancer found for vault ID ".concat(vaultID.toString()))
        autoBalancer.deposit(from: <-syWFLOWvOut)
        log("Injected syWFLOWv into AutoBalancer for vault ID ".concat(vaultID.toString()))
    }
}
