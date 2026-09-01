import SwiftUI

/// 歌词滚动视图：当前行高亮居中，自动跟随播放进度
struct LyricScrollView: View {
    let lines: [LyricLine]
    let currentIndex: Int
    var elapsed: Double = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        LyricRowView(line: line, isCurrent: index == currentIndex, elapsed: elapsed)
                            .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: currentIndex) { _, newValue in
                guard newValue >= 0 else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

struct LyricRowView: View {
    let line: LyricLine
    let isCurrent: Bool
    var elapsed: Double = 0

    var body: some View {
        VStack(spacing: 2) {
            Text(line.text)
                .font(.system(size: isCurrent ? 12.5 : 11.5,
                              weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? PodTheme.selectedBottom : PodTheme.rowText)
                .multilineTextAlignment(.center)

            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 10))
                    .foregroundStyle(isCurrent ? PodTheme.selectedBottom.opacity(0.75) : PodTheme.rowSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isCurrent ? 1 : 0.55)
    }
}
