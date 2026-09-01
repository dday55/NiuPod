import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// iPod Classic（第六代银色款）视觉规范
///
/// 参考要点：铝合金机身、内嵌 4:3 屏幕、顶部状态条、白→蓝灰渐变的标题栏、
/// 高亮行选中态、白底黑字的芝加哥风格菜单。
enum PodTheme {

    // MARK: 机身

    static let bodyTop = Color(hex: 0xF4F5F7)
    static let bodyMid = Color(hex: 0xDCDFE4)
    static let bodyBottom = Color(hex: 0xAFB4BB)
    static let bodyEdge = Color(hex: 0x8A9099)

    // MARK: 屏幕

    static let screenBezel = Color(hex: 0x1D1D1F)
    static let screenBackground = Color.white
    /// 屏幕内阴影（玻璃边缘压暗）
    static let screenInnerShadow = Color.black.opacity(0.22)

    // MARK: 状态条

    static let statusBarTop = Color(hex: 0xFFFFFF)
    static let statusBarBottom = Color(hex: 0xF0F1F3)
    static let statusBarText = Color(hex: 0x1D1D1F)
    static let statusBarDivider = Color(hex: 0xB9BDC4)

    // MARK: 标题栏

    static let titleTop = Color(hex: 0xFDFDFD)
    static let titleBottom = Color(hex: 0xA9B4C2)
    static let titleDivider = Color(hex: 0x8E96A1)
    static let titleText = Color(hex: 0x1D1D1F)

    // MARK: 菜单

    static let rowText = Color(hex: 0x1D1D1F)
    static let rowSecondary = Color(hex: 0x6B6B70)
    static let rowSeparator = Color(hex: 0xE3E4E6)
    static let sectionHeader = Color(hex: 0x8A8F98)

    // MARK: 选中行（经典蓝紫渐变）

    static let selectedTop = Color(hex: 0x6E92DE)
    static let selectedMiddle = Color(hex: 0x4C74C7)
    static let selectedBottom = Color(hex: 0x2A4EA0)
    static let selectedText = Color.white

    // MARK: 转盘区（拉丝铝机身）

    /// 转盘区底色：纵向金属渐变。拉丝铝在光下呈「亮—暗—亮—收暗」的多段变化，
    /// 单色平涂会像塑料，所以这里用多段 stop 还原反光层次。
    static let wheelZoneStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0xF3F4F6), location: 0.00),   // 紧邻屏幕下沿的高光
        .init(color: Color(hex: 0xDCE0E5), location: 0.08),
        .init(color: Color(hex: 0xC9CFD7), location: 0.30),
        .init(color: Color(hex: 0xD8DCE2), location: 0.55),
        .init(color: Color(hex: 0xE8EBEF), location: 0.80),   // 下部第二次反光
        .init(color: Color(hex: 0xC2C8D1), location: 0.95),
        .init(color: Color(hex: 0xB2B8C2), location: 1.00),   // 机身下沿收暗
    ]

    static var wheelZoneGradient: LinearGradient {
        LinearGradient(stops: wheelZoneStops, startPoint: .top, endPoint: .bottom)
    }

    /// 屏幕与机身交界的缝：先是屏幕下沿的暗线，再是金属面顶部的高光
    static let seamShadow = Color(hex: 0x8E949D).opacity(0.55)
    static let seamHighlight = Color.white.opacity(0.9)

    // MARK: 转盘本体

    /// 转盘盘面：真机是近乎均匀的亮白（比银色机身更亮、更白），渐变极弱。
    /// 半径要跟随实际尺寸，否则 stop 只能用到一部分，渐变为零。
    static func wheelFaceGradient(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [
            .init(color: Color.white, location: 0.00),
            .init(color: Color(hex: 0xF8F9FA), location: 0.70),
            .init(color: Color(hex: 0xECEEF1), location: 1.00),
        ], center: .center, startRadius: 0, endRadius: max(1, radius))
    }

    /// 转盘与机身之间的凹槽圈：上缘压暗（沉台阴影）、下缘提亮（金属反光）。
    /// 真机转盘略低于机身平面，这一圈缝就是「盘面嵌在机身里」的层次来源。
    static var wheelGrooveGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color.black.opacity(0.24), location: 0.00),
            .init(color: Color.black.opacity(0.06), location: 0.30),
            .init(color: Color.white.opacity(0.00), location: 0.55),
            .init(color: Color.white.opacity(0.90), location: 1.00),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// 转盘与机身之间那道极细的缝（描边最外圈）
    static let wheelGap = Color(hex: 0x9BA1AA).opacity(0.8)

    /// 刻字颜色：真机是清晰可辨的中灰，不是浅灰
    static let wheelGlyph = Color(hex: 0x747A84)
    static let wheelGlyphActive = Color(hex: 0x4A5058)

    /// 中心键：亮白径向渐变，边缘微微收暗
    static func centerGradient(radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [
            .init(color: Color.white, location: 0.00),
            .init(color: Color(hex: 0xF2F3F5), location: 0.60),
            .init(color: Color(hex: 0xDEE1E5), location: 1.00),
        ], center: .center, startRadius: 0, endRadius: max(1, radius))
    }

    /// 中心键外圈的凹槽环：上深下浅，让键帽与盘面有一道清晰的缝
    static var centerRingGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x969CA4), location: 0.00),
            .init(color: Color(hex: 0xC9CDD3), location: 0.45),
            .init(color: Color(hex: 0xAEB4BB), location: 1.00),
        ], startPoint: .top, endPoint: .bottom)
    }

    static let centerEdgeShadow = Color(hex: 0xA8AEB7).opacity(0.65)

    // MARK: 尺寸（相对屏幕宽度换算，保证小屏也协调）

    /// 全屏铺满后可视高度约为原来的两倍，行高/字号相应放大一点，
    /// 避免在大屏上显得稀疏
    static let statusBarHeight: CGFloat = 20
    static let titleBarHeight: CGFloat = 30
    static let rowHeight: CGFloat = 34
    static let screenCornerRadius: CGFloat = 4
    static let bodyCornerRadius: CGFloat = 26

    // MARK: 渐变

    static var bodyGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: bodyTop, location: 0),
                .init(color: bodyMid, location: 0.55),
                .init(color: bodyBottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    static var titleGradient: LinearGradient {
        LinearGradient(colors: [titleTop, titleBottom], startPoint: .top, endPoint: .bottom)
    }

    static var selectedGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: selectedTop, location: 0),
                .init(color: selectedMiddle, location: 0.5),
                .init(color: selectedBottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

}

/// iPod 界面用的字重与字号（芝加哥字体不可用，用系统字体 + 紧凑字距近似）
enum PodFont {
    static func title(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static func row(_ size: CGFloat = 15, selected: Bool = false) -> Font {
        .system(size: size, weight: selected ? .semibold : .regular, design: .default)
    }
}
