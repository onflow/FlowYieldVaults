import "UInt64LinkedList"

/// Returns true if a freshly created list has nil head, nil tail, and contains nothing.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    let ok = list.head == nil
        && list.tail == nil
        && !list.contains(id: 1)
    destroy list
    return ok
}
