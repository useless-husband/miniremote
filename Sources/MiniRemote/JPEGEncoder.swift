import Foundation
import CoreImage
import ImageIO

/// 備用編碼:每一幀都是完整 JPEG,任何瀏覽器(包含 http 非安全來源)都能顯示
final class JPEGEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func encode(_ pb: CVPixelBuffer, quality: Double) -> Data? {
        let image = CIImage(cvPixelBuffer: pb)
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: opts)
    }
}
