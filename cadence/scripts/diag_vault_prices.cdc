import "EVM"
import "FlowToken"
import "ERC4626Utils"
import "FlowEVMBridgeUtils"
import "BandOracle"

/// Reports the current redemption price of the syWFLOWv and FUSDEV ERC4626 vaults,
/// both in their underlying token and in USD (via Band Protocol oracle).
///
///   syWFLOWv price (USD) = (syWFLOWv / WFLOW)  ×  FLOW/USD   (Band symbol: "FLOW")
///   FUSDEV   price (USD) = (FUSDEV   / PYUSD0)  ×  PYUSD/USD  (Band symbol: "PYUSD")
///
/// Note: syWFLOWv does not implement convertToAssets(); share price is derived from
/// totalAssets / totalSupply instead.
///
/// Note: BandOracle.getReferenceData requires a FLOW fee. This script works only when
/// BandOracle.getFee() == 0.0. If the fee is non-zero the assertion will panic.
///
/// Run: flow scripts execute cadence/scripts/diag_vault_prices.cdc --network mainnet
access(all) fun main(): {String: {String: AnyStruct}} {
    let syWFLOWv = EVM.addressFromString("0xCBf9a7753F9D2d0e8141ebB36d99f87AcEf98597")
    let fusdev   = EVM.addressFromString("0xd069d989e2F44B70c65347d1853C0c67e10a9F8D")

    // ── Band Oracle USD prices ─────────────────────────────────────────────────
    fun bandPrice(_ symbol: String): UFix64 {
        let fee = BandOracle.getFee()
        assert(fee == 0.0, message: "BandOracle fee is non-zero (".concat(fee.toString()).concat(" FLOW). Use a transaction to pay the fee."))
        let payment <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let data = BandOracle.getReferenceData(baseSymbol: symbol, quoteSymbol: "USD", payment: <-payment)
        return data.fixedPointRate
    }

    // ── Wei → human-readable token units (8 dp) ───────────────────────────────
    fun toHuman(_ wei: UInt256, _ decimals: UInt8): UFix64 {
        if decimals <= 8 {
            return FlowEVMBridgeUtils.uint256ToUFix64(value: wei, decimals: decimals)
        }
        let quantum = FlowEVMBridgeUtils.pow(base: 10, exponent: decimals - 8)
        return FlowEVMBridgeUtils.uint256ToUFix64(value: wei - (wei % quantum), decimals: decimals)
    }

    // ── Per-vault price computation ────────────────────────────────────────────
    fun vaultPrice(
        _ vault: EVM.EVMAddress,
        _ name: String,
        _ underlyingName: String,
        _ bandSymbol: String
    ): {String: AnyStruct} {
        let shareDec = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: vault)

        // Resolve underlying asset address + decimals via ERC4626 asset()
        let underlyingRes = EVM.dryCall(
            from: vault, to: vault,
            data: EVM.encodeABIWithSignature("asset()", []),
            gasLimit: 100_000, value: EVM.Balance(attoflow: 0)
        )
        let underlying = underlyingRes.status == EVM.Status.successful
            ? (EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: underlyingRes.data)[0] as! EVM.EVMAddress)
            : vault
        let assetDec = FlowEVMBridgeUtils.getTokenDecimals(evmContractAddress: underlying)

        let totalAssetsWei = ERC4626Utils.totalAssets(vault: vault) ?? UInt256(0)
        let totalSharesWei = ERC4626Utils.totalShares(vault: vault) ?? UInt256(0)

        let assetsHuman = toHuman(totalAssetsWei, assetDec)
        let sharesHuman = toHuman(totalSharesWei, shareDec)

        // price per share in underlying token
        let priceInUnderlying = sharesHuman > 0.0 ? assetsHuman / sharesHuman : 0.0

        // USD price of the underlying from Band Oracle, then multiply through
        let underlyingUSD = bandPrice(bandSymbol)
        let priceUSD      = priceInUnderlying * underlyingUSD

        return {
            "price_usd":           priceUSD,
            "price_in_underlying": priceInUnderlying,
            "underlying_usd":      underlyingUSD,
            "interpretation":      "1 ".concat(name).concat(" = $").concat(priceUSD.toString()),
            "totalAssets":         assetsHuman,
            "totalAssets_wei":     totalAssetsWei,
            "totalShares":         sharesHuman,
            "totalShares_wei":     totalSharesWei,
            "underlying_address":  underlying.toString(),
            "asset_decimals":      assetDec,
            "share_decimals":      shareDec
        }
    }

    return {
        "syWFLOWv": vaultPrice(syWFLOWv, "syWFLOWv", "WFLOW",  "FLOW"),
        "FUSDEV":   vaultPrice(fusdev,   "FUSDEV",   "PYUSD0", "PYUSD")
    }
}
