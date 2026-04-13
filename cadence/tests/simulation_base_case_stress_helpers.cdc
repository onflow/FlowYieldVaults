import Test

// AUTO-GENERATED from simulation_ht_vs_aave.json — do not edit manually
// Run: python3 generate_fixture.py generate <input.json> <output.cdc>

access(all) struct SimAgent {
    access(all) let count: Int
    access(all) let initialHF: UFix64
    access(all) let rebalancingHF: UFix64
    access(all) let targetHF: UFix64
    access(all) let debtPerAgent: UFix64
    access(all) let totalSystemDebt: UFix64

    init(
        count: Int,
        initialHF: UFix64,
        rebalancingHF: UFix64,
        targetHF: UFix64,
        debtPerAgent: UFix64,
        totalSystemDebt: UFix64
    ) {
        self.count = count
        self.initialHF = initialHF
        self.rebalancingHF = rebalancingHF
        self.targetHF = targetHF
        self.debtPerAgent = debtPerAgent
        self.totalSystemDebt = totalSystemDebt
    }
}

access(all) struct SimPool {
    access(all) let size: UFix64
    access(all) let concentration: UFix64
    access(all) let feeTier: UFix64

    init(size: UFix64, concentration: UFix64, feeTier: UFix64) {
        self.size = size
        self.concentration = concentration
        self.feeTier = feeTier
    }
}

access(all) struct SimConstants {
    access(all) let btcCollateralFactor: UFix64
    access(all) let btcLiquidationThreshold: UFix64
    access(all) let yieldAPR: UFix64
    access(all) let directMintYT: Bool

    init(
        btcCollateralFactor: UFix64,
        btcLiquidationThreshold: UFix64,
        yieldAPR: UFix64,
        directMintYT: Bool
    ) {
        self.btcCollateralFactor = btcCollateralFactor
        self.btcLiquidationThreshold = btcLiquidationThreshold
        self.yieldAPR = yieldAPR
        self.directMintYT = directMintYT
    }
}

access(all) let simulation_ht_vs_aave_prices: [UFix64] = [
    100000.00000000,
    99551.11000000,
    99104.23000000,
    98659.37000000,
    98216.49000000,
    97775.61000000,
    97336.70000000,
    96899.77000000,
    96464.80000000,
    96031.78000000,
    95600.70000000,
    95171.56000000,
    94744.34000000,
    94319.04000000,
    93895.65000000,
    93474.17000000,
    93054.57000000,
    92636.86000000,
    92221.02000000,
    91807.05000000,
    91394.93000000,
    90984.67000000,
    90576.25000000,
    90169.66000000,
    89764.90000000,
    89361.95000000,
    88960.82000000,
    88561.48000000,
    88163.94000000,
    87768.18000000,
    87374.20000000,
    86981.98000000,
    86591.53000000,
    86202.83000000,
    85815.87000000,
    85430.65000000,
    85047.16000000,
    84665.39000000,
    84285.34000000,
    83906.99000000,
    83530.34000000,
    83155.38000000,
    82782.10000000,
    82410.50000000,
    82040.57000000,
    81672.30000000,
    81305.68000000,
    80940.71000000,
    80577.37000000,
    80215.67000000,
    79855.59000000,
    79497.12000000,
    79140.27000000,
    78785.02000000,
    78431.36000000,
    78079.29000000,
    77728.80000000,
    77379.88000000,
    77032.53000000,
    76686.74000000,
    76342.50000000
]

access(all) let simulation_ht_vs_aave_agents: [SimAgent] = [
    SimAgent(
        count: 5,
        initialHF: 1.15000000,
        rebalancingHF: 1.05000000,
        targetHF: 1.08000000,
        debtPerAgent: 133333.00000000,
        totalSystemDebt: 666665.00000000
    )
]

access(all) let simulation_ht_vs_aave_pools: {String: SimPool} = {
    "pyusd0_yt": SimPool(
        size: 500000.00000000,
        concentration: 0.95000000,
        feeTier: 0.00050000
    ),
    "pyusd0_flow": SimPool(
        size: 500000.00000000,
        concentration: 0.80000000,
        feeTier: 0.00300000
    )
}

access(all) let simulation_ht_vs_aave_constants: SimConstants = SimConstants(
    btcCollateralFactor: 0.75000000,
    btcLiquidationThreshold: 0.80000000,
    yieldAPR: 0.10000000,
    directMintYT: true
)

access(all) let simulation_ht_vs_aave_expectedLiquidationCount: Int = 0
access(all) let simulation_ht_vs_aave_expectedAllAgentsSurvive: Bool = true

access(all) let simulation_ht_vs_aave_durationMinutes: Int = 60
access(all) let simulation_ht_vs_aave_notes: String = "BTC $100K to $76,342.50 (-23.66%) exponential decline over 60 minutes. Source: comprehensive_ht_vs_aave_analysis.py"
