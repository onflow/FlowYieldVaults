import "TidalProtocol"

/// Returns only the debt balances for a position - these represent loans with accrued interest.
/// Debit balances show how much you owe (principal + accrued interest) for each token type.
///
/// @param pid: The Position ID to query
/// @return Array of PositionBalance structs where direction == BalanceDirection.Debit
///         Each balance shows the current debt amount including accrued interest.
///
access(all)
fun main(pid: UInt64): [TidalProtocol.PositionBalance] {
    let protocolAddress = Type<@TidalProtocol.Pool>().address!
    
    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find TidalProtocol Pool")
    
    let positionDetails = pool.getPositionDetails(pid: pid)
    let debtBalances: [TidalProtocol.PositionBalance] = []
    
    // Filter to only return debt (Debit) balances
    for balance in positionDetails.balances {
        if balance.direction == TidalProtocol.BalanceDirection.Debit {
            debtBalances.append(balance)
        }
    }
    
    return debtBalances
} 