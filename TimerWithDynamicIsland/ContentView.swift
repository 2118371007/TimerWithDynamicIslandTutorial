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
            
            Text(isMonitoring ? "双引擎智能搜词已启动" : "歌词同步已关闭")
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
// 核心引擎 (双引擎爬虫 + 暂停监控)
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
        
        updateIsland(songName: title, lyric: "🎵 双引擎全网搜词中...")
        
        // 🚨 核心：双引擎自动切换逻辑
        Task {
            // 1. 优先尝试 QQ 音乐 (保周杰伦)
            var lrcString = await fetchLyricFromQQMusic(title: title)
            
            // 2. 如果 QQ 音乐被墙或搜不到，瞬间无缝切换到网易云
            if lrcString.isEmpty {
                lrcString = await fetchLyricFromNetEase(title: title, artist: artist)
            }
            
            self.parsedLyrics = self.parseLRC(lrcString: lrcString)
            
            if self.parsedLyrics.isEmpty {
                self.updateIsland(songName: title, lyric: "❌ 网络限制或无版权")
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
    // 引擎 1：QQ音乐 (带强力清洗器)
    // ==========================================
    func fetchLyricFromQQMusic(title: String) async -> String {
        // 修复1：只搜歌名，防匹配失败
        let keyword = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let searchUrlString = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(keyword)&format=json&platform=yqq.json"
        
        guard let searchUrl = URL(string: searchUrlString) else { return "" }
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            // 修复2：暴力切除 callback 脏数据
            var searchString = String(data: searchData, encoding: .utf8) ?? ""
            if let start = searchString.firstIndex(of: "{"), let end = searchString.lastIndex(of: "}") {
                searchString = String(searchString[start...end])
            }
            
            guard let cleanData = searchString.data(using: .utf8),
                  let searchJson = try JSONSerialization.jsonObject(with: cleanData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let songMap = dataMap["song"] as? [String: Any],
                  let listArray = songMap["list"] as? [[String: Any]],
                  let firstSong = listArray.first,
                  let songmid = firstSong["songmid"] as? String else { return "" }
            
            let lyricUrlString = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json&platform=yqq.json&nobase64=0"
            var lyricReq = URLRequest(url: URL(string: lyricUrlString)!)
            lyricReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
            lyricReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            
            var lyricString = String(data: lyricData, encoding: .utf8) ?? ""
            if let start = lyricString.firstIndex(of: "{"), let end = lyricString.lastIndex(of: "}") {
                lyricString = String(lyricString[start...end])
            }
            
            guard let cleanLyricData = lyricString.data(using: .utf8),
                  let lyricJson = try JSONSerialization.jsonObject(with: cleanLyricData) as? [String: Any],
                  let lyricBase64 = lyricJson["lyric"] as? String,
                  let decodedData = Data(base64Encoded: lyricBase64),
                  let lyricText = String(data: decodedData, encoding: .utf8) else { return "" }
            
            return lyricText
        } catch {
            return ""
        }
    }

    // ==========================================
    // 引擎 2：网易云备用 (防海外封锁)
    // ==========================================
    func fetchLyricFromNetEase(title: String, artist: String) async -> String {
        let searchTerm = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let searchUrlString = "https://music.163.com/api/search/get/web?s=\(searchTerm)&type=1&limit=1"
        
        guard let searchUrl = URL(string: searchUrlString) else { return "" }
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            
            let (searchData, _) = try await URLSession.shared.data(for: request)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let result = searchJson["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let firstSong = songs.first,
                  let songId = firstSong["id"] as? Int else { return "" }
            
            let lyricUrlString = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&kv=1&tv=-1"
            let (lyricData, _) = try await URLSession.shared.data(from: URL(string: lyricUrlString)!)
            
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJson["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String else { return "" }
            
            return lyricText
        } catch {
            return ""
        }
    }

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
                        .replacingOccurrences(of: "&#32;", with: " ")
                        .replacingOccurrences(of: "&#40;", with: "(")
                        .replacingOccurrences(of: "&#41;", with: ")")
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