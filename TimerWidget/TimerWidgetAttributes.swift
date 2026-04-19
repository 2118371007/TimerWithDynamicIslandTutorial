import Foundation
import ActivityKit

struct TimerWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // 这里定义了灵动岛实时更新的数据：当前这行歌词
        var lyric: String
    }

    // 这里定义了灵动岛固定不变的数据：歌名
    var songName: String
}