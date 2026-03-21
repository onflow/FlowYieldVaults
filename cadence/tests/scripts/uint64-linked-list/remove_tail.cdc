import "UInt64LinkedList"

/// Returns true if removing the tail promotes the previous element to tail.
access(all) fun main(): Bool {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 2)
    list.insertAtHead(id: 3)
    // list: 3 <-> 2 <-> 1  (head=3, tail=1)
    let removed = list.remove(id: 1)
    // list: 3 <-> 2
    let ok = removed && list.head == 3 && list.tail == 2
    destroy list
    return ok
}
