import SwiftUI
import ActivityKit

struct ContentView: View {
    @State private var currentActivity: Activity<TimerWidgetAttributes>? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            Text("灵动岛歌词器测试").font(.title)
            
            Button("启动灵动岛") {
                startActivity()
            }
            .buttonStyle(.borderedProminent)
            
            Button("发送下一句测试歌词") {
                updateActivity()
            }
            .buttonStyle(.bordered)
            .disabled(currentActivity == nil)
            
            Button("关闭灵动岛") {
                stopActivity()
            }
            .foregroundColor(.red)
        }
    }

    func startActivity() {
        let attributes = TimerWidgetAttributes(songName: "七里香")
        let state = TimerWidgetAttributes.ContentState(lyric: "窗外的麻雀 在电线杆上多嘴")
        
        do {
            currentActivity = try Activity.request(attributes: attributes, contentState: state)
        } catch {
            print("启动失败: \(error.localizedDescription)")
        }
    }

    func updateActivity() {
        let newState = TimerWidgetAttributes.ContentState(lyric: "你说这一句 很有夏天的感觉")
        Task {
            await currentActivity?.update(using: newState)
        }
    }

    func stopActivity() {
        Task {
            await currentActivity?.end(dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}