import "FungibleToken"
import "Burner"
import "DFB"

access(all) contract interface StrategyComposer {

    /// Returns the Types of Strategies composed by this StrategyComposer
    access(all) view fun getComposedStrategyTypes(): {Type: Bool}
    /// Returns the Vault types which can be used to initialize a given Strategy
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool}
    /// Returns the minimum funding amount for a new Strategy of the given Type
    access(all) view fun getStrategyFundingMinimum(forStrategy: Type): UFix64? {
        post {
            self.getComposedStrategyTypes()[forStrategy] != nil ? result != nil : result == nil:
            "Invalid funding minimum result for supported Strategy \(forStrategy.identifier) was returned"
        }
    }
    /// Returns the Vault types which can be deposited to a given Strategy instance if it was initialized with the
    /// provided Vault type
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool}
    /// Composes a Strategy of the given type with the provided funds
    access(all) fun createStrategy(
        _ type: Type,
        uniqueID: DFB.UniqueIdentifier,
        withFunds: @{FungibleToken.Vault}
    ): @{Strategy} {
        pre {
            self.getSupportedInitializationVaults(forStrategy: type)[withFunds.getType()] == true:
            "Cannot initialize Strategy \(type.identifier) with Vault \(withFunds.getType().identifier) - "
                .concat("unsupported initialization Vault")
            self.getComposedStrategyTypes()[type] == true:
            "Strategy \(type.identifier) is unsupported by StrategyComposer \(self.getType().identifier)"
            withFunds.balance >= self.getStrategyFundingMinimum(forStrategy: type)!:
            "Insufficient funding balance \(withFunds.balance) of Vault \(withFunds.getType().identifier) provided for Strategy \(type.identifier)"
        }
    }

    /// Strategy
    ///
    /// A Strategy is meant to encapsulate the Sink/Source entrypoints allowing for flows into and out of stacked
    /// DeFiBlocks components. These compositions are intended to capitalize on some yield-bearing opportunity so that
    /// a Strategy bears yield on that which is deposited into it, albeit not without some risk. A Strategy then can be
    /// thought of as the top-level of a nesting of DeFiBlocks connectors & adapters where one can deposit & withdraw
    /// funds into the composed DeFi workflows.
    ///
    /// While two types of strategies may not highly differ with respect to their fields, the stacking of DeFiBlocks
    /// components & connections they provide access to likely do. This difference in wiring is why the Strategy is a
    /// resource - because the Type and uniqueness of composition of a given Strategy must be preserved as that is its
    /// distinguishing factor. These qualities are preserved by restricting the party who can construct it, which for
    /// resources is within the contract that defines it.
    ///
    /// TODO: Consider making Sink/Source multi-asset - we could then make Strategy a composite Sink, Source & do away
    ///     with the added layer of abstraction introduced by a StrategyComposer.
    access(all) resource interface Strategy : DFB.IdentifiableResource, Burner.Burnable {
        /// Returns the type of Vaults that this Strategy instance can handle
        access(all) view fun getSupportedCollateralTypes(): {Type: Bool}
        /// Returns whether the provided Vault type is supported by this Strategy instance
        access(all) view fun isSupportedCollateralType(_ type: Type): Bool {
            return self.getSupportedCollateralTypes()[type] ?? false
        }
        /// Returns the balance of the given token available for withdrawal. Note that this may be an estimate due to
        /// the lack of guarantees inherent to DeFiBlocks Sources
        access(all) fun availableBalance(ofToken: Type): UFix64
        /// Deposits up to the balance of the referenced Vault into this Strategy
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                self.isSupportedCollateralType(from.getType()):
                "Cannot deposit Vault \(from.getType().identifier) to Strategy \(self.getType().identifier) - unsupported deposit type"
            }
        }
        /// Withdraws from this Strategy and returns the resulting Vault of the requested token Type
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            post {
                result.getType() == ofToken:
                "Invalid Vault returns - requests \(ofToken.identifier) but returned \(result.getType().identifier)"
            }
        }
    }
}
