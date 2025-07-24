import "FungibleToken"
import "Burner"

import "MockOracle"

import "DeFiActions"
import "SwapStack"
import "TidalProtocolUtils"

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
        access(contract) let uniqueID: DeFiActions.UniqueIdentifier?
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
            log("swap")
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

            let uintOutTokenPrice = TidalProtocolUtils.toUInt256Balance(outTokenPrice)
            let uintInTokenPrice = TidalProtocolUtils.toUInt256Balance(inTokenPrice)

            let uintPrice = reverse ? TidalProtocolUtils.div(uintOutTokenPrice, uintInTokenPrice) : TidalProtocolUtils.div(uintInTokenPrice, uintOutTokenPrice)
            let price = TidalProtocolUtils.toUFix64Balance(uintPrice)

            if amount == UFix64.max {
                return SwapStack.BasicQuote(
                    inType: reverse ? self.outType() : self.inType(),
                    outType: reverse ? self.inType() : self.outType(),
                    inAmount: UFix64.max,
                    outAmount: UFix64.max
                )
            }

            let uintAmount = TidalProtocolUtils.toUInt256Balance(amount)
            let uintInAmount = out ? uintAmount : TidalProtocolUtils.div(uintAmount, uintPrice)
            let uintOutAmount = out ? TidalProtocolUtils.mul(uintAmount, uintPrice) : uintAmount

            let inAmount = TidalProtocolUtils.toUFix64Balance(uintInAmount)
            let outAmount = TidalProtocolUtils.toUFix64Balance(uintOutAmount)
            log("inAmount")
            log(uintInAmount)
            log("outAmount")
            log(uintOutAmount)

            return SwapStack.BasicQuote(
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
            log("swapper capacity")
            log(from.balance)
            swapInVault.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})            
            log("afterDepositCapacity")
            Burner.burn(<-from)
            let outAmount = self.quoteOut(forProvided: inAmount, reverse: reverse).outAmount
            log("outAmount")
            log(outAmount)
            var outVault <- swapOutVault.withdrawAvailable(maxAmount: outAmount)
            log("after out vault")
            log(outVault.balance)

            assert(outVault.balance == outAmount,
            message: "MockSwapper outVault returned invalid balance - expected \(outAmount), received \(outVault.balance)")

            return <- outVault
        }
    }

    init() {
        self.liquidityConnectors = {}
    }    
}
