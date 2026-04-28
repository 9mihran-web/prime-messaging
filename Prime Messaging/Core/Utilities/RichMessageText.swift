import Foundation
import SwiftUI
import UIKit

enum RichMessageText {
    fileprivate static let spoilerAttributeName = NSAttributedString.Key("PrimeSpoilerID")

    fileprivate struct StyleState: Equatable {
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStruck = false
        var isSpoiler = false
        var isCode = false
        var linkURL: URL?
    }

    fileprivate struct Segment: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var style: StyleState
        var spoilerID: String?
    }

    static func plainText(from rawText: String?) -> String {
        parseSegments(from: rawText).map(\.text).joined()
    }

    static func containsExplicitMarkup(_ rawText: String?) -> Bool {
        guard let rawText, rawText.isEmpty == false else { return false }
        return rawText.range(
            of: #"</?(b|i|u|s|code|spoiler|a)(\s+[^>]*)?>"#,
            options: .regularExpression
        ) != nil
    }

    static func detectedURLs(in rawText: String?) -> [URL] {
        let explicitURLs = parseSegments(from: rawText).compactMap(\.style.linkURL)
        let plainText = plainText(from: rawText)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Array(NSOrderedSet(array: explicitURLs)) as? [URL] ?? explicitURLs
        }

        let range = NSRange(plainText.startIndex..<plainText.endIndex, in: plainText)
        let detected = detector.matches(in: plainText, options: [], range: range).compactMap(\.url)
        let combined = explicitURLs + detected
        var seen = Set<String>()
        return combined.filter { url in
            let key = url.absoluteString.lowercased()
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    static func makeAttributedString(
        from rawText: String?,
        baseFontSize: CGFloat,
        textColor: UIColor,
        revealedSpoilerIDs: Set<String> = []
    ) -> NSAttributedString {
        let segments = parseSegments(from: rawText)
        let result = NSMutableAttributedString()

        for segment in segments {
            let text = normalizedTaskText(segment.text)
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: baseAttributes(
                    for: segment.style,
                    fontSize: baseFontSize,
                    textColor: textColor,
                    spoilerID: segment.spoilerID,
                    isSpoilerRevealed: segment.spoilerID.map(revealedSpoilerIDs.contains) ?? true
                )
            )
            result.append(attributed)
        }

        return result
    }

    static func spoilerID(
        in attributedText: NSAttributedString,
        at characterIndex: Int
    ) -> String? {
        guard characterIndex >= 0, characterIndex < attributedText.length else {
            return nil
        }
        return attributedText.attribute(spoilerAttributeName, at: characterIndex, effectiveRange: nil) as? String
    }

    private static func normalizedTaskText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ ] ", with: "☐ ")
            .replacingOccurrences(of: "[x] ", with: "☑ ")
            .replacingOccurrences(of: "[X] ", with: "☑ ")
    }

    private static func baseAttributes(
        for style: StyleState,
        fontSize: CGFloat,
        textColor: UIColor,
        spoilerID: String?,
        isSpoilerRevealed: Bool
    ) -> [NSAttributedString.Key: Any] {
        let baseFont = resolvedFont(for: style, fontSize: fontSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: textColor
        ]

        if style.isUnderlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let linkURL = style.linkURL {
            attributes[.link] = linkURL
            attributes[.foregroundColor] = UIColor(PrimeTheme.Colors.accent)
            if style.isUnderlined == false {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if style.isCode {
            attributes[.backgroundColor] = textColor.withAlphaComponent(0.08)
        }
        if let spoilerID {
            attributes[spoilerAttributeName] = spoilerID
            if isSpoilerRevealed {
                attributes[.backgroundColor] = textColor.withAlphaComponent(0.12)
            } else {
                attributes[.foregroundColor] = UIColor.clear
                attributes[.backgroundColor] = textColor.withAlphaComponent(0.8)
            }
        }

        return attributes
    }

    private static func resolvedFont(for style: StyleState, fontSize: CGFloat) -> UIFont {
        if style.isCode {
            return .monospacedSystemFont(ofSize: fontSize, weight: style.isBold ? .semibold : .regular)
        }

        var font = UIFont.systemFont(ofSize: fontSize, weight: style.isBold ? .semibold : .regular)
        if style.isItalic, let descriptor = font.fontDescriptor.withSymbolicTraits([font.fontDescriptor.symbolicTraits, .traitItalic]) {
            font = UIFont(descriptor: descriptor, size: fontSize)
        }
        return font
    }

    fileprivate static func parseSegments(from rawText: String?) -> [Segment] {
        guard let rawText, rawText.isEmpty == false else { return [] }

        var index = rawText.startIndex
        var states = [StyleState()]
        var segments: [Segment] = []

        func appendText(_ text: String) {
            guard text.isEmpty == false else { return }
            let currentStyle = states.last ?? StyleState()
            let spoilerID = currentStyle.isSpoiler ? "spoiler-\(segments.count)-\(text.hashValue)" : nil
            segments.append(Segment(text: text, style: currentStyle, spoilerID: spoilerID))
        }

        while index < rawText.endIndex {
            if rawText[index] == "<", let closing = rawText[index...].firstIndex(of: ">") {
                let rawTag = String(rawText[rawText.index(after: index)..<closing]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercasedTag = rawTag.lowercased()

                if lowercasedTag == "b" || lowercasedTag == "i" || lowercasedTag == "u" || lowercasedTag == "s" || lowercasedTag == "code" || lowercasedTag == "spoiler" {
                    var next = states.last ?? StyleState()
                    switch lowercasedTag {
                    case "b": next.isBold = true
                    case "i": next.isItalic = true
                    case "u": next.isUnderlined = true
                    case "s": next.isStruck = true
                    case "code": next.isCode = true
                    case "spoiler": next.isSpoiler = true
                    default: break
                    }
                    states.append(next)
                    index = rawText.index(after: closing)
                    continue
                }

                if lowercasedTag == "/b" || lowercasedTag == "/i" || lowercasedTag == "/u" || lowercasedTag == "/s" || lowercasedTag == "/code" || lowercasedTag == "/spoiler" || lowercasedTag == "/a" {
                    if states.count > 1 {
                        states.removeLast()
                    }
                    index = rawText.index(after: closing)
                    continue
                }

                if lowercasedTag.hasPrefix("a "), let href = hrefValue(in: rawTag) {
                    var next = states.last ?? StyleState()
                    next.linkURL = href
                    states.append(next)
                    index = rawText.index(after: closing)
                    continue
                }
            }

            let nextTagIndex = rawText[index...].firstIndex(of: "<") ?? rawText.endIndex
            appendText(String(rawText[index..<nextTagIndex]))
            index = nextTagIndex
        }

        return coalesced(segments)
    }

    private static func coalesced(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for segment in segments {
            guard segment.text.isEmpty == false else { continue }
            if var last = result.last,
               last.style == segment.style,
               last.spoilerID == segment.spoilerID {
                last.text += segment.text
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func hrefValue(in rawTag: String) -> URL? {
        guard let range = rawTag.range(of: #"href\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let rawValue = String(rawTag[range]).replacingOccurrences(of: #"href\s*=\s*""#, with: "", options: .regularExpression).dropLast()
        let text = String(rawValue)
        if let url = URL(string: text), url.scheme != nil {
            return url
        }
        if let url = URL(string: "https://" + text) {
            return url
        }
        return nil
    }
}

final class MessageRichTextViewContainer: UITextView {
    override var intrinsicContentSize: CGSize {
        let size = sizeThatFits(CGSize(width: bounds.width == 0 ? UIScreen.main.bounds.width : bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

struct MessageRichTextView: UIViewRepresentable {
    let rawText: String
    let fontSize: CGFloat
    let textColor: UIColor
    let revealedSpoilerIDs: Set<String>
    let onToggleSpoiler: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggleSpoiler: onToggleSpoiler)
    }

    func makeUIView(context: Context) -> MessageRichTextViewContainer {
        let textView = MessageRichTextViewContainer()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = context.coordinator
        textView.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapGesture)
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ uiView: MessageRichTextViewContainer, context: Context) {
        uiView.linkTextAttributes = [
            .foregroundColor: UIColor(PrimeTheme.Colors.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        uiView.attributedText = RichMessageText.makeAttributedString(
            from: rawText,
            baseFontSize: fontSize,
            textColor: textColor,
            revealedSpoilerIDs: revealedSpoilerIDs
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        let onToggleSpoiler: (String) -> Void

        init(onToggleSpoiler: @escaping (String) -> Void) {
            self.onToggleSpoiler = onToggleSpoiler
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView, gesture.state == .ended else { return }
            let location = gesture.location(in: textView)
            let inset = textView.textContainerInset
            let adjusted = CGPoint(x: location.x - inset.left, y: location.y - inset.top)
            let index = textView.layoutManager.characterIndex(
                for: adjusted,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard let spoilerID = RichMessageText.spoilerID(in: textView.attributedText, at: index) else {
                return
            }
            onToggleSpoiler(spoilerID)
        }
    }
}

struct RichBubbleTextView: View {
    let rawText: String
    let fontSize: CGFloat
    let textColor: Color

    @State private var revealedSpoilerIDs: Set<String> = []

    var body: some View {
        MessageRichTextView(
            rawText: rawText,
            fontSize: fontSize,
            textColor: UIColor(textColor),
            revealedSpoilerIDs: revealedSpoilerIDs,
            onToggleSpoiler: { spoilerID in
                if revealedSpoilerIDs.contains(spoilerID) {
                    revealedSpoilerIDs.remove(spoilerID)
                } else {
                    revealedSpoilerIDs.insert(spoilerID)
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class ComposerTextViewContainer: UITextView {
    var calculatedHeightChanged: ((CGFloat) -> Void)?
    var maximumHeight: CGFloat = 120
    var applyMarkupAction: ((String, String, String) -> Void)?
    var insertLinkAction: (() -> Void)?
    private var lastReportedHeight: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let size = sizeThatFits(CGSize(width: bounds.width == 0 ? UIScreen.main.bounds.width : bounds.width, height: .greatestFiniteMagnitude))
        let clamped = min(maximumHeight, ceil(size.height))
        return CGSize(width: UIView.noIntrinsicMetric, height: clamped)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = sizeThatFits(CGSize(width: bounds.width == 0 ? UIScreen.main.bounds.width : bounds.width, height: .greatestFiniteMagnitude))
        let clamped = min(maximumHeight, ceil(size.height))
        isScrollEnabled = size.height > maximumHeight
        if abs(lastReportedHeight - clamped) > 0.5 {
            lastReportedHeight = clamped
            calculatedHeightChanged?(clamped)
        }
        invalidateIntrinsicContentSize()
    }

    @available(iOS 16.0, *)
    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selectedRange.length > 0 else {
            return UIMenu(children: suggestedActions)
        }

        let formattingMenu = UIMenu(
            title: "Formatting",
            image: UIImage(systemName: "textformat"),
            children: [
                UIAction(title: "Bold", image: UIImage(systemName: "bold")) { [weak self] _ in
                    self?.applyMarkupAction?("<b>", "</b>", "bold")
                },
                UIAction(title: "Italic", image: UIImage(systemName: "italic")) { [weak self] _ in
                    self?.applyMarkupAction?("<i>", "</i>", "italic")
                },
                UIAction(title: "Underline", image: UIImage(systemName: "underline")) { [weak self] _ in
                    self?.applyMarkupAction?("<u>", "</u>", "underline")
                },
                UIAction(title: "Strikethrough", image: UIImage(systemName: "strikethrough")) { [weak self] _ in
                    self?.applyMarkupAction?("<s>", "</s>", "strike")
                },
                UIAction(title: "Spoiler", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                    self?.applyMarkupAction?("<spoiler>", "</spoiler>", "spoiler")
                },
                UIAction(title: "Monospace", image: UIImage(systemName: "curlybraces")) { [weak self] _ in
                    self?.applyMarkupAction?("<code>", "</code>", "code")
                },
                UIAction(title: "Link", image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.insertLinkAction?()
                }
            ]
        )

        return UIMenu(children: suggestedActions + [formattingMenu])
    }
}

struct ComposerRichTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var measuredHeight: CGFloat
    let textColor: UIColor
    let tintColor: UIColor
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let onApplyMarkup: (String, String, String) -> Void
    let onInsertLink: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: $selectedRange)
    }

    func makeUIView(context: Context) -> ComposerTextViewContainer {
        let textView = ComposerTextViewContainer()
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.smartInsertDeleteType = .yes
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.maximumHeight = maximumHeight
        textView.applyMarkupAction = onApplyMarkup
        textView.insertLinkAction = onInsertLink
        textView.delegate = context.coordinator
        textView.calculatedHeightChanged = { height in
            let nextHeight = max(minimumHeight, height)
            guard abs(measuredHeight - nextHeight) > 0.5 else { return }
            Task { @MainActor in
                guard abs(measuredHeight - nextHeight) > 0.5 else { return }
                measuredHeight = nextHeight
            }
        }
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ uiView: ComposerTextViewContainer, context: Context) {
        uiView.textColor = textColor
        uiView.tintColor = tintColor
        uiView.maximumHeight = maximumHeight
        uiView.applyMarkupAction = onApplyMarkup
        uiView.insertLinkAction = onInsertLink
        if uiView.text != text {
            uiView.text = text
        }
        if NSEqualRanges(uiView.selectedRange, selectedRange) == false, selectedRange.location <= uiView.text.count {
            uiView.selectedRange = selectedRange
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange
        weak var textView: UITextView?

        init(text: Binding<String>, selectedRange: Binding<NSRange>) {
            _text = text
            _selectedRange = selectedRange
        }

        func textViewDidChange(_ textView: UITextView) {
            if text != textView.text {
                text = textView.text
            }
            if NSEqualRanges(selectedRange, textView.selectedRange) == false {
                selectedRange = textView.selectedRange
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if NSEqualRanges(selectedRange, textView.selectedRange) == false {
                selectedRange = textView.selectedRange
            }
        }
    }
}

struct RichLinkPreviewCard: View {
    let url: URL
    let usesLightForeground: Bool

    var body: some View {
        Button {
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "link")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(2)

                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var accentColor: Color {
        usesLightForeground ? .white : PrimeTheme.Colors.accent
    }

    private var primaryTextColor: Color {
        usesLightForeground ? .white : PrimeTheme.Colors.textPrimary
    }

    private var secondaryTextColor: Color {
        usesLightForeground ? Color.white.opacity(0.78) : PrimeTheme.Colors.textSecondary
    }

    private var cardFill: Color {
        usesLightForeground ? Color.white.opacity(0.12) : Color.black.opacity(0.03)
    }

    private var cardStroke: Color {
        usesLightForeground ? Color.white.opacity(0.08) : PrimeTheme.Colors.bubbleIncomingBorder.opacity(0.82)
    }
}
