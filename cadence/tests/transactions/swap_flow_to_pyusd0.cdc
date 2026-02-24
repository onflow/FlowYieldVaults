import "FungibleToken"
import "FungibleTokenMetadataViews"
import "ViewResolver"
import "FlowToken"
import "EVM"
import "FlowEVMBridgeUtils"
import "FlowEVMBridgeConfig"
import "ScopedFTProviders"

/// Funds the signer with PYUSD0 by swapping FLOW on EVM via UniswapV3, then bridging to Cadence.
///
/// Steps:
///   1. Deposit FLOW to the signer's COA
///   2. Wrap FLOW to WFLOW
///   3. Swap WFLOW -> PYUSD0 via UniswapV3 exactInput
///   4. Bridge PYUSD0 from EVM to Cadence
///
/// @param flowAmount: Amount of FLOW to swap for PYUSD0
///
transaction(flowAmount: UFix64) {

    let coa: auth(EVM.Owner, EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount
    let scopedProvider: @ScopedFTProviders.ScopedFTProvider
    let receiver: &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability, CopyValue) &Account) {
        // Borrow COA
        self.coa = signer.storage.borrow<auth(EVM.Owner, EVM.Call, EVM.Bridge) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA at /storage/evm")

        // Withdraw FLOW and deposit to COA
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("No FlowToken vault")
        let deposit <- flowVault.withdraw(amount: flowAmount) as! @FlowToken.Vault
        self.coa.deposit(from: <-deposit)

        // Set up scoped fee provider for bridging
        let approxFee = FlowEVMBridgeUtils.calculateBridgeFee(bytes: 400_000)
        if signer.storage.type(at: FlowEVMBridgeConfig.providerCapabilityStoragePath) == nil {
            let providerCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>(
                /storage/flowTokenVault
            )
            signer.storage.save(providerCap, to: FlowEVMBridgeConfig.providerCapabilityStoragePath)
        }
        let providerCapCopy = signer.storage.copy<Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Provider}>>(
            from: FlowEVMBridgeConfig.providerCapabilityStoragePath
        ) ?? panic("Invalid provider capability")
        self.scopedProvider <- ScopedFTProviders.createScopedFTProvider(
            provider: providerCapCopy,
            filters: [ScopedFTProviders.AllowanceFilter(approxFee)],
            expiration: getCurrentBlock().timestamp + 1000.0
        )

        // Set up PYUSD0 vault if needed
        let pyusd0Type = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!
        let tokenContractAddress = FlowEVMBridgeUtils.getContractAddress(fromType: pyusd0Type)
            ?? panic("Could not get PYUSD0 contract address")
        let tokenContractName = FlowEVMBridgeUtils.getContractName(fromType: pyusd0Type)
            ?? panic("Could not get PYUSD0 contract name")
        let viewResolver = getAccount(tokenContractAddress).contracts.borrow<&{ViewResolver}>(name: tokenContractName)
            ?? panic("Could not borrow ViewResolver for PYUSD0")
        let vaultData = viewResolver.resolveContractView(
            resourceType: pyusd0Type,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for PYUSD0")
        if signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath) == nil {
            signer.storage.save(<-vaultData.createEmptyVault(), to: vaultData.storagePath)
            signer.capabilities.unpublish(vaultData.receiverPath)
            signer.capabilities.unpublish(vaultData.metadataPath)
            let receiverCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            let metadataCap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(vaultData.storagePath)
            signer.capabilities.publish(receiverCap, at: vaultData.receiverPath)
            signer.capabilities.publish(metadataCap, at: vaultData.metadataPath)
        }
        self.receiver = signer.storage.borrow<&{FungibleToken.Vault}>(from: vaultData.storagePath)
            ?? panic("Could not borrow PYUSD0 vault")
    }

    execute {
        let wflowAddr = EVM.addressFromString("0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e")
        let pyusd0Addr = EVM.addressFromString("0x99aF3EeA856556646C98c8B9b2548Fe815240750")
        let routerAddr = EVM.addressFromString("0xeEDC6Ff75e1b10B903D9013c358e446a73d35341")
        let zeroValue = EVM.Balance(attoflow: 0)

        // 1. Wrap FLOW -> WFLOW
        let flowBalance = EVM.Balance(attoflow: 0)
        flowBalance.setFLOW(flow: flowAmount)
        let wrapRes = self.coa.call(
            to: wflowAddr,
            data: EVM.encodeABIWithSignature("deposit()", []),
            gasLimit: 100_000,
            value: flowBalance
        )
        assert(wrapRes.status == EVM.Status.successful, message: "WFLOW wrap failed: ".concat(wrapRes.errorMessage))

        // 2. Approve UniV3 Router to spend WFLOW
        let amountEVM = FlowEVMBridgeUtils.convertCadenceAmountToERC20Amount(flowAmount, erc20Address: wflowAddr)
        let approveRes = self.coa.call(
            to: wflowAddr,
            data: EVM.encodeABIWithSignature("approve(address,uint256)", [routerAddr, amountEVM]),
            gasLimit: 100_000,
            value: zeroValue
        )
        assert(approveRes.status == EVM.Status.successful, message: "WFLOW approve failed: ".concat(approveRes.errorMessage))

        // 3. Swap WFLOW -> PYUSD0 via UniV3 exactInput
        //    Path encoding: tokenIn(20) | fee(3 bytes big-endian) | tokenOut(20)
        var pathBytes: [UInt8] = []
        let wflowFixed: [UInt8; 20] = wflowAddr.bytes
        let pyusd0Fixed: [UInt8; 20] = pyusd0Addr.bytes
        var i = 0
        while i < 20 { pathBytes.append(wflowFixed[i]); i = i + 1 }
        // fee 3000 = 0x000BB8 big-endian
        pathBytes.append(0x00)
        pathBytes.append(0x0B)
        pathBytes.append(0xB8)
        i = 0
        while i < 20 { pathBytes.append(pyusd0Fixed[i]); i = i + 1 }

        let swapRes = self.coa.call(
            to: routerAddr,
            data: EVM.encodeABIWithSignature(
                "exactInput((bytes,address,uint256,uint256))",
                [EVM.EVMBytes(value: pathBytes), self.coa.address(), amountEVM, UInt256(0)]
            ),
            gasLimit: 1_000_000,
            value: zeroValue
        )
        assert(swapRes.status == EVM.Status.successful, message: "UniV3 swap failed: ".concat(swapRes.errorMessage))

        // 4. Check PYUSD0 balance in COA
        let balRes = self.coa.call(
            to: pyusd0Addr,
            data: EVM.encodeABIWithSignature("balanceOf(address)", [self.coa.address()]),
            gasLimit: 100_000,
            value: zeroValue
        )
        assert(balRes.status == EVM.Status.successful, message: "balanceOf failed")
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: balRes.data)
        let pyusd0Balance = decoded[0] as! UInt256
        assert(pyusd0Balance > UInt256(0), message: "No PYUSD0 received from swap")

        // 5. Bridge PYUSD0 from EVM to Cadence
        let pyusd0Type = CompositeType("A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault")!
        let bridgedVault <- self.coa.withdrawTokens(
            type: pyusd0Type,
            amount: pyusd0Balance,
            feeProvider: &self.scopedProvider as auth(FungibleToken.Withdraw) &{FungibleToken.Provider}
        )
        assert(bridgedVault.balance > 0.0, message: "Bridged PYUSD0 vault is empty")
        log("Bridged PYUSD0 amount: ".concat(bridgedVault.balance.toString()))

        // Deposit bridged PYUSD0 into the signer's Cadence vault
        self.receiver.deposit(from: <-bridgedVault)

        destroy self.scopedProvider
    }
}
