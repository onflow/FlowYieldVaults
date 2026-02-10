// Get current block timestamp
access(all) fun main(): String {
    return getCurrentBlock().timestamp.toString()
}
