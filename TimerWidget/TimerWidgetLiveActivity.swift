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
                    .foregroundColor(.white.opacity(0.8))
                
                Text(context.state.lyric)
                    .font(.title3.bold())
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
                    // 🚨 优化点：放宽到3行，允许极限缩小到40%
                    .lineLimit(3)
                    .minimumScaleFactor(0.4)
                    .fixedSize(horizontal: false, vertical: true) // 强制垂直方向自适应撑开
            }
            .padding()
            
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
                        .minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.lyric)
                        .font(.title3)
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                        // 🚨 优化点：放宽到3行，极限缩小，并增加横向边距防止贴边
                        .lineLimit(3)
                        .minimumScaleFactor(0.4)
                        .padding(.bottom, 10)
                        .padding(.horizontal, 5)
                }
            } compactLeading: {
                // ==========================================
                // 3. 灵动岛【收缩】状态（左侧）
                // ==========================================
                Image(systemName: "music.note")
                    .foregroundColor(.blue)
            } compactTrailing: {
                // ==========================================
                // 4. 灵动岛【收缩】状态（右侧）
                // ==========================================
                Text(context.state.lyric)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
                    // 🚨 优化点：稍微拓宽胶囊空间，并允许字体极限缩小挤进去
                    .frame(maxWidth: 140, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5) 
            } minimal: {
                // ==========================================
                // 5. 极简状态
                // ==========================================
                Image(systemName: "music.note")
                    .foregroundColor(.green)
            }
        }
    }
}