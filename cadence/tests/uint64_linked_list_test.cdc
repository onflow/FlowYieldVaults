import Test

access(all) fun setup() {
    let err = Test.deployContract(
        name: "UInt64LinkedList",
        path: "../contracts/UInt64LinkedList.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all)
fun executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

// ─── Tests ───────────────────────────────────────────────────────────────────

access(all) fun test_EmptyListState() {
    let res = executeScript("./scripts/uint64-linked-list/empty_list_state.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_InsertSingle() {
    let res = executeScript("./scripts/uint64-linked-list/insert_single.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_InsertMultiple_HeadAndTailOrder() {
    let res = executeScript("./scripts/uint64-linked-list/insert_multiple_order.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_Contains() {
    let res = executeScript("./scripts/uint64-linked-list/contains.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveSingle() {
    let res = executeScript("./scripts/uint64-linked-list/remove_single.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveHead() {
    let res = executeScript("./scripts/uint64-linked-list/remove_head.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveTail() {
    let res = executeScript("./scripts/uint64-linked-list/remove_tail.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveMiddle() {
    let res = executeScript("./scripts/uint64-linked-list/remove_middle.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveAbsent() {
    let res = executeScript("./scripts/uint64-linked-list/remove_absent.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_RemoveFromEmpty() {
    let res = executeScript("./scripts/uint64-linked-list/remove_from_empty.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(true, res.returnValue as! Bool)
}

access(all) fun test_TailWalk_Order() {
    let res = executeScript("./scripts/uint64-linked-list/tail_walk_order.cdc", [])
    Test.expect(res, Test.beSucceeded())
    let expected: [UInt64] = [1, 2, 3]
    Test.assertEqual(expected, res.returnValue as! [UInt64])
}

access(all) fun test_TailWalk_Limit() {
    let res = executeScript("./scripts/uint64-linked-list/tail_walk_limit.cdc", [])
    Test.expect(res, Test.beSucceeded())
    let walked = res.returnValue as! [UInt64]
    Test.assertEqual(2, walked.length)
}

access(all) fun test_TailWalk_Empty() {
    let res = executeScript("./scripts/uint64-linked-list/tail_walk_empty.cdc", [])
    Test.expect(res, Test.beSucceeded())
    Test.assertEqual(0, res.returnValue as! Int)
}

access(all) fun test_InsertDuplicate_Panics() {
    let res = executeScript("./scripts/uint64-linked-list/insert_duplicate_panics.cdc", [])
    Test.expect(res, Test.beFailed())
}
