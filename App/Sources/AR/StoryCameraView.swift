import SwiftUI

/// 扉の中の画面（AR の画面から開いたシート）から、いまの AR のまま AR カメラを開く。
/// 返り値 false のときは、カードを作る画面が自分で AR カメラの画面を開く。
private struct OpenARCardCameraKey: EnvironmentKey {
    static let defaultValue: ((UUID) -> Bool)? = nil
}

extension EnvironmentValues {
    var openARCardCamera: ((UUID) -> Bool)? {
        get { self[OpenARCardCameraKey.self] }
        set { self[OpenARCardCameraKey.self] = newValue }
    }
}

/// AR カメラの道具（カメラの景色の上に重ねる）。AR を使わない部品だけでできているので、画面の見本でも出せる。
struct StoryCameraControls: View {
    @ObservedObject var story: StoryCamera
    /// GATE の名前（上に小さく）
    let gateTitle: String
    /// みんなの AR の飾りの数
    let artworkCount: Int
    /// 「AR を残す」（GATE に残る AR の飾りを置く）を出すか
    let canLeaveArt: Bool
    /// ちょっとした知らせ
    let toast: String?
    let onClose: () -> Void
    let onLeaveArt: () -> Void
    let onUse: (UIImage) -> Void

    @State private var editing: EditingPhoto?
    /// 整え終えた写真（整える画面が閉じてから渡す＝画面を閉じるのが重ならないように）
    @State private var edited: UIImage?
    @State private var showHint = true

