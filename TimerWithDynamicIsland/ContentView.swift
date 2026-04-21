import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// UI 界面 (保持纯净毛玻璃效果)
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
            
            Text(isMonitoring ? "防抖抗压引擎已启动" : "歌词同步已关闭")
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
// 核心引擎 (防抖延迟 + 三级搜索降落伞)
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
    
    // 🚨 用于防抖的任务管理器
    private var stateCheckTask: Task<Void, Never>?

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
        // 将所有通知都指向同一个处理函数，让防抖机制统一接管
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        systemDidReportChange()
    }
    
    // 🚨 核心抗压机制：防抖动 (Debounce)
    @objc func systemDidReportChange() {
        // 取消之前还在倒计时的任务
        stateCheckTask?.cancel()
        
        // 开启一个新的任务，先睡 0.5 秒，让苹果系统的错乱状态飞一会儿
        stateCheckTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 等待 0.5 秒
            
            // 如果在这 0.5 秒内又有人切歌了，这个任务就会被取消，直接退出
            if Task.isCancelled { return }
            
            // 0.5秒后系统冷静了，我们再来进行精确判断
            await MainActor.run {
                self.evaluateRealState()
            }
        }
    }

    // 系统冷静后的真实状态判断
    private func evaluateRealState() {
        let isPlaying = (musicPlayer.playbackState == .playing)
        let rawTitle = musicPlayer.nowPlayingItem?.title ?? ""
        let artist = musicPlayer.nowPlayingItem?.artist ?? ""
        
        // 情况 1：真的暂停了
        if !isPlaying {
            lyricTimer?.invalidate()
            if !currentSongName.isEmpty {
                updateIsland(songName: currentSongName, lyric: "⏸ 已暂停播放")
            }
            return
        }
        
        // 情况 2：没放歌
        if rawTitle.isEmpty {
            updateIsland(songName: "等待音乐...", lyric: "请播放音乐 🎵")
            return
        }
        
        // 情况 3：继续播放同一首歌（无需重新搜歌词，恢复滚动即可）
        if rawTitle == currentSongName && !parsedLyrics.isEmpty {
            startLyricSyncTimer(songName: rawTitle)
            return
        }
        
        // 情况 4：真的是切了新歌，开始全网搜词
        self.currentSongName = rawTitle
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        
        updateIsland(songName: rawTitle, lyric: "🎵 智能搜词中...")
        
        // 名字净化器
        var cleanTitle = rawTitle
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        Task {
            // 🚨 三级降落伞搜索机制
            // 第一级：酷狗精准搜索（歌名+歌手）
            var lrcString = await fetchLyricFromKugou(keyword: "\(cleanTitle) \(artist)")
            
            // 第二级：如果精准搜索失败，酷狗模糊搜索（仅歌名）
            if lrcString.isEmpty {
                lrcString = await fetchLyricFromKugou(keyword: cleanTitle)
            }
            
            // 第三级：如果酷狗彻底歇菜，网易云保底搜索（歌名+歌手）
            if lrcString.isEmpty {
                lrcString = await fetchLyricFromNetEase(keyword: "\(cleanTitle) \(artist)")
            }
            
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            DispatchQueue.main.async {
                if self.parsedLyrics.isEmpty {
                    self.updateIsland(songName: rawTitle, lyric: "❌ 无滚动歌词")
                } else {
                    // 如果此时还在播放，立刻开滚
                    if self.musicPlayer.playbackState == .playing {
                        self.startLyricSyncTimer(songName: rawTitle)
                    }
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
    // API 1：酷狗引擎 (主战武器)
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
    
    // ==========================================
    // API 2：网易云引擎 (备胎降落伞)
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
                    if #available(iOS 16.2, *) {
                        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100.0)
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), content: content)
                    } else {
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), contentState: state)
                    }
                    DispatchQueue.main.async { self.errorMessage = "✅ 同步中：\(songName)" }
                } catch {}
            } else {
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100.0)
                    await currentActivity?.update(content)
                } else {
                    await currentActivity?.update(using: state)
                }
            }
        }
    }
    
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        stateCheckTask?.cancel()
        lyricTimer?.invalidate()
        currentSongName = ""
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        self.errorMessage = "已彻底停止"
    }
}