import "UInt64LinkedList"

/// Returns true if removing a middle element re-links its neighbors correctly.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1
    let removed = list.remove(id: 2)
    // list: 3 <-> 1
    let ok = removed
        && list.head == 3
        && list.tail == 1
        && !list.contains(id: 2)
        && list.contains(id: 3)
        && list.contains(id: 1)
    destroy list
    return ok
}
