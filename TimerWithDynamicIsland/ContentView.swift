import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// UI 界面
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
            
            Text(isMonitoring ? "QQ音乐引擎已启动" : "歌词同步已关闭")
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
// 核心引擎 (QQ音乐爬虫 + 暂停监控)
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
        // 监听切歌
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        // 🚨 新增：监听暂停/播放状态
        NotificationCenter.default.addObserver(self, selector: #selector(handlePlaybackStateChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        
        handleTrackChange()
    }
    
    // 🚨 暂停/播放 智能检测
    @objc func handlePlaybackStateChange() {
        if musicPlayer.playbackState == .paused || musicPlayer.playbackState == .stopped {
            // 暂停时：只关岛，不关监听
            closeIslandOnly()
        } else if musicPlayer.playbackState == .playing {
            // 恢复播放时：重新上岛
            if currentActivity == nil {
                handleTrackChange()
            }
        }
    }

    @objc func handleTrackChange() {
        // 如果正在暂停，不处理
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
        
        updateIsland(songName: title, lyric: "🎵 QQ音乐全网搜词中...")
        
        // 调用 QQ 音乐接口
        Task {
            let lrcString = await fetchLyricFromQQMusic(title: title, artist: artist)
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

    // 🚨 QQ 音乐 API 黑科技爬虫
    func fetchLyricFromQQMusic(title: String, artist: String) async -> String {
        let keyword = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let searchUrlString = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(keyword)&format=json"
        
        guard let searchUrl = URL(string: searchUrlString) else { return "" }
        
        do {
            // 1. 搜歌名，拿 songmid
            let (searchData, _) = try await URLSession.shared.data(from: searchUrl)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let songMap = dataMap["song"] as? [String: Any],
                  let listArray = songMap["list"] as? [[String: Any]],
                  let firstSong = listArray.first,
                  let songmid = firstSong["songmid"] as? String else { return "" }
            
            // 2. 拿着 songmid 强刷歌词接口
            let lyricUrlString = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json"
            var request = URLRequest(url: URL(string: lyricUrlString)!)
            // QQ音乐接口防盗链核心：必须伪装 Referer
            request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
            
            let (lyricData, _) = try await URLSession.shared.data(for: request)
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lyricBase64 = lyricJson["lyric"] as? String,
                  let decodedData = Data(base64Encoded: lyricBase64),
                  let lyricText = String(data: decodedData, encoding: .utf8) else { return "" }
            
            return lyricText
        } catch {
            return ""
        }
    }

    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let components = lrcString.components(separatedBy: .newlines)
        // 兼容 [00:00.00] 或 [00:00.000] 格式
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
                        .replacingOccurrences(of: "&#32;", with: " ") // 处理QQ音乐特有的空格转义
                        .trimmingCharacters(in: .whitespaces)
                    lines.append(LyricLine(time: (min * 60) + sec, text: text))
                }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // 🚨 终极丝滑更新：永远不再强制杀进程，全部无缝 Update！
    func updateIsland(songName: String, lyric: String) {
        let state = TimerWidgetAttributes.ContentState(songName: songName, lyric: lyric)
        
        Task {
            if currentActivity == nil {
                do {
                    currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), contentState: state)
                    DispatchQueue.main.async { self.errorMessage = "✅ 正在同步：\(songName)" }
                } catch {
                    DispatchQueue.main.async { self.errorMessage = "❌ 灵动岛故障: \(error.localizedDescription)" }
                }
            } else {
                await currentActivity?.update(using: state)
            }
        }
    }
    
    // 只关岛，保留后台监听（用于暂停时）
    func closeIslandOnly() {
        lyricTimer?.invalidate()
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
    
    // 彻底杀掉所有功能（用于点 App 里的停止按钮）
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        currentSongName = ""
        closeIslandOnly()
        self.errorMessage = "已彻底停止"
    }
}