import "FungibleToken"
import "FlowToken"
import "EVM"
import "FungibleTokenConnectors"
import "MorphoERC4626SwapConnectors"
import "FlowYieldVaultsAutoBalancersV1"

/// Converts PYUSD0 → FUSDEV (via Morpho ERC4626 deposit) and injects the resulting
/// shares directly into the AutoBalancer for the given yield vault ID.
///
/// This simulates accumulated yield in the AutoBalancer, producing a scenario where
/// the yield token (FUSDEV) balance is greater than the vault's outstanding MOET debt.
///
/// The signer must hold PYUSD0 in their Cadence vault and have a COA at /storage/evm.
/// FLOW at /storage/flowTokenVault is used for bridge fees.
///
/// @param vaultID:       The YieldVault ID whose AutoBalancer should receive FUSDEV
/// @param fusdEvEVMAddr: EVM address of the FUSDEV Morpho ERC4626 vault (hex with 0x prefix)
/// @param pyusd0Amount:  Amount of PYUSD0 to deposit into FUSDEV and inject as excess
///
transaction(
    vaultID: UInt64,
    fusdEvEVMAddr: String,
    pyusd0Amount: UFix64
) {
    prepare(signer: auth(Storage, BorrowValue, IssueStorageCapabilityController) &Account) {
        // Issue COA capability (needs EVM.Call and EVM.Bridge for Morpho ERC4626 deposit)
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount>(/storage/evm)

        // Issue a withdraw capability on the signer's FLOW vault to serve as the bridge fee source
        let flowWithdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSinkAndSource(
            min: nil,
            max: nil,
            vault: flowWithdrawCap,
            uniqueID: nil
        )

        // Build Morpho ERC4626 swapper: PYUSD0 → FUSDEV (isReversed: false)
        // The Swapper auto-detects PYUSD0 as the underlying asset from the FUSDEV vault.
        let swapper = MorphoERC4626SwapConnectors.Swapper(
            vaultEVMAddress: EVM.addressFromString(fusdEvEVMAddr),
            coa: coaCap,
            feeSource: feeSource,
            uniqueID: nil,
            isReversed: false
        )

        let pyusd0Provider = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
            from: /storage/EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750Vault
        ) ?? panic("No PYUSD0 vault found")

        let pyusd0In <- pyusd0Provider.withdraw(amount: pyusd0Amount)

        // Quote and swap PYUSD0 → FUSDEV (Morpho ERC4626 deposit via EVM)
        let quote = swapper.quoteOut(forProvided: pyusd0Amount, reverse: false)
        assert(
            quote.outAmount > 0.0,
            message: "PYUSD0 → FUSDEV quote returned zero — Morpho vault may be at capacity"
        )
        let fusdEvOut <- swapper.swap(quote: quote, inVault: <-pyusd0In)
        log("Converted ".concat(pyusd0Amount.toString()).concat(" PYUSD0 → ").concat(fusdEvOut.balance.toString()).concat(" FUSDEV shares"))

        // Deposit FUSDEV shares directly into the vault's AutoBalancer.
        // AutoBalancers.AutoBalancer.deposit() is access(all) — callable via the public reference.
        let autoBalancer = FlowYieldVaultsAutoBalancersV1.borrowAutoBalancer(id: vaultID)
            ?? panic("No AutoBalancer found for vault ID ".concat(vaultID.toString()))
        autoBalancer.deposit(from: <-fusdEvOut)
        log("Injected FUSDEV into AutoBalancer for vault ID ".concat(vaultID.toString()))
    }
}
