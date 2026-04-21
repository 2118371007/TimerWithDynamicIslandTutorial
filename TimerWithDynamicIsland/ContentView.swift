import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation
import AVFoundation // 引入音频底层库，用于后台保活

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// 1. UI 界面 (ContentView)
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
            
            Text(isMonitoring ? "零延迟无限后台引擎运行中" : "歌词同步已关闭")
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
// 2. 核心大心脏 (MusicManager)
// 包含：后台保活、零延迟监听、QQ音乐秒解、全局正则
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
    
    // 🚨 后台静音心脏起搏器 (骗过 iOS 杀后台机制)
    private let silenceEngine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()

    // ------------------------------------------
    // 启动与保活
    // ------------------------------------------
    func setupMonitoring() {
        self.errorMessage = "正在启动引擎..."
        
        // 1. 启动静音保活引擎
        startBackgroundHeartbeat()
        
        // 2. 请求 Apple Music 权限
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 监听中，退后台绝对不掉线！"
                    self.startListening()
                } else {
                    self.errorMessage = "❌ 被拒绝访问 Apple Music"
                }
            }
        }
    }
    
    private func startBackgroundHeartbeat() {
        do {
            // 设置混音模式，绝对不打断 Apple Music 原本的音乐
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            
            silenceEngine.attach(silencePlayer)
            let format = silenceEngine.outputNode.inputFormat(forBus: 0)
            silenceEngine.connect(silencePlayer, to: silenceEngine.outputNode, format: format)
            try silenceEngine.start()
            
            // 制造纯静音缓冲液并无限循环播放
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) {
                buffer.frameLength = 44100
                silencePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
                silencePlayer.play()
            }
        } catch {
            print("后台保活引擎启动失败")
        }
    }

    private func startListening() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        // 零延迟监听：一旦切歌或暂停，瞬间触发
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidReportChange), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)
        systemDidReportChange()
    }
    
    @objc func systemDidReportChange() {
        DispatchQueue.main.async { self.evaluateRealState() }
    }

    // ------------------------------------------
    // 状态判定与搜歌逻辑
    // ------------------------------------------
    private func evaluateRealState() {
        let rawTitle = musicPlayer.nowPlayingItem?.title ?? ""
        let artist = musicPlayer.nowPlayingItem?.artist ?? ""
        let isPlaying = (musicPlayer.playbackState == .playing)
        
        // 如果歌名变了，说明切歌了，立刻去搜
        if !rawTitle.isEmpty && rawTitle != currentSongName {
            self.currentSongName = rawTitle
            self.fetchAndStart(title: rawTitle, artist: artist)
            return
        }
        
        // 如果歌名没变，处理暂停或继续播放
        if isPlaying {
            if !parsedLyrics.isEmpty { startLyricSyncTimer(songName: rawTitle) }
        } else {
            lyricTimer?.invalidate()
            if !rawTitle.isEmpty { updateIsland(songName: rawTitle, lyric: "⏸ 已暂停播放") }
        }
    }

    private func fetchAndStart(title: String, artist: String) {
        lyricTimer?.invalidate()
        parsedLyrics = []
        currentLyricIndex = -1
        updateIsland(songName: title, lyric: "🎵 秒速匹配中...")
        
        // 名字净化器：切掉 (Live版)、- 翻唱 等杂音
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        Task {
            // 用纯净 QQ 引擎搜词
            var lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)")
            if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: cleanTitle) }
            
            // 全局正则切割面条歌词
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

    // ------------------------------------------
    // 零延迟滚动与提前量同步引擎
    // ------------------------------------------
    func startLyricSyncTimer(songName: String) {
        lyricTimer?.invalidate()
        // 0.05秒极速刷新
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 🚨 黄金提前量算法：系统时间 + 0.45秒，完美抵消所有延迟
            let currentTime = self.musicPlayer.currentPlaybackTime + 0.45 
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

    // ------------------------------------------
    // 纯净版 QQ 音乐接口 (秒出周杰伦)
    // ------------------------------------------
    func fetchLyricFromQQMusic(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(encoded)&format=json")!
        
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (searchData, _) = try await URLSession.shared.data(for: request)
            
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let songMap = dataMap["song"] as? [String: Any],
                  let list = songMap["list"] as? [[String: Any]],
                  let first = list.first,
                  let songmid = first["songmid"] as? String else { return "" }
            
            let lyricUrl = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json")!
            var lyricReq = URLRequest(url: lyricUrl)
            lyricReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer") // 防盗链破解
            
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lyricB64 = lyricJson["lyric"] as? String,
                  let decodedData = Data(base64Encoded: lyricB64),
                  let lyricText = String(data: decodedData, encoding: .utf8) else { return "" }
            
            return lyricText
        } catch { return "" }
    }

    // ------------------------------------------
    // 超强正则扫描仪 (专门对付面条代码)
    // ------------------------------------------
    func parseLRC(lrcString: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        // 全局匹配 [分:秒] 后面的任何字符，直到遇到下一个 [
        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return lines }
        
        let nsString = lrcString as NSString
        let results = regex.matches(in: lrcString, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in results {
            let minStr = nsString.substring(with: match.range(at: 1))
            let secStr = nsString.substring(with: match.range(at: 2))
            var text = nsString.substring(with: match.range(at: 3))
            
            if let min = Double(minStr), let sec = Double(secStr) {
                // 清洗 HTML 乱码、回车符和首尾空格
                text = text.replacingOccurrences(of: "&#32;", with: " ")
                           .replacingOccurrences(of: "&#40;", with: "(")
                           .replacingOccurrences(of: "&#41;", with: ")")
                           .replacingOccurrences(of: "&#45;", with: "-")
                           .replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
                           .replacingOccurrences(of: "\r", with: "")
                           .replacingOccurrences(of: "\n", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !text.isEmpty {
                    lines.append(LyricLine(time: (min * 60) + sec, text: text))
                }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // ------------------------------------------
    // 强制顶配权重推送到灵动岛
    // ------------------------------------------
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
    
    // ------------------------------------------
    // 彻底销毁
    // ------------------------------------------
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        lyricTimer?.invalidate()
        
        // 🚨 停止心脏起搏器
        if silenceEngine.isRunning {
            silencePlayer.stop()
            silenceEngine.stop()
        }
        
        currentSongName = ""
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        self.errorMessage = "已彻底停止并关闭"
    }
}