import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable
final class AudioController: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var playing = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var activeID: UUID?
    var rate: Float = 1 { didSet { player?.rate = rate } }
    var error: String?

    override init() {
        super.init()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(15) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue { Task { @MainActor in self?.pause() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
                self.playing = self.player?.isPlaying ?? false
            }
        }
    }

    func load(_ item: Recording, url: URL) throws {
        if activeID == item.id { return }
        player?.stop()
        player = nil; activeID = nil; duration = 0; currentTime = 0; playing = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        player = try AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.rate = rate
        player?.delegate = self
        player?.prepareToPlay()
        activeID = item.id; duration = player?.duration ?? 0; currentTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: 0]
    }
    func toggle() { playing ? pause() : resume() }
    func pause() { player?.pause(); playing = false; updateNowPlaying() }
    func resume() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            playing = player?.play() ?? false; updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ time: Double) { player?.currentTime = min(max(0, time), duration); currentTime = player?.currentTime ?? 0; updateNowPlaying() }
    func skip(_ seconds: Double) { seek(currentTime + seconds) }
    private func updateNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}
