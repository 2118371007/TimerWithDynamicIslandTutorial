import SwiftUI
import MediaPlayer
import ActivityKit

// ==========================================
// 第一部分：UI 界面 (ContentView)
// ==========================================
struct ContentView: View {
    @State private var isMonitoring = false
    // 引入 MusicManager 实例，用来监听它发出的报错
    @ObservedObject var musicManager = MusicManager.shared
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: isMonitoring ? "waveform.circle.fill" : "waveform.circle")
                .resizable()
                .frame(width: 100, height: 100)
                .foregroundColor(isMonitoring ? .green : .gray)
            
            Text(isMonitoring ? "正在同步 Apple Music..." : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    musicManager.setupMonitoring()
                }
            }) {
                Text(isMonitoring ? "停止同步" : "开启同步")
                    .padding()
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            // 🚨 错误雷达：如果上岛失败，这里会显示红色的错误原因
            if !musicManager.errorMessage.isEmpty {
                Text("报错信息: \(musicManager.errorMessage)")
                    .foregroundColor(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

// ==========================================
// 第二部分：后台监听引擎 (MusicManager)
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    // 🚨 专门用来把错误抛给屏幕显示的变量
    @Published var errorMessage: String = ""
    
    let mockLrcRepo = [
        "七里香": "[00:10.20]窗外的麻雀 在电线杆上多嘴\n[00:14.30]你说这一句 很有夏天的感觉",
        "晴天": "[00:29.00]故事的小黄花 从出生那年就飘着\n[00:32.00]童年的荡秋千 随记忆一直晃到现在"
    ]

    func setupMonitoring() {
        self.errorMessage = "" // 每次点击清空错误
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: NSNotification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        
        // 刚开启时，立刻尝试获取当前播放的歌曲上岛
        handleTrackChange()
    }

    @objc func handleTrackChange() {
        guard let nowPlaying = musicPlayer.nowPlayingItem else { 
            DispatchQueue.main.async {
                self.errorMessage = "未获取到正在播放的歌曲，请确保 Apple Music 正在播放"
            }
            return 
        }
        let title = nowPlaying.title ?? "未知歌名"
        startOrUpdateIsland(songName: title)
    }

    func startOrUpdateIsland(songName: String) {
        let lyric = mockLrcRepo[songName] ?? "正在播放: \(songName) (暂无本地歌词)"
        let attributes = TimerWidgetAttributes(songName: songName)
        let state = TimerWidgetAttributes.ContentState(lyric: lyric)
        
        if currentActivity == nil {
            do {
                currentActivity = try Activity.request(attributes: attributes, contentState: state)
                DispatchQueue.main.async {
                    self.errorMessage = "上岛成功！" // 成功也给个提示
                }
            } catch {
                // 🚨 抓取错误并显示到屏幕上
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        } else {
            Task {
                await currentActivity?.update(using: state)
            }
        }
    }
}