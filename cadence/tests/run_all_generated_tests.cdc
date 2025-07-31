import Test

// Import all generated tests
import "./rebalance_scenario1_flow_test.cdc"
import "./rebalance_scenario2_instant_test.cdc"
import "./rebalance_scenario3_path_a_test.cdc"
import "./rebalance_scenario3_path_b_test.cdc"
import "./rebalance_scenario3_path_c_test.cdc"
import "./rebalance_scenario3_path_d_test.cdc"
import "./rebalance_scenario4_scaling_test.cdc"
import "./rebalance_scenario5_volatilemarkets_test.cdc"
import "./rebalance_scenario6_gradualtrends_test.cdc"
import "./rebalance_scenario7_edgecases_test.cdc"
import "./rebalance_scenario8_multisteppaths_test.cdc"
import "./rebalance_scenario9_randomwalks_test.cdc"
import "./rebalance_scenario10_conditionalmode_test.cdc"

access(all) fun main() {
    // Run all generated tests
    Test.run(test_RebalanceTideScenario1_FLOW)
    Test.run(test_RebalanceTideScenario2_Instant)
    Test.run(test_RebalanceTideScenario3_Path_A)
    Test.run(test_RebalanceTideScenario3_Path_B)
    Test.run(test_RebalanceTideScenario3_Path_C)
    Test.run(test_RebalanceTideScenario3_Path_D)
    Test.run(test_RebalanceTideScenario4_Scaling)
    Test.run(test_RebalanceTideScenario5_VolatileMarkets)
    Test.run(test_RebalanceTideScenario6_GradualTrends)
    Test.run(test_RebalanceTideScenario7_EdgeCases)
    Test.run(test_RebalanceTideScenario8_MultiStepPaths)
    Test.run(test_RebalanceTideScenario9_RandomWalks)
    Test.run(test_RebalanceTideScenario10_ConditionalMode)
}
