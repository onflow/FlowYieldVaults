transaction {
    prepare(signer: auth(AddKey) &Account) {
        let firstKey = signer.keys.get(keyIndex: 0)!
        let range: InclusiveRange<Int> = InclusiveRange(1, 100, step: 1)
        for element in range {
            signer.keys.add(
                publicKey: firstKey.publicKey,
                hashAlgorithm: HashAlgorithm.SHA3_256,
                weight: 1000.0
            )
        }
    }
}
