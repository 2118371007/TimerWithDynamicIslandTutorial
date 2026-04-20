import ActivityKit
import WidgetKit
import SwiftUI

struct TimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerWidgetAttributes.self) { context in
            // ==========================================
            // 1. 锁屏与通知中心界面
            // ==========================================
            VStack(spacing: 8) {
                Text(context.state.songName)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8)) // 歌名稍微变淡，突出歌词
                
                Text(context.state.lyric)
                    .font(.title3.bold()) // 锁屏状态下歌词稍微放大加粗
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding()
            // 🚨 核心修复：已经删除了原有的黑色背景，现在将完美融入 iOS 系统毛玻璃！
            
        } dynamicIsland: { context in
            DynamicIsland {
                // ==========================================
                // 2. 灵动岛长按【展开】状态
                // ==========================================
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "opticaldisc.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                        .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.songName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
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
                // ==========================================
                // 3. 灵动岛【收缩】状态（左侧）
                // ==========================================
                Image(systemName: "music.note")
                    .foregroundColor(.blue)
            } compactTrailing: {
                // ==========================================
                // 4. 灵动岛【收缩】状态（右侧）- 🚨 见缝插针黑科技！
                // ==========================================
                Text(context.state.lyric)
                    .font(.system(size: 11, weight: .medium)) // 必须极小才能塞进胶囊
                    .foregroundColor(.green)
                    .frame(maxWidth: 120, alignment: .trailing) // 限制宽度防止把岛撑破
                    .lineLimit(1)
            } minimal: {
                // ==========================================
                // 5. 极简状态（当同时有导航、录音等多个任务抢占灵动岛时）
                // ==========================================
                Image(systemName: "music.note")
                    .foregroundColor(.green)
            }
        }
    }
}