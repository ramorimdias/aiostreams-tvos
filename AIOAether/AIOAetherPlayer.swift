import AVFoundation
import Combine
import UIKit

import AetherEngine

/**
 * The page's player on AetherEngine (FFmpeg demuxing, VideoToolbox and
 * AVPlayer playing), which keeps the TV's own Dolby Vision, HDR and Atmos.
 * It speaks the page's `player-*` messages
 * (packages/web/src/lib/hosts/shell/player.ts) as the mpv player does.
 *
 * It lives in its own framework so the engine's FFmpeg is the one it calls:
 * mpv and VLC link their own into the app.
 */
@MainActor
@objc(AIOAetherPlayer)
public final class AIOAetherPlayer: NSObject {
    /// Sends a message to the page.
    @objc public var send: ([String: Any]) -> Void = { _ in }

    /// The engine's version, for the page's about screen.
    @objc public static var engineVersion: String { AetherEngine.version }

    private let host: UIView
    private let surface: AetherPlayerView
    private let subtitles: AIOSubtitleOverlay
    private let stats: UILabel
    private let engine: AetherEngine?
    private var observers = Set<AnyCancellable>()

    // The file playing, and what the page asked for it.
    private var url: String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var loaded = false
    private var ended = false
    private var subtitleMode = "default"
    /// Subtitle files added by URL, by the track id the engine listed them under.
    private var externalURLs: [Int: String] = [:]
    private var autoSkips: [(start: Double, end: Double)] = []
    private var skipping = false

    // What the page set, kept across files.
    private var volume: Double = 1
    private var muted = false
    private var speed: Double = 1
    private var wantPaused = false
    private var audioDelayMs: Double = 0
    private var shaping = AudioShaping()

    // What was last sent, so only changes go out.
    private var sentPositionAt: CFTimeInterval = 0
    private var sentTracks: String?

    private var thumbnailTask: Task<Void, Never>?
    private var statsTimer: Timer?

    @objc public init(host: UIView) {
        self.host = host
        surface = AetherPlayerView(frame: host.bounds)
        subtitles = AIOSubtitleOverlay(frame: host.bounds)
        stats = UILabel()
        engine = try? AetherEngine()
        super.init()

        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false
        surface.isHidden = true
        host.addSubview(surface)

        subtitles.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        subtitles.isHidden = true
        host.addSubview(subtitles)

        stats.numberOfLines = 0
        stats.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        stats.textColor = .white
        stats.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        stats.layer.cornerRadius = 8
        stats.layer.masksToBounds = true
        stats.isHidden = true
        host.addSubview(stats)

        guard let engine else {
            NSLog("[aether] the engine couldn't start")
            return
        }
        engine.bind(view: surface)
        subtitles.engine = engine
        observe(engine)
    }

    // MARK: - Messages from the page

    @objc(handle:message:)
    public func handle(_ type: String, message: [String: Any]) -> Bool {
        switch type {
        case "player-load": load(message)
        case "player-stop": stop()
        case "player-set": change(message)
        case "player-seek":
            guard let ms = number(message["positionMs"]) else { break }
            let exact = (number(message["snapMs"]) ?? 0) <= 0
            Task { await engine?.seek(to: ms / 1000, exact: exact) }
        case "player-sync": sync()
        case "player-skips": setSkips(message["segments"])
        case "player-style": style(message)
        case "player-settings": settings(message)
        case "player-subtitle-add": addSubtitle(message)
        case "player-stats-overlay": showStats(message["page"] as? String)
        case "player-thumbnail": thumbnail(message)
        case "player-subtitle-index":
            send(["type": "player-subtitle-index", "tracks": NSNull()])
        case "subtitle-file": addSubtitleFile(message)
        default:
            // player-subtitle-lines, player-controls, player-engine, player-retry: nothing here.
            return type.hasPrefix("player-")
        }
        return true
    }

    @objc public func pauseForBackground() {
        engine?.pause()
    }

