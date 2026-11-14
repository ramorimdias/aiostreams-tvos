import Foundation

/**
 * When each line of a Matroska file's own subtitles shows, read from the
 * file's index (its Cues) with a few range requests rather than by playing
 * it: the page's `player-subtitle-index`, which lets it line an added
 * subtitle up at once. AIOStreams' desktop and Android apps read the same
 * from the file (`subtitle_timelines`).
 *
 * mkvmerge lists every subtitle frame in the Cues, with its duration. A file
 * without Cues, or whose Cues leave the subtitles out, has no index, and
 * neither has any other container here; the page then waits for the lines as
 * they play.
 */
enum AIOSubtitleIndex {
    /// One of the file's subtitle tracks, in file order.
    struct Timeline {
        /// Matroska's codec ID, such as `S_TEXT/UTF8`.
        let codec: String
        /// Pictures (PGS, VobSub, DVB), whose index entries aren't one a line: listed without lines.
        let isPicture: Bool
        /// In milliseconds.
        let lines: [(start: Double, end: Double)]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let pictureCodecs: Set<String> = ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB"]
    /// How long a line whose entry has no duration shows, at most, before the next.
    private static let untimedMs: UInt64 = 4_000
    private static let headBytes = 64 * 1024
    private static let largestElement: UInt64 = 32 * 1024 * 1024

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let cluster: UInt32 = 0x1F43_B675
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueDuration: UInt32 = 0xB2
    }

