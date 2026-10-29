import Foundation

nonisolated enum WorkshopPlaybackPolicy {
    static let convertedVideoKey = "workshop.autoBake.enabled"

    /// 原生视频一直使用原文件；关闭转换开关时不读取、不选用转换缓存。
    static func videoURL(original: URL?, useConvertedVideo: Bool, converted: () -> URL?) -> URL? {
        if let original { return original }
        return useConvertedVideo ? converted() : nil
    }
}
