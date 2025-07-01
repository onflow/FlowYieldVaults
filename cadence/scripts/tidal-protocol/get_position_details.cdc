import "TidalProtocol"

/// Returns detailed information about a position including all token balances, 
/// directions (Credit/Debit), position health, and available withdrawal balance.
/// 
/// Debit balances represent debt/loans with accrued interest.
/// Credit balances represent collateral deposits earning interest.
///
/// @param pid: The Position ID to query
/// @return PositionDetails struct containing:
///   - balances: Array of PositionBalance showing token type, direction, and current balance (including accrued interest)
///   - poolDefaultToken: The pool's default token type (usually MOET)
///   - defaultTokenAvailableBalance: Amount of default token available for withdrawal
///   - health: Current position health ratio (collateral/debt)
///
access(all)
fun main(pid: UInt64): TidalProtocol.PositionDetails {
    let protocolAddress = Type<@TidalProtocol.Pool>().address!
    
    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find a configured TidalProtocol Pool")
    
    return pool.getPositionDetails(pid: pid)
} 