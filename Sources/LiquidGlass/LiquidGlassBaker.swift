import UIKit
import Metal
import simd

/// renders the glass once into an image, for glass that does not need to be live.
/// the light is fixed (`configuration.staticLightDirection`). main thread only
public enum LiquidGlassBaker {

    public enum Content {
        /// just the rim light and shade as one transparent layer, independent of any backdrop
        case rimOverlay
        /// the whole glass over `image`
        case glass(over: UIImage)
    }

    public static func image(size: CGSize,
                             shapes: [LiquidGlassShape]? = nil,
                             configuration: LiquidGlassConfiguration = .regular,
                             content: Content,
                             scale: CGFloat? = nil) -> UIImage? {
        guard let engine = LiquidGlassEngine.shared, size.width >= 1, size.height >= 1 else { return nil }
        let scale = scale ?? UIScreen.main.scale
        let bounds = CGRect(origin: .zero, size: size)

        let container = UIView(frame: bounds)
        let source: UIView
        let overlayOnly: Bool
        switch content {
        case .rimOverlay:
            // mid-grey, so the light is scaled by a neutral brightness
            source = UIView(frame: bounds)
            source.backgroundColor = UIColor(white: 0.5, alpha: 1)
            overlayOnly = true
        case let .glass(image):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = bounds
            source = imageView
            overlayOnly = false
        }
        container.addSubview(source)

        var configuration = configuration
        configuration.motionResponsive = false
        let glass = LiquidGlassView(frame: bounds)
        glass.renderScaleOverride = scale
        glass.rendersRimOverlayOnly = overlayOnly
        glass.reduceTransparencyOverride = false     // a bake is an asset, not a setting
        glass.configuration = configuration
        glass.shapes = shapes
        container.addSubview(glass)
        container.layoutIfNeeded()

        guard let backdrop = LiquidGlassBackdrop(sourceView: source) else { return nil }
        backdrop.captureRect = bounds
        backdrop.captureScale = 1
        backdrop.isLive = false
        glass.backdrop = backdrop
        guard backdrop.captureIfNeeded() else { return nil }

        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = engine.device.makeTexture(descriptor: descriptor),
              let commandBuffer = engine.commandQueue.makeCommandBuffer()
        else { return nil }

        engine.encodePyramid(for: backdrop, into: commandBuffer)
        let light = simd_normalize(configuration.staticLightDirection)
        guard glass.encodeGlass(into: commandBuffer, target: target, light: light) else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return makeImage(from: target, scale: scale)
    }

    private static func makeImage(from texture: MTLTexture, scale: CGFloat) -> UIImage? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: texture.width, height: texture.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
