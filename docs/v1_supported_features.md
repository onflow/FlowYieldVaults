# FlowYieldVaults v1 — Supported Features

> **Status:** Draft — items marked ⚠️ require confirmation before finalization.

---

## 1. Strategies Supported

### TracerStrategy
The flagship v1 strategy. Deposits FLOW as collateral into a FlowALP lending position, borrows MOET against it, and swaps into a yield-bearing token for ongoing yield.

- **Collateral**: FLOW
- **Borrow token**: MOET (via FlowALP)
- **Yield token**: YieldToken (e.g. tauUSDF or mUSDC, depending on configuration)
- **Integrated protocols**: FlowALP v1, Uniswap V3 (EVM), ERC4626 vaults

### mUSDCStrategy
ERC4626 vault integration strategy. Swaps into mUSDC and deposits into a Morpho-compatible vault.

- **Collateral**: FLOW
- **Yield source**: mUSDC (ERC4626 vault)
- **Integrated protocols**: Uniswap V3, ERC4626

### mUSDFStrategy *(v1.1)*
Advanced strategy targeting USDF yield via Morpho Finance.

- **Collateral**: FLOW
- **Yield source**: mUSDDF (Morpho Finance)
- **Integrated protocols**: Uniswap V3, Morpho Finance, ERC4626

### Simple ERC4626 Strategies *(PMStrategiesV1)*

| Strategy | Yield Source |
|----------|-------------|
| `syWFLOWvStrategy` | Swap-based Yield FLOW |
| `tauUSDFvStrategy` | Tau Labs USDF vault |
| `FUSDEVStrategy` | Flow USD Expeditionary Vault |

---

## 2. Supported Input (Deposit) Token

| Token | Notes |
|-------|-------|
| **FLOW** | Only supported deposit token in v1 |

> ⚠️ Multi-collateral support (WETH, WBTC, etc.) is not in v1 scope — confirm if any bridged assets are accepted directly.

---

## 3. Output / Receipt Token

- **YieldToken** (`@YieldToken.Vault`) — issued to users representing their share of the yield-bearing position.
- Each YieldVault also tracks a **position ID** (UInt64) tied to the underlying FlowALP position.

---

## 4. Rebalancing

| Parameter | Value |
|-----------|-------|
| Rebalancing frequency | **10 minutes** (600 seconds) |
| Scheduling mechanism | Flow native `FlowTransactionScheduler` (FLIP 330) |
| Lower rebalance threshold | **0.95** (5% below target triggers recollateralization) |
| Upper rebalance threshold | **1.05** (5% above target triggers rebalancing) |
| Force rebalance option | Available (bypasses threshold checks) |
| Fee margin multiplier | 1.2× (20% buffer on estimated scheduling fees) |
| Supervisor recovery batch | Up to 50 stuck vaults per recovery run |

The AutoBalancer self-schedules each subsequent execution at creation and after each run. A Supervisor contract handles recovery for vaults that fall out of the schedule.

---

## 5. Health Factors (FlowALP Position)

| Parameter | Value |
|-----------|-------|
| Target health | 1.30 |
| Minimum health (liquidation threshold) | 1.10 |
| Liquidation target health factor | 1.05 |

---

## 6. Position & Deposit Limits

| Parameter | Value | Notes |
|-----------|-------|-------|
| Minimum deposit | ⚠️ TBD | No contract-enforced minimum found |
| Maximum deposit capacity | 1,000,000 FLOW (default) | Governance-configurable cap |
| Deposit rate limit | 1,000,000 FLOW (default) | Per-block rate limiting via FlowALP |

---

## 7. Fees

| Fee Type | Value | Notes |
|----------|-------|-------|
| Scheduling / rebalancing fee | Paid in FLOW from AutoBalancer fee source | Min fallback: governance-set |
| Protocol / interest fee | Dynamic (utilization-based via FlowALP) | |
| Insurance reserve | 0.1% of credit balance | Taken before distributing credit interest |
| Management / performance fee | ⚠️ TBD | Confirm if any protocol-level fee applies |
| Withdrawal fee | ⚠️ TBD | Not observed in contracts — confirm |

---

## 8. Access Control (Closed Beta)

| Feature | Details |
|---------|---------|
| YieldVault creation | Requires a `BetaBadge` capability |
| Badge grant / revoke | Admin-only via `FlowYieldVaultsClosedBeta` contract |
| Rebalancing | Any account can trigger; Supervisor handles recovery |
| Governance params | Admin / Configure entitlements only |

---

## 9. Contracts & Mainnet Addresses

All core contracts are deployed to **`0xb1d63873c3cc9f79`**.

| Contract | Address |
|----------|---------|
| `FlowYieldVaults` | `0xb1d63873c3cc9f79` |
| `FlowYieldVaultsStrategies` | `0xb1d63873c3cc9f79` |
| `FlowYieldVaultsAutoBalancers` | `0xb1d63873c3cc9f79` |
| `FlowYieldVaultsClosedBeta` | `0xb1d63873c3cc9f79` |
| `FlowYieldVaultsSchedulerV1` | `0xb1d63873c3cc9f79` |
| `FlowYieldVaultsSchedulerRegistry` | `0xb1d63873c3cc9f79` |
| FlowALP (lending) | `0x6b00ff876c299c61` |
| DeFiActions platform | `0x6d888f175c158410` |
| EVM Bridge | `0x1e4aa0b87d10b141` |

### Key EVM Asset Addresses (Mainnet)

| Token | EVM Address |
|-------|-------------|
| USDC | `0xF1815bd50389c46847f0Bda824eC8da914045D14` |
| wETH | `0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590` |
| cbBTC | `0xA0197b2044D28b08Be34d98b23c9312158Ea9A18` |
| tauUSDF (ERC4626) | `0xc52E820d2D6207D18667a97e2c6Ac22eB26E803c` |

---

## 10. Open Items

| # | Item | Owner |
|---|------|-------|
| 1 | Minimum deposit value (is there a floor?) | |
| 2 | Management / performance fee — does one exist? | |
| 3 | Withdrawal fee — confirm none | |
| 4 | Are any bridged assets (WETH, WBTC) accepted as direct deposits in v1? | |
| 5 | Confirm deposit capacity cap of 1,000,000 FLOW for v1 launch | |
| 6 | mUSDFStrategy and simple ERC4626 strategies — in v1 or later? | |
