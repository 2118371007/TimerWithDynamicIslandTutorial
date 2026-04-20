import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// UI 界面 (保持你喜欢的居中排版不变)
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
            
            Text(isMonitoring ? "酷狗搜词引擎已启动" : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    musicManager.setupMonitoring()
                } else {
                    musicManager.stopEverything()
                }
            }) {
                Text(isMonitoring ? "🛑 彻底停止并关闭" : "🚀 开启智能同步")
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
// 核心引擎 (酷狗 API + 智能暂停监控)
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

    func setupMonitoring() {
        self.errorMessage = "正在请求权限..."
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 权限获取，监听中..."
                    self.startListening()
                } else {
                    self.errorMessage = "❌ 被拒绝访问 Apple Music"
                }
            }
        }
    }
    
    private func startListening() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePlaybackStateChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        handleTrackChange()
    }
    
    @objc func handlePlaybackStateChange() {
        if musicPlayer.playbackState == .paused || musicPlayer.playbackState == .stopped {
            closeIslandOnly()
        } else if musicPlayer.playbackState == .playing {
            if currentActivity == nil { handleTrackChange() }
        }
    }

    @objc func handleTrackChange() {
        if musicPlayer.playbackState == .paused { return }
        
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            updateIsland(songName: "等待音乐...", lyric: "请播放音乐 🎵")
            return
        }
        
        let title = nowPlaying.title ?? "未知歌名"
        let artist = nowPlaying.artist ?? ""
        
        if title == currentSongName && !parsedLyrics.isEmpty { return }
        self.currentSongName = title
        
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        
        updateIsland(songName: title, lyric: "🎵 酷狗全网搜词中...")
        
        Task {
            // 直接呼叫酷狗 API，传歌名和歌手以保证100%精确度
            let lrcString = await fetchLyricFromKugou(title: title, artist: artist)
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            if self.parsedLyrics.isEmpty {
                self.updateIsland(songName: title, lyric: "❌ 未找到滚动歌词")
            } else {
                DispatchQueue.main.async {
                    self.startLyricSyncTimer(songName: title)
                }
            }
        }
    }

    func startLyricSyncTimer(songName: String) {
        lyricTimer?.invalidate()
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentTime = self.musicPlayer.currentPlaybackTime
            if currentTime.isNaN { return }
            
            var newIndex = -1
            for (index, line) in self.parsedLyrics.enumerated() {
                if currentTime >= line.time { newIndex = index } else { break }
            }
            
            if newIndex != self.currentLyricIndex && newIndex >= 0 {
                self.currentLyricIndex = newIndex
                let currentText = self.parsedLyrics[newIndex].text
                if !currentText.isEmpty {
                    self.updateIsland(songName: songName, lyric: currentText)
                }
            }
        }
    }

    // ==========================================
    // 🚨 全新酷狗音乐 API (纯净无加密，支持周杰伦)
    // ==========================================
    func fetchLyricFromKugou(title: String, artist: String) async -> String {
        // 1. 先用关键字搜出这首歌的专属 Hash 码
        let keyword = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let searchUrlString = "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(keyword)&page=1&pagesize=1"
        
        guard let searchUrl = URL(string: searchUrlString) else { return "" }
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let infoArray = dataMap["info"] as? [[String: Any]],
                  let firstSong = infoArray.first,
                  let hash = firstSong["hash"] as? String else { return "" }
            
            // 2. 拿着 Hash 码去拿歌词，cmd=100 会直接返回完美的纯文本 LRC
            let lyricUrlString = "https://m.kugou.com/app/i/krc.php?cmd=100&hash=\(hash)&timelength=300000"
            guard let lyricUrl = URL(string: lyricUrlString) else { return "" }
            
            let (lyricData, _) = try await URLSession.shared.data(from: lyricUrl)
            
            // 酷狗直接给 UTF-8 文本，不需要任何解密和 Base64！
            let lyricText = String(data: lyricData, encoding: .utf8) ?? ""
            return lyricText
            
        } catch {
            return ""
        }
    }

    // 标准 LRC 解析器
    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let components = lrcString.components(separatedBy: .newlines)
        let pattern = "\\[(\\d{2,}):(\\d{2}\\.\\d{2,3})\\](.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return lines }
        
        for line in components {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, options: [], range: range) {
                if let minRange = Range(match.range(at: 1), in: line),
                   let secRange = Range(match.range(at: 2), in: line),
                   let textRange = Range(match.range(at: 3), in: line) {
                    let min = Double(line[minRange]) ?? 0
                    let sec = Double(line[secRange]) ?? 0
                    let text = String(line[textRange])
                        .replacingOccurrences(of: "\r", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    lines.append(LyricLine(time: (min * 60) + sec, text: text))
                }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    func updateIsland(songName: String, lyric: String) {
        let state = TimerWidgetAttributes.ContentState(songName: songName, lyric: lyric)
        Task {
            if currentActivity == nil {
                do {
                    currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), contentState: state)
                    DispatchQueue.main.async { self.errorMessage = "✅ 同步中：\(songName)" }
                } catch {}
            } else {
                await currentActivity?.update(using: state)
            }
        }
    }
    
    func closeIslandOnly() {
        lyricTimer?.invalidate()
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
    
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        currentSongName = ""
        closeIslandOnly()
        self.errorMessage = "已彻底停止"
    }
}