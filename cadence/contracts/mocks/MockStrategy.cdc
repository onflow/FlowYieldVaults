import "FungibleToken"
import "FlowToken"

import "DFBUtils"
import "DFB"

import "StrategyComposer"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MockStrategy : StrategyComposer {

    access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
        return { Type<@Strategy>(): true }
    }
    access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
        return { Type<@FlowToken.Vault>(): true }
    }
    access(all) view fun getStrategyFundingMinimum(forStrategy: Type): UFix64? {
        switch forStrategy {
            case Type<@Strategy>():
                return 0.0
            default:
                return nil
        }
    }
    access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
        return { Type<@FlowToken.Vault>(): true }
    }
    access(all) fun createStrategy(
        _ type: Type,
        uniqueID: DFB.UniqueIdentifier,
        withFunds: @{FungibleToken.Vault}
    ): @{StrategyComposer.Strategy} {
        let id = DFB.UniqueIdentifier()
        let strat <- create Strategy(
            id: id,
            sink: Sink(id),
            source: Source(id)
        )
        strat.deposit(from: &withFunds as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
        destroy withFunds
        return <- strat
    }
    
    access(all) struct Sink : DFB.Sink {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        init(_ id: DFB.UniqueIdentifier?) {
            self.uniqueID = id
        }
        access(all) view fun getSinkType(): Type {
            return Type<@FlowToken.Vault>()
        }
        access(all) fun minimumCapacity(): UFix64 {
            return 0.0
        }
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            return
        }
    }
    access(all) struct Source : DFB.Source {
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        init(_ id: DFB.UniqueIdentifier?) {
            self.uniqueID = id
        }
        access(all) view fun getSourceType(): Type {
            return Type<@FlowToken.Vault>()
        }
        access(all) fun minimumAvailable(): UFix64 {
            return 0.0
        }
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- DFBUtils.getEmptyVault(self.getSourceType())
        }
    }

    access(all) resource Strategy : StrategyComposer.Strategy {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) var sink: {DFB.Sink}
        access(self) var source: {DFB.Source}

        init(id: DFB.UniqueIdentifier?, sink: {DFB.Sink}, source: {DFB.Source}) {
            self.uniqueID = id
            self.sink = sink
            self.source = source
        }

        access(all) view fun getSupportedCollateralTypes(): {Type: Bool} {
            return {self.sink.getSinkType(): true }
        }

        access(all) view fun isSupportedCollateralType(_ type: Type): Bool {
            return self.sink.getSinkType() == type
        }

        /// Returns the amount available for withdrawal via the inner Source
        access(all) fun availableBalance(ofToken: Type): UFix64 {
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable() : 0.0
        }

        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.sink.depositCapacity(from: from)
        }

        /// Withdraws up to the max amount, returning the withdrawn Vault. If the requested token type is unsupported,
        /// an empty Vault is returned.
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            if ofToken != self.source.getSourceType() {
                return <- DFBUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }

        access(contract) fun burnCallback() {} // no-op
    }
}
