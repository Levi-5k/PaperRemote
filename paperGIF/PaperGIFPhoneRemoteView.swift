import Combine
import simd
import SwiftUI

/// Remote pages shown in the native tab bar's bottom accessory. With the tab bar minimized the
/// accessory sits inline beside it and lists every page; once the tab bar expands it collapses
/// to the current page with previous/next buttons.
struct PaperGIFRemotePageAccessory: View {
    let pages: [PaperGIFRemotePage]
    @Binding var selectedPageID: UUID?
    var showPages: () -> Void = {}
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if placement == .inline, pages.count <= 5 {
            Picker("Page", selection: $selectedPageID) {
                ForEach(pages) { page in
                    Text(page.name).tag(Optional(page.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 6)
        } else if placement == .inline {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(pages) { page in
                            Button(page.name) { selectedPageID = page.id }
                                .font(.subheadline.weight(page.id == currentID ? .semibold : .regular))
                                .foregroundStyle(page.id == currentID ? .primary : .secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(page.id == currentID ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
                                .id(page.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: currentID, initial: true) { _, id in
                    withAnimation { reader.scrollTo(id, anchor: .center) }
                }
            }
        } else {
            HStack {
                Button("Previous Page", systemImage: "chevron.left") { step(-1) }
                    .disabled(index == 0)
                Spacer(minLength: 8)
                Button(action: showPages) {
                    Text(pages.first { $0.id == currentID }?.name ?? "Remote")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .accessibilityHint("Shows all remote pages")
                Spacer(minLength: 8)
                Button("Next Page", systemImage: "chevron.right") { step(1) }
                    .disabled(index == nil || index == pages.count - 1)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 16)
        }
    }

    private var currentID: UUID? { selectedPageID ?? pages.first?.id }
    private var index: Int? { pages.firstIndex { $0.id == currentID } }

    private func step(_ delta: Int) {
        guard let index, pages.indices.contains(index + delta) else { return }
        selectedPageID = pages[index + delta].id
    }
}

/// Full-screen touch remote for the saved profile. Session state stays on the phone:
/// taps do not sync the profile or drive a connected board.
struct PaperGIFPhoneRemoteView: View {
    let profile: PaperGIFRemoteProfile
    var isVisible = true
    /// When set, the pages are picked from the app tab bar's accessory instead of the strip at the top.
    var selectedPageID: Binding<UUID?>?
    /// Each increment minimizes the app tab bar so the page tabs show.
    var minimizeTabBarRequests = 0

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PaperGIFPhoneRemoteBackground.storageKey) private var backgroundRaw = PaperGIFPhoneRemoteBackground.off.rawValue
    @AppStorage(PaperGIFPhoneRemoteChrome.opacityKey) private var elementOpacity = PaperGIFPhoneRemoteChrome.defaultOpacity
    @State private var session = PaperGIFPhoneRemoteSession()
    @State private var touchOutline = PaperGIFPhoneTouchOutline()
    @State private var heldOutlines: [UUID: [SIMD2<Float>]] = [:]
    @State private var pageStripHeight: CGFloat = 0
    @State private var measuredButtons: [UUID: CGRect] = [:]
    @State private var lastHeldOutlineAt = Date.distantPast
    @State private var scheduler = PaperGIFPhoneRequestScheduler()
    @State private var status = "Ready"
    @State private var busy: Set<UUID> = []
    @State private var heldJogs: Set<UUID> = []
    @State private var now = Date()
    @State private var statusGeneration = 0
    @State private var tabBarScrollPosition = ScrollPosition(y: 20_000)
    @State private var tabBarScrollOffset: CGFloat = 20_000

    private static let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let edgeClearance: CGFloat = 28

    var body: some View {
        NavigationStack {
            GeometryReader { screen in
                ZStack {
                    PaperGIFPhoneRemoteBackgroundView(
                        background: background,
                        isAnimating: effectsLive,
                        outline: touchOutline
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    if usesRemoteTabBar {
                        tabBarScrollSurface
                    }
                    VStack(spacing: 0) {
                        if profile.pages.isEmpty {
                            ContentUnavailableView(
                                "No Remote Pages", systemImage: "av.remote",
                                description: Text("Add a page in the Edit tab.")
                            )
                        } else {
                            if !usesRemoteTabBar {
                                pageStrip
                                    .onGeometryChange(for: CGFloat.self) { proxy in
                                        proxy.size.height
                                    } action: { height in
                                        if pageStripHeight != height { pageStripHeight = height }
                                    }
                            }
                            pageCanvas(
                                shaderSize: screen.size,
                                origin: CGPoint(
                                    x: screen.safeAreaInsets.leading,
                                    y: screen.safeAreaInsets.top + Self.edgeClearance + (usesRemoteTabBar ? 0 : pageStripHeight)
                                )
                            )
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("phone-remote-status")
                                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        }
                    }
                    .padding(.top, screen.safeAreaInsets.top + Self.edgeClearance)
                    .padding(.bottom, screen.safeAreaInsets.bottom + Self.edgeClearance)
                    .padding(.leading, screen.safeAreaInsets.leading)
                    .padding(.trailing, screen.safeAreaInsets.trailing)
                }
                .coordinateSpace(name: PaperGIFPhoneShaderSpace.name)
                .simultaneousGesture(pageSwipe, including: usesRemoteTabBar ? .all : .none)
            }
            .ignoresSafeArea()
            .navigationTitle(page?.name ?? "Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(usesRemoteTabBar ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .ignoresSafeArea()
        .onAppear { selectInitialPage() }
        .onChange(of: selectedPageID?.wrappedValue) { _, id in
            if let id, id != session.selectedPageID { selectPage(id) }
        }
        .onChange(of: profile.pages.map(\.id)) { _, ids in
            if session.selectedPageID == nil || !ids.contains(session.selectedPageID ?? UUID()) {
                session.selectedPageID = ids.first
                selectedPageID?.wrappedValue = ids.first
            }
        }
        .task(id: isVisible && scenePhase == .active) {
            guard isVisible, scenePhase == .active else { return }
            while !Task.isCancelled {
                let date = Date()
                flushScheduler(at: date, force: false)
                refreshHeldOutlines(at: date)
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    break
                }
            }
        }
        .onReceive(Self.clock) { date in
            guard isVisible, scenePhase == .active else { return }
            now = date
        }
        .task(id: "\(page?.id.uuidString ?? "")|\(isVisible)|\(scenePhase == .active)") {
            guard isVisible, scenePhase == .active else { return }
            await pollComputers()
        }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            releaseHeldJogs()
            flushScheduler(at: Date(), force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            releaseHeldJogs()
            flushScheduler(at: Date(), force: true)
        }
        .onDisappear {
            releaseHeldJogs()
            flushScheduler(at: Date(), force: true)
        }
    }

    private var page: PaperGIFRemotePage? {
        if let selected = session.selectedPageID,
           let match = profile.pages.first(where: { $0.id == selected }) {
            return match
        }
        return profile.pages.first
    }

    private var usesRemoteTabBar: Bool {
        selectedPageID != nil && !profile.pages.isEmpty
    }

    /// The remote never scrolls, so this invisible scroll surface behind the controls gives the
    /// native tab bar something to follow: swipe down to minimize it, up to bring it back.
    private var tabBarScrollSurface: some View {
        ScrollView(.vertical) {
            Color.clear.frame(height: 40_000)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($tabBarScrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            tabBarScrollOffset = y
        }
        .onChange(of: minimizeTabBarRequests) { minimizeTabBar() }
        .onAppear {
            tabBarScrollPosition.scrollTo(y: 20_000)
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                minimizeTabBar()
            }
        }
    }

    /// The tab bar only minimizes in response to scrolling, so fake a short downward scroll.
    private func minimizeTabBar() {
        withAnimation(.easeOut(duration: 0.3)) {
            tabBarScrollPosition.scrollTo(y: tabBarScrollOffset + 200)
        }
    }

    @ViewBuilder private var pageStrip: some View {
        if profile.pages.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(profile.pages) { candidate in
                        let selected = candidate.id == page?.id
                        Button {
                            selectPage(candidate.id)
                        } label: {
                            Text(candidate.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Color.white.opacity(elementOpacity) : Color.white.opacity(elementOpacity * 0.28),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func pageCanvas(shaderSize: CGSize, origin: CGPoint) -> some View {
        GeometryReader { proxy in
            let current = page
            let columns = max(1, current?.gridColumns ?? 1)
            let rows = max(1, current?.gridRows ?? 1)
            let controls = current?.controls ?? []
            let placements = PaperGIFRemoteGrid.placements(
                for: controls, columns: columns, rows: rows,
                reserved: current.map(PaperGIFRemoteGrid.reservedCells(for:)) ?? []
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(!usesRemoteTabBar)
                    .gesture(pageSwipe)
                ForEach(Array(controls.enumerated()), id: \.element.id) { index, control in
                    if let placement = placements[index], let current {
                        let local = PaperGIFAdaptiveGridGeometry.frame(
                            placement, in: proxy.size, columns: columns, rows: rows
                        )
                        let button = PaperGIFPhoneShaderSpace.resolvedButtonFrame(
                            measured: measuredButtons[control.id],
                            tile: local,
                            origin: origin,
                            shader: shaderSize
                        )
                        PaperGIFPhoneControlTile(
                            control: control,
                            profile: profile,
                            page: current,
                            session: session,
                            now: now,
                            busy: busy.contains(control.id)
                        ) { phase in
                            noteOutline(
                                phase, control: control, page: current,
                                frame: button,
                                canvas: shaderSize
                            )
                            perform(phase, control: control, page: current)
                        }
                        .frame(width: local.width, height: local.height)
                        .offset(x: local.minX, y: local.minY)
                        .onGeometryChange(for: CGRect.self) { tileProxy in
                            tileProxy.frame(in: .named(PaperGIFPhoneShaderSpace.name))
                        } action: { frame in
                            if measuredButtons[control.id] != frame {
                                measuredButtons[control.id] = frame
                            }
                        }
                    }
                }
            }
        }
    }

    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 48).onEnded { drag in
            guard abs(drag.translation.width) > 64, abs(drag.translation.height) < 48 else { return }
            changePage(by: drag.translation.width < 0 ? 1 : -1)
        }
    }

    private func selectInitialPage() {
        if session.selectedPageID == nil {
            session.selectedPageID = selectedPageID?.wrappedValue ?? profile.pages.first?.id
        }
        selectedPageID?.wrappedValue = page?.id
    }

    private func selectPage(_ id: UUID) {
        selectedPageID?.wrappedValue = id
        guard session.selectedPageID != id else { return }
        releaseHeldJogs()
        flushScheduler(at: Date(), force: true)
        session.selectedPageID = id
        status = PaperGIFPhoneActionMessage.pageChanged
    }

    private func changePage(by delta: Int) {
        guard let current = page,
              let index = profile.pages.firstIndex(where: { $0.id == current.id }) else { return }
        let next = index + delta
        guard profile.pages.indices.contains(next) else { return }
        selectPage(profile.pages[next].id)
    }

    private func perform(
        _ phase: PaperGIFPhoneActionPhase,
        control: PaperGIFRemoteControl,
        page: PaperGIFRemotePage
    ) {
        if case .press = phase, PaperGIFPhoneActionRunner.isContinuousJog(control.action, on: page) {
            guard heldJogs.insert(control.id).inserted else { return }
        } else if case .press = phase, busy.contains(control.id) {
            return
        }
        if case .release = phase, heldJogs.remove(control.id) == nil {
            return
        }
        // Move the fill with the finger; the device's reply doesn't feed back into this session.
        if case .slide(let value, _) = phase, control.action.type != .netHomeTemperature {
            let range = PaperGIFPhoneActionRunner.sliderRange(for: control.action, unit: profile.temperatureUnit)
            session.values[control.id] = min(max(value, range.lowerBound), range.upperBound)
            if control.action.text == "seek", let timeline = session.timelines[control.id] {
                var moved = timeline
                moved.elapsedMilliseconds = timeline.durationMilliseconds * session.values[control.id, default: 0] / 255
                moved.sampledAt = Date()
                session.timelines[control.id] = moved
            }
        }
        if case .release = phase {} else { session.lastInputAt[control.id] = Date() }
        let outcome = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: control, phase: phase, session: session, now: now
        )
        apply(outcome)
    }

    private func apply(_ outcome: PaperGIFPhoneActionOutcome) {
        if let setpoint = outcome.setpoint {
            session.values[setpoint.controlID] = setpoint.value
            session.valueTenths[setpoint.controlID] = setpoint.valueTenths
        }
        switch outcome.effect {
        case .none:
            break
        case .navigate(let id):
            selectPage(id)
        case .request(let request):
            if request.blocksControl && busy.contains(request.controlID) { return }
            guard let ready = scheduler.submit(request, at: Date().timeIntervalSinceReferenceDate) else { return }
            transmit(ready)
        case .unsupported(let message), .rejected(let message):
            status = message
        }
    }

    private func transmit(_ request: PaperGIFPhoneNetworkRequest) {
        if request.blocksControl {
            busy.insert(request.controlID)
            status = PaperGIFPhoneActionMessage.sending
        }
        statusGeneration += 1
        let generation = statusGeneration
        Task {
            let accepted = await PaperGIFPhoneRequestSender.send(request)
            await MainActor.run {
                busy.remove(request.controlID)
                if request.recordsToggle && accepted {
                    session.toggleOn[request.controlID] = request.toggleOnAfterSuccess
                }
                guard generation == statusGeneration else { return }
                if !accepted {
                    status = PaperGIFPhoneActionMessage.failed
                } else if !request.isSlider {
                    status = PaperGIFPhoneActionMessage.sent
                }
            }
        }
    }

    private var background: PaperGIFPhoneRemoteBackground {
        PaperGIFPhoneRemoteBackground(rawValue: backgroundRaw) ?? .off
    }

    private var effectsLive: Bool {
        isVisible && scenePhase == .active
    }

    private func noteOutline(
        _ phase: PaperGIFPhoneActionPhase,
        control: PaperGIFRemoteControl,
        page: PaperGIFRemotePage,
        frame: CGRect,
        canvas: CGSize
    ) {
        guard canvas.width > 1, canvas.height > 1 else { return }
        guard PaperGIFPhoneShaderSpace.isButton(frame, on: canvas) else { return }
        guard effectsLive, background.acceptsTouchOutline else { return }
        switch phase {
        case .slide:
            return
        case .release:
            heldOutlines[control.id] = nil
        case .press:
            let loop = PaperGIFPhoneTouchOutlineSampler.loop(frame: frame, canvas: canvas)
            guard !loop.isEmpty else { return }
            if PaperGIFPhoneActionRunner.isContinuousJog(control.action, on: page) {
                let first = heldOutlines[control.id] == nil
                heldOutlines[control.id] = loop
                guard first else { return }
                publish(loops: [loop])
                lastHeldOutlineAt = Date()
            } else {
                publish(loops: [loop])
            }
        }
    }

    private func publish(loops: [[SIMD2<Float>]]) {
        guard !loops.isEmpty else { return }
        touchOutline.generation &+= 1
        touchOutline.loops = loops
    }

    private func refreshHeldOutlines(at date: Date) {
        guard effectsLive, background.acceptsTouchOutline, !heldOutlines.isEmpty else { return }
        guard date.timeIntervalSince(lastHeldOutlineAt) >= 0.5 else { return }
        lastHeldOutlineAt = date
        publish(loops: Array(heldOutlines.values))
    }

    /// The phone gets no pushes, so it asks the page's computers for media, volume, play and text state.
    private func pollComputers() async {
        var round = 0
        while !Task.isCancelled, let current = page {
            // Text boxes can run scripts on the computer, so they refresh less often than media state.
            let batches = PaperGIFPhoneStateFetcher.batches(for: current, profile: profile).map { batch in
                round % 5 == 0 ? batch : PaperGIFPhoneStateFetcher.Batch(
                    destination: batch.destination,
                    items: batch.items.filter { item in
                        current.controls.first { $0.id.uuidString == item.id }?.kind != .textBox
                    }
                )
            }.filter { !$0.items.isEmpty }
            await withTaskGroup(of: [PaperGIFPhoneStateFetcher.Reply]?.self) { group in
                for batch in batches {
                    group.addTask { await PaperGIFPhoneStateFetcher.fetch(batch) }
                }
                for await replies in group {
                    guard let replies else { continue }
                    PaperGIFPhoneStateFetcher.apply(replies, on: current, to: &session, now: Date())
                }
            }
            round += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func flushScheduler(at date: Date, force: Bool) {
        let now = date.timeIntervalSinceReferenceDate
        let due = force ? scheduler.flushAll(at: now) : scheduler.flush(at: now)
        for request in due {
            transmit(request)
        }
    }

    private func releaseHeldJogs() {
        heldOutlines.removeAll()
        touchOutline = PaperGIFPhoneTouchOutline()
        let ids = heldJogs
        heldJogs.removeAll()
        for id in ids {
            guard let located = locate(id) else { continue }
            let outcome = PaperGIFPhoneActionRunner.prepare(
                profile: profile, page: located.page, control: located.control,
                phase: .release, session: session, now: now
            )
            apply(outcome)
        }
    }

    private func locate(_ id: UUID) -> (page: PaperGIFRemotePage, control: PaperGIFRemoteControl)? {
        for page in profile.pages {
            if let control = page.controls.first(where: { $0.id == id }) {
                return (page, control)
            }
        }
        return nil
    }
}

private struct PaperGIFPhoneControlTile: View {
    let control: PaperGIFRemoteControl
    let profile: PaperGIFRemoteProfile
    let page: PaperGIFRemotePage
    let session: PaperGIFPhoneRemoteSession
    let now: Date
    let busy: Bool

    @AppStorage(PaperGIFPhoneRemoteChrome.opacityKey) private var elementOpacity = PaperGIFPhoneRemoteChrome.defaultOpacity
    @Environment(\.displayScale) private var displayScale
    let perform: (PaperGIFPhoneActionPhase) -> Void

    var body: some View {
        Group {
            if control.kind == .slider {
                slider
            } else if control.kind == .textBox {
                textTile
            } else if PaperGIFPhoneActionRunner.isContinuousJog(control.action, on: page) {
                holdButton
            } else {
                tapButton
            }
        }
        .opacity(busy ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(session.isOn(control) && control.isToggle == true ? .isSelected : [])
    }

    private var tapButton: some View {
        Button {
            perform(.press)
        } label: {
            face
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var holdButton: some View {
        face
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in perform(.press) }
                    .onEnded { _ in perform(.release) }
            )
    }

    private var textTile: some View {
        Button {
            perform(.press)
        } label: {
            Text(PaperGIFPhoneTextRenderer.text(
                for: control, profile: profile, session: session, now: now
            ))
            .font(textFont)
            .minimumScaleFactor(control.textBox?.textSize == .autoFit ? 0.4 : 0.7)
            .multilineTextAlignment(horizontalAlignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .padding(8)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(elementOpacity))
            }
        }
        .buttonStyle(.plain)
        .disabled(busy || control.textBox?.tapBehavior == .displayOnly)
    }

    // Matches the device slider tiles (firmware/include/waveshare_page_view.h): a light fill on a dark
    // tile, with the title and value redrawn dark wherever the fill passes under them.
    private var slider: some View {
        GeometryReader { geo in
            let range = PaperGIFPhoneActionRunner.sliderRange(
                for: control.action, unit: profile.temperatureUnit
            )
            let size = geo.size
            let outline = control.sliderOutlineInsetPixels.map {
                CGFloat(min($0, 32, max(0, Int(min(size.width, size.height)) / 2 - 2)))
            } ?? 0
            let fillWidth = max(0, size.width - 2) * fraction(range: range)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Self.tileColor.opacity(elementOpacity))
                RoundedRectangle(cornerRadius: 5)
                    .fill(Self.fillColor.opacity(elementOpacity))
                    .frame(width: fillWidth, height: max(0, size.height - 2))
                    .offset(x: 1, y: 1)
                if outline > 0 {
                    RoundedRectangle(cornerRadius: max(2, 5 - outline / 2))
                        .fill(Self.tileColor.opacity(elementOpacity))
                        .padding(outline)
                }
                RoundedRectangle(cornerRadius: 6).strokeBorder(Self.borderColor, lineWidth: 1)
                sliderLabels(in: size, range: range)
                    .foregroundStyle(Self.textColor)
                if outline == 0, fillWidth > 0 {
                    sliderLabels(in: size, range: range)
                        .foregroundStyle(Self.tileColor)
                        .mask(alignment: .topLeading) {
                            Rectangle().frame(width: 1 + fillWidth, height: size.height)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        perform(.slide(sliderValue(at: drag.location, in: size, range: range), final: false))
                    }
                    .onEnded { drag in
                        perform(.slide(sliderValue(at: drag.location, in: size, range: range), final: true))
                    }
            )
        }
    }

    /// Title (and value, except on seek bars) centered in the tile, sized to the tile and shrunk to fit.
    private func sliderLabels(in size: CGSize, range: ClosedRange<Int>) -> some View {
        let seek = control.action.text == "seek"
        let timeline = seek ? session.timelines[control.id] : nil
        let fontSize = min(CGFloat(profile.maxButtonTextSize), max(9, (size.height - 12) * 0.6))
        return HStack(spacing: fontSize * 0.5) {
            Text(seek ? session.texts[control.id] ?? control.title : control.title)
                .lineLimit(size.height >= fontSize * 2.6 ? 2 : 1)
                .multilineTextAlignment(.center)
            if let timeline {
                Text(timeline.label(at: now))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            } else if !seek {
                Text(sliderLabel(range: range))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .minimumScaleFactor(0.25)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private static let tileColor = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255)
    private static let fillColor = Color(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xE8 / 255)
    private static let borderColor = Color(red: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255)
    private static let textColor = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)

    private var face: some View {
        VStack(spacing: 4) {
            RemoteIconGlyphView(name: displayedSymbol)
                .frame(width: 22, height: 22)
            Text(displayedTitle)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
        .background { buttonBackground }
    }

    private var buttonStyle: PaperGIFRemoteButtonBackground {
        profile.buttonBackground(for: control)
    }

    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let scale = max(displayScale, 1)
        return GeometryReader { geo in
            PaperGIFButtonBackgroundPreview(
                background: buttonStyle,
                texture: profile.buttonTexture(for: control),
                pixelWidth: max(1, Int((geo.size.width * scale).rounded())),
                pixelHeight: max(1, Int((geo.size.height * scale).rounded())),
                scale: 1 / scale,
                backgroundHex: control.backgroundTintHex,
                foregroundHex: control.tintHex == "202020" ? nil : control.tintHex,
                imageTintHex: control.imageTintHex,
                smooth: true
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(elementOpacity)
            .clipShape(shape)
        }
        .overlay {
            if session.isOn(control) && control.isToggle == true {
                shape.strokeBorder(foreground, lineWidth: 2)
            }
        }
    }

    private var foreground: Color {
        PaperGIFButtonColors.textColor(tintHex: control.tintHex, style: buttonStyle)
    }

    private var accessibilityLabel: String {
        if control.kind == .textBox {
            return PaperGIFPhoneTextRenderer.text(for: control, profile: profile, session: session, now: now)
        }
        return control.title
    }

    private var textFont: Font {
        switch control.textBox?.textSize {
        case .small: .caption2
        case .medium: .caption
        case .large: .body
        case .extraLarge: .title3
        case .autoFit, .none: .body
        }
    }

    private var horizontalAlignment: TextAlignment {
        switch control.textBox?.horizontalAlignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    private var frameAlignment: Alignment {
        let horizontal: HorizontalAlignment
        switch control.textBox?.horizontalAlignment {
        case .center: horizontal = .center
        case .trailing: horizontal = .trailing
        default: horizontal = .leading
        }
        switch control.textBox?.verticalAlignment {
        case .center: return Alignment(horizontal: horizontal, vertical: .center)
        case .bottom: return Alignment(horizontal: horizontal, vertical: .bottom)
        default: return Alignment(horizontal: horizontal, vertical: .top)
        }
    }

    /// Computer play/pause buttons show Play or Pause once the computer reports its state, like the device.
    private var reportedPlaying: Bool? {
        control.action.type == .computerMedia && control.action.text == "playPause"
            ? session.toggleOn[control.id] : nil
    }

    private var displayedTitle: String {
        reportedPlaying.map { $0 ? "Pause" : "Play" } ?? control.title
    }

    private var displayedSymbol: String {
        reportedPlaying.map { $0 ? "pause.fill" : "play.fill" }
            ?? (control.symbol.isEmpty ? "square" : control.symbol)
    }

    private func fraction(range: ClosedRange<Int>) -> Double {
        let touched = session.lastInputAt[control.id].map {
            now.timeIntervalSince($0) < PaperGIFPhoneStateFetcher.inputHold
        } ?? false
        if control.action.text == "seek", !touched, let timeline = session.timelines[control.id] {
            return min(1, max(0, timeline.fraction(at: now)))
        }
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        let value = displayedSliderValue(range: range)
        return min(1, max(0, Double(value - range.lowerBound) / span))
    }

    private func displayedSliderValue(range: ClosedRange<Int>) -> Int {
        if control.action.type == .netHomeTemperature {
            return profile.temperatureUnit.displayValue(celsiusTenths: session.tenths(for: control))
        }
        return min(range.upperBound, max(range.lowerBound, session.value(for: control)))
    }

    // Same text as the device: one decimal for setpoints, otherwise a percentage of the slider's range.
    private func sliderLabel(range: ClosedRange<Int>) -> String {
        if control.action.type == .netHomeTemperature {
            let tenths = Double(session.tenths(for: control))
            let display = profile.temperatureUnit == .celsius ? tenths / 10 : tenths * 9 / 50 + 32
            return String(format: "%.1f", display)
        }
        let value = displayedSliderValue(range: range)
        let span = range.upperBound - range.lowerBound
        let percent = span > 100 ? Double(value - range.lowerBound) * 100 / Double(span) : Double(value)
        return String(format: "%.0f%%", percent)
    }

    private func sliderValue(at location: CGPoint, in size: CGSize, range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound
        let fraction = min(1, max(0, location.x / max(1, size.width)))
        return range.lowerBound + Int((Double(span) * fraction).rounded())
    }
}
