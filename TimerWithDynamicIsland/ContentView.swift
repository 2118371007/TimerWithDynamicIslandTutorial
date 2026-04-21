import SwiftUI
import MediaPlayer
import ActivityKit
import Foundation
import AVFoundation
import Dispatch

struct LyricLine {
    let time: TimeInterval
    let text: String
}

// ==========================================
// 1. UI 界面：华丽变身内置播放器
// ==========================================
struct ContentView: View {
    @State private var showMediaPicker = false
    @ObservedObject var musicManager = MusicManager.shared
    
    var body: some View {
        VStack(spacing: 30) {
            // 顶部封面与歌曲信息
            VStack(spacing: 15) {
                Image(systemName: "music.note.house.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .foregroundColor(Color(hex: musicManager.currentThemeColor))
                    .shadow(color: Color(hex: musicManager.currentThemeColor).opacity(0.5), radius: 20)
                
                Text(musicManager.currentSongName.isEmpty ? "动歌岛 - 内置播放器" : musicManager.currentSongName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .padding(.horizontal)
                
                Text(musicManager.currentArtistName.isEmpty ? "请选择歌曲开始播放" : musicManager.currentArtistName)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.top, 40)
            
            // 当前歌词展示区
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

            // 🎵 播放控制区 (真正的内置控制)
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

            // 🚀 选歌按钮 (触发我们纯手工打造的选歌器)
            Button(action: {
                MPMediaLibrary.requestAuthorization { status in
                    DispatchQueue.main.async {
                        if status == .authorized {
                            self.showMediaPicker = true
                        } else {
                            musicManager.errorMessage = "❌ 请在系统设置中允许访问媒体与 Apple Music"
                        }
                    }
                }
            }) {
                HStack {
                    Image(systemName: "music.quarternote.3")
                    Text("从 Apple Music 选择歌曲")
                }
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.05))
                .foregroundColor(.primary)
                .cornerRadius(15)
                .padding(.horizontal, 30)
            }
            
            // 系统状态日志
            Text(musicManager.errorMessage)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.bottom, 20)
        }
        .sheet(isPresented: $showMediaPicker) {
            // 弹出纯 SwiftUI 版选歌器，彻底告别闪退
            CustomMusicPickerView { collection in
                musicManager.playCollection(collection)
            }
        }
        .onAppear {
            musicManager.setupAudioSession()
        }
    }
}

// ==========================================
// 2. 纯 SwiftUI 本地音乐选择器 (专治跨平台水土不服)
// ==========================================
struct CustomMusicPickerView: View {
    var onSelect: (MPMediaItemCollection) -> Void
    @Environment(\.presentationMode) var presentationMode
    
    @State private var songs: [MPMediaItem] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("加载本地音乐中...")
                } else if songs.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("未在本地发现任何音乐\\n请前往 Apple Music 下载或同步歌曲")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                    }
                } else {
                    List(songs, id: \.persistentID) { song in
                        Button(action: {
                            // 将选中的歌曲打包成播放集合
                            let collection = MPMediaItemCollection(items: [song])
                            onSelect(collection)
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title ?? "未知歌曲")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(song.artist ?? "未知歌手")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let artwork = song.artwork, let image = artwork.image(at: CGSize(width: 45, height: 45)) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .frame(width: 45, height: 45)
                                        .cornerRadius(8)
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(width: 45, height: 45)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(8)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择歌曲")
            .navigationBarItems(trailing: Button("取消") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                loadMusicLibrary()
            }
        }
    }

    private func loadMusicLibrary() {
        // 在后台线程加载音乐，防止卡顿
        DispatchQueue.global(qos: .userInitiated).async {
            let query = MPMediaQuery.songs()
            let items = query.items ?? []
            DispatchQueue.main.async {
                self.songs = items
                self.isLoading = false
            }
        }
    }
}

// ==========================================
// 3. 核心大心脏 (内置 applicationQueuePlayer 保活版)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    // 🚨 我们的内部专属播放器
    private var musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    @Published var errorMessage: String = "等待选歌..."
    @Published var currentThemeColor: String = "#34C759"
    @Published var currentSongName: String = ""
    @Published var currentArtistName: String = ""
    @Published var currentDisplayLyric: String = ""
    @Published var isPlaying: Bool = false
    
    private var parsedLyrics: [LyricLine] = []
    private var masterTimer: DispatchSourceTimer?
    private var currentLyricIndex = -1
    private var engineTickCount = 0
    private var lastUpdatedLyric = ""
    private var isFetchingLyrics = false 

    func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            purgeOrphanedActivities()
        } catch {
            self.errorMessage = "音频会话初始化失败: \(error.localizedDescription)"
        }
    }
    
    func playCollection(_ collection: MPMediaItemCollection) {
        setupAudioSession()
        musicPlayer.setQueue(with: collection)
        musicPlayer.play()
        self.isPlaying = true
        startMasterLoop()
    }
    
    func togglePlayPause() {
        if musicPlayer.playbackState == .playing {
            musicPlayer.pause()
            self.isPlaying = false
        } else {
            setupAudioSession()
            musicPlayer.play()
            self.isPlaying = true
        }
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
        
        let queue = DispatchQueue(label: "com.musicmanager.loop", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now(), repeating: 0.2)
        
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.engineTickCount += 1
            
            let rawTitle = self.musicPlayer.nowPlayingItem?.title ?? ""
            let artist = self.musicPlayer.nowPlayingItem?.artist ?? ""
            let systemTime = self.musicPlayer.currentPlaybackTime
            let currentlyPlaying = (self.musicPlayer.playbackState == .playing)
            
            DispatchQueue.main.async { self.isPlaying = currentlyPlaying }
            
            // 切歌监测
            if !rawTitle.isEmpty && rawTitle != self.currentSongName {
                DispatchQueue.main.async {
                    self.currentSongName = rawTitle
                    self.currentArtistName = artist
                }
                
                self.currentLyricIndex = -1
                self.parsedLyrics = []
                self.lastUpdatedLyric = ""
                
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
            
            // 歌词滚动推送
            if currentlyPlaying && !systemTime.isNaN {
                if !self.parsedLyrics.isEmpty {
                    let calculatedTime = systemTime + 0.3
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
            } else if !currentlyPlaying && !rawTitle.isEmpty {
                self.updateIsland(songName: rawTitle, lyric: "⏸ 已暂停播放")
            }
            
            // 心跳报告
            if self.engineTickCount % 10 == 0 {
                DispatchQueue.main.async {
                    if !self.errorMessage.contains("失败") && !self.errorMessage.contains("错误") && !self.errorMessage.contains("❌") {
                        self.errorMessage = "✅ 专属播放器运行中 | \(currentlyPlaying ? "▶️ 播放" : "⏸ 暂停")"
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
                        let staleDate = Date().addingTimeInterval(300)
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
                    let staleDate = Date().addingTimeInterval(300)
                    let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100.0)
                    await currentActivity?.update(content)
                } else {
                    await currentActivity?.update(using: state)
                }
            }
        }
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