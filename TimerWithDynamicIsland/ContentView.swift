import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation
import AVFoundation
import Dispatch
import UIKit

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// 1. UI 界面：Apple Music 专属监听器
// ==========================================
struct ContentView: View {
    @ObservedObject var musicManager = MusicManager.shared
    
    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 15) {
                Image(systemName: musicManager.isMonitoring ? "waveform.circle.fill" : "waveform.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .foregroundColor(Color(hex: musicManager.currentThemeColor))
                    .shadow(color: Color(hex: musicManager.currentThemeColor).opacity(0.5), radius: 20)
                
                Text(musicManager.currentSongName.isEmpty ? "等待 Apple Music 播放" : musicManager.currentSongName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .padding(.horizontal)
                
                Text(musicManager.currentArtistName.isEmpty ? "未检测到歌曲" : musicManager.currentArtistName)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.top, 40)
            
            VStack {
                Text(musicManager.currentDisplayLyric.isEmpty ? "🎵" : musicManager.currentDisplayLyric)
                    .font(.headline)
                    .foregroundColor(Color(hex: musicManager.currentThemeColor))
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color(hex: musicManager.currentThemeColor).opacity(0.1))
                    .cornerRadius(15)
            }
            .padding(.horizontal, 20)

            HStack(spacing: 40) {
                Button(action: { musicManager.playPrevious() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.primary)
                }
                
                Button(action: { musicManager.togglePlayPause() }) {
                    Image(systemName: musicManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(Color(hex: musicManager.currentThemeColor))
                        .shadow(color: Color(hex: musicManager.currentThemeColor).opacity(0.3), radius: 10)
                }
                
                Button(action: { musicManager.playNext() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.primary)
                }
            }
            
            Spacer()

            VStack(spacing: 10) {
                Button(action: {
                    if musicManager.isMonitoring {
                        musicManager.stopEverything()
                    } else {
                        musicManager.startMonitoring()
                    }
                }) {
                    HStack {
                        Image(systemName: musicManager.isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                        Text(musicManager.isMonitoring ? "停止监听并关闭灵动岛" : "开启 Apple Music 不死监听")
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(musicManager.isMonitoring ? Color.red.opacity(0.8) : Color.black.opacity(0.05))
                    .foregroundColor(musicManager.isMonitoring ? .white : .primary)
                    .cornerRadius(15)
                    .padding(.horizontal, 30)
                }
                
                // ⚠️ 极其重要的操作提示
                Text("⚠️ iOS 16.2+ 必看：请在系统设置中找到本应用\\n进入【实时活动】并开启【允许频繁更新】")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            
            Text(musicManager.errorMessage)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.bottom, 20)
        }
        .onAppear {
            MPMediaLibrary.requestAuthorization { _ in }
        }
    }
}

// ==========================================
// 2. 核心大心脏 (纯内存计算级音频保活，彻底隔绝磁盘休眠)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = "点击下方按钮启动监听"
    @Published var currentThemeColor: String = "#34C759"
    @Published var currentSongName: String = ""
    @Published var currentArtistName: String = ""
    @Published var currentDisplayLyric: String = ""
    @Published var isPlaying: Bool = false
    @Published var isMonitoring: Bool = false
    
    private var parsedLyrics: [LyricLine] = []
    private var masterTimer: DispatchSourceTimer?
    private var currentLyricIndex = -1
    private var lastUpdatedLyric = ""
    private var isFetchingLyrics = false 
    
    private var isAppInBackground: Bool = false
    private var inertialTime: TimeInterval = 0
    private var lastTickDate = Date()
    private var engineTickCount = 0
    
    // 🚨 终极核武器：全内存实时的数学音频生成器
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        self.isAppInBackground = true
    }

    @objc private func appWillEnterForeground() {
        self.isAppInBackground = false
        let rawSystemTime = self.musicPlayer.currentPlaybackTime
        if !rawSystemTime.isNaN {
            self.inertialTime = rawSystemTime
        }
    }

    func startMonitoring() {
        self.isMonitoring = true
        self.errorMessage = "正在挂载底层数学引擎..."
        
        purgeOrphanedActivities()
        setupMathAudioEngine()
        
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self.startMasterLoop()
                    self.errorMessage = "✅ 数学保活引擎挂载成功"
                } else {
                    self.errorMessage = "❌ 请允许访问 Apple Music"
                    self.isMonitoring = false
                }
            }
        }
    }
    
    // 🚨 史上最强防休眠技术：使用纯数学计算在内存里每秒实时生成 44100 个采样点。
    // 没有文件读取！没有硬盘 I/O！完美避开所有系统清理机制！
    private func setupMathAudioEngine() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioEngine = AVAudioEngine()
            guard let engine = audioEngine else { return }
            
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            var localTime: Double = 0
            
            // 构建底层音频源节点，直接通过 CPU 生成 20kHz 隐形声波
            sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    // 20kHz，15% 振幅，欺骗系统却绝对安静
                    let value = Float(sin(2.0 * .pi * 20000.0 * localTime / 44100.0)) * 0.15
                    localTime += 1.0
                    
                    for buffer in ablPointer {
                        if let mData = buffer.mData {
                            let floatPtr = mData.assumingMemoryBound(to: Float.self)
                            floatPtr[frame] = value
                        }
                    }
                }
                return noErr
            }
            
            guard let source = sourceNode else { return }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            
            try engine.start()
            
            // 拦截一切外部打断
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                      
                if type == .ended {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.audioEngine?.start()
                }
            }
        } catch {
            self.errorMessage = "引擎挂载失败: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        if musicPlayer.playbackState == .playing { musicPlayer.pause() } 
        else { musicPlayer.play() }
    }
    func playNext() { musicPlayer.skipToNextItem() }
    func playPrevious() { musicPlayer.skipToPreviousItem() }

    private func purgeOrphanedActivities() {
        Task {
            for activity in Activity<TimerWidgetAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
        }
    }

    private func startMasterLoop() {
        masterTimer?.cancel()
        self.lastTickDate = Date()
        self.inertialTime = 0
        self.engineTickCount = 0
        
        let queue = DispatchQueue(label: "com.musicmanager.loop", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now(), repeating: 0.2)
        
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.engineTickCount += 1
            
            let now = Date()
            let delta = now.timeIntervalSince(self.lastTickDate)
            self.lastTickDate = now
            
            // 保证纯内存引擎永不止步
            if self.audioEngine?.isRunning == false {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.audioEngine?.start()
            }
            
            let isSystemPlaying = (self.musicPlayer.playbackState == .playing)
            let isOtherPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
            let currentlyPlaying = self.isAppInBackground ? isOtherPlaying : (isSystemPlaying || isOtherPlaying)
            
            DispatchQueue.main.async { self.isPlaying = currentlyPlaying }
            
            if currentlyPlaying {
                self.inertialTime += delta
            }
            
            if !self.isAppInBackground {
                let rawSystemTime = self.musicPlayer.currentPlaybackTime
                let rawTitle = self.musicPlayer.nowPlayingItem?.title ?? ""
                let artist = self.musicPlayer.nowPlayingItem?.artist ?? ""
                
                if !rawSystemTime.isNaN {
                    let diff = rawSystemTime - self.inertialTime
                    if abs(diff) > 1.5 {
                        self.inertialTime = rawSystemTime
                    } else {
                        self.inertialTime += diff * 0.2
                    }
                }
                
                if !rawTitle.isEmpty && rawTitle != self.currentSongName {
                    DispatchQueue.main.async {
                        self.currentSongName = rawTitle
                        self.currentArtistName = artist
                    }
                    
                    self.currentLyricIndex = -1
                    self.parsedLyrics = []
                    self.lastUpdatedLyric = ""
                    self.inertialTime = rawSystemTime.isNaN ? 0 : rawSystemTime
                    
                    if let artwork = self.musicPlayer.nowPlayingItem?.artwork,
                       let image = artwork.image(at: CGSize(width: 50, height: 50)) {
                        DispatchQueue.main.async { self.currentThemeColor = image.averageColorHex() ?? "#34C759" }
                    }
                    
                    self.updateIsland(songName: rawTitle, lyric: "🎵 连网抓取歌词...")
                    
                    if !self.isFetchingLyrics {
                        self.isFetchingLyrics = true
                        DispatchQueue.main.async {
                            Task {
                                let newLyrics = await self.downloadLyrics(title: rawTitle, artist: artist)
                                DispatchQueue.main.async {
                                    self.isFetchingLyrics = false
                                    if self.currentSongName == rawTitle {
                                        self.parsedLyrics = newLyrics
                                        if newLyrics.isEmpty {
                                            let msg = "❌ 无滚动歌词"
                                            self.currentDisplayLyric = msg
                                            self.updateIsland(songName: rawTitle, lyric: msg)
                                        } else {
                                            let msg = newLyrics.first?.text ?? ""
                                            self.currentDisplayLyric = msg
                                            self.updateIsland(songName: rawTitle, lyric: msg)
                                            self.errorMessage = "✅ 歌词已就位 (\(newLyrics.count)行)"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } 
            
            // === 核心歌词推送，附带系统限制保护 ===
            if currentlyPlaying {
                if !self.parsedLyrics.isEmpty {
                    let calculatedTime = self.inertialTime + 0.3
                    var newIndex = -1
                    for (index, line) in self.parsedLyrics.enumerated() {
                        if calculatedTime >= line.time { newIndex = index } else { break }
                    }
                    
                    if newIndex != self.currentLyricIndex && newIndex >= 0 {
                        self.currentLyricIndex = newIndex
                        let currentText = self.parsedLyrics[newIndex].text
                        if !currentText.isEmpty {
                            DispatchQueue.main.async { self.currentDisplayLyric = currentText }
                            self.updateIsland(songName: self.currentSongName, lyric: currentText)
                        }
                    }
                }
            } else if !currentlyPlaying && !self.currentSongName.isEmpty {
                if self.engineTickCount % 5 == 0 {
                    self.updateIsland(songName: self.currentSongName, lyric: "⏸ 已暂停")
                }
            }
            
            if self.engineTickCount % 10 == 0 {
                DispatchQueue.main.async {
                    if !self.errorMessage.contains("失败") && !self.errorMessage.contains("错误") && !self.errorMessage.contains("❌") {
                        let sec = Int(self.inertialTime)
                        let stateStr = self.isAppInBackground ? "🔒内存盲走" : "📡前台同步"
                        self.errorMessage = "✅ \(stateStr) | 进度: \(sec)s | \(currentlyPlaying ? "▶️" : "⏸")"
                    }
                }
            }
        }
        
        timer.resume()
        self.masterTimer = timer
    }

    private func downloadLyrics(title: String, artist: String) async -> [LyricLine] {
        var cleanTitle = title
        if let idx = cleanTitle.firstIndex(of: "(") { cleanTitle = String(cleanTitle[..<idx]) }
        if let idx = cleanTitle.firstIndex(of: "-") { cleanTitle = String(cleanTitle[..<idx]) }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)
        
        var lrcString = await fetchLyricFromNetEase(keyword: "\(cleanTitle) \(artist)")
        if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: "\(cleanTitle) \(artist)") }
        if lrcString.isEmpty { lrcString = await fetchLyricFromQQMusic(keyword: cleanTitle) }
        if lrcString.isEmpty { lrcString = await fetchLyricFromKugou(keyword: cleanTitle) }
        
        return self.parseLRC(lrcString: lrcString)
    }

    func fetchLyricFromNetEase(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=1")!
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (searchData, _) = try await URLSession.shared.data(for: request)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let result = searchJson["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let firstSong = songs.first,
                  let songId = firstSong["id"] as? Int else { return "" }
            
            let lyricUrl = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&kv=1&tv=-1")!
            var lyricReq = URLRequest(url: lyricUrl)
            lyricReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            lyricReq.timeoutInterval = 10
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            guard let lyricJson = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJson["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String else { return "" }
            return lyricText
        } catch { return "" }
    }

    func fetchLyricFromQQMusic(keyword: String) async -> String {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let searchUrl = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=1&w=\(encoded)&format=json")!
        do {
            var request = URLRequest(url: searchUrl)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (searchData, _) = try await URLSession.shared.data(for: request)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let songMap = dataMap["song"] as? [String: Any],
                  let list = songMap["list"] as? [[String: Any]],
                  let first = list.first,
                  let songmid = first["songmid"] as? String else { return "" }
            
            let lyricUrl = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json")!
            var lyricReq = URLRequest(url: lyricUrl)
            lyricReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            lyricReq.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
            lyricReq.timeoutInterval = 10
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
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (searchData, _) = try await URLSession.shared.data(for: request)
            guard let searchJson = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let dataMap = searchJson["data"] as? [String: Any],
                  let infoArray = dataMap["info"] as? [[String: Any]],
                  let hash = infoArray.first?["hash"] as? String else { return "" }
            
            let lyricUrl = URL(string: "https://m.kugou.com/app/i/krc.php?cmd=100&hash=\(hash)&timelength=999999")!
            var lyricReq = URLRequest(url: lyricUrl)
            lyricReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            lyricReq.timeoutInterval = 10
            let (lyricData, _) = try await URLSession.shared.data(for: lyricReq)
            let lyricText = String(data: lyricData, encoding: .utf8) ?? ""
            return lyricText
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
        if lyric == lastUpdatedLyric { return }
        lastUpdatedLyric = lyric

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
                        let staleDate = Date().addingTimeInterval(3600)
                        let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100.0)
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), content: content)
                    } else {
                        currentActivity = try Activity.request(attributes: TimerWidgetAttributes(), contentState: state)
                    }
                } catch {
                    print("灵动岛错误: \(error)")
                }
            } else {
                if #available(iOS 16.2, *) {
                    let staleDate = Date().addingTimeInterval(3600)
                    let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100.0)
                    await currentActivity?.update(content)
                } else {
                    await currentActivity?.update(using: state)
                }
            }
        }
    }
    
    func stopEverything() {
        self.isMonitoring = false
        masterTimer?.cancel()
        audioEngine?.stop()
        
        currentSongName = ""
        currentArtistName = ""
        currentDisplayLyric = ""
        lastUpdatedLyric = ""
        isPlaying = false
        purgeOrphanedActivities() 
        self.errorMessage = "监听已彻底停止"
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