    /// Stops at once and lets go of the views, for another player to take over.
    @objc public func shutdown() {
        loadTask?.cancel()
        thumbnailTask?.cancel()
        statsTimer?.invalidate()
        observers.removeAll()
        if let engine {
            engine.volume = 0
            engine.stop()
        }
        surface.removeFromSuperview()
        subtitles.removeFromSuperview()
        stats.removeFromSuperview()
    }

    // MARK: - Loading

    private func load(_ message: [String: Any]) {
        guard let engine else {
            post(["type": "player-ended", "reason": "error", "error": "AetherEngine couldn't start"])
            return
        }
        guard let text = message["url"] as? String, let source = URL(string: text),
              ["http", "https"].contains(source.scheme?.lowercased() ?? "") else {
            post(["type": "error", "message": "only http(s) urls play"])
            return
        }
        loadTask?.cancel()
        thumbnailTask?.cancel()
        generation += 1
        let current = generation
        url = text
        loaded = false
        ended = false
        externalURLs = [:]
        sentTracks = nil
        subtitleMode = message["subtitleMode"] as? String ?? "default"

        var options = LoadOptions()
        options.httpHeaders = headers(message["headers"])
        options.preferredAudioLanguages = languages(message["audioLanguages"])
        if subtitleMode != "none" && subtitleMode != "forced" {
            options.preferredSubtitleLanguages = languages(message["subtitleLanguages"])
        }
        options.matchContentEnabled = host.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? true
        options.autoplay = !wantPaused
        options.audioDelaySeconds = audioDelayMs / 1000
        options.audioShaping = shaping
        let startMs = number(message["startMs"]) ?? 0

        surface.isHidden = false
        subtitles.isHidden = false
        subtitles.clear()
        sendEvent("start")
        loadTask = Task { [weak self] in
            do {
                _ = try await engine.load(url: source, startPosition: startMs > 0 ? startMs / 1000 : nil,
                                          options: options)
                guard let self, current == self.generation else { return }
                self.loaded = true
                self.applyVolume()
                if self.speed != 1 { engine.setRate(Float(self.speed)) }
                self.pickSubtitles()
                self.sendEvent("loaded")
                self.sync()
            } catch is CancellationError {
            } catch {
                guard let self, current == self.generation else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Subtitles the engine doesn't pick by language: none, or only forced ones.
    private func pickSubtitles() {
        guard let engine else { return }
        if subtitleMode == "none" {
            engine.clearSubtitle()
        } else if subtitleMode == "forced" {
            if let forced = engine.subtitleTracks.first(where: { $0.isForced }) {
                engine.selectSubtitleTrack(index: forced.id)
            } else {
                engine.clearSubtitle()
            }
        }
    }

    /// Silent at once, then stopped.
    private func stop() {
        loadTask?.cancel()
        thumbnailTask?.cancel()
        generation += 1
        url = nil
        loaded = false
        if let engine {
            engine.volume = 0
            engine.stop()
        }
        surface.isHidden = true
        subtitles.isHidden = true
        subtitles.clear()
        post(["type": "player-ended", "reason": "stop", "error": NSNull()])
        sendState(["idle": true])
    }

    private func fail(_ text: String) {
        guard !ended else { return }
        ended = true
        var message: [String: Any] = ["type": "player-ended", "reason": "error", "error": text]
        if let info = engine?.errorInfo {
            if info.kind == .sourceRefused || info.kind == .sourceRateLimited, let status = info.underlyingCode,
               status >= 100 {
                message["status"] = status
            }
            message["cause"] = info.message
        }
        post(message)
    }

    // MARK: - Changes

    private func change(_ message: [String: Any]) {
        guard let engine else { return }
        if let paused = message["paused"] as? Bool {
            wantPaused = paused
            if loaded { paused ? engine.pause() : engine.play() }
        }
        if let value = number(message["volume"]) { volume = value }
        if let value = message["muted"] as? Bool { muted = value }
        if message["volume"] != nil || message["muted"] != nil {
            applyVolume()
            sendState(["volume": volume, "muted": muted])
        }
        if let value = number(message["speed"]) {
            speed = value
            engine.setRate(Float(value))
            sendState(["speed": value])
        }
        if let audio = message["audio"] as? String, let id = Int(audio) {
            engine.selectAudioTrack(index: id)
        }
        if let subtitle = message["subtitle"] {
            if subtitle is NSNull {
                engine.clearSubtitle()
            } else if let text = subtitle as? String, let id = Int(text) {
                engine.selectSubtitleTrack(index: id)
            }
        }
        if let delay = number(message["subtitleDelayMs"]) {
            subtitles.delay = delay / 1000
        }
    }

    private func applyVolume() {
        engine?.volume = muted ? 0 : Float(min(1, max(0, volume)))
    }

    private func setSkips(_ segments: Any?) {
        autoSkips = (segments as? [[String: Any]] ?? []).compactMap { segment in
            guard segment["auto"] as? Bool == true, let start = number(segment["startMs"]),
                  let end = number(segment["endMs"]), end > start else { return nil }
            return (start, end)
        }
    }

    private func skipIfInSegment(_ positionMs: Double) {
        guard !skipping, let engine else { return }
        for skip in autoSkips where positionMs >= skip.start && positionMs < skip.end - 500 {
            skipping = true
            Task { [weak self] in
                await engine.seek(to: skip.end / 1000)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.skipping = false
            }
            return
        }
    }

    /// The page's subtitle look and fit.
    private func style(_ message: [String: Any]) {
        switch message["fit"] as? String {
        case "crop": engine?.videoGravity = .resizeAspectFill
        case "stretch": engine?.videoGravity = .resize
        default: engine?.videoGravity = .resizeAspect
        }
        if let look = message["subtitles"] as? [String: Any] {
            subtitles.style = AIOSubtitleStyle(look)
        }
    }

    private func settings(_ message: [String: Any]) {
        guard let engine else { return }
        if let delay = number(message["audioDelayMs"]) {
            audioDelayMs = delay
            if loaded { engine.setAudioDelay(delay / 1000) }
        }
        // Shaping rebuilds the session, so it waits for the next file.
        var next = shaping
        if let channels = message["audioChannels"] as? String {
            next.maxChannels = ["stereo": 2, "5.1": 6, "7.1": 8][channels]
        }
        if let boost = number(message["dialogueBoost"]) {
            next.dialogueGainDB = min(AudioShaping.maxDialogueGainDB, max(0, boost))
        }
        if let night = message["nightMode"] as? Bool {
            next.compressor = night ? .night : nil
        }
        shaping = next
    }

    // MARK: - Subtitle files

    private func addSubtitle(_ message: [String: Any]) {
        guard let engine, let text = message["url"] as? String, let source = URL(string: text),
              ["http", "https"].contains(source.scheme?.lowercased() ?? "") else {
            post(["type": "error", "message": "only http(s) subtitles load"])
            return
        }
        if let replace = number(message["replace"]) {
            engine.removeExternalSubtitleTrack(id: Int(replace))
            externalURLs[Int(replace)] = nil
        }
        let title = message["title"] as? String
        let language = (message["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: source, name: title, language: language, httpHeaders: [:]))
        externalURLs[track.id] = text
        engine.selectSubtitleTrack(index: track.id)
        sendTracks(force: true)
    }

    /// A subtitle file the user picked, sent as base64, written out for the engine to open.
    private func addSubtitleFile(_ message: [String: Any]) {
        guard let engine else { return }
        let name = message["name"] as? String ?? "subtitle.srt"
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["srt", "vtt", "ass", "ssa", "sub", "sup"].contains(ext),
              let data = Data(base64Encoded: message["data"] as? String ?? "", options: .ignoreUnknownCharacters),
              !data.isEmpty, data.count <= 10 << 20 else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: file)) != nil else { return }
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: file, name: String(name.prefix(200)), formatHint: ext))
        engine.selectSubtitleTrack(index: track.id)
        sendTracks(force: true)
    }

    // MARK: - Seek-bar pictures

    /// The engine's still from what it already holds, or its keyframe ladder: no second connection.
    private func thumbnail(_ message: [String: Any]) {
        guard let engine, let wanted = message["url"] as? String, wanted == url,
              let positionMs = number(message["positionMs"]) else { return }
        thumbnailTask?.cancel()
        let cancelled = AIOFlag()
        thumbnailTask = Task { [weak self] in
            await withTaskCancellationHandler {
                guard let frame = await engine.scrubPreviewFrame(
                    atSeconds: positionMs / 1000, refined: false, maxWidth: 480,
                    isCancelled: { cancelled.value }) else { return }
                guard !Task.isCancelled,
                      let jpeg = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.7) else { return }
                // No picture is no answer: a null tells the page the file has none at all.
                self?.send([
                    "type": "player-thumbnail", "url": wanted,
                    "positionMs": frame.actualSeconds * 1000,
                    "src": "data:image/jpeg;base64," + jpeg.base64EncodedString(),
                ])
            } onCancel: {
                cancelled.value = true
            }
        }
    }

