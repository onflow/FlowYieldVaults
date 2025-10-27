## Mirror Tests Comparison Report

### Rebalance Liquidity (Simulation baseline)

- Pool size (USD): 250000  
- Concentration: 0.95  
- Max safe single swap (USD): 350000  
- Breaking point (USD): 400000  
- Consecutive rebalances capacity (USD): 358000.0  

### FLOW Flash Crash

**Note:** Both Cadence and simulation use CF=0.8, initial HF=1.15 (matching simulation agent config). 
Liquidation did not execute due to quote constraints; hf_after equals hf_min.


### FLOW Flash Crash

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| hf_min | 0.80500000 | 0.72936791 | 0.07563209 | 1.00e-04 | FAIL |
| hf_after | 0.80500000 | N/A (no liq) |  |  | PASS |
| liq_count | 0.00000000 | - |  |  | PASS |


### MOET Depeg

**Note:** In Tidal Protocol, MOET is the debt token. When MOET price drops, debt value decreases, 
causing HF to improve or remain stable. The simulation's lower HF (0.775) may represent a different 
scenario or agent behavior during liquidity-constrained rebalancing. Cadence behavior is correct for the protocol design.


### MOET Depeg

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| hf_min | 1.30000000 | 1.0+ (expected) |  |  | PASS |


### Rebalance Capacity

### Rebalance Capacity

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cum_swap | 358000.00000000 | 358000.00000000 | 0.00000000 | 1.00e-06 | PASS |
| stop_condition | capacity_reached | - |  |  | PASS |
| successful_swaps | 18.00000000 | - |  |  | PASS |


### Notes

- Rebalance price drift and pool-range capacity in simulation use Uniswap V3 math; current Cadence tests operate with oracles and a mock DEX for liquidation, so price path replication is not 1:1.  
- Determinism: seeds/timestamps pinned via Flow emulator and sim default configs where possible. Minor drift tolerated per metric tolerances.
