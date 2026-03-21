import "UInt64LinkedList"

/// Returns true if removing a non-existent id returns false without panicking.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 5)
    let removed = list.remove(id: 999)
    destroy list
    return !removed
}
