import "UInt64LinkedList"

/// Returns true if contains is accurate for present and absent ids.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 10)
    list.insertAtHead(id: 20)
    let ok = list.contains(id: 10)
        && list.contains(id: 20)
        && !list.contains(id: 99)
    destroy list
    return ok
}
