import SwiftUI

struct ContentView: View {
    @State private var isMonitoring = false
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: isMonitoring ? "waveform.circle.fill" : "waveform.circle")
                .resizable()
                .frame(width: 100, height: 100)
                .foregroundColor(isMonitoring ? .green : .gray)
            
            Text(isMonitoring ? "正在同步 Apple Music..." : "歌词同步已关闭")
                .font(.headline)

            Button(action: {
                isMonitoring.toggle()
                if isMonitoring {
                    MusicManager.shared.setupMonitoring()
                }
            }) {
                Text(isMonitoring ? "停止同步" : "开启同步")
                    .padding()
                    .background(isMonitoring ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
}