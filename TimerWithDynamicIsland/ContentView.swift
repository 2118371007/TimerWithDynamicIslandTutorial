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
                .foregroundColor(Color(hex: musicManager.currentThemeColor))
                .shadow(color: Color(hex: musicManager.currentThemeColor).opacity(0.5), radius: 10)
            
            Text(isMonitoring ? "防打断强心针引擎运行中" : "歌词同步已关闭")
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
                    .background(isMonitoring ? Color.red : Color(hex: musicManager.currentThemeColor))
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
// 2. 核心大心脏 (去除括号Bug + 加入强心针)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = ""
    @Published var currentThemeColor: String = "#34C759"
    
    private var parsedLyrics: [LyricLine] = []
    private var masterLoopTask: Task<Void, Never>? 
    private var currentLyricIndex = -1
    private var currentSongName = ""
    private var lastPlaybackState: MPMusicPlaybackState = .stopped
    
    private let silenceEngine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    
    // 🚨 强制心跳定时器
    private var heartbeatTimer: Timer?

    func setupMonitoring() {
        self.errorMessage = "正在唤醒系统底层通讯..."
        purgeOrphanedActivities()
        configureAudioSession()
        
        musicPlayer.beginGeneratingPlaybackNotifications()
        
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 引擎启动，切歌秒级响应！"
                    self.startMasterLoop()
                } else {
                    self.errorMessage = "❌ 被拒绝访问 Apple Music"
                }
            }
        }
    }
    
    private func purgeOrphanedActivities() {
        Task {
            for activity in Activity<TimerWidgetAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
        }
    }
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            
            silenceEngine.attach(silencePlayer)
            let format = silenceEngine.outputNode.inputFormat(forBus: 0)
            silenceEngine.connect(silencePlayer, to: silenceEngine.outputNode, format: format)
            try silenceEngine.start()
            
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) {
                buffer.frameLength = 44100
                if let floatChannelData = buffer.floatChannelData {
                    for channel in 0..<Int(format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            // 稍微提高一丁点噪音级别，确保不被最新 iOS 系统忽略
                            floatChannelData[channel][frame] = 1e-4 
                        }
                    }
                }
                silencePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
                silencePlayer.play()
            }
            
            // 🚨 终极心跳复苏：不管是谁掐断了我们的白噪音，每2秒强行重启一次！
            heartbeatTimer?.invalidate()
            // 必须挂在 common 模式下，防止后台定时器失效
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if !self.silenceEngine.isRunning {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try self.silenceEngine.start()
                        self.silencePlayer.play()
                        print("🫀 引擎被掐断，已成功自愈重启！")
                    } catch { }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeatTimer = timer
            
        } catch { print("音频引擎故障") }
    }

    private func startMasterLoop() {
        masterLoopTask?.cancel()
        
        masterLoopTask = Task {
            var lastKnownSystemTime: TimeInterval = -1
            var inertialTime: TimeInterval = 0
            var lastTickDate = Date()
            
            while !Task.isCancelled {
                let now = Date()
                let rawTitle = self.musicPlayer.nowPlayingItem?.title ?? ""
                let artist = self.musicPlayer.nowPlayingItem?.artist ?? ""
                let isPlaying = (self.musicPlayer.playbackState == .playing)
                let systemTime = self.musicPlayer.currentPlaybackTime
                
                // 惯性时钟
                if !systemTime.isNaN {
                    if abs(systemTime - lastKnownSystemTime) > 0.001 {
                        inertialTime = systemTime
                        lastKnownSystemTime = systemTime
                    } else if isPlaying {
                        inertialTime += now.timeIntervalSince(lastTickDate)
                    }
                }
                lastTickDate = now
                
                // 切歌监测
                if !rawTitle.isEmpty && rawTitle != self.currentSongName {
                    self.currentSongName = rawTitle
                    self.currentLyricIndex = -1
                    
                    if let artwork = self.musicPlayer.nowPlayingItem?.artwork,
                       let image = artwork.image(at: CGSize(width: 50, height: 50)) {
                        DispatchQueue.main.async { self.currentThemeColor = image.averageColorHex() ?? "#34C759" }
                    }
                    
                    self.updateIsland(songName: rawTitle, lyric: "🎵 匹配歌词中...")
                    await self.fetchAndParseLyrics(title: rawTitle, artist: artist)
                }
                
                // 歌词滚动
                if isPlaying {
                    if !self.parsedLyrics.isEmpty {
                        let calculatedTime = inertialTime + 0.45
                        
                        var newIndex = -1
                        for (index, line) in self.parsedLyrics.enumerated() {
                            if calculatedTime >= line.time { newIndex = index } else { break }
                        }
                        
                        if newIndex != self.currentLyricIndex && newIndex >= 0 {
                            self.currentLyricIndex = newIndex
                            let currentText = self.parsedLyrics[newIndex].text
                            if !currentText.isEmpty {
                                self.updateIsland(songName: self.currentSongName, lyric: currentText)
                            }
                        }
                    }
                } else {
                    if self.lastPlaybackState == .playing {
                        self.updateIsland(songName: rawTitle.isEmpty ? "等待音乐" : rawTitle, lyric: "⏸ 已暂停播放")
                    }
                }
                
                self.lastPlaybackState = self.musicPlayer.playbackState
                
                try? await Task.sleep(nanoseconds: 100_000_000) 
            }
        }
    }

    private func fetchAndParseLyrics(title: String, artist: String) async {
        self.parsedLyrics = []
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        var lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)")
        if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: cleanTitle) }
        
        if lrcString.isEmpty {
            lrcString = await fetchLyricFromKugou(keyword: cleanTitle)
        }
        
        self.parsedLyrics = self.parseLRC(lrcString: lrcString)
        
        if self.parsedLyrics.isEmpty {
            self.updateIsland(songName: title, lyric: "❌ 无滚动歌词")
        }
    }

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
            lyricReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer") 
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lyricB64 = lyricJson["lyric"] as? String,
                  let decodedData = Data(base64Encoded: lyricB64),
                  let lyricText = String(data: decodedData, encoding: .utf8) else { return "" }
            return lyricText
        } catch { return "" }
    }

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
        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\]([^\\[]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return lines }
        let nsString = lrcString as NSString
        let results = regex.matches(in: lrcString, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for match in results {
            let minStr = nsString.substring(with: match.range(at: 1))
            let secStr = nsString.substring(with: match.range(at: 2))
            var text = nsString.substring(with: match.range(at: 3))
            if let min = Double(minStr), let sec = Double(secStr) {
                text = text.replacingOccurrences(of: "&#32;", with: " ")
                           .replacingOccurrences(of: "&#40;", with: "(")
                           .replacingOccurrences(of: "&#41;", with: ")")
                           .replacingOccurrences(of: "&#45;", with: "-")
                           .replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
                           .replacingOccurrences(of: "\r", with: "")
                           .replacingOccurrences(of: "\n", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(LyricLine(time: (min * 60) + sec, text: text)) }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    func updateIsland(songName: String, lyric: String) {
        let state = TimerWidgetAttributes.ContentState(songName: songName, lyric: lyric, themeColorHex: currentThemeColor)
        Task {
            if currentActivity == nil {
                if let existing = Activity<TimerWidgetAttributes>.activities.first {
                    self.currentActivity = existing
                }
            }
            
            if currentActivity == nil {
                do {
                    if #available(iOS 16.2, *) {
                        // 🔑 关键修复：设置 staleDate 为 5 分钟后，告诉系统持续推送更新
                        let staleDate = Calendar.current.date(byAdding: .second, value: 300, to: Date())
                        let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100.0)
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), content: content)
                    } else {
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), contentState: state)
                    }
                } catch {}
            } else {
                if #available(iOS 16.2, *) {
                    // 🔑 关键修复：每次更新都刷新 staleDate，保持 Activity 活跃
                    let staleDate = Calendar.current.date(byAdding: .second, value: 300, to: Date())
                    let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100.0)
                    await currentActivity?.update(content)
                } else {
                    await currentActivity?.update(using: state)
                }
            }
        }
    }
    
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        masterLoopTask?.cancel()
        heartbeatTimer?.invalidate()
        if silenceEngine.isRunning { silencePlayer.stop(); silenceEngine.stop() }
        currentSongName = ""
        purgeOrphanedActivities() 
        self.errorMessage = "已彻底停止并关闭"
    }
}

extension UIImage {
    func averageColorHex() -> String? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(x: inputImage.extent.origin.x, y: inputImage.extent.origin.y, z: inputImage.extent.size.width, w: inputImage.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        
        let brightness = (Double(bitmap[0]) * 0.299 + Double(bitmap[1]) * 0.587 + Double(bitmap[2]) * 0.114)
        if brightness < 50 { return "#34C759" }
        return String(format: "#%02x%02x%02x", bitmap[0], bitmap[1], bitmap[2])
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (52, 199, 89)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue:  Double(b) / 255, opacity: 1)
    }
}