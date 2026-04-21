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
// 1. UI 界面 (带全息诊断面板)
// ==========================================
struct ContentView: View {
    @State private var isMonitoring = false
    @ObservedObject var musicManager = MusicManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isMonitoring ? "music.note.house.fill" : "music.note.house")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(Color(hex: musicManager.currentThemeColor))
                .shadow(color: Color(hex: musicManager.currentThemeColor).opacity(0.5), radius: 10)
            
            Text(isMonitoring ? "防弹级不死引擎运行中" : "歌词同步已关闭")
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
            
            // 🚨 全息诊断面板：让你清清楚楚看到 App 的生死状态
            VStack(spacing: 8) {
                Text("【系统诊断日志】")
                    .font(.caption).bold().foregroundColor(.gray)
                Text(musicManager.errorMessage)
                    .foregroundColor(musicManager.errorMessage.contains("❌") ? .red : .green)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.05))
            .cornerRadius(10)
            .padding(.horizontal, 20)
        }
        .padding(.vertical)
    }
}

// ==========================================
// 2. 核心大心脏 (移除网络限制 + 音频降级保活)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = "等待启动..."
    @Published var currentThemeColor: String = "#34C759"
    
    private var parsedLyrics: [LyricLine] = []
    private var masterLoopTask: Task<Void, Never>? 
    private var currentLyricIndex = -1
    private var currentSongName = ""
    private var engineTickCount = 0
    
    // 🚨 使用最基础的 AVAudioPlayer 保活，绝不崩溃
    private var audioPlayer: AVAudioPlayer?

    func setupMonitoring() {
        self.errorMessage = "正在初始化底层驱动..."
        self.engineTickCount = 0
        purgeOrphanedActivities()
        configureBulletproofAudio()
        
        musicPlayer.beginGeneratingPlaybackNotifications()
        
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.errorMessage = "✅ 权限通过，启动主循环！"
                    self.startMasterLoop()
                } else {
                    self.errorMessage = "❌ 致命错误：被拒绝访问 Apple Music"
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
    
    // 🚨 物理级静音音频生成器 (加了详细报错)
    private func configureBulletproofAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("silence_keepalive.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            let format = AVAudioFormat(settings: settings)!
            let frameCount = AVAudioFrameCount(44100 * 5) // 5秒循环
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                buffer.frameLength = frameCount
                if let int16ChannelData = buffer.int16ChannelData {
                    for i in 0..<Int(frameCount) {
                        int16ChannelData[0][i] = (i % 50 == 0) ? 1 : 0 // 极弱白噪音
                    }
                }
                let file = try AVAudioFile(forWriting: fileURL, settings: settings)
                try file.write(from: buffer)
            }
            
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.05
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            DispatchQueue.main.async { self.errorMessage = "✅ 物理音频引擎挂载成功" }
        } catch {
            DispatchQueue.main.async { self.errorMessage = "❌ 音频引擎崩溃: \(error.localizedDescription)" }
        }
    }

    private func startMasterLoop() {
        masterLoopTask?.cancel()
        
        masterLoopTask = Task {
            var lastKnownSystemTime: TimeInterval = -1
            var inertialTime: TimeInterval = 0
            var lastTickDate = Date()
            
            while !Task.isCancelled {
                self.engineTickCount += 1
                let now = Date()
                let rawTitle = self.musicPlayer.nowPlayingItem?.title ?? ""
                let artist = self.musicPlayer.nowPlayingItem?.artist ?? ""
                let isPlaying = (self.musicPlayer.playbackState == .playing)
                let systemTime = self.musicPlayer.currentPlaybackTime
                
                // 保活防坠毁
                if self.audioPlayer?.isPlaying == false {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.audioPlayer?.play()
                }
                
                // 惯性时钟推算
                if !systemTime.isNaN {
                    if abs(systemTime - lastKnownSystemTime) > 0.001 {
                        inertialTime = systemTime
                        lastKnownSystemTime = systemTime
                    } else if isPlaying {
                        inertialTime += now.timeIntervalSince(lastTickDate)
                    }
                }
                lastTickDate = now
                
                // 切歌监测 (防止空歌名乱搜)
                if !rawTitle.isEmpty && rawTitle != self.currentSongName {
                    self.currentSongName = rawTitle
                    self.currentLyricIndex = -1
                    self.parsedLyrics = [] 
                    
                    if let artwork = self.musicPlayer.nowPlayingItem?.artwork,
                       let image = artwork.image(at: CGSize(width: 50, height: 50)) {
                        DispatchQueue.main.async { self.currentThemeColor = image.averageColorHex() ?? "#34C759" }
                    }
                    
                    self.updateIsland(songName: rawTitle, lyric: "🎵 正在连网抓取歌词...")
                    
                    // 独立拉取数据，绝不阻塞主线程
                    Task {
                        let newLyrics = await self.downloadLyrics(title: rawTitle, artist: artist)
                        if self.currentSongName == rawTitle {
                            self.parsedLyrics = newLyrics
                            if newLyrics.isEmpty {
                                self.updateIsland(songName: rawTitle, lyric: "❌ 题库中无此歌词")
                                DispatchQueue.main.async { self.errorMessage = "❌ 搜词失败: \(rawTitle)" }
                            } else {
                                DispatchQueue.main.async { self.errorMessage = "✅ 歌词抓取成功！" }
                            }
                        }
                    }
                }
                
                // 歌词推送
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
                    if !rawTitle.isEmpty {
                        self.updateIsland(songName: rawTitle, lyric: "⏸ 已暂停播放")
                    }
                }
                
                // 心跳报告 (每 1 秒更新一次存活时间)
                if self.engineTickCount % 10 == 0 {
                    let secondsAlive = self.engineTickCount / 10
                    DispatchQueue.main.async {
                        if !self.errorMessage.contains("失败") && !self.errorMessage.contains("错误") {
                            self.errorMessage = "✅ 后台存活: \(secondsAlive) 秒 | 播放状态: \(isPlaying ? "播放" : "暂停")"
                        }
                    }
                }
                
                try? await Task.sleep(nanoseconds: 100_000_000) 
            }
        }
    }

    // 🚨 移除了超时限制，给接口足够的响应时间
    private func downloadLyrics(title: String, artist: String) async -> [LyricLine] {
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        var lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)")
        if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: cleanTitle) }
        if lrcString.isEmpty { lrcString = await fetchLyricFromKugou(keyword: cleanTitle) }
        
        return self.parseLRC(lrcString: lrcString)
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
    
    func stopEverything() {
        musicPlayer.endGeneratingPlaybackNotifications()
        masterLoopTask?.cancel()
        audioPlayer?.stop()
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