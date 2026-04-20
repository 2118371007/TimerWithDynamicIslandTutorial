import ActivityKit
import WidgetKit
import SwiftUI

struct TimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerWidgetAttributes.self) { context in
            // 锁屏界面 (锁屏时的卡片)
            VStack(spacing: 8) {
                // 🚨 注意这里：已经全部改成了 context.state.songName
                Text(context.state.songName)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(context.state.lyric)
                    .font(.body)
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                // 灵动岛展开状态
                DynamicIslandExpandedRegion(.leading) {
                    // 左侧加一个音乐图标，不再空荡荡
                    Image(systemName: "opticaldisc")
                        .foregroundColor(.blue)
                        .font(.title2)
                        .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    // 顶部居中显示歌名
                    Text(context.state.songName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 底部专门留给歌词，居中显示，超长自动缩小
                    Text(context.state.lyric)
                        .font(.title3)
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 10)
                }
            } compactLeading: {
                // 灵动岛缩小状态（左侧小图标）
                Image(systemName: "music.note")
                    .foregroundColor(.blue)
            } compactTrailing: {
                // 灵动岛缩小状态（右侧跳动音符）
                Text("🎵")
            } minimal: {
                // 极简状态
                Image(systemName: "music.note")
            }
        }
    }
}