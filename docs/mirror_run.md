## Mirror Run Logs

- Report: `docs/mirror_report.md`

### FLOW Flash Crash (flow_flash_crash_mirror_test.cdc)

```
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_before=1.300000000009750000000073"
11:21PM INF [1;34mLOG:[0m "MIRROR:coll_before=1000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:debt_before=615.38461538"
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_min=0.910000000006825000000051"
11:21PM INF [1;34mLOG:[0m "[LIQ][QUOTE] repayExact=410.25641024 seizeExact=615.38461535 trueCollateralSeize=1000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_after=inf"
11:21PM INF [1;34mLOG:[0m "MIRROR:coll_after=384.61538465"
11:21PM INF [1;34mLOG:[0m "MIRROR:debt_after=263.73626457"
11:21PM INF [1;34mLOG:[0m "MIRROR:liq_count=1"
11:21PM INF [1;34mLOG:[0m "MIRROR:liq_repaid=879.12087995"
11:21PM INF [1;34mLOG:[0m "MIRROR:liq_seized=615.38461535"

Test results: "/Users/keshavgupta/tidal-sc/cadence/tests/flow_flash_crash_mirror_test.cdc"
- PASS: test_flow_flash_crash_liquidation_path
```

### MOET Depeg (moet_depeg_mirror_test.cdc)

```
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_before=1.300000000009750000000073"
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_min=1.300000000009750000000073"
11:21PM INF [1;34mLOG:[0m "MIRROR:hf_after=1.300000000009750000000073"

Test results: "/Users/keshavgupta/tidal-sc/cadence/tests/moet_depeg_mirror_test.cdc"
- PASS: test_moet_depeg_health_resilience
```

### Rebalance Capacity (rebalance_liquidity_mirror_test.cdc)

```
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=20000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=1"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=40000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=2"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=60000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=3"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=80000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=4"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=100000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=5"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=120000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=6"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=140000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=7"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=160000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=8"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=180000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=9"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=200000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=10"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=220000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=11"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=240000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=12"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=260000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=13"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=280000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=14"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=300000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=15"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=320000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=16"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=340000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=17"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=358000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=18"
11:21PM INF [1;34mLOG:[0m "MIRROR:cum_swap=358000.00000000"
11:21PM INF [1;34mLOG:[0m "MIRROR:successful_swaps=18"
11:21PM INF [1;34mLOG:[0m "MIRROR:stop_condition=capacity_reached"

Test results: "/Users/keshavgupta/tidal-sc/cadence/tests/rebalance_liquidity_mirror_test.cdc"
- PASS: test_rebalance_capacity_thresholds
```