    // MARK: - Statistics

    private func showStats(_ page: String?) {
        statsTimer?.invalidate()
        statsTimer = nil
        stats.isHidden = page == nil
        guard page != nil else { return }
        updateStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
    }

    private func updateStats() {
        guard let engine else { return }
        let width = engine.sourceVideoWidth
        let height = engine.sourceVideoHeight
        let lines = [
            "Engine     AetherEngine \(AetherEngine.version)",
            "Route      \(engine.videoRoute.rawValue)",
            "Video      \(engine.sourceVideoCodecName ?? "?") \(width)×\(height) · \(engine.videoFormat)",
            "Decoder    \(engine.activeVideoDecoder ?? "AVPlayer")",
            "Audio      \(engine.activeAudioDecoder ?? "?") · \(engine.audioDelivery)",
            String(format: "Buffered   %.1f s", max(0, engine.clock.bufferedPosition - engine.clock.currentTime)),
        ]
        stats.text = lines.map { "  \($0)  " }.joined(separator: "\n")
        let size = stats.sizeThatFits(CGSize(width: host.bounds.width, height: .greatestFiniteMagnitude))
        stats.frame = CGRect(x: 60, y: 40, width: size.width, height: size.height)
    }

    // MARK: - Reports

    private func observe(_ engine: AetherEngine) {
        engine.$state.sink { [weak self] state in
            self?.stateChanged(state)
        }.store(in: &observers)
        engine.$playbackPhase.sink { [weak self] phase in
            switch phase {
            case .rebuffering, .stalled, .loading: self?.sendState(["buffering": true])
            default: self?.sendState(["buffering": false])
            }
        }.store(in: &observers)
        engine.$isSeeking.removeDuplicates().sink { [weak self] seeking in
            self?.sendState(["seeking": seeking])
        }.store(in: &observers)
        engine.$duration.removeDuplicates().sink { [weak self] duration in
            if duration > 0 { self?.sendState(["durationMs": duration * 1000]) }
        }.store(in: &observers)
        engine.clock.$currentTime.sink { [weak self] seconds in
            self?.positionChanged(seconds)
        }.store(in: &observers)
        engine.$audioTracks.combineLatest(engine.$subtitleTracks)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.sendTracks(force: false) }
            }.store(in: &observers)
        engine.$activeAudioTrackIndex.removeDuplicates().sink { [weak self] id in
            self?.sendState(["audio": id.map { String($0) } ?? NSNull()])
        }.store(in: &observers)
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] id in
            self?.sendState(["subtitle": id.map { String($0) } ?? NSNull()])
        }.store(in: &observers)
        engine.$mediaChapters.sink { [weak self] chapters in
            self?.sendChapters(chapters)
        }.store(in: &observers)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().sink { [weak self] ready in
            if ready { self?.sendEvent("restart") }
        }.store(in: &observers)
        engine.seekEvents.sink { [weak self] event in
            if case .landed = event.outcome { self?.sendEvent("restart") }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreAfterBackground() }
            }.store(in: &observers)
    }

    /// tvOS takes the video away in the background; it comes back paused where it was.
    private func restoreAfterBackground() {
        guard let engine, loaded, engine.needsForegroundVideoRestore else { return }
        Task {
            _ = try? await engine.reloadAtCurrentPosition { options in
                options.autoplay = false
            }
        }
    }

    private func stateChanged(_ state: PlaybackState) {
        switch state {
        case .playing:
            sendState(["paused": false, "idle": false])
        case .paused:
            sendState(["paused": true, "idle": false])
        case .ended:
            guard !ended, url != nil else { return }
            ended = true
            post(["type": "player-ended", "reason": "eof", "error": NSNull()])
            sendState(["idle": true])
        case .error(let text):
            guard url != nil else { return }
            fail(text)
        default:
            break
        }
    }

    private func positionChanged(_ seconds: Double) {
        guard url != nil, seconds.isFinite else { return }
        let ms = seconds * 1000
        skipIfInSegment(ms)
        let now = CACurrentMediaTime()
        guard now - sentPositionAt >= 0.25 else { return }
        sentPositionAt = now
        var fields: [String: Any] = ["positionMs": ms]
        if let buffered = engine?.clock.bufferedPosition, buffered > seconds {
            fields["buffered"] = [["startMs": ms, "endMs": buffered * 1000]]
        }
        sendState(fields)
    }

    private func sync() {
        guard let engine else { return }
        let idle = url == nil || engine.state == .idle || engine.state == .ended
        var state: [String: Any] = [
            "idle": idle,
            "paused": engine.state == .paused,
            "volume": volume,
            "maxVolume": 1,
            "muted": muted,
            "speed": speed,
            "seeking": engine.isSeeking,
        ]
        if !idle { state["positionMs"] = engine.clock.currentTime * 1000 }
        if engine.duration > 0 { state["durationMs"] = engine.duration * 1000 }
        state["audio"] = engine.activeAudioTrackIndex.map { String($0) } ?? NSNull()
        state["subtitle"] = engine.activeSubtitleTrackIndex.map { String($0) } ?? NSNull()
        sendState(state)
        sendTracks(force: true)
        sendChapters(engine.mediaChapters)
    }

    private func sendTracks(force: Bool) {
        guard let engine, url != nil else { return }
        var tracks: [[String: Any]] = []
        for (kind, list) in [("audio", engine.audioTracks), ("subtitle", engine.subtitleTracks)] {
            for track in list {
                var entry: [String: Any] = [
                    "id": String(track.id), "type": kind,
                    "default": track.isDefault, "forced": track.isForced,
                    "hearingImpaired": track.isHearingImpaired, "visualImpaired": track.isVisualImpaired,
                    "external": track.isExternal, "codec": track.codec,
                ]
                if !track.name.isEmpty { entry["title"] = track.name }
                if let language = track.language, !language.isEmpty { entry["language"] = language }
                if let url = externalURLs[track.id] { entry["url"] = url }
                tracks.append(entry)
            }
        }
        let key = tracks.map { "\($0["type"]!):\($0["id"]!):\($0["title"] ?? ""):\($0["url"] ?? "")" }.joined(separator: "|")
        if !force && key == sentTracks { return }
        sentTracks = key
        post(["type": "player-tracks", "tracks": tracks])
    }

    private func sendChapters(_ chapters: [ChapterInfo]) {
        guard url != nil else { return }
        post(["type": "player-chapters", "chapters": chapters.map { chapter -> [String: Any] in
            var entry: [String: Any] = ["startMs": chapter.startSeconds * 1000]
            if !chapter.name.isEmpty { entry["title"] = chapter.name }
            return entry
        }])
    }

    private func sendEvent(_ name: String) {
        post(["type": "player-event", "name": name])
    }

    private func sendState(_ fields: [String: Any]) {
        var state = fields
        state["type"] = "player-state"
        post(state)
    }

    private func post(_ message: [String: Any]) {
        send(message)
    }

    // MARK: - Helpers

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func languages(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= 16 }
    }

    private func headers(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in value as? [String: Any] ?? [:] {
            if let text = value as? String, !name.isEmpty, !text.contains("\n"), !text.contains("\r") {
                out[name] = text
            }
        }
        return out
    }
}

/// A flag read from the engine's own threads.
private final class AIOFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
