## Mirror Tests Comparison Report

### Rebalance Liquidity (Simulation baseline)

- Pool size (USD): 250000  
- Concentration: 0.95  
- Max safe single swap (USD): 350000  
- Breaking point (USD): 400000  
- Consecutive rebalances capacity (USD): 358000.0  

### FLOW Flash Crash

### FLOW Flash Crash

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| hf_min | None | 0.72936791 |  | 1.00e-04 | FAIL |
| hf_after | None | 1.00000000 |  | 1.00e-04 | FAIL |


### MOET Depeg

### MOET Depeg

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| hf_min | None | 0.77507692 |  | 1.00e-04 | FAIL |


### Rebalance Capacity

### Rebalance Capacity

| Metric | Mirror | Sim | Delta | Tolerance | Pass |
| --- | ---: | ---: | ---: | ---: | :---: |
| cum_swap | None | 358000.00000000 |  | 1.00e-06 | FAIL |


### Notes

- Rebalance price drift and pool-range capacity in simulation use Uniswap V3 math; current Cadence tests operate with oracles and a mock DEX for liquidation, so price path replication is not 1:1.  
- Determinism: seeds/timestamps pinned via Flow emulator and sim default configs where possible. Minor drift tolerated per metric tolerances.
