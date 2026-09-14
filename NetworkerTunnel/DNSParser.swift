import Foundation

/// Extracts (address, name) pairs from DNS responses so destinations can be labelled with hostnames.
enum DNSParser {
    struct Record {
        let address: String
        let name: String
    }

    static func parseResponse(_ message: [UInt8]) -> [Record] {
        let m = message
        guard m.count >= 12 else { return [] }
        let flags = readUInt16(m, 2)
        guard flags & 0x8000 != 0 else { return [] }      // must be a response
        guard flags & 0x000f == 0 else { return [] }      // RCODE must be NOERROR
        let questionCount = Int(readUInt16(m, 4))
        let answerCount = Int(readUInt16(m, 6))
        guard questionCount >= 1 else { return [] }

        var offset = 12
        var questionName: String? = nil
        for _ in 0 ..< questionCount {
            guard let name = readName(m, at: offset) else { return [] }
            if questionName == nil { questionName = name.text }
            offset = name.end + 4   // QTYPE + QCLASS
            guard offset <= m.count else { return [] }
        }
        guard let owner = questionName, !owner.isEmpty, owner.count <= 253 else { return [] }

        var records: [Record] = []
        for _ in 0 ..< answerCount {
            guard let name = readName(m, at: offset) else { break }
            offset = name.end
            guard offset + 10 <= m.count else { break }
            let type = readUInt16(m, offset)
            let dataLength = Int(readUInt16(m, offset + 8))
            offset += 10
            guard offset + dataLength <= m.count else { break }
            if type == 1 && dataLength == 4 {
                records.append(Record(address: IPAddr(bytes: Array(m[offset ..< offset + 4])).string, name: owner))
            } else if type == 28 && dataLength == 16 {
                records.append(Record(address: IPAddr(bytes: Array(m[offset ..< offset + 16])).string, name: owner))
            }
            offset += dataLength
        }
        return records
    }

    /// Reads a possibly compressed domain name. `end` is the offset just past the name in the
    /// original position (i.e. not following compression pointers).
    static func readName(_ m: [UInt8], at start: Int) -> (text: String, end: Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int? = nil
        var jumps = 0
        while true {
            guard offset < m.count else { return nil }
            let length = Int(m[offset])
            if length == 0 {
                offset += 1
                break
            }
            if (length & 0xc0) == 0xc0 {
                guard offset + 1 < m.count else { return nil }
                let pointer = ((length & 0x3f) << 8) | Int(m[offset + 1])
                if end == nil { end = offset + 2 }
                jumps += 1
                guard jumps < 64 else { return nil }   // bounded, so pointer loops terminate
                offset = pointer
                continue
            }
            guard (length & 0xc0) == 0 else { return nil }
            guard offset + 1 + length <= m.count else { return nil }
            labels.append(String(decoding: m[(offset + 1) ..< (offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
            guard labels.count <= 128 else { return nil }
        }
        return (labels.joined(separator: "."), end ?? offset)
    }
}
