import CoreGraphics
import Foundation
import simd
import Testing
@testable import paperGIF

struct PaperGIFPhoneRemoteTests {
    @Test func computerActionUsesBearerAndPayload() throws {
        let token = "companion-token"
        let computerID = UUID()
        let profile = PaperGIFRemoteProfile(
            computers: [PaperGIFRemoteComputer(
                id: computerID, name: "Desk", host: "192.168.1.20", port: 43_821, token: token
            )],
            pages: [PaperGIFRemotePage(name: "Main", controls: [
                .button(title: "Play", symbol: "play.fill", action: PaperGIFRemoteAction(
                    type: .computerMedia, text: "playPause", computerID: computerID.uuidString
                )),
            ])]
        )
        let before = profile
        let outcome = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: profile.pages[0], control: profile.pages[0].controls[0],
            phase: .press, session: PaperGIFPhoneRemoteSession()
        )
        let unchanged = profile == before
        #expect(unchanged)
        let request = try networkRequest(from: outcome)
        let authorized = request.headers["Authorization"] == "Bearer \(token)"
        #expect(authorized)
        #expect(request.method == "POST")
        #expect(request.url.host == "192.168.1.20")
        #expect(request.url.port == 43_821)
        #expect(request.url.path == "/action")
        let object = try json(request.body)
        #expect(object["type"] as? String == "macMedia")
        #expect(object["text"] as? String == "playPause")
        #expect(object["host"] as? String == "")
        #expect(int(object, "value") == 0)
        #expect(object["valueTenths"] == nil)
        #expect(object["modifiers"] as? [String] == [])
    }

    @Test func legacyComputerFallsBackToSavedHost() throws {
        let token = "legacy-token"
        var profile = PaperGIFRemoteProfile(
            macHost: "10.0.0.4", macPort: 43_821, macToken: token,
            pages: [PaperGIFRemotePage(name: "Main", controls: [
                .button(title: "Shortcut", symbol: "bolt.fill", action: PaperGIFRemoteAction(
                    type: .appleShortcut, text: "Lights"
                )),
            ])]
        )
        profile.computers = []
        let request = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: profile.pages[0], control: profile.pages[0].controls[0],
            phase: .press, session: PaperGIFPhoneRemoteSession()
        ))
        let authorized = request.headers["Authorization"] == "Bearer \(token)"
        #expect(authorized)
        #expect(request.url.host == "10.0.0.4")
        #expect(try json(request.body)["type"] as? String == "macShortcut")
    }

    @Test func wledBuildsStateAndRejectsPublicHosts() throws {
        let lights = control(PaperGIFRemoteAction(type: .wledPower, host: "http://10.0.0.8/", text: "toggle"), toggle: true)
        let page = PaperGIFRemotePage(name: "Lights", controls: [lights])
        let profile = PaperGIFRemoteProfile(pages: [page])
        var session = PaperGIFPhoneRemoteSession()
        session.toggleOn[lights.id] = false
        let turnOn = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: lights, phase: .press, session: session
        ))
        #expect(turnOn.url.absoluteString == "http://10.0.0.8/json/state")
        #expect(try json(turnOn.body)["on"] as? Bool == true)
        #expect(turnOn.recordsToggle)
        #expect(turnOn.toggleOnAfterSuccess)

        var brightness = control(PaperGIFRemoteAction(type: .wledBrightness, host: "lights.local", value: 999))
        brightness.kind = .slider
        let slide = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: brightness, phase: .slide(999, final: false),
            session: session
        ))
        #expect(slide.url.host == "lights.local")
        #expect(int(try json(slide.body), "bri") == 255)
        #expect(slide.isSlider)
        if case .paced = slide.delivery {
        } else {
            Issue.record("Brightness updates should coalesce")
        }

        let rejected = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page,
            control: control(PaperGIFRemoteAction(type: .wledPower, host: "https://10.0.0.8", text: "on")),
            phase: .press, session: session
        )
        #expect(rejected.effect == .rejected(PaperGIFPhoneActionMessage.invalidAddress))
        let publicHost = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page,
            control: control(PaperGIFRemoteAction(type: .wledPreset, host: "8.8.8.8", value: 3)),
            phase: .press, session: session
        )
        #expect(publicHost.effect == .rejected(PaperGIFPhoneActionMessage.invalidAddress))
    }

    @Test func localHTTPAllowsPrivateAndRejectsUnsafeTargets() throws {
        let page = PaperGIFRemotePage(name: "LAN", controls: [])
        let profile = PaperGIFRemoteProfile(pages: [page])
        let get = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page,
            control: control(PaperGIFRemoteAction(
                type: .localHTTP, host: "192.168.1.20", text: "/cm?cmnd=Power%20TOGGLE", httpMethod: "GET",
                httpBody: "ignored"
            )),
            phase: .press, session: PaperGIFPhoneRemoteSession()
        ))
        #expect(get.method == "GET")
        #expect(get.url.absoluteString == "http://192.168.1.20/cm?cmnd=Power%20TOGGLE")
        #expect(get.body == nil)

        let post = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page,
            control: control(PaperGIFRemoteAction(
                type: .localHTTP, host: "127.0.0.1:8080", text: "/hook", httpMethod: "POST", httpBody: "{\"ok\":true}"
            )),
            phase: .press, session: PaperGIFPhoneRemoteSession()
        ))
        #expect(post.method == "POST")
        #expect(post.url.absoluteString == "http://127.0.0.1:8080/hook")
        #expect(post.body == Data(#"{"ok":true}"#.utf8))

        let cases: [(PaperGIFRemoteAction, String)] = [
            (PaperGIFRemoteAction(type: .localHTTP, host: "8.8.8.8", text: "/"), PaperGIFPhoneActionMessage.invalidAddress),
            (PaperGIFRemoteAction(type: .localHTTP, host: "https://10.0.0.1", text: "/"), PaperGIFPhoneActionMessage.invalidAddress),
            (PaperGIFRemoteAction(type: .localHTTP, host: "10.0.0.1", text: "cm"), PaperGIFPhoneActionMessage.invalidPath),
            (PaperGIFRemoteAction(type: .localHTTP, host: "10.0.0.1", text: "/x", httpMethod: "PUT"), PaperGIFPhoneActionMessage.invalidMethod),
            (PaperGIFRemoteAction(type: .localHTTP, host: "example.com", text: "/"), PaperGIFPhoneActionMessage.invalidAddress),
        ]
        for (action, message) in cases {
            let outcome = PaperGIFPhoneActionRunner.prepare(
                profile: profile, page: page, control: control(action), phase: .press,
                session: PaperGIFPhoneRemoteSession()
            )
            #expect(outcome.effect == .rejected(message))
        }
    }

    @Test func scheduledLocalActionStillRunsOnTap() throws {
        var action = PaperGIFRemoteAction(type: .localHTTP, host: "10.1.2.3", text: "/ok", httpMethod: "GET")
        action.scheduleEnabled = true
        let page = PaperGIFRemotePage(name: "LAN", controls: [control(action)])
        let request = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: PaperGIFRemoteProfile(pages: [page]), page: page, control: page.controls[0],
            phase: .press, session: PaperGIFPhoneRemoteSession()
        ))
        #expect(request.url.absoluteString == "http://10.1.2.3/ok")
    }

    @Test func eWeLinkEncryptionMatchesKnownVector() throws {
        let key = "test-key"
        let action = PaperGIFRemoteAction(
            type: .eWeLinkPower, host: "10.0.0.9", text: "on", deviceID: "device-1", deviceKey: key
        )
        let page = PaperGIFRemotePage(name: "Plugs", controls: [control(action)])
        let outcome = PaperGIFPhoneActionRunner.prepare(
            profile: PaperGIFRemoteProfile(pages: [page]), page: page, control: page.controls[0],
            phase: .press, session: PaperGIFPhoneRemoteSession(),
            ewelinkIV: Data(repeating: 0x11, count: 16), ewelinkSequence: "0000000001000"
        )
        let request = try networkRequest(from: outcome)
        #expect(request.url.absoluteString == "http://10.0.0.9/zeroconf/switch")
        let object = try json(request.body)
        let dataMatches = object["data"] as? String == "iHsbjoVSOQUrlD9oiAIjwg=="
        let ivMatches = object["iv"] as? String == "EREREREREREREREREREREQ=="
        #expect(dataMatches)
        #expect(ivMatches)
        #expect(object["deviceid"] as? String == "device-1")
        #expect(object["selfApikey"] as? String == "123")
        #expect(object["encrypt"] as? Bool == true)
        #expect(object["sequence"] as? String == "0000000001000")
        let encoded = String(decoding: request.body ?? Data(), as: UTF8.self)
        let leaked = encoded.contains(key) || request.url.absoluteString.contains(key)
        #expect(!leaked)

        var toggled = action
        toggled.text = "toggle"
        var session = PaperGIFPhoneRemoteSession()
        session.toggleOn[page.controls[0].id] = true
        let off = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: PaperGIFRemoteProfile(pages: [page]), page: page,
            control: control(toggled, id: page.controls[0].id), phase: .press, session: session,
            ewelinkIV: Data(repeating: 0x11, count: 16), ewelinkSequence: "0000000001000"
        ))
        let flipped = (try json(off.body)["data"] as? String) != "iHsbjoVSOQUrlD9oiAIjwg=="
        #expect(flipped)
        #expect(off.recordsToggle)
        #expect(!off.toggleOnAfterSuccess)
    }

    @Test func pageNavigationSelectsSavedPage() {
        let target = UUID()
        let page = PaperGIFRemotePage(id: UUID(), name: "Main", controls: [
            .button(title: "Next", symbol: "arrow.right", action: PaperGIFRemoteAction(
                type: .page, text: target.uuidString.lowercased()
            )),
        ])
        let profile = PaperGIFRemoteProfile(pages: [page, PaperGIFRemotePage(id: target, name: "Other", controls: [])])
        let outcome = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: page.controls[0], phase: .press,
            session: PaperGIFPhoneRemoteSession()
        )
        #expect(outcome.effect == .navigate(target))
        let missing = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page,
            control: .button(title: "Missing", symbol: "xmark", action: PaperGIFRemoteAction(
                type: .page, text: UUID().uuidString
            )),
            phase: .press, session: PaperGIFPhoneRemoteSession()
        )
        #expect(missing.effect == .rejected(PaperGIFPhoneActionMessage.pageNotFound))
    }

    @Test func temperatureStepMatchesFirmwareClamps() throws {
        let computerID = UUID()
        let token = "climate-token"
        let setpoint = control(PaperGIFRemoteAction(
            type: .netHomeTemperature, host: "climate.local", value: 22, valueTenths: 220,
            computerID: computerID.uuidString
        ))
        let step = control(PaperGIFRemoteAction(
            type: .netHomeTemperatureStep, host: "climate.local", value: 1, computerID: computerID.uuidString
        ))
        var profile = PaperGIFRemoteProfile(
            computers: [PaperGIFRemoteComputer(
                id: computerID, name: "Desk", host: "10.0.0.4", port: 43_821, token: token
            )],
            pages: [PaperGIFRemotePage(name: "Climate", controls: [setpoint, step])]
        )
        let raised = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: profile.pages[0], control: step, phase: .press,
            session: PaperGIFPhoneRemoteSession()
        )
        #expect(raised.setpoint?.controlID == setpoint.id)
        #expect(raised.setpoint?.value == 23)
        #expect(raised.setpoint?.valueTenths == 230)
        let raisedRequest = try networkRequest(from: raised)
        let raisedJSON = try json(raisedRequest.body)
        #expect(raisedJSON["type"] as? String == "netHomeTemperature")
        #expect(int(raisedJSON, "value") == 23)
        #expect(int(raisedJSON, "valueTenths") == 230)
        if case .trailing = raisedRequest.delivery {
        } else {
            Issue.record("Temperature steps should trail")
        }

        var hot = PaperGIFPhoneRemoteSession()
        hot.valueTenths[setpoint.id] = 300
        let capped = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: profile.pages[0], control: step, phase: .press, session: hot
        )
        #expect(capped.setpoint?.valueTenths == 300)

        profile.temperatureUnit = .fahrenheit
        let fahrenheit = PaperGIFPhoneActionRunner.adjustedTemperature(currentTenths: 220, step: 1, unit: .fahrenheit)
        #expect(fahrenheit.tenths == 230)
        #expect(fahrenheit.value == 23)
        #expect(PaperGIFPhoneActionRunner.adjustedTemperature(currentTenths: 300, step: 1, unit: .fahrenheit).tenths == 300)
        #expect(PaperGIFPhoneActionRunner.adjustedTemperature(currentTenths: 160, step: -1, unit: .fahrenheit).tenths == 160)
        #expect(PaperGIFPhoneActionRunner.adjustedTemperature(currentTenths: 160, step: -1, unit: .celsius).tenths == 160)

        let otherHost = control(PaperGIFRemoteAction(
            type: .netHomeTemperatureStep, host: "other.local", value: 1, computerID: computerID.uuidString
        ))
        let missing = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: profile.pages[0], control: otherHost, phase: .press,
            session: PaperGIFPhoneRemoteSession()
        )
        #expect(missing.effect == .rejected(PaperGIFPhoneActionMessage.setpointUnavailable))
        #expect(missing.setpoint == nil)
    }

    @Test func sliderCoalescingKeepsLatestAndFlushesOnRelease() throws {
        var scheduler = PaperGIFPhoneRequestScheduler()
        let first = sliderRequest(value: 10)
        #expect(scheduler.submit(first, at: 0) == first)
        #expect(scheduler.submit(sliderRequest(value: 20), at: 0.04) == nil)
        #expect(scheduler.submit(sliderRequest(value: 30), at: 0.05) == nil)
        #expect(scheduler.flush(at: 0.07).isEmpty)
        let due = scheduler.flush(at: 0.08)
        #expect(due.count == 1)
        #expect(int(try json(due[0].body), "value") == 30)

        #expect(scheduler.submit(sliderRequest(value: 40), at: 0.10) == nil)
        let final = sliderRequest(value: 41, immediate: true)
        #expect(scheduler.submit(final, at: 0.10) == final)
        #expect(scheduler.flushAll(at: 1).isEmpty)

        #expect(scheduler.submit(trailingRequest(value: 1), at: 5) == nil)
        #expect(scheduler.submit(trailingRequest(value: 2), at: 5.2) == nil)
        #expect(scheduler.flush(at: 5.4).isEmpty)
        let trailed = scheduler.flush(at: 5.7)
        #expect(trailed.count == 1)
        #expect(int(try json(trailed[0].body), "value") == 2)
    }

    @Test func openBuildsContinuousCancelsOnRelease() throws {
        let computerID = UUID()
        let token = "cnc-token"
        var page = PaperGIFRemotePage(name: "CNC", controls: [
            .button(title: "X+", symbol: "arrow.right", action: PaperGIFRemoteAction(
                type: .openBuilds, text: "jogXPositive", computerID: computerID.uuidString
            )),
        ])
        page.openBuildsController = PaperGIFOpenBuildsController(
            host: "127.0.0.1", jogSpeed: 1_500, jogMode: .continuous, jogDistanceThousandths: 2_500
        )
        let profile = PaperGIFRemoteProfile(
            computers: [PaperGIFRemoteComputer(
                id: computerID, name: "Desk", host: "10.0.0.5", port: 43_821, token: token
            )],
            pages: [page]
        )
        let press = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: page.controls[0], phase: .press,
            session: PaperGIFPhoneRemoteSession()
        ))
        let pressJSON = try json(press.body)
        #expect(pressJSON["text"] as? String == "continuousJogXPositive")
        #expect(pressJSON["host"] as? String == "127.0.0.1")
        #expect(int(pressJSON, "value") == 1_500)
        #expect(int(pressJSON, "valueTenths") == 25)
        #expect(pressJSON["modifiers"] as? [String] == ["feed=1500", "units=mm", "dist=2500"])
        #expect(!press.isSafety)

        let release = try networkRequest(from: PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: page.controls[0], phase: .release,
            session: PaperGIFPhoneRemoteSession()
        ))
        let releaseJSON = try json(release.body)
        #expect(releaseJSON["text"] as? String == "cancelJog")
        #expect(releaseJSON["host"] as? String == "127.0.0.1")
        #expect(int(releaseJSON, "value") == 0)
        #expect(int(releaseJSON, "valueTenths") == 0)
        #expect(releaseJSON["modifiers"] as? [String] == [])
        #expect(release.isSafety)

        page.openBuildsController?.jogMode = .incremental
        let incrementalRelease = PaperGIFPhoneActionRunner.prepare(
            profile: profile, page: page, control: page.controls[0], phase: .release,
            session: PaperGIFPhoneRemoteSession()
        )
        #expect(incrementalRelease.effect == .none)
    }

    @Test func unsupportedActionsDoNotBuildRequests() {
        let page = PaperGIFRemotePage(name: "Main", controls: [])
        let profile = PaperGIFRemoteProfile(pages: [page])
        let types: [PaperGIFRemoteActionType] = [.iPhoneMedia, .iPhoneHomePower, .netHomeAuto]
        for type in types {
            let outcome = PaperGIFPhoneActionRunner.prepare(
                profile: profile, page: page, control: control(PaperGIFRemoteAction(type: type, text: "playPause")),
                phase: .press, session: PaperGIFPhoneRemoteSession()
            )
            #expect(outcome.effect == .unsupported(PaperGIFPhoneActionMessage.unavailable))
        }
    }

    @Test func localDateFormatMatchesDeviceTokens() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)
        #expect(PaperGIFPhoneTextRenderer.dateText("%b %e, %H:%M", date: date, calendar: calendar) == "Jan  1, 00:00")
    }
}

