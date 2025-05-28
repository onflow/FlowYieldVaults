import "Burner"
import "FungibleToken"

import "DFB"

/// SwapStack
///
/// This contract defines DeFiBlocks Sink & Source connector implementations for use with DeFi protocols. These
/// connectors can be used alone or in conjunction with other DeFiBlocks connectors to create complex DeFi workflows.
///
access(all) contract SwapStack {

    /// A simple implementation of DFB.Quote allowing callers of Swapper.quoteIn() and .quoteOut() to cache quoted
    /// amount in and/or out.
    ///
    access(all) struct BasicQuote : DFB.Quote {
        access(all) let inType: Type
        access(all) let outType: Type
        access(all) let inAmount: UFix64
        access(all) let outAmount: UFix64

        init(
            inType: Type,
            outType: Type,
            inAmount: UFix64,
            outAmount: UFix64
        ) {
            self.inType = inType
            self.outType = outType
            self.inAmount = inAmount
            self.outAmount = outAmount
        }
    }

    /// A MultiSwapper specific DFB.Quote implementation allowing for callers to set the Swapper used in MultiSwapper
    /// that should fulfill the Swap
    ///
    access(all) struct MultiSwapperQuote : DFB.Quote {
        access(all) let inType: Type
        access(all) let outType: Type
        access(all) let inAmount: UFix64
        access(all) let outAmount: UFix64
        access(all) let swapperIndex: Int

        init(
            inType: Type,
            outType: Type,
            inAmount: UFix64,
            outAmount: UFix64,
            swapperIndex: Int
        ) {
            pre {
                swapperIndex >= 0: "Invalid swapperIndex - provided \(swapperIndex) is less than 0"
            }
            self.inType = inType
            self.outType = outType
            self.inAmount = inAmount
            self.outAmount = outAmount
            self.swapperIndex = swapperIndex
        }
    }

    /// A Swapper implementation routing swap requests to the optimal contained Swapper. Once constructed, this can
    /// effectively be used as an aggregator across all contained Swapper implementations, though it is limited to the
    /// routes and pools exposed by its inner Swappers as well as runtime computation limits.
    ///
    access(all) struct MultiSwapper : DFB.Swapper {
        access(all) let swappers: [{DFB.Swapper}]
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        access(self) let inVault: Type
        access(self) let outVault: Type

        init(
            inVault: Type,
            outVault: Type,
            swappers: [{DFB.Swapper}],
            uniqueID: DFB.UniqueIdentifier?
        ) {
            pre {
                inVault.getType().isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Invalid inVault type - \(inVault.identifier) is not a FungibleToken Vault implementation"
                outVault.getType().isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Invalid outVault type - \(outVault.identifier) is not a FungibleToken Vault implementation"
            }
            for swapper in swappers {
                assert(swapper.inType() == inVault,
                    message: "Mismatched inVault \(inVault.identifier) - Swapper \(swapper.getType().identifier) accepts \(swapper.inType().identifier)")
                assert(swapper.outType() == outVault,
                    message: "Mismatched outVault \(outVault.identifier) - Swapper \(swapper.getType().identifier) accepts \(swapper.outType().identifier)")
            }
            self.inVault = inVault
            self.outVault = outVault
            self.uniqueID = uniqueID
            self.swappers = swappers
        }

        /// The type of Vault this Swapper accepts when performing a swap
        access(all) view fun inType(): Type {
            return self.inVault
        }

        /// The type of Vault this Swapper provides when performing a swap
        access(all) view fun outType(): Type  {
            return self.outVault
        }

        /// The estimated amount required to provide a Vault with the desired output balance
        access(all) fun quoteIn(forDesired: UFix64, reverse: Bool): {DFB.Quote} {
            let estimate = self._estimate(amount: forDesired, out: true, reverse: reverse)
            return MultiSwapperQuote(
                inType: reverse ? self.outType() : self.inType(),
                outType: reverse ? self.inType() : self.outType(),
                inAmount: estimate[1],
                outAmount: forDesired,
                swapperIndex: Int(estimate[0])
            )
        }

        /// The estimated amount delivered out for a provided input balance
        access(all) fun quoteOut(forProvided: UFix64, reverse: Bool): {DFB.Quote} {
            let estimate = self._estimate(amount: forProvided, out: true, reverse: reverse)
            return MultiSwapperQuote(
                inType: reverse ? self.outType() : self.inType(),
                outType: reverse ? self.inType() : self.outType(),
                inAmount: forProvided,
                outAmount: estimate[1],
                swapperIndex: Int(estimate[0])
            )
        }
        /// Performs a swap taking a Vault of type inVault, outputting a resulting outVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols. If the provided quote is not a MultiSwapperQuote, a new quote is
        /// requested and the optimal Swapper used to fulfill the swap.
        /// NOTE: providing a Quote does not guarantee the fulfilled swap will enforce the quote's defined outAmount
        access(all) fun swap(quote: {DFB.Quote}?, inVault: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <-self._swap(quote: quote, from: <-inVault, reverse: false)
        }

        /// Performs a swap taking a Vault of type outVault, outputting a resulting inVault. Implementations may choose
        /// to swap along a pre-set path or an optimal path of a set of paths or even set of contained Swappers adapted
        /// to use multiple Flow swap protocols.
        /// NOTE: providing a Quote does not guarantee the fulfilled swap will enforce the quote's defined outAmount
        access(all) fun swapBack(quote: {DFB.Quote}?, residual: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            return <-self._swap(quote: quote, from: <-residual, reverse: true)
        }

        /// Returns the the index of the optimal Swapper (result[0]) and the associated amountOut or amountIn (result[0])
        /// as a UFix64 array
        access(self) fun _estimate(amount: UFix64, out: Bool, reverse: Bool): [UFix64; 2] {
            var res: [UFix64; 2] = [0.0, 0.0]
            for i, swapper in self.swappers {
                // call the appropriate estimator
                let estimate = out
                    ? swapper.quoteOut(forProvided: amount, reverse: true).outAmount
                    : swapper.quoteIn(forDesired: amount, reverse: true).inAmount
                if (out ? res[1] < estimate : estimate < res[1]) {
                    // take minimum for in, maximum for out
                    res = [UFix64(i), estimate]
                }
            }
            return res
        }

        /// Swaps the provided Vault in the defined direction. If the quote is not a MultiSwapperQuote, a new quote is
        /// requested and the current optimal Swapper used to fulfill the swap.
        access(self) fun _swap(quote: {DFB.Quote}?, from: @{FungibleToken.Vault}, reverse: Bool): @{FungibleToken.Vault} {
            var multiQuote = quote as? MultiSwapperQuote
            if multiQuote != nil || multiQuote!.swapperIndex > self.swappers.length {
                multiQuote = self.quoteOut(forProvided: from.balance, reverse: reverse) as! MultiSwapperQuote
            }
            let optimalSwapper = &self.swappers[multiQuote!.swapperIndex] as &{DFB.Swapper}
            if reverse {
                return <- optimalSwapper.swapBack(quote: multiQuote, residual: <-from)
            } else {
                return <- optimalSwapper.swap(quote: multiQuote, inVault: <-from)
            }
        }
    }

    /// SwapSink DeFiBlocks connector that deposits the resulting post-conversion currency of a token swap to an inner
    /// DeFiBlocks Sink, sourcing funds from a deposited Vault of a pre-set Type.
    ///
    access(all) struct SwapSink : DFB.Sink {
        access(self) let swapper: {DFB.Swapper}
        access(self) let sink: {DFB.Sink}
        access(contract) let uniqueID: DFB.UniqueIdentifier?

        init(swapper: {DFB.Swapper}, sink: {DFB.Sink}, uniqueID: DFB.UniqueIdentifier?) {
            pre {
                swapper.outType() == sink.getSinkType():
                "Swapper outputs \(swapper.outType().identifier) but Sink takes \(sink.getSinkType().identifier) - "
                    .concat("Ensure the provided Swapper outputs a Vault Type compatible with the provided Sink")
            }
            self.swapper = swapper
            self.sink = sink
            self.uniqueID = uniqueID
        }

        access(all) view fun getSinkType(): Type {
            return self.swapper.inType()
        }

        access(all) fun minimumCapacity(): UFix64 {
            return self.swapper.quoteIn(forDesired: self.sink.minimumCapacity(), reverse: false).inAmount
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let limit = self.sink.minimumCapacity()
            if from.balance == 0.0 || limit == 0.0 || !from.getType().isInstance(self.getSinkType()) {
                return // nothing to swap from, no capacity to ingest, invalid Vault type - do nothing
            }

            let quote = self.swapper.quoteIn(forDesired: from.balance, reverse: false)
            let sinkLimit = quote.inAmount
            let swapVault <- from.createEmptyVault()

            if sinkLimit < swapVault.balance {
                // The sink is limited to fewer tokens than we have available. Only swap
                // the amount we need to meet the sink limit.
                swapVault.deposit(from: <-from.withdraw(amount: sinkLimit))
            } else {
                // The sink can accept all of the available tokens, so we swap everything
                swapVault.deposit(from: <-from.withdraw(amount: from.balance))
            }

            let swappedTokens <- self.swapper.swap(quote: quote, inVault: <-swapVault)
            self.sink.depositCapacity(from: &swappedTokens as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

            if swappedTokens.balance > 0.0 {
                from.deposit(from: <-self.swapper.swapBack(quote: nil, residual: <-swappedTokens))
            } else {
                Burner.burn(<-swappedTokens)
            }
        }
    }

    /// SwapSource DeFiBlocks connector that returns post-conversion currency, sourcing pre-converted funds from an inner
    /// DeFiBlocks Source
    ///
    access(all) struct SwapSource : DFB.Source {
        access(self) let swapper: {DFB.Swapper}
        access(self) let source: {DFB.Source}
        access(contract) let uniqueID: DFB.UniqueIdentifier?

        init(swapper: {DFB.Swapper}, source: {DFB.Source}, uniqueID: DFB.UniqueIdentifier) {
            pre {
                source.getSourceType() == swapper.inType():
                "Source outputs \(source.getSourceType().identifier) but Swapper takes \(swapper.inType().identifier) - "
                    .concat("Ensure the provided Source outputs a Vault Type compatible with the provided Swapper")
            }
            self.swapper = swapper
            self.source = source
            self.uniqueID = uniqueID
        }

        access(all) view fun getSourceType(): Type {
            return self.swapper.outType()
        }

        access(all) fun minimumAvailable(): UFix64 {
            // estimate post-conversion currency based on the source's pre-conversion balance available
            let availableIn = self.source.minimumAvailable()
            return availableIn > 0.0
                ? self.swapper.quoteOut(forProvided: availableIn, reverse: false).outAmount
                : 0.0
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let minimumAvail = self.minimumAvailable()
            if minimumAvail == 0.0 || maxAmount == 0.0 {
                return <- SwapStack.getEmptyVault(self.getSourceType())
            }

            // expect output amount as the lesser between the amount available and the maximum amount
            var amountOut = minimumAvail < maxAmount ? minimumAvail : maxAmount

            // find out how much liquidity to gather from the inner Source
            let availableIn = self.source.minimumAvailable()
            let quote = self.swapper.quoteIn(forDesired: amountOut, reverse: false)
            let quoteIn = availableIn < quote.inAmount ? availableIn : quote.inAmount

            let sourceLiquidity <- self.source.withdrawAvailable(maxAmount: quoteIn)
            if sourceLiquidity.balance == 0.0 {
                Burner.burn(<-sourceLiquidity)
                return <- SwapStack.getEmptyVault(self.getSourceType())
            }
            let outVault <- self.swapper.swap(quote: quote, inVault: <-sourceLiquidity)
            if outVault.balance > amountOut {
                // TODO - what to do if excess is found?
                //  - can swapBack() but can't deposit to the inner source and can't return an unsupported Vault type
                //      -> could make inner {Source} an intersection {Source, Sink}
            }
            return <- outVault
        }
    }

    /// Returns an empty Vault of the given Type, sourcing the new Vault from the defining FT contract
    access(self) fun getEmptyVault(_ vaultType: Type): @{FungibleToken.Vault} {
        return <- getAccount(vaultType.address!)
            .contracts
            .borrow<&{FungibleToken}>(name: vaultType.contractName!)!
            .createEmptyVault(vaultType: vaultType)
    }
}
