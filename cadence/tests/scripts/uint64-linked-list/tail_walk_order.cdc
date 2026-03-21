import "UInt64LinkedList"

/// Returns ids from tailWalk — should be oldest-first (tail toward head).
access(all) fun main(): [UInt64] {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // head=3, tail=1 → tailWalk yields [1, 2, 3]
    let walked = list.tailWalk(limit: 10)
    destroy list
    return walked
}
