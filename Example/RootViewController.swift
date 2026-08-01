import UIKit
import LiquidGlass

/// One glass compose button over a colorful backdrop. That is the whole
/// example: everything else worth knowing is in the README.
final class RootViewController: UIViewController {

    /// What the glass refracts. The glass view is a sibling *above* this, never
    /// a subview of it, or it would capture itself.
    private let contentView = UIView()
    private let wallpaper = UIImageView()

    private let button = LiquidGlassView()
    private var backdrop: LiquidGlassBackdrop?

    /// Room around the button for the stretch to be drawn in: the drawable only
    /// covers `bounds`, so a deformation needs somewhere to go.
    private static let room: CGFloat = 40
    private static let size: CGFloat = 56

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        wallpaper.contentMode = .scaleAspectFill
        contentView.addSubview(wallpaper)
        view.addSubview(contentView)

        backdrop = LiquidGlassBackdrop(sourceView: contentView)
        button.backdrop = backdrop
        button.elasticity = 1
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pull)))
        view.addSubview(button)

        let glyph = UIImageView(image: UIImage(systemName: "square.and.pencil",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)))
        glyph.tintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        contentView.frame = view.bounds
        wallpaper.frame = contentView.bounds
        if wallpaper.image?.size != contentView.bounds.size, contentView.bounds.width > 0 {
            wallpaper.image = Self.makeWallpaper(size: contentView.bounds.size)
        }

        let side = Self.size + Self.room * 2
        button.frame = CGRect(x: view.bounds.midX - side / 2,
                              y: view.bounds.midY - side / 2,
                              width: side, height: side)
        button.shapes = [LiquidGlassShape(rect: CGRect(x: Self.room, y: Self.room,
                                                       width: Self.size, height: Self.size))]
    }

    /// Drag it and the shape stretches after your finger: far edge held, near
    /// edge travelling, narrowing across the pull.
    @objc private func pull(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: button.pullPoint = recognizer.location(in: button)
        default: button.pullPoint = nil
        }
    }

    /// Generated rather than shipped as an asset: saturated blobs prove the
    /// chromatic dispersion, and the straight grid proves the lensing, a
    /// straight line bending at the rim is the one thing a plain blur cannot fake.
    private static func makeWallpaper(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()

            let base = CGGradient(colorsSpace: space,
                                  colors: [UIColor(red: 0.05, green: 0.06, blue: 0.18, alpha: 1).cgColor,
                                           UIColor(red: 0.10, green: 0.04, blue: 0.24, alpha: 1).cgColor,
                                           UIColor(red: 0.02, green: 0.10, blue: 0.22, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.55, 1])!
            cg.drawLinearGradient(base, start: .zero,
                                  end: CGPoint(x: size.width, y: size.height), options: [])

            cg.setBlendMode(.plusLighter)
            for (unit, radiusFraction, color) in [
                (CGPoint(x: 0.18, y: 0.18), CGFloat(0.45), UIColor(red: 1.00, green: 0.23, blue: 0.45, alpha: 1)),
                (CGPoint(x: 0.84, y: 0.30), CGFloat(0.40), UIColor(red: 1.00, green: 0.72, blue: 0.10, alpha: 1)),
                (CGPoint(x: 0.70, y: 0.72), CGFloat(0.46), UIColor(red: 0.16, green: 0.86, blue: 0.98, alpha: 1)),
                (CGPoint(x: 0.22, y: 0.82), CGFloat(0.42), UIColor(red: 0.42, green: 0.28, blue: 1.00, alpha: 1)),
            ] {
                let center = CGPoint(x: unit.x * size.width, y: unit.y * size.height)
                let radius = radiusFraction * min(size.width, size.height)
                let gradient = CGGradient(colorsSpace: space,
                                          colors: [color.withAlphaComponent(0.85).cgColor,
                                                   color.withAlphaComponent(0).cgColor] as CFArray,
                                          locations: [0, 1])!
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: radius, options: [])
            }
            cg.setBlendMode(.normal)

            cg.setStrokeColor(UIColor(white: 1, alpha: 0.22).cgColor)
            cg.setLineWidth(1)
            var x: CGFloat = 0
            while x <= size.width {
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height)); x += 26
            }
            var y: CGFloat = 0
            while y <= size.height {
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y)); y += 26
            }
            cg.strokePath()

            cg.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            cg.setLineWidth(3)
            var diagonal: CGFloat = -size.height
            while diagonal < size.width {
                cg.move(to: CGPoint(x: diagonal, y: 0))
                cg.addLine(to: CGPoint(x: diagonal + size.height, y: size.height))
                diagonal += 190
            }
            cg.strokePath()
        }
    }
}
