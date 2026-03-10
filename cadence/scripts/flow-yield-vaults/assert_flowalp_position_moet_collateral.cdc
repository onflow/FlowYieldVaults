import "FlowALPv0"

/// Verifies the PYUSD0→MOET pre-swap invariant for the FlowALP pool:
///
///   1. PYUSD0 is NOT a supported collateral token in FlowALP (so it cannot be deposited directly).
///   2. MOET (the pool's default token) IS a supported collateral token.
///
/// Together with a successful PYUSD0 vault creation test, this proves that the strategy
/// pre-swapped PYUSD0 → MOET before depositing into FlowALP — since FlowALP cannot receive
/// PYUSD0 directly.
///
/// Returns a string starting with "OK:" on success or "FAIL:" on failure.
access(all) fun main(): String {
    let pool = getAccount(0x6b00ff876c299c61)
        .capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not borrow FlowALP pool")

    let pyusd0TypeID = "A.1e4aa0b87d10b141.EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault"
    let supportedTokens = pool.getSupportedTokens()

    // Assert PYUSD0 is NOT supported (FlowALP cannot receive it as collateral)
    for t in supportedTokens {
        if t.identifier == pyusd0TypeID {
            return "FAIL: PYUSD0 is listed as a supported FlowALP token — pre-swap may not be required"
        }
    }

    // Assert MOET (default token) IS supported
    let defaultToken = pool.getDefaultToken()
    var moetSupported = false
    for t in supportedTokens {
        if t == defaultToken {
            moetSupported = true
        }
    }
    if !moetSupported {
        return "FAIL: MOET (pool default token) is not in the supported tokens list"
    }

    return "OK: PYUSD0 is not a supported FlowALP collateral; MOET (".concat(defaultToken.identifier).concat(") is — pre-swap invariant confirmed")
}
