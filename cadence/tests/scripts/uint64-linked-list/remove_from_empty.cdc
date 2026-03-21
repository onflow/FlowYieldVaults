import "UInt64LinkedList"

/// Returns true if removing from an empty list returns false without panicking.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    let removed = list.remove(id: 42)
    destroy list
    return !removed
}
