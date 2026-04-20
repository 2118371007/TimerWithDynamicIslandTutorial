import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation

// ==========================================
// 歌词数据模型
// ==========================================
struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// 第一部分：UI 界面 (ContentView)
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
            
            Text(isMonitoring ? "灵动歌词引擎已启动" : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    musicManager.setupMonitoring()
                } else {
                    musicManager.stopMonitoring()
                }
            }) {
                Text(isMonitoring ? "🛑 停止同步" : "🚀 开启全自动同步")
                    .font(.title3.bold())
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(15)
                    .padding(.horizontal, 40)
            }
            
            // 状态与错误雷达
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
// 第二部分：全自动后台监听与网络引擎 (MusicManager)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = ""
    
    // 同步滚动所需的状态变量
    private var parsedLyrics: [LyricLine] = []
    private var lyricTimer: Timer?
    private var currentLyricIndex = -1
    private var currentSongName = ""

    // ------------------------------------------
    // 1. 初始化与权限
    // ------------------------------------------
    func setupMonitoring() {
        self.errorMessage = "正在请求 Apple Music 权限..."
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 权限已获取，开始监听！"
                    self.startListening()
                } else {
                    self.errorMessage = "❌ 被拒绝访问 Apple Music"
                }
            }
        }
    }
    
    private func startListening() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: NSNotification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        handleTrackChange()
    }

    // ------------------------------------------
    // 2. 切歌触发器
    // ------------------------------------------
    @objc func handleTrackChange() {
        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            updateIsland(songName: "等待音乐...", lyric: "请在 Apple Music 中播放 🎵", isNewSong: true)
            return
        }
        
        let title = nowPlaying.title ?? "未知歌名"
        let artist = nowPlaying.artist ?? ""
        
        // 如果是同一首歌重复触发，不处理
        if title == currentSongName { return }
        self.currentSongName = title
        
        // 清理上一首歌的计时器和数据
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        
        // 强行重启岛，显示搜索状态
        updateIsland(songName: title, lyric: "🎵 正在全网搜索歌词...", isNewSong: true)
        
        // 异步去网易云接口抓取真实歌词
        Task {
            let lrcString = await fetchLyricFromNetEase(title: title, artist: artist)
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            if self.parsedLyrics.isEmpty {
                self.updateIsland(songName: title, lyric: "❌ 暂无滚动歌词", isNewSong: false)
            } else {
                // 抓到歌词后，启动高频滚动引擎
                DispatchQueue.main.async {
                    self.startLyricSyncTimer(songName: title)
                }
            }
        }
    }

    // ------------------------------------------
    // 3. Apple Music 进度条同步引擎
    // ------------------------------------------
    func startLyricSyncTimer(songName: String) {
        lyricTimer?.invalidate()
        // 每 0.1 秒检查一次播放进度
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let currentTime = self.musicPlayer.currentPlaybackTime
            if currentTime.isNaN { return }
            
            // 找出当前时间对应的歌词
            var newIndex = -1
            for (index, line) in self.parsedLyrics.enumerated() {
                if currentTime >= line.time {
                    newIndex = index
                } else {
                    break
                }
            }
            
            // 如果歌词跳到了下一句，就推送给灵动岛
            if newIndex != self.currentLyricIndex && newIndex >= 0 {
                self.currentLyricIndex = newIndex
                let currentText = self.parsedLyrics[newIndex].text
                
                // 过滤掉空的间奏行，保持灵动岛美观
                if !currentText.isEmpty {
                    self.updateIsland(songName: songName, lyric: currentText, isNewSong: false)
                }
            }
        }
    }

    // ------------------------------------------
    // 4. 网易云音乐 API 爬虫 (搜索 -> 取词)
    // ------------------------------------------
    func fetchLyricFromNetEase(title: String, artist: String) async -> String {
        // 拼接搜索关键词
        let searchTerm = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let searchUrlString = "https://music.163.com/api/search/get/web?s=\(searchTerm)&type=1&limit=1"
        
        guard let searchUrl = URL(string: searchUrlString) else { return "" }
        
        do {
            // 伪装成浏览器防止被拦截
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            
            // 第一步：搜歌，拿到歌曲 ID
            let (searchData, _) = try await URLSession.shared.data(for: request)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let result = searchJson["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let firstSong = songs.first,
                  let songId = firstSong["id"] as? Int else {
                return ""
            }
            
            // 第二步：用 ID 下载歌词
            let lyricUrlString = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&kv=1&tv=-1"
            guard let lyricUrl = URL(string: lyricUrlString) else { return "" }
            
            let (lyricData, _) = try await URLSession.shared.data(for: URLRequest(url: lyricUrl))
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJson["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String else {
                return ""
            }
            return lyricText
        } catch {
            return ""
        }
    }

    // ------------------------------------------
    // 5. LRC 时间轴解析器
    // ------------------------------------------
    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let components = lrcString.components(separatedBy: .newlines)
        
        // 正则表达式匹配 [00:00.00] 格式
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
                    let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                    
                    lines.append(LyricLine(time: (min * 60) + sec, text: text))
                }
            }
        }
        // 按时间先后排序
        return lines.sorted { $0.time < $1.time }
    }

    // ------------------------------------------
    // 6. 灵动岛上岛与刷新逻辑
    // ------------------------------------------
    func updateIsland(songName: String, lyric: String, isNewSong: Bool) {
        let attributes = TimerWidgetAttributes(songName: songName)
        let state = TimerWidgetAttributes.ContentState(lyric: lyric)
        
        Task {
            if isNewSong {
                // 切歌时：拔掉旧岛，升起新岛
                if let existingActivity = currentActivity {
                    await existingActivity.end(dismissalPolicy: .immediate)
                }
                do {
                    currentActivity = try Activity.request(attributes: attributes, contentState: state)
                    DispatchQueue.main.async {
                        self.errorMessage = "✅ 正在同步：\(songName)"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = "❌ 灵动岛故障: \(error.localizedDescription)"
                    }
                }
            } else {
                // 同一首歌滚动歌词时：静默无缝刷新
                await currentActivity?.update(using: state)
            }
        }
    }
    
    // ------------------------------------------
    // 7. 停止与销毁
    // ------------------------------------------
    func stopMonitoring() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        lyricTimer?.invalidate()
        currentSongName = ""
        
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        self.errorMessage = "已停止同步并关闭灵动岛"
    }
}