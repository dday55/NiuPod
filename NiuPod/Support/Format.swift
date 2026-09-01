import Foundation

extension Double {
    /// 秒 → `m:ss`（负数保留符号，用于「剩余时间」）
    var mmss: String {
        let total = Int(abs(self).rounded())
        let sign = self < 0 ? "-" : ""
        return String(format: "%@%d:%02d", sign, total / 60, total % 60)
    }
}

extension Int {
    /// 毫秒 → `m:ss`
    var durationText: String {
        Double(self / 1000).mmss
    }
}

/// 列表副标题：如 `12 首 · 98 张`
extension Int {
    var songCountText: String { "\(self) 首" }
}
