import "UInt64LinkedList"

/// Returns true if removing the head promotes the next element to head.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1  (head=3, tail=1)
    let removed = list.remove(id: 3)
    // list: 2 <-> 1
    let ok = removed && list.head == 2 && list.tail == 1
    destroy list
    return ok
}
