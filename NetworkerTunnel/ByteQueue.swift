import Foundation

/// A FIFO byte buffer with O(1) amortised removal from the front.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    /// Returns up to `n` bytes from the front without removing them.
    func prefix(_ n: Int) -> ArraySlice<UInt8> {
        let length = min(max(n, 0), count)
        return storage[head ..< head + length]
    }

    mutating func removeFirst(_ n: Int) {
        let length = min(max(n, 0), count)
        head += length
        if head == storage.count {
            if storage.capacity > 256 * 1024 {
                storage = []
            } else {
                storage.removeAll(keepingCapacity: true)
            }
            head = 0
        } else if head >= 64 * 1024 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        storage = []
        head = 0
    }
}
