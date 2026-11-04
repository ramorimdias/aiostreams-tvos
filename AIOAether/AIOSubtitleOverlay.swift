import AVFoundation
import Combine
import CoreText
import UIKit

import AetherEngine

/// The page's subtitle look, in mpv's units (packages/web/src/lib/hosts/shell/player.ts, subtitleLook).
struct AIOSubtitleStyle {
    var scale: Double = 1
    var bold = false
    var color = UIColor.white
    var outlineColor = UIColor.black
    /// mpv pixels at a 720-line picture.
    var outlineSize: Double = 1.65
    var shadowSize: Double = 0
    var backColor = UIColor.clear
    var box = false
    var font: String?
    /// mpv's sub-pos: 100 is the bottom of the picture.
    var position: Double = 100

    init() {}

    init(_ look: [String: Any]) {
        scale = (look["scale"] as? NSNumber)?.doubleValue ?? 1
        bold = look["bold"] as? Bool ?? false
        color = AIOSubtitleStyle.colour(look["color"]) ?? .white
        outlineColor = AIOSubtitleStyle.colour(look["outlineColor"]) ?? .black
        outlineSize = (look["outlineSize"] as? NSNumber)?.doubleValue ?? 0
        shadowSize = (look["shadowSize"] as? NSNumber)?.doubleValue ?? 0
        backColor = AIOSubtitleStyle.colour(look["backColor"]) ?? .clear
        box = look["box"] as? Bool ?? false
        font = look["font"] as? String
        position = (look["position"] as? NSNumber)?.doubleValue ?? 100
    }

    /// `#AARRGGBB` or `#RRGGBB`, as mpv takes them.
    static func colour(_ value: Any?) -> UIColor? {
        guard var text = value as? String, text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6 || text.count == 8, let number = UInt32(text, radix: 16) else { return nil }
        let alpha = text.count == 8 ? CGFloat((number >> 24) & 0xFF) / 255 : 1
        return UIColor(red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
                       blue: CGFloat(number & 0xFF) / 255, alpha: alpha)
    }
}

/**
 * Draws the engine's subtitle cues over the picture: AetherEngine leaves the
 * drawing to its host. Text in the page's style; pictures (PGS, DVB, DVD)
 * where the disc placed them.
 */
@MainActor
final class AIOSubtitleOverlay: UIView {
    weak var engine: AetherEngine? {
        didSet { observe() }
    }
    var style = AIOSubtitleStyle() {
        didSet { shownIDs = nil; refresh() }
    }
    /// Positive shows the subtitles later.
    var delay: Double = 0 {
        didSet { refresh() }
    }

    private var cues: [SubtitleCue] = []
    private var observers = Set<AnyCancellable>()
    private var shownIDs: [Int]?
    private var views: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        AIOSubtitleOverlay.registerFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func clear() {
        cues = []
        shownIDs = nil
        views.forEach { $0.removeFromSuperview() }
        views = []
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shownIDs = nil
        refresh()
    }

