/// UInt64LinkedList
///
/// A reusable doubly-linked list over UInt64 keys, packaged as a resource
/// so that its lifetime is explicit and multiple lists can be instantiated
/// per contract if needed.
///
/// Head = most recently inserted/refreshed entry.
/// Tail = least recently inserted/refreshed entry.
///
access(all) contract UInt64LinkedList {

    /* --- TYPES --- */

    /// Node in the doubly-linked list.
    /// `prev` points toward the head; `next` points toward the tail.
    access(all) struct ListNode {
        access(all) var prev: UInt64?
        access(all) var next: UInt64?

        init(prev: UInt64?, next: UInt64?) {
            self.prev = prev
            self.next = next
        }

        access(all) fun setPrev(prev: UInt64?) { self.prev = prev }
        access(all) fun setNext(next: UInt64?) { self.next = next }
    }

    /* --- RESOURCE --- */

    access(all) resource List {
        access(all) var nodes: {UInt64: ListNode}
        access(all) var head: UInt64?
        access(all) var tail: UInt64?

        init() {
            self.nodes = {}
            self.head = nil
            self.tail = nil
        }

        /// Insert `id` at the head. Caller must ensure `id` is not already present.
        access(all) fun insertAtHead(id: UInt64) {
            let node = ListNode(prev: nil, next: self.head)
            if let oldHeadID = self.head {
                var oldHead = self.nodes[oldHeadID]!
                oldHead.setPrev(prev: id)
                self.nodes[oldHeadID] = oldHead
            } else {
                self.tail = id
            }
            self.nodes[id] = node
            self.head = id
        }

        /// Remove `id` from wherever it sits. Returns false if not present.
        access(all) fun remove(id: UInt64): Bool {
            let node = self.nodes.remove(key: id)
            if node == nil {
                return false
            }

            if let prevID = node!.prev {
                var prevNode = self.nodes[prevID]!
                prevNode.setNext(next: node!.next)
                self.nodes[prevID] = prevNode
            } else {
                self.head = node!.next
            }

            if let nextID = node!.next {
                var nextNode = self.nodes[nextID]!
                nextNode.setPrev(prev: node!.prev)
                self.nodes[nextID] = nextNode
            } else {
                self.tail = node!.prev
            }
            return true
        }

        /// Returns true if `id` is currently in the list.
        access(all) view fun contains(id: UInt64): Bool {
            return self.nodes[id] != nil
        }

        /// Returns up to `limit` IDs starting from the tail (least recently used).
        access(all) fun tailWalk(limit: UInt): [UInt64] {
            var result: [UInt64] = []
            var current = self.tail
            var count: UInt = 0
            while count < limit {
                if let id = current {
                    result.append(id)
                    current = self.nodes[id]?.prev
                    count = count + 1
                } else {
                    break
                }
            }
            return result
        }
    }

    /// Create a new empty List resource.
    access(all) fun createList(): @List {
        return <- create List()
    }
}
