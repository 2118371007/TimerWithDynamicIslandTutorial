import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// UI 界面 (保持居中排版)
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
            
            Text(isMonitoring ? "智能搜词引擎已启动" : "歌词同步已关闭")
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
// 核心引擎 (防误杀机制 + 名字净化器)
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
                    self.errorMessage = "❌ 被拒绝访问"
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
    
    // 🚨 修复Bug 1：防误杀机制
    @objc func handlePlaybackStateChange() {
        let title = musicPlayer.nowPlayingItem?.title ?? currentSongName
        
        if musicPlayer.playbackState == .paused || musicPlayer.playbackState == .stopped {
            // 切歌或暂停时：千万不要关岛！只是暂停滚动，并显示暂停状态
            lyricTimer?.invalidate()
            updateIsland(songName: title, lyric: "⏸ 已暂停播放")
        } else if musicPlayer.playbackState == .playing {
            // 恢复播放时：检查是否切了新歌
            if title != currentSongName || parsedLyrics.isEmpty {
                handleTrackChange()
            } else {
                startLyricSyncTimer(songName: title)
            }
        }
    }

    @objc func handleTrackChange() {
        if musicPlayer.playbackState == .paused { return }
        
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            updateIsland(songName: "等待音乐...", lyric: "请播放音乐 🎵")
            return
        }
        
        let rawTitle = nowPlaying.title ?? "未知歌名"
        if rawTitle == currentSongName && !parsedLyrics.isEmpty { return }
        self.currentSongName = rawTitle
        
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        
        updateIsland(songName: rawTitle, lyric: "🎵 全网匹配歌词中...")
        
        // 🚨 修复Bug 2：歌名净化器 (砍掉括号里的 Live 版等杂音)
        var cleanTitle = rawTitle
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        Task {
            // 先用网易云搜，如果搜不到（比如周杰伦），瞬间切酷狗
            var lrcString = await fetchLyricFromNetEase(keyword: cleanTitle)
            if lrcString.isEmpty {
                lrcString = await fetchLyricFromKugou(keyword: cleanTitle)
            }
            
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            if self.parsedLyrics.isEmpty {
                self.updateIsland(songName: rawTitle, lyric: "❌ 版权限制或无歌词")
            } else {
                DispatchQueue.main.async {
                    self.startLyricSyncTimer(songName: rawTitle)
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
    // API 1：网易云音乐 (解析最稳定)
    // ==========================================
    func fetchLyricFromNetEase(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=1")!
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let result = searchJson["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let songId = songs.first?["id"] as? Int else { return "" }
            
            let lyricUrl = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&kv=1&tv=-1")!
            let (lyricData, _) = try await URLSession.shared.data(from: lyricUrl)
            
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJson["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String else { return "" }
            return lyricText
        } catch { return "" }
    }

    // ==========================================
    // API 2：酷狗音乐 (专治周杰伦等无版权歌曲)
    // ==========================================
    func fetchLyricFromKugou(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(encoded)&page=1&pagesize=1")!
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let infoArray = dataMap["info"] as? [[String: Any]],
                  let hash = infoArray.first?["hash"] as? String else { return "" }
            
            let lyricUrl = URL(string: "https://m.kugou.com/app/i/krc.php?cmd=100&hash=\(hash)&timelength=999999")!
            let (lyricData, _) = try await URLSession.shared.data(from: lyricUrl)
            return String(data: lyricData, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let components = lrcString.components(separatedBy: .newlines)
        let pattern = "\\[(\\d{2,}):(\\d{2}\\.\\d{2,3})\\](.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return lines }
        
        for line in components {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, options: [], range: range) {
                if let min = Double(String(line[Range(match.range(at: 1), in: line)!])),
                   let sec = Double(String(line[Range(match.range(at: 2), in: line)!])) {
                    let text = String(line[Range(match.range(at: 3), in: line)!])
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
    
    // 只在彻底关闭时调用
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        lyricTimer?.invalidate()
        currentSongName = ""
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        self.errorMessage = "已彻底停止"
    }
}