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
    private let library: LibraryStore
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var artwork: MPMediaItemArtwork?

    init(library: LibraryStore) {
        self.library = library
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
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
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
        let available = songs.filter(library.isAvailable)
        guard available.contains(where: { $0.id == song.id }) else { error = "音声ファイルが見つかりません。検索からもう一度保存してください。"; return }
        queue.start(available.map(\.id), at: song.id, shuffle: shuffle)
        load(song)
    }
    func play() {
        guard current != nil else { return }
        if duration > 0 && elapsed >= duration - 0.1 { seek(0) }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            player.play(); playing = true; updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    func pause() { player.pause(); playing = false; updateNowPlaying() }
    func toggle() { playing ? pause() : play() }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        elapsed = min(max(0, seconds), max(0, duration))
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }
    func next(automatically: Bool = false) {
        // Skip missing files, without recursion or an infinite repeat loop.
        var inspected = Set<String>()
        while let id = queue.advance(automatically: automatically) {
            guard inspected.insert(id).inserted else { break }
            if let song = library.song(id), library.isAvailable(song) { load(song); return }
        }
        pause()
        if automatically { seek(duration) }
    }
    func previous() {
        if elapsed > 3 { seek(0); return }
        if let id = queue.previous(), let song = library.song(id), library.isAvailable(song) { load(song) }
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
            if let next = queue.current, let song = library.song(next), library.isAvailable(song) { load(song) }
        }
    }
    func refreshAfterAudioRepair() {
        guard let current, let updated = library.song(current.id), updated.fileName != current.fileName else { return }
        let position = elapsed, wasPlaying = playing
        load(updated, autoplay: wasPlaying)
        seek(min(position, updated.duration))
    }
    private func load(_ song: Song, autoplay: Bool = true) {
        guard let url = library.file(song.fileName), library.isAvailable(song) else { error = "音声ファイルが見つかりません。"; return }
        statusObservation = nil
        player.pause()
        let item = AVPlayerItem(url: url)
        current = song; elapsed = 0; duration = song.duration
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
