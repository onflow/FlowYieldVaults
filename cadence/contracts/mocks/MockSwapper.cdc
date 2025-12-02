import "FungibleToken"
import "Burner"

import "MockOracle"

import "DeFiActions"
import "SwapConnectors"
import "FlowCreditMarketMath"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MockSwapper {

    /// Mocked liquidity sources
    access(self) let liquidityConnectors: {Type: {DeFiActions.Sink, DeFiActions.Source}}

    /// Mock setter enabling the configuration of liquidity sources used by mock swappers
    access(all) fun setLiquidityConnector(_ connector: {DeFiActions.Sink, DeFiActions.Source}) {
        pre {
            connector.getSinkType() == connector.getSourceType():
            "Connector sink Type \(connector.getSinkType().identifier) != connector source Type \(connector.getSourceType().identifier)"
        }
        self.liquidityConnectors[connector.getSinkType()] = connector
    }

    // Swapper
    //
    /// Mocked DeFiActions Swapper implementation. Be sure to set connectors for Vaults you wish to handle via this mock
    /// in MockSwapper.liquidityConnectors via .setLiquidityConnector before instantiating mocks
    access(all) struct Swapper : DeFiActions.Swapper {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let inVault: Type
        access(self) let outVault: Type
        access(self) let oracle: {DeFiActions.PriceOracle}

        init(inVault: Type, outVault: Type, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                MockSwapper.liquidityConnectors[inVault] != nil:
                "Invalid inVault - \(inVault.identifier) does not have a MockSwapper connector to handle funds"
                MockSwapper.liquidityConnectors[outVault] != nil:
                "Invalid outVault - \(outVault.identifier) does not have a MockSwapper connector to handle funds"
            }
            self.inVault = inVault
            self.outVault = outVault
            self.oracle = MockOracle.PriceOracle()
            self.uniqueID = uniqueID
        }

        /// The type of Vault this Swapper accepts when performing a swap
        access(all) view fun inType(): Type {
            return self.inVault
        }

        /// The type of Vault this Swapper provides when performing a swap
        access(all) view fun outType(): Type {
            return self.outVault
        }

        /// The estimated amount required to provide a Vault with the desired output balance, sourcing pricing from the
        /// mocked oracle
        access(all) fun quoteIn(forDesired: UFix64, reverse: Bool): {DeFiActions.Quote} {
            return self._estimate(amount: forDesired, out: false, reverse: reverse)
        }

        /// The estimated amount delivered out for a provided input balance, sourcing pricing from the mocked oracle
        access(all) fun quoteOut(forProvided: UFix64, reverse: Bool): {DeFiActions.Quote} {
            return self._estimate(amount: forProvided, out: true, reverse: reverse)
        }

        /// Performs a swap taking a Vault of type inVault, outputting a resulting outVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        /// NOTE: This mock sources pricing data from the mocked oracle, allowing for pricing to be manually manipulated
        /// for testing and demonstration purposes
        access(all) fun swap(quote: {DeFiActions.Quote}?, inVault: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <- self._swap(<-inVault, reverse: false)
        }

        /// Performs a swap taking a Vault of type outVault, outputting a resulting inVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        /// NOTE: This mock sources pricing data from the mocked oracle, allowing for pricing to be manually manipulated
        /// for testing and demonstration purposes
        access(all) fun swapBack(quote: {DeFiActions.Quote}?, residual: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <- self._swap(<-residual, reverse: true)
        }

        /// Internal estimator returning a quote for the amount in/out and in the desired direction
        access(self) fun _estimate(amount: UFix64, out: Bool, reverse: Bool): {DeFiActions.Quote} {
            let outTokenPrice = self.oracle.price(ofToken: self.outType())
            ?? panic("Price for token \(self.outType().identifier) is currently unavailable")
            let inTokenPrice = self.oracle.price(ofToken: self.inType())
            ?? panic("Price for token \(self.inType().identifier) is currently unavailable")

            let uintOutTokenPrice = FlowCreditMarketMath.toUFix128(outTokenPrice)
            let uintInTokenPrice = FlowCreditMarketMath.toUFix128(inTokenPrice)

            // the original formula is correct, but lacks precision
            // let price = reverse  ? outTokenPrice / inTokenPrice : inTokenPrice / outTokenPrice
            let uintPrice = reverse ? FlowCreditMarketMath.div(uintOutTokenPrice, uintInTokenPrice) : FlowCreditMarketMath.div(uintInTokenPrice, uintOutTokenPrice)

            if amount == UFix64.max {
                return SwapConnectors.BasicQuote(
                    inType: reverse ? self.outType() : self.inType(),
                    outType: reverse ? self.inType() : self.outType(),
                    inAmount: UFix64.max,
                    outAmount: UFix64.max
                )
            }

            let uintAmount = FlowCreditMarketMath.toUFix128(amount)
            let uintInAmount = out ? uintAmount : FlowCreditMarketMath.div(uintAmount, uintPrice)
            let uintOutAmount = out ? uintAmount * uintPrice : uintAmount

            let inAmount = FlowCreditMarketMath.toUFix64Round(uintInAmount)
            let outAmount = FlowCreditMarketMath.toUFix64Round(uintOutAmount)

            return SwapConnectors.BasicQuote(
                inType: reverse ? self.outVault : self.inVault,
                outType: reverse ? self.inVault : self.outVault,
                inAmount: inAmount,
                outAmount: outAmount
            )
        }

        access(self) fun _swap(_ from: @{FungibleToken.Vault}, reverse: Bool): @{FungibleToken.Vault} {
            let inAmount = from.balance
            var swapInVault = reverse ? MockSwapper.liquidityConnectors[from.getType()]! : MockSwapper.liquidityConnectors[self.inType()]!
            var swapOutVault = reverse ? MockSwapper.liquidityConnectors[self.inType()]! : MockSwapper.liquidityConnectors[self.outType()]!
            swapInVault.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})            
            Burner.burn(<-from)
            let outAmount = self.quoteOut(forProvided: inAmount, reverse: reverse).outAmount
            var outVault <- swapOutVault.withdrawAvailable(maxAmount: outAmount)

            assert(outVault.balance == outAmount,
            message: "MockSwapper outVault returned invalid balance - expected \(outAmount), received \(outVault.balance)")

            return <- outVault
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

    init() {
        self.liquidityConnectors = {}
    }    
}

