import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var current: Song?
    @Published private(set) var playing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue = PlaybackQueue()
    @Published var error: String?
    private let player = AVPlayer()
    private let request: ([String: String]) async throws -> EngineResponse
    private let streamItem: (URL, [String: Any]) -> AVPlayerItem
    private let library: LibraryStore
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = UUID()
    private var durationTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var artwork: MPMediaItemArtwork?
    lazy var preview = PreviewController(suspendMain: { [weak self] in
        guard let self else { return false }
        let resume = self.playing; self.pauseMain(); return resume
    }, resumeMain: { [weak self] in self?.play() }, onError: { [weak self] message in self?.error = message })

    func togglePreview(_ song: Song) {
        let saved = library.song(song.id)
        let local = saved.flatMap { library.isAvailable($0) ? library.file($0.fileName) : nil }
        preview.toggle(song, localURL: local)
    }

    init(library: LibraryStore,
         request: @escaping ([String: String]) async throws -> EngineResponse = { try await PythonService.shared.request($0) },
         streamItem: @escaping (URL, [String: Any]) -> AVPlayerItem = { AVPlayerItem(asset: AVURLAsset(url: $0, options: $1)) }) {
        self.request = request; self.streamItem = streamItem
        self.library = library
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { self.error = error.localizedDescription }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite { self.elapsed = max(0, time.seconds) }
                self.playing = self.player.rate > 0
                self.updateNowPlaying()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem,
                      self.preview.song == nil else { return }
                self.next(automatically: true)
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.playing; self.pause()
                } else if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.play()
                }
                if type != AVAudioSession.InterruptionType.began.rawValue { self.resumeAfterInterruption = false }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.pause(); self.error = "この曲を最後まで再生できませんでした。再保存を試してください。"
            }
        })
        configureCommands()
    }
    func start(_ songs: [Song], at song: Song, shuffle: Bool = false) {
        let available = songs.map { library.song($0.id) ?? $0 }.filter(library.isPlayable)
        guard available.contains(where: { $0.id == song.id }) else { error = "音声ファイルが見つかりません。検索からもう一度保存してください。"; return }
        queue.start(available.map(\.id), at: song.id, shuffle: shuffle)
        load(song)
    }
    func play() {
        preview.stop(resume: false)
        guard let current else { return }
        if player.currentItem == nil, current.onlineOnly == true { load(current); return }
        if duration > 0 && elapsed >= duration - 0.1 { seek(0) }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            player.play(); playing = true; updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    private func pauseMain() { player.pause(); playing = false; updateNowPlaying() }
    func pause() { streamGeneration = UUID(); streamTask?.cancel(); preview.stop(resume: false); pauseMain() }
    func toggle() {
        if preview.song != nil { preview.stop(resume: false) }
        else { playing ? pause() : play() }
    }
    func seek(_ seconds: Double) {
        preview.stop(resume: false)
        guard seconds.isFinite else { return }
        elapsed = min(max(0, seconds), max(0, duration))
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }
    func next(automatically: Bool = false) {
        preview.stop(resume: false)
        // Skip missing files, without recursion or an infinite repeat loop.
        var inspected = Set<String>()
        while let id = queue.advance(automatically: automatically) {
            guard inspected.insert(id).inserted else { break }
            if let song = library.song(id), library.isPlayable(song) { load(song); return }
        }
        pause()
        if automatically { seek(duration) }
    }
    func previous() {
        preview.stop(resume: false)
        if elapsed > 3 { seek(0); return }
        if let id = queue.previous(), let song = library.song(id), library.isPlayable(song) { load(song) }
        else { seek(0) }
    }
    func toggleShuffle() { queue.toggleShuffle() }
    func toggleRepeat() { queue.repeatMode = queue.repeatMode.next }
    func enqueue(_ song: Song) {
        if current == nil { start([song], at: song) } else { queue.append(song.id) }
    }
    func remove(_ id: String) {
        let wasCurrent = current?.id == id
        queue.remove(id)
        if wasCurrent {
            pause(); player.replaceCurrentItem(with: nil); current = nil; elapsed = 0; duration = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if let next = queue.current, let song = library.song(next), library.isPlayable(song) { load(song) }
        }
    }
    func refreshAfterAudioRepair() {
        guard let current, let updated = library.song(current.id),
              updated.fileName != current.fileName || updated.duration != current.duration else { return }
        let position = elapsed, wasPlaying = playing
        load(updated, autoplay: wasPlaying)
        seek(min(position, updated.duration))
    }
    func releaseRemovedDownload(_ id: String) {
        if preview.song?.id == id { preview.stop(resume: current?.id != id) }
        guard current?.id == id else { return }
        pause()
        durationTask?.cancel(); statusObservation = nil
        player.replaceCurrentItem(with: nil)
        current = library.song(id)
        elapsed = 0; duration = current?.duration ?? 0
        updateNowPlaying()
        // Keep queue position, shuffle order and repeat mode. The next play
        // resolves the online audio instead of continuing an unlinked local file.
    }
    private func load(_ song: Song, autoplay: Bool = true) {
        preview.stop(resume: false)
        let song = library.song(song.id) ?? song
        streamGeneration = UUID(); streamTask?.cancel()
        if !library.isAvailable(song), song.onlineOnly == true {
            loadOnline(song, autoplay: autoplay); return
        }
        guard let url = library.file(song.fileName), library.isAvailable(song) else { error = "音声ファイルが見つかりません。"; return }
        statusObservation = nil
        durationTask?.cancel()
        player.pause()
        let item = AVPlayerItem(url: url)
        current = song; elapsed = 0; duration = song.duration
        if song.audioTimingVersion == 1, duration.isFinite, duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 44100)
        } else {
            durationTask = Task { [weak self, weak item] in
                do {
                    let timing = try await AudioTiming.read(url)
                    try Task.checkCancellation()
                    guard let self, let item, self.player.currentItem === item, self.current?.id == song.id else { return }
                    self.duration = timing.duration
                    self.current?.duration = timing.duration
                    item.forwardPlaybackEndTime = CMTime(seconds: timing.duration, preferredTimescale: 44100)
                    if let fileName = song.fileName {
                        do { try self.library.updateAudioDuration(song.id, expectedFileName: fileName,
                                                                  duration: timing.duration) }
                        catch { self.library.message = error.localizedDescription }
                    }
                    self.updateNowPlaying()
                } catch is CancellationError { }
                catch {
                    guard let self, let item, self.player.currentItem === item else { return }
                    self.pause(); self.error = error.localizedDescription
                }
            }
        }
        artwork = nil
        if let url = library.file(song.artworkName), let image = UIImage(contentsOfFile: url.path) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let detail = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if failed { self.pause(); self.error = detail ?? "この曲を再生できません。" }
            }
        }
        if autoplay { play() } else { playing = false; updateNowPlaying() }
    }
    private func loadOnline(_ song: Song, autoplay: Bool) {
        let token = streamGeneration
        durationTask?.cancel(); statusObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        current = song; elapsed = 0; duration = song.duration; playing = false
        artwork = nil; updateNowPlaying()
        streamTask = Task { [weak self] in
            do {
                let response = try await self?.request(["op": "resolve", "id": song.id])
                guard let response else { return }
                try Task.checkCancellation()
                guard let self, self.streamGeneration == token else { return }
                guard let text = response.url, let url = URL(string: text), url.scheme == "https",
                      url.host?.hasSuffix(".googlevideo.com") == true else { throw AppFailure("音声の取得先を確認できません。") }
                var options: [String: Any] = [:]
                if let agent = response.headers?.first(where: { $0.key.lowercased() == "user-agent" })?.value { options[AVURLAssetHTTPUserAgentKey] = agent }
                let item = self.streamItem(url, options)
                self.duration = response.song?.duration ?? song.duration
                if self.duration > 0 { item.forwardPlaybackEndTime = CMTime(seconds: self.duration, preferredTimescale: 600) }
                item.preferredForwardBufferDuration = 15
                self.player.replaceCurrentItem(with: item)
                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed { self.pause(); self.error = "オンライン再生に失敗しました。通信を確認して再生し直してください。" }
                        else if item.status == .readyToPlay, self.duration <= 0, item.duration.seconds.isFinite { self.duration = item.duration.seconds; self.updateNowPlaying() }
                    }
                }
                if autoplay { self.play() }
            } catch is CancellationError {} catch {
                guard let self, self.streamGeneration == token else { return }
                self.playing = false; self.error = error.localizedDescription
            }
        }
    }
    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title,
                                  MPMediaItemPropertyArtist: current.artist,
                                  MPMediaItemPropertyPlaybackDuration: duration,
                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                                  MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                                  MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(seconds) }
            return .success
        }
    }
}
