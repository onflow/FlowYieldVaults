import Test
import "UInt64LinkedList"

access(all) fun setup() {
    let err = Test.deployContract(
        name: "UInt64LinkedList",
        path: "../contracts/UInt64LinkedList.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// ─── Tests ───────────────────────────────────────────────────────────────────

access(all) fun test_EmptyListState() {
    let list <- UInt64LinkedList.createList()
    Test.assert(list.head == nil)
    Test.assert(list.tail == nil)
    Test.assert(!list.contains(id: 1))
    destroy list
}

access(all) fun test_InsertSingle() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 42)
    Test.assert(list.contains(id: 42))
    Test.assert(list.head == 42)
    Test.assert(list.tail == 42)
    destroy list
}

access(all) fun test_InsertMultiple_HeadAndTailOrder() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // head = 3 (most recent), tail = 1 (oldest)
    Test.assert(list.head == 3)
    Test.assert(list.tail == 1)
    destroy list
}

access(all) fun test_Contains() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 10)
    list.insertAtHead(id: 20)
    Test.assert(list.contains(id: 10))
    Test.assert(list.contains(id: 20))
    Test.assert(!list.contains(id: 99))
    destroy list
}

access(all) fun test_RemoveSingle() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 7)
    Test.assert(list.remove(id: 7))
    Test.assert(list.head == nil)
    Test.assert(list.tail == nil)
    Test.assert(!list.contains(id: 7))
    destroy list
}

access(all) fun test_RemoveHead() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1  (head=3, tail=1)
    Test.assert(list.remove(id: 3))
    // list: 2 <-> 1
    Test.assert(list.head == 2)
    Test.assert(list.tail == 1)
    destroy list
}

access(all) fun test_RemoveTail() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1  (head=3, tail=1)
    Test.assert(list.remove(id: 1))
    // list: 3 <-> 2
    Test.assert(list.head == 3)
    Test.assert(list.tail == 2)
    destroy list
}

access(all) fun test_RemoveMiddle() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1
    Test.assert(list.remove(id: 2))
    // list: 3 <-> 1
    Test.assert(list.head == 3)
    Test.assert(list.tail == 1)
    Test.assert(!list.contains(id: 2))
    Test.assert(list.contains(id: 3))
    Test.assert(list.contains(id: 1))
    destroy list
}

access(all) fun test_RemoveAbsent() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 5)
    Test.assert(!list.remove(id: 999))
    destroy list
}

access(all) fun test_RemoveFromEmpty() {
    let list <- UInt64LinkedList.createList()
    Test.assert(!list.remove(id: 42))
    destroy list
}

access(all) fun test_TailWalk_Order() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // head=3, tail=1 → tailWalk yields [1, 2, 3]
    let walked = list.tailWalk(limit: 10)
    destroy list
    let expected: [UInt64] = [1, 2, 3]
    Test.assertEqual(expected, walked)
}

access(all) fun test_TailWalk_Limit() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    let walked = list.tailWalk(limit: 2)
    destroy list
    Test.assertEqual(2, walked.length)
}

access(all) fun test_TailWalk_Empty() {
    let list <- UInt64LinkedList.createList()
    let walked = list.tailWalk(limit: 5)
    destroy list
    Test.assertEqual(0, walked.length)
}

access(all) fun test_InsertDuplicate_Panics() {
    Test.expectFailure(fun() {
        let list <- UInt64LinkedList.createList()
        list.insertAtHead(id: 1)
        list.insertAtHead(id: 1)
        destroy list
    }, errorMessageSubstring: "ID already exists in list")
}