    private func observe() {
        observers.removeAll()
        guard let engine else { return }
        engine.$subtitleCues.sink { [weak self] cues in
            self?.cues = cues
            self?.refresh()
        }.store(in: &observers)
        engine.clock.$sourceTime.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &observers)
        engine.$isSubtitleActive.sink { [weak self] _ in
            self?.refresh()
        }.store(in: &observers)
    }

    private func refresh() {
        guard let engine, !isHidden else { return }
        let time = engine.clock.sourceTime - delay
        let active = engine.isSubtitleActive
        let current = cues.filter { cue in
            guard time >= cue.startTime && time < cue.endTime else { return false }
            // A disc's forced captions show even with subtitles off.
            if case .image(let image) = cue.body, image.isForced { return true }
            return active
        }
        let ids = current.map(\.id)
        if ids == shownIDs { return }
        shownIDs = ids
        views.forEach { $0.removeFromSuperview() }
        views = []

        let video = videoRect(engine)
        var texts: [SubtitleCue] = []
        for cue in current {
            if case .image(let image) = cue.body {
                show(image, in: video)
            } else {
                texts.append(cue)
            }
        }
        showTexts(texts, in: video)
    }

    /// Where the picture is, fitted into the view.
    private func videoRect(_ engine: AetherEngine) -> CGRect {
        let width = Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio
        let height = Double(engine.sourceVideoHeight)
        guard width > 0, height > 0 else { return bounds }
        switch engine.videoGravity {
        case .resize, .resizeAspectFill: return bounds
        default: return AVMakeRect(aspectRatio: CGSize(width: width, height: height), insideRect: bounds)
        }
    }

    private func show(_ image: SubtitleImage, in video: CGRect) {
        // The canvas, width-aligned and centred on the picture.
        var canvas = video
        if image.canvasSize.width > 0, image.canvasSize.height > 0 {
            let scale = video.width / image.canvasSize.width
            let size = CGSize(width: image.canvasSize.width * scale, height: image.canvasSize.height * scale)
            canvas = CGRect(x: video.midX - size.width / 2, y: video.midY - size.height / 2,
                            width: size.width, height: size.height)
        }
        let p = image.position
        let view = UIImageView(image: UIImage(cgImage: image.cgImage))
        view.frame = CGRect(x: canvas.minX + p.minX * canvas.width, y: canvas.minY + p.minY * canvas.height,
                            width: p.width * canvas.width, height: p.height * canvas.height)
        view.contentMode = .scaleToFill
        addSubview(view)
        views.append(view)
    }

    private func showTexts(_ cues: [SubtitleCue], in video: CGRect) {
        guard !cues.isEmpty else { return }
        // mpv's sizes are for a 720-line picture.
        let unit = video.height / 720
        let fontSize = max(12, 55 * style.scale * unit)
        let margin = 22 * unit

        var bottom: [SubtitleCue] = []
        var top: [SubtitleCue] = []
        for cue in cues {
            if let alignment = cue.placement?.alignment, (7...9).contains(alignment) {
                top.append(cue)
            } else {
                bottom.append(cue)
            }
        }
        let maxWidth = video.width * 0.9
        if let label = label(for: bottom, fontSize: fontSize, unit: unit, maxWidth: maxWidth) {
            let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let baseline = video.minY + video.height * min(100, max(0, style.position)) / 100 - margin
            label.frame = CGRect(x: video.midX - size.width / 2, y: baseline - size.height,
                                 width: size.width, height: size.height)
            addSubview(label)
            views.append(label)
        }
        if let label = label(for: top, fontSize: fontSize, unit: unit, maxWidth: maxWidth) {
            let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: video.midX - size.width / 2, y: video.minY + margin,
                                 width: size.width, height: size.height)
            addSubview(label)
            views.append(label)
        }
    }

    private func label(for cues: [SubtitleCue], fontSize: CGFloat, unit: CGFloat, maxWidth: CGFloat) -> AIOOutlinedLabel? {
        guard !cues.isEmpty else { return nil }
        let text = NSMutableAttributedString()
        let base = font(size: fontSize, bold: style.bold, italic: false)
        for (index, cue) in cues.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
            switch cue.body {
            case .text(let string):
                text.append(NSAttributedString(string: AIOSubtitleOverlay.clean(string),
                                               attributes: [.font: base, .foregroundColor: style.color]))
            case .richText(let runs):
                for run in runs {
                    var colour = style.color
                    if let c = run.color {
                        colour = UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                         blue: CGFloat(c.b) / 255, alpha: 1)
                    }
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: font(size: fontSize, bold: style.bold || run.isBold, italic: run.isItalic),
                        .foregroundColor: colour,
                    ]
                    if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    text.append(NSAttributedString(string: AIOSubtitleOverlay.clean(run.text), attributes: attributes))
                }
            case .image:
                break
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        let label = AIOOutlinedLabel()
        label.numberOfLines = 0
        label.attributedText = text
        label.outlineWidth = style.box ? 0 : style.outlineSize * unit
        label.outlineColor = style.outlineColor
        label.inset = style.box ? max(4, style.outlineSize * unit) : style.outlineSize * unit
        if style.box { label.backgroundColor = style.backColor }
        if style.shadowSize > 0 {
            label.layer.shadowColor = style.outlineColor.cgColor
            label.layer.shadowOpacity = 1
            label.layer.shadowRadius = 0.3 * unit
            label.layer.shadowOffset = CGSize(width: style.shadowSize * unit, height: style.shadowSize * unit)
        }
        return label
    }

    private func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        var font = style.font.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont(name: bold ? "Inter-SemiBold" : "Inter-Medium", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    /// Text the engine passes as the file had it: ASS line breaks and leftover tags.
    static func clean(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "</?(i|b|u|s|font)[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var fontsRegistered = false

    /// The app's subtitle fonts, which aren't tvOS's own.
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        for name in ["Inter-Medium", "Inter-SemiBold", "NotoSans-Regular"] {
            for ext in ["otf", "ttf"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts") {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
    }
}

/// A label with an outline drawn outside its letters, as libass draws one.
final class AIOOutlinedLabel: UILabel {
    var outlineWidth: CGFloat = 0
    var outlineColor: UIColor = .black
    var inset: CGFloat = 0

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - inset * 2, height: size.height))
        return CGSize(width: ceil(inner.width + inset * 2), height: ceil(inner.height + inset * 2))
    }

    override func drawText(in rect: CGRect) {
        let area = rect.insetBy(dx: inset, dy: inset)
        guard let text = attributedText else { return }
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        if outlineWidth > 0, let context = UIGraphicsGetCurrentContext() {
            // The outline first, twice as wide as asked since half falls inside the letters.
            let outline = NSMutableAttributedString(attributedString: text)
            let range = NSRange(location: 0, length: outline.length)
            outline.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let size = (value as? UIFont)?.pointSize ?? 40
                outline.addAttributes([
                    .strokeColor: outlineColor,
                    .strokeWidth: outlineWidth * 2 / size * 100,
                    .foregroundColor: outlineColor,
                ], range: subrange)
            }
            context.saveGState()
            context.setLineJoin(.round)
            outline.draw(with: area, options: options, context: nil)
            context.restoreGState()
        }
        text.draw(with: area, options: options, context: nil)
    }
}
