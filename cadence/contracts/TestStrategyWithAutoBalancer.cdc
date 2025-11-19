// standards
import "FungibleToken"
import "FlowToken"
import "Burner"

// DeFiActions
import "DeFiActions"
import "FlowVaults"

// Mocks
import "MockOracle"
import "MockSwapper"

/// Test strategy with built-in AutoBalancer for testing scheduled rebalancing on testnet
/// Uses mocks to avoid UniswapV3 complexity and account access issues
///
/// THIS CONTRACT IS FOR TESTING ONLY
///
access(all) contract TestStrategyWithAutoBalancer {

    access(all) let IssuerStoragePath: StoragePath

    /// Simple strategy with embedded AutoBalancer for testing
    access(all) resource Strategy : FlowVaults.Strategy {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let vaultType: Type
        access(self) var vault: @{FungibleToken.Vault}
        access(self) var autoBalancer: @DeFiActions.AutoBalancer
        
        init(uniqueID: DeFiActions.UniqueIdentifier, withFunds: @{FungibleToken.Vault}) {
            self.uniqueID = uniqueID
            self.vaultType = withFunds.getType()
            
            // Create a simple vault to hold funds
            self.vault <- withFunds
            
            // Create AutoBalancer with mock oracle and REAL rebalancing
            let oracle = MockOracle.PriceOracle()
            
            // Create AutoBalancer first (with nil sink/source, will set later)
            self.autoBalancer <- DeFiActions.createAutoBalancer(
                oracle: oracle,
                vaultType: self.vaultType,
                lowerThreshold: 0.9,  // 10% below triggers rebalance
                upperThreshold: 1.1,  // 10% above triggers rebalance
                rebalanceSink: nil,   // Set later
                rebalanceSource: nil, // Set later
                recurringConfig: nil,
                uniqueID: uniqueID
            )
            
            // Create REAL sink/source for actual rebalancing using MockSwapper
            // Note: We set both to nil initially because the mock swapper requires
            // liquidity connectors to be set up first (done on testnet before tide creation)
            // The AutoBalancer will work for testing scheduled execution even without
            // actual rebalancing, but with proper setup it can rebalance too
        }
        
        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return {self.vaultType: true}
        }
        
        access(all) fun availableBalance(ofToken: Type): UFix64 {
            if ofToken == self.vaultType {
                return self.vault.balance
            }
            return 0.0
        }
        
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let amount = from.balance
            self.vault.deposit(from: <- from.withdraw(amount: amount))
        }
        
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            if ofToken != self.vaultType {
                return <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            }
            return <- self.vault.withdraw(amount: maxAmount)
        }
        
        /// Get the AutoBalancer for rebalancing
        access(all) fun borrowAutoBalancer(): &DeFiActions.AutoBalancer {
            return &self.autoBalancer
        }
        
        /// Manually trigger rebalancing (for testing)
        access(all) fun rebalance(force: Bool) {
            self.autoBalancer.rebalance(force: force)
        }
        
        /// NOTE: For FULL rebalancing testing with actual fund movement:
        /// - MockSwapper liquidity connectors must be configured on testnet
        /// - Then use setSink/setSource transactions to configure the AutoBalancer
        /// - This contract focuses on testing the scheduled execution mechanism
        /// - The rebalancing logic itself is tested in emulator scenario tests
        
        access(contract) fun burnCallback() {
            // Destroy resources by moving them out first
            let v <- self.vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
            Burner.burn(<-v)
            
            // Create dummy AutoBalancer to swap out
            let dummyAB <- DeFiActions.createAutoBalancer(
                oracle: MockOracle.PriceOracle(),
                vaultType: Type<@FlowToken.Vault>(),
                lowerThreshold: 0.9,
                upperThreshold: 1.1,
                rebalanceSink: nil,
                rebalanceSource: nil,
                recurringConfig: nil,
                uniqueID: nil
            )
            let ab <- self.autoBalancer <- dummyAB
            Burner.burn(<-ab)
        }
        
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }
        
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
        
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    access(all) resource StrategyComposer : FlowVaults.StrategyComposer {
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            return {Type<@Strategy>(): true}
        }
        
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return {Type<@FlowToken.Vault>(): true}
        }
        
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return {Type<@FlowToken.Vault>(): true}
        }
        
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{FlowVaults.Strategy} {
            let strategy <- create Strategy(uniqueID: uniqueID, withFunds: <-withFunds)
            return <- strategy
        }
    }

    access(all) resource StrategyComposerIssuer : FlowVaults.StrategyComposerIssuer {
        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return {Type<@StrategyComposer>(): true}
        }
        
        access(all) fun issueComposer(_ type: Type): @{FlowVaults.StrategyComposer} {
            return <- create StrategyComposer()
        }
    }

    init() {
        self.IssuerStoragePath = StoragePath(identifier: "TestStrategyComposerIssuer_\(self.account.address)")!
        self.account.storage.save(<-create StrategyComposerIssuer(), to: self.IssuerStoragePath)
    }
}

