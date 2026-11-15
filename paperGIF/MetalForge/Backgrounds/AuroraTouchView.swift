import SwiftUI
import MetalKit
import simd
import QuartzCore

enum AuroraEmitter {
    case scatter
    case bottomUp
}

struct AuroraColorPalette {
    var hueRange: ClosedRange<Float> = 0...1
    var saturation: Float = 1
    var value: Float = 1
    var intensity: Float = 0.15
}

struct SimConfig {
    var simResolution: Int = 128
    var bloomResolution: Int = 256
    var dyeResolution: Int = 640

    var velocityDissipation: Float = 0.75
    var densityDissipation: Float = 1.6
    var pressure: Float = 0.8
    var pressureIterations: Int = 20
    var curl: Float = 4.0
    var splatRadius: Float = 0.3
    var splatForce: Float = 2600.0
    var timeScale: Float = 1.0

    var wind: Float = 260.0
    var windScale: Float = 15.0
    var windLift: Float = 170.0

    var emitter: AuroraEmitter = .scatter
    var emitterSpeed: Float = 210.0
    var emitterIntensity: Float = 1.3
    var idleSplatInterval: Float = 0.45
    var seedCount: Int = 6
    var seedIntensity: Float = 1.3
    var seedSpeed: Float = 220.0
    var touchIntensity: Float = 3.0
    var colorful: Bool = false
    var colorUpdateSpeed: Float = 10.0
    var palette: AuroraColorPalette = AuroraColorPalette(hueRange: 0.0...0.0, saturation: 0.0, value: 1.0, intensity: 0.1)

    var bloom: Bool = true
    var bloomIterations: Int = 8
    var bloomIntensity: Float = 0.35
    var bloomThreshold: Float = 0.06
    var bloomSoftKnee: Float = 0.7
    var p0: Float = 1.2
    var p1: Float = 0.16
    var p2: Float = 0.0
    var p3: Float = 0.0

    var displayA: SIMD3<Float> = SIMD3<Float>(0.0118, 0.0196, 0.051)
    var displayB: SIMD3<Float> = SIMD3<Float>(0.0039, 0.0078, 0.0157)
    var displayC: SIMD3<Float> = SIMD3<Float>(0.102, 1.0, 0.451)
    var displayD: SIMD3<Float> = SIMD3<Float>(0.6196, 0.2, 1.0)
}

let auroraForgedConfig: SimConfig = {
    var c = SimConfig()
    c.timeScale = 0.7
    c.splatRadius = 1.6
    c.idleSplatInterval = 0
    c.seedCount = 0
    c.palette = AuroraColorPalette(hueRange: 0.0...0.0, saturation: 0.0, value: 1.0, intensity: 0.45)
    c.p0 = 0.28
    c.bloomIterations = 3
    c.bloomIntensity = 0.12
    c.bloomThreshold = 0.4
    c.simResolution = 96
    c.dyeResolution = 384
    c.bloomResolution = 128
    c.pressureIterations = 10
    return c
}()

private struct DoubleBuffer {
    var read: MTLTexture
    var write: MTLTexture
    mutating func swap() { Swift.swap(&read, &write) }
}

private struct SplatInput {
    var point: SIMD2<Float>
    var velocity: SIMD2<Float>
    var color: SIMD3<Float>
    /// Shader-space gaussian radius. Zero uses the finger-tuned config radius.
    var radius: Float = 0
}

private struct DisplayUniforms {
    var texelX: Float = 0
    var texelY: Float = 0
    var bloomEnabled: Float = 0
    var time: Float = 0
    var aspect: Float = 1
    var p0: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
    var reveal: Float = 1

    var ramp0r: Float = 0, ramp0g: Float = 0, ramp0b: Float = 0
    var ramp1r: Float = 0, ramp1g: Float = 0, ramp1b: Float = 0
    var ramp2r: Float = 0, ramp2g: Float = 0, ramp2b: Float = 0
    var ramp3r: Float = 0, ramp3g: Float = 0, ramp3b: Float = 0
}

