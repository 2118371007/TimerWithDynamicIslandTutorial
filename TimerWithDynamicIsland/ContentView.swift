import SwiftUI
import MediaPlayer
import ActivityKit

// ==========================================
// 第一部分：UI 界面 (ContentView)
// ==========================================
struct ContentView: View {
    @State private var isMonitoring = false
    // 引入 MusicManager 实例，用来监听它发出的状态和报错
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
                } else {
                    musicManager.stopMonitoring()
                }
            }) {
                Text(isMonitoring ? "停止同步" : "开启同步")
                    .padding()
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            // 🚨 状态与错误雷达：让所有报错在屏幕上无处遁形
            if !musicManager.errorMessage.isEmpty {
                Text(musicManager.errorMessage)
                    // 如果包含叉号就变红，否则变绿
                    .foregroundColor(musicManager.errorMessage.contains("❌") ? .red : .green)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .padding()
    }
}

// ==========================================
// 第二部分：后台监听引擎 (MusicManager)
// 直接写在同一个文件里，完美绕过云端编译器的文件链接限制！
// ==========================================
class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    // 专门用来把错误和状态抛给屏幕显示的变量
    @Published var errorMessage: String = ""
    
    // 模拟的本地歌词库
    let mockLrcRepo = [
        "七里香": "[00:10.20]窗外的麻雀 在电线杆上多嘴\n[00:14.30]你说这一句 很有夏天的感觉",
        "晴天": "[00:29.00]故事的小黄花 从出生那年就飘着\n[00:32.00]童年的荡秋千 随记忆一直晃到现在"
    ]

    func setupMonitoring() {
        self.errorMessage = "正在请求 Apple Music 权限..."
        
        // 主动呼叫系统的权限弹窗
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.errorMessage = "✅ 权限已获取，开始监听！"
                    self.startListening()
                case .denied, .restricted:
                    self.errorMessage = "❌ 被拒绝访问 Apple Music，请去设置中允许"
                case .notDetermined:
                    self.errorMessage = "⚠️ 权限未确定"
                @unknown default:
                    break
                }
            }
        }
    }
    
    // 权限通过后真正执行监听的逻辑
    private func startListening() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTrackChange), name: NSNotification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        
        // 刚开启时，立刻尝试获取当前播放的歌曲上岛
        handleTrackChange()
    }

    @objc func handleTrackChange() {
        // 不再拦截空值，直接强行读取，读不到就用占位符
        let title = musicPlayer.nowPlayingItem?.title ?? "等待 Apple Music..."
        
        print("🎶 尝试同步: \(title)")
        startOrUpdateIsland(songName: title)
    }

    func startOrUpdateIsland(songName: String) {
        let lyric: String
        // 如果系统没在放歌，先上岛占个位
        if songName == "等待 Apple Music..." {
            lyric = "请在 Apple Music 中播放音乐 🎵"
        } else {
            // 否则去匹配本地词库
            lyric = mockLrcRepo[songName] ?? "正在播放: \(songName) (暂无本地歌词)"
        }
        
        let attributes = TimerWidgetAttributes(songName: songName)
        let state = TimerWidgetAttributes.ContentState(lyric: lyric)
        
        // 核心：强制触发上岛
        if currentActivity == nil {
            do {
                currentActivity = try Activity.request(attributes: attributes, contentState: state)
                DispatchQueue.main.async {
                    if !self.errorMessage.contains("❌") {
                        self.errorMessage = "✅ 成功激活灵动岛！"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "❌ 激活失败: \(error.localizedDescription)"
                }
            }
        } else {
            // 已经在岛上了，直接静默刷新数据
            Task {
                await currentActivity?.update(using: state)
            }
        }
    }
    
    // 停止同步并下岛
    func stopMonitoring() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
        
        self.errorMessage = "已停止同步并关闭灵动岛"
    }
}