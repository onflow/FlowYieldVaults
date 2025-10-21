## Mirror Tests Comparison Report

### Rebalance Liquidity (Simulation baseline)

- Pool size (USD): 250000  
- Concentration: 0.95  
- Max safe single swap (USD): 350000  
- Breaking point (USD): 400000  
- Consecutive rebalances capacity (USD): 358000.0  

### FLOW Flash Crash

- Simulation: min HF 0.729, max HF 1.430  
- Cadence: liquidation path available via mock DEX; post-liq HF >= 1.01 (test PASS)  

### MOET Depeg

- Simulation: min HF 0.775, max HF 1.500  
- Cadence: depeg to 0.95 does not reduce HF (within tolerance) (test PASS)  

### Notes

- Rebalance price drift and pool-range capacity in simulation use Uniswap V3 math; current Cadence tests operate with oracles and a mock DEX for liquidation, so price path replication is not 1:1.  
- Next: add test-only governance transactions to manipulate pool reserves and expose utilization/price metrics to enable closer mirroring.
