import "UInt64LinkedList"

/// Returns true if a single inserted element becomes both head and tail.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 42)
    let ok = list.contains(id: 42)
        && list.head == 42
        && list.tail == 42
    destroy list
    return ok
}
