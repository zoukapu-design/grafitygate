import SwiftUI
import UIKit

/// 便せんの文字（2026-11-20 オーナー「手紙の線を、ちゃんと文字の下に」）：
/// 1 行の高さを決まった値（`lineHeight`）にそろえ、罫線は 1 行ごとに文字のすぐ下に引く。書く・読むの両方で使う。
/// SwiftUI の TextEditor は行の高さが字の種類で変わり、線と文字がずれていたので、UITextView で行の高さを固定する。
struct RuledTextArea: UIViewRepresentable {
    @Binding var text: String
    var editable = true
    var placeholder = ""
    /// 文字が少なくても、この行数ぶんは罫線を引く
    var minLines = 6
    var maxLength = 2000
    /// 書いているあいだ true（キーボードと重なるボタンを隠すため）
    var editing: Binding<Bool>? = nil

    static let lineHeight: CGFloat = 34
    static let insetTop: CGFloat = 4
    static let font: UIFont = {
        let base = UIFont.systemFont(ofSize: 17)
        let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return UIFont(descriptor: desc, size: 17)
    }()
    static let ink = UIColor(red: 0x2B / 255, green: 0x24 / 255, blue: 0x40 / 255, alpha: 1)

    static var attributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: ink, .paragraphStyle: p]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView(usingTextLayoutManager: false)
        v.backgroundColor = .clear
        v.isEditable = editable
        v.isSelectable = true
        v.isScrollEnabled = false
        v.textContainerInset = UIEdgeInsets(top: Self.insetTop, left: 0, bottom: 0, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.typingAttributes = Self.attributes
        v.attributedText = NSAttributedString(string: text, attributes: Self.attributes)
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.tintColor = UIColor(red: 0x5B / 255, green: 0x3F / 255, blue: 0xE0 / 255, alpha: 1)
        // うすい案内（1 行目の文字と同じ高さに置く）
        let label = UILabel()
        label.text = placeholder
        label.font = Self.font
        label.textColor = Self.ink.withAlphaComponent(0.35)
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.tag = 7001
        label.isHidden = !text.isEmpty || placeholder.isEmpty
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        let top = Self.insetTop + Self.lineHeight + Self.font.descender - Self.font.ascender
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            label.widthAnchor.constraint(equalTo: v.widthAnchor),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: top),
        ])
        if editable {
            // キーボードの上に「書けた」
            let bar = UIToolbar()
            bar.sizeToFit()
            let done = UIBarButtonItem(title: "書けた", style: .done, target: v,
                                       action: #selector(UIResponder.resignFirstResponder))
            bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
            v.inputAccessoryView = bar
        }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            v.attributedText = NSAttributedString(string: text, attributes: Self.attributes)
        }
        v.isEditable = editable
        (v.viewWithTag(7001) as? UILabel)?.isHidden = !text.isEmpty || placeholder.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 60
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lines = max(CGFloat(minLines), ((fit.height - Self.insetTop) / Self.lineHeight).rounded(.up))
        return CGSize(width: width, height: Self.insetTop + lines * Self.lineHeight + 2)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RuledTextArea
        init(_ parent: RuledTextArea) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            var value = textView.text ?? ""
            if value.count > parent.maxLength {
                value = String(value.prefix(parent.maxLength))
                textView.attributedText = NSAttributedString(string: value, attributes: RuledTextArea.attributes)
            }
            parent.text = value
            (textView.viewWithTag(7001) as? UILabel)?.isHidden = !value.isEmpty
            // 行が増えたら高さを測り直す
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editing?.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editing?.wrappedValue = false
        }
    }
}

/// 罫線（`RuledTextArea` と同じ間隔で、1 行ごとに文字のすぐ下）
struct RuledTextLines: View {
    var body: some View {
        Canvas { ctx, size in
            var y = RuledTextArea.insetTop + RuledTextArea.lineHeight - 0.5
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(LetterPalette.rule), lineWidth: 1)
                y += RuledTextArea.lineHeight
            }
        }
        .allowsHitTesting(false)
    }
}
