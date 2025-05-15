import "FungibleToken"
import "Burner"

import "DFB"
import "SwapStack"

access(all) contract MockSwapper {

    access(all) struct Swapper : DFB.Swapper {
        /// An optional identifier allowing protocols to identify stacked connector operations by defining a protocol-
        /// specific Identifier to associated connectors on construction
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(self) let inVault: {DFB.Sink, DFB.Source}
        access(self) let outVault: {DFB.Sink, DFB.Source}
        access(self) let oracle: {DFB.PriceOracle}

        init(inVault: {DFB.Sink, DFB.Source}, outVault: {DFB.Sink, DFB.Source}, oracle: {DFB.PriceOracle}, uniqueID: {DFB.UniqueIdentifier}?) {
            self.inVault = inVault
            self.outVault = outVault
            self.oracle = oracle
            self.uniqueID = uniqueID
        }

        /// The type of Vault this Swapper accepts when performing a swap
        access(all) view fun inVaultType(): Type {
            return self.inVault.getSinkType()
        }

        /// The type of Vault this Swapper provides when performing a swap
        access(all) view fun outVaultType(): Type {
            return self.outVault.getSourceType()
        }

        /// The estimated amount required to provide a Vault with the desired output balance
        access(all) fun amountIn(forDesired: UFix64, reverse: Bool): {DFB.Quote} {
            return self._estimate(amount: forDesired, out: false, reverse: reverse)
        }

        /// The estimated amount delivered out for a provided input balance
        access(all) fun amountOut(forProvided: UFix64, reverse: Bool): {DFB.Quote} {
            return self._estimate(amount: forProvided, out: true, reverse: reverse)
        }

        /// Performs a swap taking a Vault of type inVault, outputting a resulting outVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        access(all) fun swap(quote: {DFB.Quote}?, inVault: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <- self._swap(<-inVault, reverse: false)
        }

        /// Performs a swap taking a Vault of type outVault, outputting a resulting inVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        access(all) fun swapBack(quote: {DFB.Quote}?, residual: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <- self._swap(<-residual, reverse: true)
        }

        /// Internal estimator returning a quote for the amount in/out and in the desired direction
        access(self) fun _estimate(amount: UFix64, out: Bool, reverse: Bool): {DFB.Quote} {
            let price = reverse 
                ? self.oracle.price(ofToken: self.outVaultType()) / self.oracle.price(ofToken: self.inVaultType())
                : self.oracle.price(ofToken: self.inVaultType()) / self.oracle.price(ofToken: self.outVaultType())
            return SwapStack.BasicQuote(
                inVault: reverse ? self.outVaultType() : self.inVaultType(),
                outVault: reverse ? self.inVaultType() : self.outVaultType(),
                inAmount: out ? amount : amount / price,
                outAmount: out ? amount * price : amount
            )
        }

        access(self) fun _swap(_ from: @{FungibleToken.Vault}, reverse: Bool): @{FungibleToken.Vault} {
            let inAmount = from.balance
            if reverse {
                self.outVault.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            } else {
                self.inVault.depositCapacity(from: &from as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
            }
            Burner.burn(<-from)

            let outAmount = self.amountOut(forProvided: inAmount, reverse: reverse).outAmount
            var outVault: @{FungibleToken.Vault}? <- nil
            if reverse {
                outVault <-! self.inVault.withdrawAvailable(maxAmount: outAmount)
            } else {
                outVault <-! self.outVault.withdrawAvailable(maxAmount: outAmount)
            }
            let withdrawn = (outVault?.balance)!
            assert(withdrawn == outAmount,
                message: "MockSwapper outVault returned invalid balance - expected \(outAmount), received \(withdrawn)")
            return <- outVault!
        }
    }
    
}