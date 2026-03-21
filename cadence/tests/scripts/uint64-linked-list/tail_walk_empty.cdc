import "UInt64LinkedList"

/// Returns the length of tailWalk on an empty list — should be 0.
access(all) fun main(): Int {
    let list <- UInt64LinkedList.createList()
    let walked = list.tailWalk(limit: 5)
    destroy list
    return walked.length
}
