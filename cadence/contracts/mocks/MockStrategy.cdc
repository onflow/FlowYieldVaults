import "FungibleToken"
import "FlowToken"

import "DeFiActionsUtils"
import "DeFiActions"

import "TidalYield"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MockStrategy {

    access(all) let IssuerStoragePath : StoragePath
    
    access(all) struct Sink : DeFiActions.Sink {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        init(_ id: DeFiActions.UniqueIdentifier?) {
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
    access(all) struct Source : DeFiActions.Source {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        init(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
        access(all) view fun getSourceType(): Type {
            return Type<@FlowToken.Vault>()
        }
        access(all) fun minimumAvailable(liquidation: Bool): UFix64 {
            return 0.0
        }
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- DeFiActionsUtils.getEmptyVault(self.getSourceType())
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

    access(all) resource Strategy : TidalYield.Strategy {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) var sink: {DeFiActions.Sink}
        access(self) var source: {DeFiActions.Source}

        init(id: DeFiActions.UniqueIdentifier?, sink: {DeFiActions.Sink}, source: {DeFiActions.Source}) {
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
            return ofToken == self.source.getSourceType() ? self.source.minimumAvailable(liquidation: true) : 0.0
        }

        /// Deposits up to the inner Sink's capacity from the provided authorized Vault reference
        access(all) fun deposit(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.sink.depositCapacity(from: from)
        }

        /// Withdraws up to the max amount, returning the withdrawn Vault. If the requested token type is unsupported,
        /// an empty Vault is returned.
        access(FungibleToken.Withdraw) fun withdraw(maxAmount: UFix64, ofToken: Type): @{FungibleToken.Vault} {
            if ofToken != self.source.getSourceType() {
                return <- DeFiActionsUtils.getEmptyVault(ofToken)
            }
            return <- self.source.withdrawAvailable(maxAmount: maxAmount)
        }

        access(contract) fun burnCallback() {} // no-op

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

    access(all) resource StrategyComposer : TidalYield.StrategyComposer {
        access(all) view fun getComposedStrategyTypes(): {Type: Bool} {
            return { Type<@Strategy>(): true }
        }
        access(all) view fun getSupportedInitializationVaults(forStrategy: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }
        access(all) view fun getSupportedInstanceVaults(forStrategy: Type, initializedWith: Type): {Type: Bool} {
            return { Type<@FlowToken.Vault>(): true }
        }
        access(all) fun createStrategy(
            _ type: Type,
            uniqueID: DeFiActions.UniqueIdentifier,
            withFunds: @{FungibleToken.Vault}
        ): @{TidalYield.Strategy} {
            let id = DeFiActions.createUniqueIdentifier()
            let strat <- create Strategy(
                id: id,
                sink: Sink(id),
                source: Source(id)
            )
            strat.deposit(from: &withFunds as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            destroy withFunds
            return <- strat
        }
    }

    /// This resource enables the issuance of StrategyComposers, thus safeguarding the issuance of Strategies which
    /// may utilize resource consumption (i.e. account storage). Since TracerStrategy creation consumes account storage
    /// via configured AutoBalancers
    access(all) resource StrategyComposerIssuer : TidalYield.StrategyComposerIssuer {
        access(all) view fun getSupportedComposers(): {Type: Bool} {
            return { Type<@StrategyComposer>(): true }
        }
        access(all) fun issueComposer(_ type: Type): @{TidalYield.StrategyComposer} {
            switch type {
            case Type<@StrategyComposer>():
                return <- create StrategyComposer()
            default:
                panic("Unsupported StrategyComposer requested: \(type.identifier)")
            }
        }
    }

    init() {
        self.IssuerStoragePath = StoragePath(identifier: "MockStrategyComposerIssuer_\(self.account.address)")!

        self.account.storage.save(<-create StrategyComposerIssuer(), to: self.IssuerStoragePath)
    }
}
