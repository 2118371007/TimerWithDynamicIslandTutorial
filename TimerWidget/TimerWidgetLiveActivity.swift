import ActivityKit
import WidgetKit
import SwiftUI

struct TimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerWidgetAttributes.self) { context in
            // 1. 锁屏与通知中心界面
            VStack(spacing: 8) {
                Text(context.state.songName)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(context.state.lyric)
                    .font(.title3.bold())
                    // 🚨 魔法调色：读取 Hex 字符串并渲染为真色彩
                    .foregroundColor(Color(hex: context.state.themeColorHex))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            
        } dynamicIsland: { context in
            DynamicIsland {
                // 2. 灵动岛长按【展开】状态
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "opticaldisc.fill")
                        .foregroundColor(Color(hex: context.state.themeColorHex))
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
                        .foregroundColor(Color(hex: context.state.themeColorHex))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.4)
                        .padding(.bottom, 10)
                        .padding(.horizontal, 5)
                }
            } compactLeading: {
                // 3. 灵动岛【收缩】状态（左侧图标）
                Image(systemName: "music.note")
                    .foregroundColor(Color(hex: context.state.themeColorHex))
            } compactTrailing: {
                // 4. 灵动岛【收缩】状态（右侧歌词）
                Text(context.state.lyric)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: context.state.themeColorHex))
                    .frame(maxWidth: 140, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5) 
            } minimal: {
                // 5. 极简状态
                Image(systemName: "music.note")
                    .foregroundColor(Color(hex: context.state.themeColorHex))
            }
        }
    }
}

// ==========================================
// 🚨 SwiftUI 颜色解码器：把 "#FF0000" 变回真正的 Color
// ==========================================
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: // RGB (24-bit)
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (52, 199, 89) // 如果解析失败，回退到经典的 iOS 绿色
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue:  Double(b) / 255, opacity: 1)
    }
}