    /// Every subtitle track of a Matroska file, in file order.
    static func read(url: URL, headers: [String: String]) async throws -> [Timeline] {
        let reader = RangeReader(url: url, headers: headers)
        let head = try await reader.read(0, headBytes)
        guard head.count > 4, element(head, 0)?.id == ID.ebml else { throw Failure("not a Matroska file") }

        // The EBML header, then the segment everything else is in.
        guard let ebml = element(head, 0), let ebmlSize = ebml.size,
              let segment = element(head, ebml.length + Int(ebmlSize)), segment.id == ID.segment else {
            throw Failure("no segment")
        }
        let dataStart = UInt64(ebml.length) + ebmlSize + UInt64(segment.length)

        // What the head holds whole, and where the seek head says the rest is.
        var bodies: [UInt32: [UInt8]] = [:]
        var positions: [UInt32: UInt64] = [:]
        var at = Int(dataStart)
        while let next = element(head, at), next.id != ID.cluster, let size = next.size {
            let start = at + next.length
            let end = start + Int(min(size, UInt64(Int.max / 2)))
            if end <= head.count {
                let body = Array(head[start..<end])
                if next.id == ID.seekHead {
                    for seek in children(body) where seek.id == ID.seek {
                        guard let id = find(seek.body, ID.seekID), let position = find(seek.body, ID.seekPosition)
                        else { continue }
                        positions[UInt32(truncatingIfNeeded: uint(id))] = dataStart + uint(position)
                    }
                } else {
                    bodies[next.id] = body
                }
            } else {
                positions[next.id] = positions[next.id] ?? UInt64(at)
            }
            at = end
            if at >= head.count { break }
        }

        func body(_ id: UInt32) async throws -> [UInt8]? {
            if let held = bodies[id] { return held }
            guard let position = positions[id] else { return nil }
            let start = try await reader.read(position, 16)
            guard let found = element(start, 0), found.id == id, let size = found.size, size <= largestElement else {
                throw Failure("element \(String(id, radix: 16)) isn't where the file says")
            }
            return try await reader.read(position + UInt64(found.length), Int(size))
        }

        guard let tracksBody = try await body(ID.tracks) else { throw Failure("no tracks") }
        var subtitles: [(number: UInt64, codec: String)] = []
        for entry in children(tracksBody) where entry.id == ID.trackEntry {
            guard let type = find(entry.body, ID.trackType), uint(type) == 0x11,
                  let number = find(entry.body, ID.trackNumber) else { continue }
            let codec = find(entry.body, ID.codecID).map { String(decoding: $0, as: UTF8.self) } ?? ""
            subtitles.append((uint(number), codec.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))))
        }
        guard !subtitles.isEmpty else { return [] }

        var scale: UInt64 = 1_000_000
        if let info = try await body(ID.info), let value = find(info, ID.timestampScale), uint(value) > 0 {
            scale = uint(value)
        }
        guard let cues = try await body(ID.cues) else { throw Failure("no index") }

        var points: [UInt64: [(start: UInt64, duration: UInt64?)]] = [:]
        let wanted = Set(subtitles.map(\.number))
        for point in children(cues) where point.id == ID.cuePoint {
            guard let time = find(point.body, ID.cueTime) else { continue }
            let startMs = uint(time) &* scale / 1_000_000
            for place in children(point.body) where place.id == ID.cueTrackPositions {
                guard let track = find(place.body, ID.cueTrack), wanted.contains(uint(track)) else { continue }
                let duration = find(place.body, ID.cueDuration).map { uint($0) &* scale / 1_000_000 }
                points[uint(track), default: []].append((startMs, duration))
            }
        }

        return subtitles.map { track in
            let picture = pictureCodecs.contains(track.codec)
            let lines = picture ? [] : timedLines(points[track.number] ?? [])
            return Timeline(codec: track.codec, isPicture: picture,
                            lines: lines.map { (Double($0.0), Double($0.1)) })
        }
    }

    /// Each entry a line, to its duration's end, or to the next line or four seconds on without one.
    private static func timedLines(_ unsorted: [(start: UInt64, duration: UInt64?)]) -> [(UInt64, UInt64)] {
        var seen = Set<UInt64>()
        let points = unsorted.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
        var lines: [(UInt64, UInt64)] = []
        for (i, point) in points.enumerated() {
            var end = point.start + untimedMs
            if let duration = point.duration, duration > 0 {
                end = point.start + duration
            } else if i + 1 < points.count {
                end = min(end, points[i + 1].start)
            }
            if end > point.start { lines.append((point.start, end)) }
        }
        return lines
    }

    // MARK: EBML

    /// An element's id (with its length marker), its header's length and its body's size; nil size is unknown.
    private static func element(_ b: [UInt8], _ i: Int) -> (id: UInt32, length: Int, size: UInt64?)? {
        guard i >= 0, i < b.count, b[i] != 0 else { return nil }
        let idLength = b[i].leadingZeroBitCount + 1
        guard idLength <= 4, i + idLength < b.count else { return nil }
        var id: UInt32 = 0
        for k in 0..<idLength { id = id << 8 | UInt32(b[i + k]) }
        let s = i + idLength
        guard b[s] != 0 else { return nil }
        let sizeLength = b[s].leadingZeroBitCount + 1
        guard s + sizeLength <= b.count else { return nil }
        var size = UInt64(b[s]) & (0xFF >> sizeLength)
        var unknown = size == UInt64(0xFF >> sizeLength)
        for k in 1..<sizeLength {
            size = size << 8 | UInt64(b[s + k])
            if b[s + k] != 0xFF { unknown = false }
        }
        return (id, idLength + sizeLength, unknown ? nil : size)
    }

    private static func children(_ body: [UInt8]) -> [(id: UInt32, body: [UInt8])] {
        var out: [(UInt32, [UInt8])] = []
        var at = 0
        while let next = element(body, at), let size = next.size {
            let start = at + next.length
            guard size <= UInt64(body.count - start) else { break }
            let end = start + Int(size)
            out.append((next.id, Array(body[start..<end])))
            at = end
        }
        return out
    }

    private static func find(_ body: [UInt8], _ id: UInt32) -> [UInt8]? {
        children(body).first { $0.id == id }?.body
    }

    private static func uint(_ b: [UInt8]) -> UInt64 {
        b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// Reads stretches of the file, one request at a time, and only from a server that honours ranges.
private final class RangeReader: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func read(_ offset: UInt64, _ length: Int) async throws -> [UInt8] {
        guard length > 0 else { return [] }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        // A whole file in answer to a range isn't read.
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            bytes.task.cancel()
            throw AIOSubtitleIndex.Failure("the server doesn't answer ranges")
        }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        for try await byte in bytes {
            out.append(byte)
            if out.count >= length { break }
        }
        bytes.task.cancel()
        return out
    }
}
