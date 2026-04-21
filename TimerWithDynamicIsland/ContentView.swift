import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation
import AVFoundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// 1. UI 界面
// ==========================================
struct ContentView: View {
    @State private var isMonitoring = false
    @ObservedObject var musicManager = MusicManager.shared
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: isMonitoring ? "music.note.house.fill" : "music.note.house")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(isMonitoring ? .green : .gray)
                .shadow(color: isMonitoring ? .green.opacity(0.5) : .clear, radius: 10)
            
            Text(isMonitoring ? "后台免死金牌已激活" : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    musicManager.setupMonitoring()
                } else {
                    musicManager.stopEverything()
                }
            }) {
                Text(isMonitoring ? "🛑 彻底停止并关闭" : "🚀 开启不死同步")
                    .font(.title3.bold())
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(15)
                    .padding(.horizontal, 40)
            }
            
            if !musicManager.errorMessage.isEmpty {
                Text(musicManager.errorMessage)
                    .foregroundColor(musicManager.errorMessage.contains("❌") ? .red : .gray)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .padding()
    }
}

// ==========================================
// 2. 核心引擎 (加强保活版)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = ""
    
    private var parsedLyrics: [LyricLine] = []
    private var lyricTimer: Timer?
    private var currentLyricIndex = -1
    private var currentSongName = ""
    
    // 🚨 增强保活所需组件
    private let silenceEngine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func setupMonitoring() {
        self.errorMessage = "正在注入保活驱动..."
        
        // 1. 激活后台音频 Session
        configureAudioSession()
        
        // 2. 申请系统后台任务令牌
        renewBackgroundTask()
        
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 不死模式已就绪！"
                    self.startListening()
                } else {
                    self.errorMessage = "❌ 权限被拒"
                }
            }
        }
    }
    
    // 🚨 核心逻辑：配置音频 Session 为最高优先级后台播放
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            
            // 启动静音播放
            silenceEngine.attach(silencePlayer)
            let format = silenceEngine.outputNode.inputFormat(forBus: 0)
            silenceEngine.connect(silencePlayer, to: silenceEngine.outputNode, format: format)
            try silenceEngine.start()
            
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) {
                buffer.frameLength = 44100
                silencePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
                silencePlayer.play()
            }
        } catch { print("音频引擎故障") }
    }
    
    // 🚨 核心逻辑：申请后台无限时间
    private func renewBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LyricKeepAlive") {
            // 当系统快要杀掉 App 时，再次尝试重新申请（垂死挣扎）
            self.renewBackgroundTask()
        }
    }

    private func startListening() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        systemDidReportChange()
    }
    
    @objc func systemDidReportChange() {
        DispatchQueue.main.async { self.evaluateRealState() }
    }

    private func evaluateRealState() {
        let rawTitle = musicPlayer.nowPlayingItem?.title ?? ""
        let artist = musicPlayer.nowPlayingItem?.artist ?? ""
        let isPlaying = (musicPlayer.playbackState == .playing)
        
        if !rawTitle.isEmpty && rawTitle != currentSongName {
            self.currentSongName = rawTitle
            self.fetchAndStart(title: rawTitle, artist: artist)
            return
        }
        
        if isPlaying {
            if !parsedLyrics.isEmpty { startLyricSyncTimer(songName: rawTitle) }
        } else {
            lyricTimer?.invalidate()
            if !rawTitle.isEmpty { updateIsland(songName: rawTitle, lyric: "⏸ 已暂停") }
        }
    }

    private func fetchAndStart(title: String, artist: String) {
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        updateIsland(songName: title, lyric: "🎵 正在搜词...")
        
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        Task {
            let lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)")
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            DispatchQueue.main.async {
                if self.musicPlayer.playbackState == .playing { self.startLyricSyncTimer(songName: title) }
            }
        }
    }

    func startLyricSyncTimer(songName: String) {
        lyricTimer?.invalidate()
        // 🚨 使用 RunLoop.common 模式，防止 App 在后台时 Timer 被降频
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentTime = self.musicPlayer.currentPlaybackTime + 0.45
            if currentTime.isNaN { return }
            
            var newIndex = -1
            for (index, line) in self.parsedLyrics.enumerated() {
                if currentTime >= line.time { newIndex = index } else { break }
            }
            
            if newIndex != self.currentLyricIndex && newIndex >= 0 {
                self.currentLyricIndex = newIndex
                let currentText = self.parsedLyrics[newIndex].text
                self.updateIsland(songName: songName, lyric: currentText)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.lyricTimer = timer
    }

    func fetchLyricFromQQMusic(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(encoded)&format=json")!
        do {
            let (searchData, _) = try await URLSession.shared.data(from: searchUrl)
            guard let json = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let song = (json["data"] as? [String: Any])?["song"] as? [String: Any],
                  let first = (song["list"] as? [[String: Any]])?.first,
                  let songmid = first["songmid"] as? String else { return "" }
            
            let lyricUrl = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json")!
            var req = URLRequest(url: lyricUrl)
            req.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
            let (lyricData, _) = try await URLSession.shared.data(for: req)
            guard let lJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let b64 = lJson["lyric"] as? String,
                  let d = Data(base64Encoded: b64) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return lines }
        let ns = lrcString as NSString
        let results = regex.matches(in: lrcString, range: NSRange(location: 0, length: ns.length))
        for m in results {
            let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let txt = ns.substring(with: m.range(at: 3))
                .replacingOccurrences(of: "&#\\d+;", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !txt.isEmpty { lines.append(LyricLine(time: (min * 60) + sec, text: txt)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    func updateIsland(songName: String, lyric: String) {
        let state = TimerWidgetAttributes.ContentState(songName: songName, lyric: lyric)
        Task {
            if currentActivity == nil {
                do {
                    let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100.0)
                    currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), content: content)
                } catch {}
            } else {
                let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100.0)
                await currentActivity?.update(content)
            }
        }
    }
    
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        lyricTimer?.invalidate()
        if silenceEngine.isRunning { silencePlayer.stop(); silenceEngine.stop() }
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        currentSongName = ""
        Task { await currentActivity?.end(dismissalPolicy: .immediate); currentActivity = nil }
        self.errorMessage = "已停止同步"
    }
}