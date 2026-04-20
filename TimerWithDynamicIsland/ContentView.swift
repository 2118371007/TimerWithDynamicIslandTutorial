import SwiftUI
import MediaPlayer
import ActivityKit

// ==========================================
// 第一部分：UI 界面 (ContentView)
// ==========================================
struct ContentView: View {
    @State private var isMonitoring = false
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: isMonitoring ? "waveform.circle.fill" : "waveform.circle")
                .resizable()
                .frame(width: 100, height: 100)
                .foregroundColor(isMonitoring ? .green : .gray)
            
            Text(isMonitoring ? "正在同步 Apple Music..." : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    MusicManager.shared.setupMonitoring()
                }
            }) {
                Text(isMonitoring ? "停止同步" : "开启同步")
                    .padding()
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}

// ==========================================
// 第二部分：后台监听引擎 (MusicManager)
// 直接写在同一个文件里，完美绕过 Xcode 编译限制！
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    // 模拟的歌词库
    let mockLrcRepo = [
        "七里香": "[00:10.20]窗外的麻雀 在电线杆上多嘴\n[00:14.30]你说这一句 很有夏天的感觉",
        "晴天": "[00:29.00]故事的小黄花 从出生那年就飘着\n[00:32.00]童年的荡秋千 随记忆一直晃到现在"
    ]

    func setupMonitoring() {
        // 开启系统音乐更改通知
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: NSNotification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
    }

    @objc func handleTrackChange() {
        guard let nowPlaying = musicPlayer.nowPlayingItem else { return }
        let title = nowPlaying.title ?? "未知歌名"
        let artist = nowPlaying.artist ?? "未知歌手"
        
        print("🎶 正在播放: \(title) - \(artist)")
        
        // 自动开启或更新灵动岛
        startOrUpdateIsland(songName: title)
    }

    func startOrUpdateIsland(songName: String) {
        let lyric = mockLrcRepo[songName] ?? "🎵 正在播放: \(songName) (暂无歌词)"
        let attributes = TimerWidgetAttributes(songName: songName)
        let state = TimerWidgetAttributes.ContentState(lyric: lyric)
        
        if currentActivity == nil {
            do {
                currentActivity = try Activity.request(attributes: attributes, contentState: state)
            } catch {
                print("上岛失败: \(error)")
            }
        } else {
            Task {
                await currentActivity?.update(using: state)
            }
        }
    }
}