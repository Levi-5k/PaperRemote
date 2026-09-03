import SwiftUI

struct PaperGIFCropView: View {
    private enum Framing: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case crop = "Crop"

        var id: Self { self }
    }

    private let originalImage: CGImage
    private let initialCropRect: CGRect?
    let onConvert: (CGRect?, Int) -> Void
    let onCancel: () -> Void

    @State private var previewImage: CGImage
    @State private var framing = Framing.crop
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero
    @State private var viewportSize = CGSize.zero
    @State private var rotationQuarterTurns = 0
    @State private var didRestoreCrop = false

    init(
        image: CGImage,
        initialCropRect: CGRect? = nil,
        initialRotationQuarterTurns: Int = 0,
        initialFramingIsCrop: Bool = true,
        onConvert: @escaping (CGRect?, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        originalImage = image
        self.initialCropRect = initialCropRect
        self.onConvert = onConvert
        self.onCancel = onCancel
        let turns = ((initialRotationQuarterTurns % 4) + 4) % 4
        _previewImage = State(initialValue: (try? PaperGIFEncoder.rotatedImage(image, quarterTurns: turns)) ?? image)
        _framing = State(initialValue: initialCropRect != nil || initialFramingIsCrop ? .crop : .fit)
        _rotationQuarterTurns = State(initialValue: turns)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack {
                    Spacer(minLength: 12)

                    cropPreview
                        .aspectRatio(displayAspectRatio, contentMode: .fit)
                        .frame(
                            maxWidth: max(1, proxy.size.width - 32),
                            maxHeight: max(1, proxy.size.height - 24)
                        )

                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomControls
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(.bar)
            }
            .navigationTitle("Frame for Display")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var cropPreview: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let visibleOffset = clampedOffset(offset, viewport: viewport)
            let imageSize = framing == .crop
                ? scaledCropImageSize(viewport: viewport)
                : fittedImageSize(viewport: viewport)

            ZStack {
                Color.white
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .offset(framing == .crop ? visibleOffset : .zero)

                if framing == .crop {
                    cropGrid
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .contentShape(Rectangle())
            .clipped()
            .overlay {
                Rectangle().stroke(.primary, lineWidth: 2)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard framing == .crop else { return }
                        offset = clampedOffset(
                            CGSize(
                                width: dragOrigin.width + value.translation.width,
                                height: dragOrigin.height + value.translation.height
                            ),
                            viewport: viewport
                        )
                    }
                    .onEnded { _ in
                        offset = clampedOffset(offset, viewport: viewport)
                        dragOrigin = offset
                    }
            )
            .onAppear {
                viewportSize = viewport
                restoreCrop(in: viewport)
            }
            .onChange(of: viewport) {
                viewportSize = viewport
                restoreCrop(in: viewport)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            Picker("Framing", selection: $framing) {
                ForEach(Framing.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if framing == .crop {
                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 1...4)
                    Image(systemName: "plus.magnifyingglass")
                }
                .onChange(of: zoom) {
                    offset = clampedOffset(offset, viewport: viewportSize)
                    dragOrigin = offset
                }
            }

            HStack(spacing: 10) {
                Button {
                    rotateClockwise()
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button("Next") {
                    onConvert(
                        framing == .crop ? normalizedCropRect() : nil,
                        rotationQuarterTurns
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var cropGrid: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 3, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 3, y: proxy.size.height))
                path.move(to: CGPoint(x: proxy.size.width * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width * 2 / 3, y: proxy.size.height))
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 3))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 3))
                path.move(to: CGPoint(x: 0, y: proxy.size.height * 2 / 3))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * 2 / 3))
            }
            .stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func clampedOffset(_ proposed: CGSize, viewport: CGSize) -> CGSize {
        let displayed = displayedImageSize(viewport: viewport)
        let maximumX = max(0, (displayed.width * zoom - viewport.width) / 2)
        let maximumY = max(0, (displayed.height * zoom - viewport.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func displayedImageSize(viewport: CGSize) -> CGSize {
        let scale = max(
            viewport.width / CGFloat(previewImage.width),
            viewport.height / CGFloat(previewImage.height)
        )
        return CGSize(
            width: CGFloat(previewImage.width) * scale,
            height: CGFloat(previewImage.height) * scale
        )
    }

    private func scaledCropImageSize(viewport: CGSize) -> CGSize {
        let displayed = displayedImageSize(viewport: viewport)
        return CGSize(width: displayed.width * zoom, height: displayed.height * zoom)
    }

    private func fittedImageSize(viewport: CGSize) -> CGSize {
        let scale = min(
            viewport.width / CGFloat(previewImage.width),
            viewport.height / CGFloat(previewImage.height)
        )
        return CGSize(
            width: CGFloat(previewImage.width) * scale,
            height: CGFloat(previewImage.height) * scale
        )
    }

    private var displayAspectRatio: CGFloat {
        CGFloat(PaperGIFAnimation.width) / CGFloat(PaperGIFAnimation.height)
    }

    private func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        guard let rotatedImage = try? PaperGIFEncoder.rotatedImage(
            originalImage,
            quarterTurns: rotationQuarterTurns
        ) else { return }
        previewImage = rotatedImage
        zoom = 1
        offset = .zero
        dragOrigin = .zero
        didRestoreCrop = true
    }

    private func restoreCrop(in viewport: CGSize) {
        guard !didRestoreCrop, viewport.width > 0, viewport.height > 0 else { return }
        didRestoreCrop = true
        guard let initialCropRect else { return }

        let displayed = displayedImageSize(viewport: viewport)
        let horizontalZoom = viewport.width / (displayed.width * initialCropRect.width)
        let verticalZoom = viewport.height / (displayed.height * initialCropRect.height)
        zoom = min(max((horizontalZoom + verticalZoom) / 2, 1), 4)
        let scaledWidth = displayed.width * zoom
        let scaledHeight = displayed.height * zoom
        offset = clampedOffset(
            CGSize(
                width: (0.5 - initialCropRect.midX) * scaledWidth,
                height: (0.5 - initialCropRect.midY) * scaledHeight
            ),
            viewport: viewport
        )
        dragOrigin = offset
    }

    private func normalizedCropRect() -> CGRect {
        let viewport = viewportSize == .zero
            ? CGSize(width: PaperGIFAnimation.width, height: PaperGIFAnimation.height)
            : viewportSize
        let displayed = displayedImageSize(viewport: viewport)
        let effectiveOffset = clampedOffset(offset, viewport: viewport)
        let scaledWidth = displayed.width * zoom
        let scaledHeight = displayed.height * zoom
        let width = viewport.width / scaledWidth
        let height = viewport.height / scaledHeight
        let centerX = min(max(0.5 - effectiveOffset.width / scaledWidth, width / 2), 1 - width / 2)
        let centerY = min(max(0.5 - effectiveOffset.height / scaledHeight, height / 2), 1 - height / 2)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
}