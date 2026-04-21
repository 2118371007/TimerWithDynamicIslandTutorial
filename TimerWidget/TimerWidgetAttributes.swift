import ActivityKit
import Foundation

struct TimerWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var songName: String
        var lyric: String
        // 🚨 新增：存放专辑主色调的 Hex 字符串 (例如 "#E5A823")
        var themeColorHex: String
    }
}