private func control(
    _ action: PaperGIFRemoteAction,
    id: UUID = UUID(),
    toggle: Bool = false
) -> PaperGIFRemoteControl {
    var control = PaperGIFRemoteControl.button(title: "Control", symbol: "square", action: action)
    control.id = id
    control.isToggle = toggle
    return control
}

private func networkRequest(from outcome: PaperGIFPhoneActionOutcome) throws -> PaperGIFPhoneNetworkRequest {
    guard case .request(let request) = outcome.effect else {
        Issue.record("Expected a network request")
        throw PaperGIFPhoneTestError.missingRequest
    }
    return request
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func int(_ object: [String: Any], _ key: String) -> Int? {
    (object[key] as? NSNumber)?.intValue
}

private func sliderRequest(value: Int, immediate: Bool = false) -> PaperGIFPhoneNetworkRequest {
    PaperGIFPhoneNetworkRequest(
        url: URL(string: "http://10.0.0.1/json/state")!,
        method: "POST",
        headers: [:],
        body: try? JSONSerialization.data(withJSONObject: ["value": value]),
        controlID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        delivery: immediate ? .immediate : .paced(key: "slider"),
        coalescingKey: "slider",
        isSlider: true
    )
}

private func trailingRequest(value: Int) -> PaperGIFPhoneNetworkRequest {
    PaperGIFPhoneNetworkRequest(
        url: URL(string: "http://10.0.0.2/action")!,
        method: "POST",
        headers: [:],
        body: try? JSONSerialization.data(withJSONObject: ["value": value]),
        controlID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        delivery: .trailing(key: "setpoint"),
        coalescingKey: "setpoint"
    )
}

private enum PaperGIFPhoneTestError: Error {
    case missingRequest
}

struct PaperGIFPhoneTouchOutlineTests {
    @Test func buttonFrameStaysOnTheTileNotTheScreen() {
        let shader = CGSize(width: 402, height: 874)
        let canvas = CGRect(x: 0, y: 118, width: 402, height: 640)
        let tile = CGRect(x: 24, y: 36, width: 110, height: 64)
        let button = PaperGIFPhoneShaderSpace.buttonFrame(tile: tile, canvasInShader: canvas)
        #expect(button == CGRect(x: 24, y: 154, width: 110, height: 64))
        let isButton = PaperGIFPhoneShaderSpace.isButton(button, on: shader)
        #expect(isButton)
        let screen = CGRect(origin: .zero, size: shader)
        let screenIsButton = PaperGIFPhoneShaderSpace.isButton(screen, on: shader)
        #expect(!screenIsButton)
        let pageCanvas = CGRect(x: 0, y: 40, width: 402, height: 700)
        let pageIsButton = PaperGIFPhoneShaderSpace.isButton(pageCanvas, on: shader)
        #expect(!pageIsButton)
        let resolved = PaperGIFPhoneShaderSpace.resolvedButtonFrame(
            measured: screen, tile: tile, origin: CGPoint(x: 0, y: 118), shader: shader
        )
        #expect(resolved == CGRect(x: 24, y: 154, width: 110, height: 64))
        let slider = CGRect(x: 16, y: 200, width: 370, height: 48)
        #expect(PaperGIFPhoneShaderSpace.isButton(slider, on: shader))
        let outside = PaperGIFPhoneTouchOutlineSampler.loop(
            frame: CGRect(x: -2000, y: -2000, width: 80, height: 50),
            canvas: shader
        )
        #expect(outside.isEmpty)
    }

    @Test func buttonOutlineStaysInsideTheTile() {
        let canvas = CGSize(width: 400, height: 800)
        let frame = CGRect(x: 40, y: 100, width: 120, height: 64)
        let loop = PaperGIFPhoneTouchOutlineSampler.loop(frame: frame, canvas: canvas)
        #expect(loop.count > 16)
        let minU = Float(frame.minX / canvas.width) - 0.02
        let maxU = Float(frame.maxX / canvas.width) + 0.02
        let minV = Float(frame.minY / canvas.height) - 0.02
        let maxV = Float(frame.maxY / canvas.height) + 0.02
        let inside = loop.allSatisfy { point in
            point.x >= minU && point.x <= maxU && point.y >= minV && point.y <= maxV
        }
        #expect(inside)
        let onTopEdge = abs(loop[0].y - Float(frame.minY / canvas.height)) < 0.03
        #expect(onTopEdge)
    }

    @Test func separateButtonOutlinesDoNotConnect() {
        var downs: [SIMD2<Float>] = []
        var moves: [(SIMD2<Float>, SIMD2<Float>)] = []
        var seen: UInt64 = 0
        let first = [SIMD2<Float>(0.1, 0.1), SIMD2<Float>(0.2, 0.1), SIMD2<Float>(0.2, 0.2)]
        let second = [SIMD2<Float>(0.6, 0.4), SIMD2<Float>(0.7, 0.4), SIMD2<Float>(0.7, 0.5)]
        let outline = PaperGIFPhoneTouchOutline(generation: 1, loops: [first, second])
        PaperGIFPhoneTouchOutlineRelay.apply(outline, seen: &seen, down: { downs.append($0) }, move: { moves.append(($0, $1)) })
        #expect(downs == [first[0], second[0]])
        let bridged = moves.contains { $0 == first[2] && $1 == second[0] }
        #expect(!bridged)
        let closed = moves.contains { $0 == first[2] && $1 == first[0] } && moves.contains { $0 == second[2] && $1 == second[0] }
        #expect(closed)
        PaperGIFPhoneTouchOutlineRelay.apply(outline, seen: &seen, down: { downs.append($0) }, move: { moves.append(($0, $1)) })
        #expect(downs.count == 2)
    }
}
