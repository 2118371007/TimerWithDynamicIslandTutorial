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
            
            Text(isMonitoring ? "零延迟 QQ 引擎已启动" : "歌词同步已关闭")
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
// 核心引擎 (零延迟秒切 + QQ音乐主导)
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
        // 🚨 统一监听口，不再等待 0.5 秒，实现零延迟响应
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        systemDidReportChange()
    }
    
    @objc func systemDidReportChange() {
        DispatchQueue.main.async {
            self.evaluateRealState()
        }
    }

    private func evaluateRealState() {
        let rawTitle = musicPlayer.nowPlayingItem?.title ?? ""
        let artist = musicPlayer.nowPlayingItem?.artist ?? ""
        let isPlaying = (musicPlayer.playbackState == .playing)
        
        // 1. 优先判断是否切了新歌（不等播放状态，只要歌名变了瞬间开搜）
        if !rawTitle.isEmpty && rawTitle != currentSongName {
            self.currentSongName = rawTitle
            self.fetchAndStart(title: rawTitle, artist: artist)
            return
        }
        
        // 2. 如果没切歌，仅仅是暂停或恢复
        if isPlaying {
            if !parsedLyrics.isEmpty { startLyricSyncTimer(songName: rawTitle) }
        } else {
            lyricTimer?.invalidate()
            if !rawTitle.isEmpty { updateIsland(songName: rawTitle, lyric: "⏸ 已暂停播放") }
        }
    }

    // 独立出搜词逻辑
    private func fetchAndStart(title: String, artist: String) {
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        
        updateIsland(songName: title, lyric: "🎵 秒速匹配中...")
        
        // 名字净化器
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        Task {
            // 🚨 强制使用破解版的 QQ 音乐 API 搜词 (保周杰伦)
            var lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)")
            
            // 备用降落伞
            if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: cleanTitle) }
            
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            DispatchQueue.main.async {
                if self.parsedLyrics.isEmpty {
                    self.updateIsland(songName: title, lyric: "❌ 无滚动歌词")
                } else {
                    if self.musicPlayer.playbackState == .playing {
                        self.startLyricSyncTimer(songName: title)
                    }
                }
            }
        }
    }

    func startLyricSyncTimer(songName: String) {
        lyricTimer?.invalidate()
        // 将刷新频率提高，确保动画丝滑
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 🚨 核心提前量算法：系统时间 + 0.4秒，抵消苹果底层跨进程的延迟！
            let currentTime = self.musicPlayer.currentPlaybackTime + 0.4
            
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
    // 🚨 完美破解版 QQ 音乐 API
    // ==========================================
    func fetchLyricFromQQMusic(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 强制 format=json 屏蔽 callback 脏数据
        let searchUrl = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(encoded)&format=json")!
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            // 纯净 JSON 解析
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let songMap = dataMap["song"] as? [String: Any],
                  let list = songMap["list"] as? [[String: Any]],
                  let first = list.first,
                  let songmid = first["songmid"] as? String else { return "" }
            
            // 获取歌词
            let lyricUrl = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json")!
            var lyricReq = URLRequest(url: lyricUrl)
            lyricReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer") // 核心防盗链破解
            
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lyricB64 = lyricJson["lyric"] as? String,
                  let decodedData = Data(base64Encoded: lyricB64),
                  let lyricText = String(data: decodedData, encoding: .utf8) else { return "" }
            
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
                        // 处理 QQ 音乐特有的 HTML 转义字符
                        .replacingOccurrences(of: "&#32;", with: " ")
                        .replacingOccurrences(of: "&#40;", with: "(")
                        .replacingOccurrences(of: "&#41;", with: ")")
                        .replacingOccurrences(of: "&#45;", with: "-")
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
        lyricTimer?.invalidate()
        currentSongName = ""
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        self.errorMessage = "已彻底停止"
    }
}