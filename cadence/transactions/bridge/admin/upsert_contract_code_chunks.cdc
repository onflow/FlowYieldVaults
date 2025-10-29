import "FlowEVMBridgeTemplates"

/// Upserts the provided contract template stored in FlowEVMBridgeTemplates
///
/// @param forTemplate: The name of the template to upsert
/// @param newChunks: The new code chunks to upsert, chunked on the Cadence contract code separated on the contract
///     name. The included chunks should be hex-encoded bytecode values of the contract code which are then decoded
///     and stored in the FlowEVMBridgeTemplates contract under the `forTemplate` key.
///
transaction(forTemplate: String, newChunks: [String]) {
    prepare(signer: auth(BorrowValue) &Account) {
        signer.storage.borrow<&FlowEVMBridgeTemplates.Admin>(from: FlowEVMBridgeTemplates.AdminStoragePath)
            ?.upsertContractCodeChunks(forTemplate: forTemplate, chunks: newChunks)
            ?? panic("Could not borrow FlowEVMBridgeTemplates Admin reference")
    }
}
