import ActivityKit
import WidgetKit
import SwiftUI

struct TimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerWidgetAttributes.self) { context in
            // 1. 锁屏界面的样式（灵动岛不展开时的底部通知）
            VStack {
                Text(context.attributes.songName).font(.caption).foregroundColor(.secondary)
                Text(context.state.lyric).font(.headline)
            }
            .padding()

        } dynamicIsland: { context in
            DynamicIsland {
                // 2. 灵动岛长按展开后的完整界面
                DynamicIslandExpandedRegion(.leading) {
                    Text("🎵").font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.songName).font(.caption).foregroundColor(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.lyric)
                        .font(.title3)
                        .lineLimit(1)
                        .padding(.top, 5)
                }
            } compactLeading: {
                // 3. 灵动岛左侧紧凑态（显示个图标）
                Text("🎵")
            } compactTrailing: {
                // 4. 灵动岛右侧紧凑态（显示当前歌词摘要）
                Text(context.state.lyric).font(.caption2)
            } minimal: {
                // 5. 独立态（当有多个灵动岛时显示的小圆点）
                Text("🎵")
            }
        }
    }
}