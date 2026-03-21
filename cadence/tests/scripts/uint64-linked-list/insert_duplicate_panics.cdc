import "UInt64LinkedList"

/// Expected to fail — inserting a duplicate id violates the pre-condition.
access(all) fun main() {
    let list <- UInt64LinkedList.createList()
    list.insertAtHead(id: 1)
    list.insertAtHead(id: 1)
    destroy list
}
