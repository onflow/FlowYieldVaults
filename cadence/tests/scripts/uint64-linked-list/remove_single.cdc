import "UInt64LinkedList"

/// Returns true if removing the only element leaves an empty list.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 7)
    let removed = list.remove(id: 7)
    let ok = removed
        && list.head == nil
        && list.tail == nil
        && !list.contains(id: 7)
    destroy list
    return ok
}
