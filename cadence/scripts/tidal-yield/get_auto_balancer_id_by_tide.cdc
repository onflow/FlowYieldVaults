access(all) fun main(tideID: UInt64): UInt64 {
    // The Tide creates a UniqueIdentifier and uses its ID for both:
    // 1. The Tide's own ID (returned by tide.id())
    // 2. The uniqueID passed to createStrategy, which is used for the AutoBalancer
    // Therefore, the AutoBalancer ID is the same as the Tide ID
    return tideID
} 