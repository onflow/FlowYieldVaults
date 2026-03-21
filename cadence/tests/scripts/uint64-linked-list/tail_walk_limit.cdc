import "UInt64LinkedList"

/// Returns tailWalk result capped to limit=2.
access(all) fun main(): [UInt64] {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    let walked = list.tailWalk(limit: 2)
    destroy list
    return walked
}
