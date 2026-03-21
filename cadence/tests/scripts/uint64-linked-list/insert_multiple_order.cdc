import "UInt64LinkedList"

/// Returns true if head is the most recently inserted element and tail is the oldest.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // head = 3 (most recent), tail = 1 (oldest)
    let ok = list.head == 3 && list.tail == 1
    destroy list
    return ok
}
