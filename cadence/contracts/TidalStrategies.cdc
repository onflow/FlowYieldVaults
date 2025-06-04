import "FungibleToken"

import "DFB"

access(all) contract TidalStrategies {
    
    access(self) let strategies: {UInt64: {Strategy}}

    access(all) view fun getCollateralTypes(forStrategy: UInt64): [Type]? {
        return self.strategies[forStrategy]?.getSupportedCollateralTypes() ?? nil
    }

    access(all) view fun isSupportedCollateralType(_ type: Type, forStrategy: UInt64): Bool? {
        return self.strategies[forStrategy]?.isSupportedCollateralType(type) ?? nil
    }

    access(all) fun createStrategy(number: UInt64, vault: @{FungibleToken.Vault}): {Strategy} {
        destroy vault // TODO: Update vault handling
        return DummyStrategy(id: DFB.UniqueIdentifier())
    }

    access(all) struct interface StrategyBuilder {
        access(all) fun createStrategy(funds: @{FungibleToken.Vault}): {Strategy}
    }
    
    access(all) struct interface StrategyInfo {
        access(all) view fun getSupportedCollateralTypes(): [Type]
        access(all) view fun isSupportedCollateralType(_ type: Type): Bool
    }

    access(all) struct Strategy : StrategyInfo, DFB.Sink, DFB.Source  {}

    access(all) struct DummyStrategy : Strategy {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) var sink: {DFB.Sink}? // TODO: update from optional
        access(self) var source: {DFB.Source}? // TODO: update from optional

        init(id: DFB.UniqueIdentifier?) {
            self.uniqueID = id
            self.sink = nil
            self.source = nil
        }

        access(all) view fun getSupportedCollateralTypes(): [Type] {
            return [self.sink!.getSinkType()]
        }

        access(all) view fun isSupportedCollateralType(_ type: Type): Bool {
            return self.sink!.getSinkType() == type
        }

        /// Returns the Vault type accepted by this Sink
        access(all) view fun getSinkType(): Type {
            return self.sink!.getSinkType()
        }
        /// Returns an estimate of how much can be withdrawn from the depositing Vault for this Sink to reach capacity
        access(all) fun minimumCapacity(): UFix64 {
            return self.sink!.minimumCapacity()
        }
        /// Deposits up to the Sink's capacity from the provided Vault
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.sink!.depositCapacity(from: from)
        }
        /// Returns the Vault type provided by this Source
        access(all) view fun getSourceType(): Type {
            return self.source!.getSourceType()
        }
        /// Returns an estimate of how much of the associated Vault Type can be provided by this Source
        access(all) fun minimumAvailable(): UFix64 {
            return self.source!.minimumAvailable()
        }
        /// Withdraws the lesser of maxAmount or minimumAvailable(). If none is available, an empty Vault should be
        /// returned
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- self.source!.withdrawAvailable(maxAmount: maxAmount)
        }
    }

    init() {
        self.strategies = {}
    }
}