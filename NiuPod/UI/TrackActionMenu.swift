import SwiftUI

/// 曲目操作菜单
///
/// 真 iPod 上长按中心键会呼出「评级 / 加入歌单」这类上下文菜单，这里沿用同一
/// 套交互：长按中心键弹出，转盘选行，中心键执行，MENU 关闭。
///
/// 收藏的唯一入口曾经藏在「正在播放 → 中心键切两下 → 选项」里，收藏列表本身
/// 也没有任何移除方式——这个菜单就是为了补上这个死角。
struct TrackActionMenu: View {
    let track: Track
    let isFavorite: Bool
    /// 选中某一项（转盘中心键或点按都会走这里），0=播放 1=收藏/取消收藏 2=取消
    var onSelect: (Int) -> Void
    @Binding var selected: Int
    /// 点遮罩空白处关闭
    var onClose: () -> Void

    /// 菜单项（ActionRow 也要用，所以不能是 private）
    struct Item {
        let icon: String
        let title: String
        let isDestructive: Bool
        /// 使用自绘实心图形（SF Symbols 没有 xmark.fill，纯 xmark 又太细）
        var isCustomIcon = false
    }

    private var items: [Item] {
        [
            Item(icon: "play.fill", title: "播放", isDestructive: false),
            Item(icon: isFavorite ? "heart.slash.fill" : "heart.fill",
                 title: isFavorite ? "取消收藏" : "收藏",
                 isDestructive: isFavorite),
            Item(icon: "xmark", title: "取消", isDestructive: false, isCustomIcon: true),
        ]
    }

    var body: some View {
        ZStack {
            // 遮罩：点按空白处也能关掉，避免只剩转盘一条路
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    // 曲目头
                    VStack(spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.system(size: 11))
                            .foregroundStyle(PodTheme.rowSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(PodTheme.titleGradient)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(PodTheme.titleDivider).frame(height: 1)
                    }

                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ActionRow(item: item, isSelected: index == selected)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected = index
                                onSelect(index)
                            }
                    }
                }
                .background(PodTheme.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 6)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }

}

private struct ActionRow: View {
    let item: TrackActionMenu.Item
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if item.isCustomIcon {
                SolidX()
                    .fill(isSelected ? PodTheme.selectedText : PodTheme.rowText)
                    .frame(width: 12, height: 12)
                    // 与 SF Symbol 图标同占 16pt 宽，保证三项图标中心对齐
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
            }
            Text(item.title)
                .font(PodFont.row(15, selected: isSelected))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: PodTheme.rowHeight)
        .foregroundStyle(isSelected ? PodTheme.selectedText : PodTheme.rowText)
        .background {
            if isSelected {
                PodTheme.selectedGradient
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PodTheme.rowSeparator)
                .frame(height: 0.5)
                .opacity(isSelected ? 0 : 1)
        }
        .clipShape(Rectangle())
    }
}

/// 实心 ✕：与 play.fill / heart.fill 一致的实心图形（SF Symbols 没有 xmark.fill）
struct SolidX: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let stroke = w * 0.26
        let inset = stroke * 0.5

        func addBar(from p1: CGPoint, to p2: CGPoint) {
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let len = max(0.0001, sqrt(dx * dx + dy * dy))
            let nx = -dy / len * stroke * 0.5
            let ny = dx / len * stroke * 0.5
            path.move(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
            path.addLine(to: CGPoint(x: p2.x + nx, y: p2.y + ny))
            path.addLine(to: CGPoint(x: p2.x - nx, y: p2.y - ny))
            path.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
            path.closeSubpath()
        }

        addBar(from: CGPoint(x: rect.minX + inset, y: rect.minY + inset),
               to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        addBar(from: CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
               to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        return path
    }
}
