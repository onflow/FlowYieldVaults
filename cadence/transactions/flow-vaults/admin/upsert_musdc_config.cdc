import "FlowVaultsStrategies"
import "FlowToken"
import "EVM"

// Upserts the config for mUSDCStrategy under mUSDCStrategyComposer.
//
// Args (in order):
// 0: univ3FactoryEVMAddress              (String)
// 1: univ3RouterEVMAddress               (String)
// 2: univ3QuoterEVMAddress               (String)
// 3: yieldTokenEVMAddress                (String)
// 4: recollateralizationUniV3AddressPath ([String])
// 5: recollateralizationUniV3FeePath     ([UInt32])
//
// Example JSON args you gave:
// [
//   "0x92657b195e22b69E4779BBD09Fa3CD46F0CF8e39",                  // factory
//   "0x2Db6468229F6fB1a77d248Dbb1c386760C257804",                  // router
//   "0xA1e0E4CCACA34a738f03cFB1EAbAb16331FA3E2c",                  // quoter
//   "0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95",                  // yield token
//   ["0x4154d5B0E2931a0A1E5b733f19161aa7D2fc4b95",
//    "0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"],                // recollat path
//   [3000]                                                         // fee path
// ]
//
transaction(
    univ3FactoryEVMAddress: String,
    univ3RouterEVMAddress: String,
    univ3QuoterEVMAddress: String,
    yieldTokenEVMAddress: String,
    recollateralizationUniV3AddressPath: [String],
    recollateralizationUniV3FeePath: [UInt32]
) {

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the StrategyComposerIssuer with Configure entitlement
        let issuerRef = signer.storage.borrow<
            auth(FlowVaultsStrategies.Configure) &FlowVaultsStrategies.StrategyComposerIssuer
        >(from: FlowVaultsStrategies.IssuerStoragePath)
            ?? panic("Could not borrow StrategyComposerIssuer from IssuerStoragePath")

        // Collateral type we’re configuring for (matches contract init)
        let initialCollateralType: Type = Type<@FlowToken.Vault>()

        // Build the Uniswap V3 address path as [EVM.EVMAddress]
        var swapAddressPath: [EVM.EVMAddress] = []
        for hex in recollateralizationUniV3AddressPath {
            swapAddressPath.append(EVM.addressFromString(hex))
        }

        // Build the config shape:
        // { Strategy Type: { Collateral Type: { String: AnyStruct } } }
        //
        // This mirrors what the contract does in init(...) for mUSDCStrategyComposer.
        let config: {Type: {Type: {String: AnyStruct}}} = {
            Type<@FlowVaultsStrategies.mUSDCStrategy>(): {
                initialCollateralType: {
                    "univ3FactoryEVMAddress": EVM.addressFromString(univ3FactoryEVMAddress),
                    "univ3RouterEVMAddress":  EVM.addressFromString(univ3RouterEVMAddress),
                    "univ3QuoterEVMAddress":  EVM.addressFromString(univ3QuoterEVMAddress),
                    "yieldTokenEVMAddress":   EVM.addressFromString(yieldTokenEVMAddress),
                    "yieldToCollateralUniV3AddressPaths": {
                        initialCollateralType: swapAddressPath
                    },
                    "yieldToCollateralUniV3FeePaths": {
                        initialCollateralType: recollateralizationUniV3FeePath
                    }
                }
            }
        }

        // Upsert config for the mUSDCStrategyComposer
        issuerRef.upsertConfigFor(
            composer: Type<@FlowVaultsStrategies.mUSDCStrategyComposer>(),
            config: config
        )
    }

    execute {
        log("Updated mUSDC strategy config for FlowVaultsStrategies.mUSDCStrategyComposer")
    }
}
