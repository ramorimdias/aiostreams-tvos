import Foundation
import OSLog

/**
 * The app's own unified log (its NSLog lines, AetherEngine's and the players'
 * logging), read back for the diagnostics server. It lives here because the
 * app's own code is Objective-C, and OSLogStore is Swift only.
 */
@objc(AIOLogStore)
public final class AIOLogStore: NSObject {
    private static let time: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm:ss.SSS"
        return format
    }()

    /// The last `seconds` of this process's log, oldest first, at most `limit` lines.
    @objc public static func recent(seconds: Double, limit: Int) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-seconds))
            var lines: [String] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: since) {
                let source = entry.subsystem.isEmpty ? entry.process : "\(entry.subsystem)/\(entry.category)"
                lines.append("\(time.string(from: entry.date)) [\(source)] \(entry.composedMessage)")
                if lines.count > limit * 2 { lines.removeFirst(lines.count - limit) }
            }
            return lines.suffix(limit).joined(separator: "\n")
        } catch {
            return "The log couldn't be read: \(error)"
        }
    }
}
