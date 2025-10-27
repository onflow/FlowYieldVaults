import "MockTidalProtocolConsumer"

/// Sets the target health factor for a wrapped position
transaction(targetHealth: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let wrapper = signer.storage.borrow<&MockTidalProtocolConsumer.PositionWrapper>(
            from: MockTidalProtocolConsumer.WrapperStoragePath
        ) ?? panic("No position wrapper found")
        
        let position = wrapper.borrowPosition()
        position.setTargetHealth(targetHealth: targetHealth)
    }
}

