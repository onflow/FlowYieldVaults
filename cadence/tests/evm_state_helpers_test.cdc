import Test
import "evm_state_helpers.cdc"

// Simple smoke test to verify helpers are importable and functional
access(all) fun testHelpersExist() {
    // Just verify we can import the helpers without errors
    // Actual usage will be tested in the forked rebalance tests
    Test.assertEqual(true, true)
}
