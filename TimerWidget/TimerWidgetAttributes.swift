import ActivityKit
import Foundation

struct TimerWidgetAttributes: ActivityAttributes {
    // 动态状态：把 songName 和 lyric 都放在这里，切歌才能无缝刷新
    public struct ContentState: Codable, Hashable {
        var songName: String
        var lyric: String
    }
}