    var body: some View {
        ZStack {
            if let shot = story.shot {
                review(shot)
                    .transition(.opacity)
            } else {
                camera
            }
            if let draft = story.textDraft {
                StoryTextComposer(story: story, draft: draft)
                    .transition(.opacity)
            }
            if let count = story.countdown {
                Text("\(count)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .allowsHitTesting(false)
            }
            Color.white.opacity(story.flash ? 0.85 : 0).ignoresSafeArea().allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: story.shot != nil)
        .animation(.easeInOut(duration: 0.2), value: story.textDraft != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: story.countdown)
        .fullScreenCover(item: $editing, onDismiss: {
            if let edited {
                self.edited = nil
                onUse(edited)
            }
        }) { item in
            CardPhotoEditor(original: item.image) { result in
                edited = result
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation(.easeOut(duration: 0.4)) { showHint = false }
        }
    }

    private struct EditingPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    // MARK: 撮る

    private var camera: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                roundButton("xmark", label: "閉じる", action: onClose)
                VStack(alignment: .leading, spacing: 6) {
                    Label(gateTitle.isEmpty ? "AR カメラ" : gateTitle, systemImage: "door.left.hand.open")
                        .font(.footnote.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(.black.opacity(0.35), in: Capsule())
                    if artworkCount > 0 {
                        Label("みんなの AR \(artworkCount)", systemImage: "person.2.wave.2.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(.black.opacity(0.3), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                rail
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 10)
                    .transition(.opacity)
            } else if showHint {
                Text(artworkCount > 0 ? "扉や、みんなの AR と一緒に撮れます。AR の飾りは押すと動きます。"
                                      : "扉と一緒に撮れます。効果と文字を足してみましょう。")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 10)
                    .padding(.horizontal, 30)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            if story.selected != nil {
                selectedTools
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            effects
            shutterRow
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: story.selected)
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    /// 右の道具（文字・扉・タイマー・AR を残す）
    private var rail: some View {
        VStack(spacing: 12) {
            railButton("textformat", label: "文字", disabled: story.stickers.count >= StoryCamera.maxStickers) {
                story.startText()
            }
            railButton(story.doorHidden ? "door.left.hand.closed" : "door.left.hand.open",
                       label: story.doorHidden ? "扉を出す" : "扉を隠す", active: story.doorHidden) {
                story.toggleDoor()
            }
            railButton("timer", label: story.timerSeconds == 0 ? "タイマー" : "\(story.timerSeconds) 秒",
                       active: story.timerSeconds > 0) {
                story.cycleTimer()
            }
            if canLeaveArt {
                railButton("sparkles.rectangle.stack", label: "AR を残す") {
                    onLeaveArt()
                }
            }
        }
    }

    private func railButton(_ symbol: String, label: String, active: Bool = false, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(active ? Color(hex: 0x1B1235) : .white)
                    .frame(width: 44, height: 44)
                    .background(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.35)), in: Circle())
                    .rotationEffect(.degrees(story.iconTurn))
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
                .rotationEffect(.degrees(story.iconTurn))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 選んだ文字の道具
    private var selectedTools: some View {
        HStack(spacing: 10) {
            Button {
                if let id = story.selected { story.startText(editing: id) }
            } label: {
                Label("書き直す", systemImage: "pencil")
            }
            Button(role: .destructive) {
                story.removeSelected()
            } label: {
                Label("消す", systemImage: "trash")
            }
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(alignment: .top) {
            Text("指でなぞると動く・2 本の指で大きさと傾き")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 2)
                .fixedSize()
                .offset(y: -20)
        }
    }

    /// 効果を選ぶ丸（横にめくる）
    private var effects: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(StoryEffect.allCases) { item in
                    Button {
                        story.setEffect(item)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: item.chipColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: item.symbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(story.iconTurn))
                            }
                            .frame(width: 54, height: 54)
                            .overlay(Circle().strokeBorder(story.effect == item ? Color.white : Color.white.opacity(0.25),
                                                           lineWidth: story.effect == item ? 3 : 1))
                            .scaleEffect(story.effect == item ? 1.08 : 1)
                            Text(item.label)
                                .font(.system(size: 10, weight: story.effect == item ? .heavy : .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 2)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("効果：\(item.label)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: story.effect)
    }

    private var shutterRow: some View {
        HStack {
            Spacer()
            Button {
                if story.countdown != nil { story.cancelCountdown() } else { story.shutter() }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [Color(hex: 0xFF9A3D), Color(hex: 0xFF3D7F), Color(hex: 0x9B5CFF),
                                                               Color(hex: 0x3DC8FF), Color(hex: 0xFF9A3D)],
                                                      center: .center), lineWidth: 5)
                        .frame(width: 82, height: 82)
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                    if story.countdown != nil {
                        Image(systemName: "stop.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Color(hex: 0x1B1235))
                    } else if story.capturing {
                        ProgressView().tint(Color(hex: 0x1B1235))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(story.countdown != nil ? "タイマーを止める" : "撮る")
            Spacer()
        }
    }

    // MARK: 撮ったあと

    private func review(_ shot: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: shot)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 130)
                .padding(.top, 60)
            VStack(spacing: 12) {
                HStack {
                    Text("この写真でカードを作りますか？")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        story.shot = nil
                    } label: {
                        Label("撮り直す", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StoryGhostButton())
                    Button {
                        editing = EditingPhoto(image: shot)
                    } label: {
                        Label("整える", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StoryGhostButton())
                }
                .padding(.horizontal, 16)
                Button {
                    onUse(shot)
                } label: {
                    Text("この写真でカードを作る")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct StoryGhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(minHeight: 48)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// AR の文字を書く（画面のまん中に大きく。色と見た目を選ぶ）
private struct StoryTextComposer: View {
    @ObservedObject var story: StoryCamera
    let draft: StoryTextDraft
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { story.textDraft?.text ?? "" },
                set: { story.textDraft?.text = String($0.prefix(40)) })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { story.commitText() }
            VStack(spacing: 18) {
                HStack {
                    Button("やめる") { story.textDraft = nil }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("置く") { story.commitText() }
                        .font(.body.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(Theme.neonBand, in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                Spacer()
                TextField("", text: text, prompt: Text("ここに文字").foregroundStyle(.white.opacity(0.45)), axis: .vertical)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(preview)
                    .shadow(color: (story.textDraft?.style ?? .neon) == .neon ? (story.textDraft?.ink.color ?? .white).opacity(0.9) : .clear,
                            radius: 10)
                    .padding(.horizontal, (story.textDraft?.style ?? .neon) == .label ? 16 : 0)
                    .padding(.vertical, (story.textDraft?.style ?? .neon) == .label ? 8 : 0)
                    .background {
                        if (story.textDraft?.style ?? .neon) == .label {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                        }
                    }
                    .lineLimit(1...3)
                    .focused($focused)
                    .padding(.horizontal, 30)
                Text("\(story.textDraft?.text.count ?? 0) / 40・写真だけに入る文字です（GATE には残りません）")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Picker("見た目", selection: Binding(get: { story.textDraft?.style ?? .neon },
                                                  set: { story.textDraft?.style = $0 })) {
                    ForEach(StoryTextStyle.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    ForEach(StoryInk.allCases) { ink in
                        Button {
                            story.textDraft?.ink = ink
                        } label: {
                            Circle()
                                .fill(ink.color)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.white, lineWidth: story.textDraft?.ink == ink ? 3 : 1))
                                .scaleEffect(story.textDraft?.ink == ink ? 1.15 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("色")
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { focused = true }
    }

    private var preview: Color {
        guard let d = story.textDraft else { return .white }
        if d.style == .label && d.ink == .white { return Color(hex: 0x291A52) }
        return d.ink.color
    }
}