final class SimRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var drawablePixelFormat: MTLPixelFormat = .bgra8Unorm

    var config: SimConfig

    private let velocityFormat: MTLPixelFormat = .rg16Float
    private let scalarFormat: MTLPixelFormat   = .r16Float
    private let dyeFormat: MTLPixelFormat      = .rgba16Float
    private let bloomFormat: MTLPixelFormat    = .rgba16Float

    private var splatVelocityPS: MTLRenderPipelineState!
    private var curlPS, vorticityPS, divergencePS, clearPS, pressurePS, gradientPS: MTLRenderPipelineState!
    private var advectionVelocityPS: MTLRenderPipelineState!
    private var splatDyePS, advectionDyePS: MTLRenderPipelineState!
    private var windPS: MTLRenderPipelineState!
    private var bloomPrefilterPS, bloomBlurPS, bloomBlurAdditivePS, bloomFinalPS: MTLRenderPipelineState!
    private var displayPS: MTLRenderPipelineState!

    private var velocity: DoubleBuffer!
    private var pressure: DoubleBuffer!
    private var dye: DoubleBuffer!
    private var curlTex: MTLTexture!
    private var divergenceTex: MTLTexture!
    private var bloomTex: MTLTexture!
    private var bloomChain: [MTLTexture] = []

    private var simWidth = 0, simHeight = 0
    private var simTexel = SIMD2<Float>(0, 0)

    private var drawableWidth: Float = 1
    private var drawableHeight: Float = 1
    private var aspectRatio: Float = 1

    private var lastTime: CFTimeInterval = 0
    private var elapsed: Float = 0
    private var colorUpdateTimer: Float = 0
    private var idleTimer: Float = 0
    private var didSeed = false

    private var pointerColor = SIMD3<Float>(0.2, 0.1, 0.3)
    private var pendingSplats: [SplatInput] = []

    init?(device: MTLDevice, config: SimConfig = SimConfig()) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.config = config
        super.init()
        do {
            try buildPipelines()
        } catch {
            print("SimRenderer: failed to build pipelines — \(error)")
            return nil
        }
        pointerColor = generateColor()
    }

    private func makePipeline(_ library: MTLLibrary,
                              fragment: String,
                              format: MTLPixelFormat,
                              vertex: String = "au_fullscreen_vertex",
                              additiveBlend: Bool = false) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        let att = desc.colorAttachments[0]!
        att.pixelFormat = format
        if additiveBlend {
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func buildPipelines() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw NSError(domain: "SimRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No default Metal library — is aurora.metal in the target?"])
        }
        splatVelocityPS     = try makePipeline(library, fragment: "au_splat_fragment", format: velocityFormat)
        curlPS              = try makePipeline(library, fragment: "au_curl_fragment", format: scalarFormat)
        vorticityPS         = try makePipeline(library, fragment: "au_vorticity_fragment", format: velocityFormat)
        divergencePS        = try makePipeline(library, fragment: "au_divergence_fragment", format: scalarFormat)
        clearPS             = try makePipeline(library, fragment: "au_clear_fragment", format: scalarFormat)
        pressurePS          = try makePipeline(library, fragment: "au_pressure_fragment", format: scalarFormat)
        gradientPS          = try makePipeline(library, fragment: "au_gradient_fragment", format: velocityFormat)
        advectionVelocityPS = try makePipeline(library, fragment: "au_advection_fragment", format: velocityFormat)
        splatDyePS          = try makePipeline(library, fragment: "au_splat_fragment", format: dyeFormat)
        advectionDyePS      = try makePipeline(library, fragment: "au_advection_fragment", format: dyeFormat)
        windPS              = try makePipeline(library, fragment: "au_wind_fragment", format: velocityFormat)
        bloomPrefilterPS    = try makePipeline(library, fragment: "au_bloom_prefilter_fragment", format: bloomFormat)
        bloomBlurPS         = try makePipeline(library, fragment: "au_bloom_blur_fragment", format: bloomFormat)
        bloomBlurAdditivePS = try makePipeline(library, fragment: "au_bloom_blur_fragment", format: bloomFormat, additiveBlend: true)
        bloomFinalPS        = try makePipeline(library, fragment: "au_bloom_final_fragment", format: bloomFormat)
        displayPS           = try makePipeline(library, fragment: "au_display_aurora_fragment", format: drawablePixelFormat)
    }

    private func makeTexture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.pixelFormat = format
        d.width = max(1, width)
        d.height = max(1, height)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func clearToZero(_ textures: [MTLTexture]) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        for tex in textures {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        }
        cb.commit()
    }

    private func resolution(for base: Int) -> (Int, Int) {
        var aspect = drawableWidth / drawableHeight
        if aspect < 1 { aspect = 1 / aspect }
        let minDim = Int((Float(base)).rounded())
        let maxDim = Int((Float(base) * aspect).rounded())
        return drawableWidth > drawableHeight ? (maxDim, minDim) : (minDim, maxDim)
    }

    private func allocateTextures() {
        let sim = resolution(for: config.simResolution)
        let bloomRes = resolution(for: config.bloomResolution)

        simWidth = sim.0;  simHeight = sim.1
        simTexel = SIMD2<Float>(1 / Float(simWidth), 1 / Float(simHeight))

        guard let velRead = makeTexture(simWidth, simHeight, velocityFormat),
              let velWrite = makeTexture(simWidth, simHeight, velocityFormat),
              let pressRead = makeTexture(simWidth, simHeight, scalarFormat),
              let pressWrite = makeTexture(simWidth, simHeight, scalarFormat),
              let curl = makeTexture(simWidth, simHeight, scalarFormat),
              let divergence = makeTexture(simWidth, simHeight, scalarFormat),
              let bloom = makeTexture(bloomRes.0, bloomRes.1, bloomFormat) else {
            print("SimRenderer: texture allocation failed (GPU out of memory?)")
            velocity = nil
            return
        }

        velocity = DoubleBuffer(read: velRead, write: velWrite)
        pressure = DoubleBuffer(read: pressRead, write: pressWrite)
        curlTex = curl
        divergenceTex = divergence
        bloomTex = bloom

        var toClear: [MTLTexture] = [velRead, velWrite, pressRead, pressWrite, curl, divergence, bloom]
        let dyeRes = resolution(for: config.dyeResolution)
        guard let dyeRead = makeTexture(dyeRes.0, dyeRes.1, dyeFormat),
              let dyeWrite = makeTexture(dyeRes.0, dyeRes.1, dyeFormat) else {
            print("SimRenderer: dye allocation failed")
            velocity = nil
            return
        }
        dye = DoubleBuffer(read: dyeRead, write: dyeWrite)
        toClear.append(contentsOf: [dyeRead, dyeWrite])

        bloomChain.removeAll()
        var w = bloomRes.0, h = bloomRes.1
        for _ in 0..<config.bloomIterations {
            w >>= 1; h >>= 1
            if w < 2 || h < 2 { break }
            guard let chainTex = makeTexture(w, h, bloomFormat) else { break }
            bloomChain.append(chainTex)
        }
        toClear.append(contentsOf: bloomChain)

        clearToZero(toClear)
        pendingSplats.removeAll(keepingCapacity: true)
        idleTimer = 0
        colorUpdateTimer = 0
        didSeed = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if view.colorPixelFormat != drawablePixelFormat, let lib = device.makeDefaultLibrary() {
            drawablePixelFormat = view.colorPixelFormat
            do {
                displayPS = try makePipeline(lib, fragment: "au_display_aurora_fragment", format: drawablePixelFormat)
            } catch {
                print("SimRenderer: failed to rebuild display pipeline — \(error)")
            }
        }
        guard size.width > 0, size.height > 0 else { return }
        drawableWidth = Float(size.width)
        drawableHeight = Float(size.height)
        aspectRatio = drawableWidth / drawableHeight
        allocateTextures()
    }

    func draw(in view: MTKView) {
        guard PaperGIFEffectVisibility.remoteLive else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            return
        }
        guard velocity != nil, displayPS != nil,
              let cb = commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        var dt: Float = lastTime == 0 ? 1.0 / 60.0 : Float(now - lastTime)
        lastTime = now
        dt = min(dt, 0.016666) * config.timeScale
        elapsed += dt

        if !didSeed {
            seedField()
            didSeed = true
        }
        updateColors(dt)
        updateIdle(dt)

        applyInputs(cb)
        step(cb, dt: dt)
        render(cb, view: view)

        if let drawable = view.currentDrawable {
            cb.present(drawable)
        }
        cb.commit()
    }

    private func step(_ cb: MTLCommandBuffer, dt: Float) {
        pass(cb, to: curlTex, ps: curlPS) { e in
            e.setFragmentTexture(self.velocity.read, index: 0)
            setBytes(e, self.simTexel, 0)
        }
        pass(cb, to: velocity.write, ps: vorticityPS) { e in
            e.setFragmentTexture(self.velocity.read, index: 0)
            e.setFragmentTexture(self.curlTex, index: 1)
            setBytes(e, self.simTexel, 0)
            setBytes(e, self.config.curl, 1)
            setBytes(e, dt, 2)
        }
        velocity.swap()
        if config.wind > 0 {
            pass(cb, to: velocity.write, ps: windPS) { e in
                e.setFragmentTexture(self.velocity.read, index: 0)
                e.setFragmentTexture(self.dye.read, index: 1)
                setBytes(e, self.config.wind, 0)
                setBytes(e, self.config.windScale, 1)
                setBytes(e, self.config.windLift, 2)
                setBytes(e, self.elapsed, 3)
                setBytes(e, dt, 4)
            }
            velocity.swap()
        }
        pass(cb, to: divergenceTex, ps: divergencePS) { e in
            e.setFragmentTexture(self.velocity.read, index: 0)
            setBytes(e, self.simTexel, 0)
        }
        pass(cb, to: pressure.write, ps: clearPS) { e in
            e.setFragmentTexture(self.pressure.read, index: 0)
            setBytes(e, self.config.pressure, 0)
        }
        pressure.swap()
        for _ in 0..<config.pressureIterations {
            pass(cb, to: pressure.write, ps: pressurePS) { e in
                e.setFragmentTexture(self.pressure.read, index: 0)
                e.setFragmentTexture(self.divergenceTex, index: 1)
                setBytes(e, self.simTexel, 0)
            }
            pressure.swap()
        }
        pass(cb, to: velocity.write, ps: gradientPS) { e in
            e.setFragmentTexture(self.pressure.read, index: 0)
            e.setFragmentTexture(self.velocity.read, index: 1)
            setBytes(e, self.simTexel, 0)
        }
        velocity.swap()
        pass(cb, to: velocity.write, ps: advectionVelocityPS) { e in
            e.setFragmentTexture(self.velocity.read, index: 0)
            e.setFragmentTexture(self.velocity.read, index: 1)
            setBytes(e, self.simTexel, 0)
            setBytes(e, dt, 1)
            setBytes(e, self.config.velocityDissipation, 2)
        }
        velocity.swap()
        pass(cb, to: dye.write, ps: advectionDyePS) { e in
            e.setFragmentTexture(self.velocity.read, index: 0)
            e.setFragmentTexture(self.dye.read, index: 1)
            setBytes(e, self.simTexel, 0)
            setBytes(e, dt, 1)
            setBytes(e, self.config.densityDissipation, 2)
        }
        dye.swap()
    }

    private func applyInputs(_ cb: MTLCommandBuffer) {
        guard !pendingSplats.isEmpty else { return }
        var radius = config.splatRadius / 100.0
        if aspectRatio > 1 { radius *= aspectRatio }

        for s in pendingSplats {
            var point = s.point
            var vel = SIMD3<Float>(s.velocity.x, s.velocity.y, 0)
            var splatRadius = s.radius > 0 ? s.radius : radius
            pass(cb, to: velocity.write, ps: splatVelocityPS) { e in
                e.setFragmentTexture(self.velocity.read, index: 0)
                e.setFragmentBytes(&point, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.setFragmentBytes(&vel, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                setBytes(e, splatRadius, 2)
                setBytes(e, self.aspectRatio, 3)
            }
            velocity.swap()

            var color = s.color
            pass(cb, to: dye.write, ps: splatDyePS) { e in
                e.setFragmentTexture(self.dye.read, index: 0)
                e.setFragmentBytes(&point, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
                setBytes(e, splatRadius, 2)
                setBytes(e, self.aspectRatio, 3)
            }
            dye.swap()
        }
        pendingSplats.removeAll(keepingCapacity: true)
    }

    private func emitterSplat(intensity: Float, speed: Float) -> SplatInput {
        let c = generateColor() * intensity
        switch config.emitter {
        case .scatter:
            let p = SIMD2<Float>(.random(in: 0.15...0.85), .random(in: 0.15...0.85))
            let v = SIMD2<Float>(speed * (.random(in: 0...1) - 0.5),
                                 speed * (.random(in: 0...1) - 0.5))
            return SplatInput(point: p, velocity: v, color: c)
        case .bottomUp:
            let p = SIMD2<Float>(.random(in: 0.12...0.88), .random(in: 0.88...0.99))
            let v = SIMD2<Float>(speed * 0.4 * (.random(in: 0...1) - 0.5),
                                 -speed * .random(in: 0.6...1.0))
            return SplatInput(point: p, velocity: v, color: c)
        }
    }

    private func seedField() {
        for _ in 0..<config.seedCount {
            pendingSplats.append(emitterSplat(intensity: config.seedIntensity,
                                              speed: config.seedSpeed))
        }
    }

    private func updateIdle(_ dt: Float) {
        guard config.idleSplatInterval > 0 else { return }
        idleTimer += dt
        guard idleTimer >= config.idleSplatInterval else { return }
        idleTimer = 0
        pendingSplats.append(emitterSplat(intensity: config.emitterIntensity,
                                          speed: config.emitterSpeed))
    }

    private func render(_ cb: MTLCommandBuffer, view: MTKView) {
        let source = dye.read
        let bloomOn = config.bloom && !bloomChain.isEmpty
        if bloomOn {
            applyBloom(cb, source: source)
        }
        guard let rpd = view.currentRenderPassDescriptor,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        var u = DisplayUniforms()
        u.texelX = 1 / drawableWidth
        u.texelY = 1 / drawableHeight
        u.bloomEnabled = bloomOn ? 1 : 0
        u.time = elapsed
        u.aspect = aspectRatio
        u.p0 = config.p0
        u.p1 = config.p1
        u.p2 = config.p2
        u.p3 = config.p3
        u.ramp0r = config.displayA.x; u.ramp0g = config.displayA.y; u.ramp0b = config.displayA.z
        u.ramp1r = config.displayB.x; u.ramp1g = config.displayB.y; u.ramp1b = config.displayB.z
        u.ramp2r = config.displayC.x; u.ramp2g = config.displayC.y; u.ramp2b = config.displayC.z
        u.ramp3r = config.displayD.x; u.ramp3g = config.displayD.y; u.ramp3b = config.displayD.z

        enc.setRenderPipelineState(displayPS)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(bloomTex, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func applyBloom(_ cb: MTLCommandBuffer, source: MTLTexture) {
        let knee = config.bloomThreshold * config.bloomSoftKnee + 0.0001
        let curve = SIMD3<Float>(config.bloomThreshold - knee, knee * 2, 0.25 / knee)

        pass(cb, to: bloomTex, ps: bloomPrefilterPS) { e in
            e.setFragmentTexture(source, index: 0)
            setBytes(e, curve, 0)
            setBytes(e, self.config.bloomThreshold, 1)
        }

        var last = bloomTex!
        for dest in bloomChain {
            let texel = SIMD2<Float>(1 / Float(last.width), 1 / Float(last.height))
            pass(cb, to: dest, ps: bloomBlurPS) { e in
                e.setFragmentTexture(last, index: 0)
                setBytes(e, texel, 0)
            }
            last = dest
        }

        var i = bloomChain.count - 2
        while i >= 0 {
            let base = bloomChain[i]
            let texel = SIMD2<Float>(1 / Float(last.width), 1 / Float(last.height))
            pass(cb, to: base, ps: bloomBlurAdditivePS, loadAction: .load) { e in
                e.setFragmentTexture(last, index: 0)
                setBytes(e, texel, 0)
            }
            last = base
            i -= 1
        }

        let texel = SIMD2<Float>(1 / Float(last.width), 1 / Float(last.height))
        pass(cb, to: bloomTex, ps: bloomFinalPS) { e in
            e.setFragmentTexture(last, index: 0)
            setBytes(e, texel, 0)
            setBytes(e, self.config.bloomIntensity, 1)
        }
    }

    private func pass(_ cb: MTLCommandBuffer,
                      to target: MTLTexture,
                      ps: MTLRenderPipelineState,
                      loadAction: MTLLoadAction = .dontCare,
                      _ body: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = loadAction
        rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(ps)
        body(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    private func updateColors(_ dt: Float) {
        guard config.colorful else { return }
        colorUpdateTimer += dt * config.colorUpdateSpeed
        if colorUpdateTimer >= 1 {
            colorUpdateTimer = colorUpdateTimer.truncatingRemainder(dividingBy: 1)
            pointerColor = generateColor()
        }
    }

    private func generateColor() -> SIMD3<Float> {
        let p = config.palette
        let h = p.hueRange.lowerBound == p.hueRange.upperBound
            ? p.hueRange.lowerBound
            : Float.random(in: p.hueRange)
        return hsvToRgb(h, p.saturation, p.value) * p.intensity
    }

    private func hsvToRgb(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    func pointerDown(at tc: SIMD2<Float>) {
        idleTimer = 0
        guard config.touchIntensity > 0 else { return }
        pointerColor = generateColor()
        let c = generateColor() * config.touchIntensity
        let v = SIMD2<Float>(10 * (.random(in: 0...1) - 0.5),
                             30 * (.random(in: 0...1) - 0.5))
        pendingSplats.append(SplatInput(point: tc, velocity: v, color: c))
    }

    func pointerMoved(from prev: SIMD2<Float>, to tc: SIMD2<Float>) {
        idleTimer = 0
        var dx = tc.x - prev.x
        var dy = tc.y - prev.y
        if aspectRatio < 1 { dx *= aspectRatio }
        if aspectRatio > 1 { dy /= aspectRatio }
        if dx == 0 && dy == 0 { return }
        let v = SIMD2<Float>(dx * config.splatForce, dy * config.splatForce)
        pendingSplats.append(SplatInput(point: tc, velocity: v, color: pointerColor))
    }

    /// Button outline. Dye only, so the wind field is not kicked across the whole screen.
    func outlineDown(at tc: SIMD2<Float>) {
        idleTimer = 0
        guard Self.outlinePoint(tc) else { return }
        pointerColor = generateColor()
        pendingSplats.append(SplatInput(
            point: tc, velocity: .zero, color: generateColor() * 0.2, radius: Self.outlineRadius
        ))
    }

    func outlineMoved(from prev: SIMD2<Float>, to tc: SIMD2<Float>) {
        idleTimer = 0
        guard Self.outlinePoint(prev), Self.outlinePoint(tc) else { return }
        guard hypot(tc.x - prev.x, tc.y - prev.y) <= Self.outlineMaxStep else { return }
        pendingSplats.append(SplatInput(
            point: tc, velocity: .zero, color: pointerColor * 0.14, radius: Self.outlineRadius
        ))
    }

    private static let outlineRadius: Float = 0.0011
    private static let outlineMaxStep: Float = 0.08

    private static func outlinePoint(_ point: SIMD2<Float>) -> Bool {
        point.x >= -0.002 && point.x <= 1.002 && point.y >= -0.002 && point.y <= 1.002
    }
}

private func setBytes<T>(_ encoder: MTLRenderCommandEncoder, _ value: T, _ index: Int) {
    var v = value
    encoder.setFragmentBytes(&v, length: MemoryLayout<T>.stride, index: index)
}

#if canImport(UIKit)
import UIKit
typealias AuroraPlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
typealias AuroraPlatformViewRepresentable = NSViewRepresentable
#endif

struct SimMetalView: AuroraPlatformViewRepresentable {
    var config: SimConfig
    var outline: PaperGIFPhoneTouchOutline

    final class Coordinator {
        var renderer: SimRenderer?
        var seenOutline: UInt64 = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMTKView(_ coordinator: Coordinator) -> MTKView {
        let view = PaperGIFPausingMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = PaperGIFMetalEffect.framesPerSecond
        view.isUserInteractionEnabled = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let device = view.device,
           let renderer = SimRenderer(device: device, config: config) {
            coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    private func apply(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        PaperGIFPhoneTouchOutlineRelay.apply(
            outline,
            seen: &coordinator.seenOutline,
            down: renderer.outlineDown(at:),
            move: renderer.outlineMoved(from:to:)
        )
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> MTKView { makeMTKView(context.coordinator) }
    func updateUIView(_ uiView: MTKView, context: Context) {
        (uiView as? PaperGIFPausingMTKView)?.applyVisibility()
        apply(context.coordinator)
    }
    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        PaperGIFMetalEffect.release(uiView)
        coordinator.renderer = nil
    }
    #else
    func makeNSView(context: Context) -> MTKView { makeMTKView(context.coordinator) }
    func updateNSView(_ nsView: MTKView, context: Context) {
        (nsView as? PaperGIFPausingMTKView)?.applyVisibility()
        apply(context.coordinator)
    }
    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        PaperGIFMetalEffect.release(nsView)
        coordinator.renderer = nil
    }
    #endif
}

struct AuroraTouchBackground: View {
    var outline: PaperGIFPhoneTouchOutline

    var body: some View {
        SimMetalView(config: auroraForgedConfig, outline: outline)
            .background(Color.black)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
