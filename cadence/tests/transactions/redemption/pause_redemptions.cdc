import RedemptionWrapper from "../../../contracts/RedemptionWrapper.cdc"

transaction() {
    prepare(admin: auth(Storage) &Account) {
        let adminRef = admin.storage.borrow<&RedemptionWrapper.Admin>(
            from: RedemptionWrapper.AdminStoragePath
        ) ?? panic("No admin resource")
        
        adminRef.pause()
    }
}

