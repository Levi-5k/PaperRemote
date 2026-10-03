# Music visualizers

The Player's waveform menu selects eight styles and opens full screen. Tap the full-screen canvas to show playback/style/close controls; horizontal swipes still change songs. The selected style and embedded-stage visibility remain saved. Both style menus include **Music Response: Gentle / Punchy / Intense**, saved across launches; **Punchy** is the default.

## Visual changes

- **Ink Bloom:** six flowing, frequency-shaped luminous contours; bass and drum hits visibly expand the rings, and different bands deform each contour. Circular composition fits the shorter screen dimension.
- **Spectral Tunnel:** logarithmic depth, audio-driven travel, bass zoom, rotating spokes, and frequency-deformed rings. Motion speed is integrated rather than multiplying elapsed time by changing bass levels.
- **Wavefold:** layered ribbons with different frequency responses, a central waveform, interpolated samples, and full-width sampling in either orientation.
- **Particle Field:** three depth layers of stars, each assigned a spectrum band that drives its position and size. Bass and percussion expand the field. Pixel work is bounded by neighboring cells rather than the total number of stars.
- **Album Diffraction:** aspect-filled, unstretched artwork with bass zoom, chromatic refraction and ripples driven by the music. Missing/invalid covers retain a procedural fallback.

### Retro styles

- **Phosphor Scope:** green oscilloscope trace on a dark instrument grid, luminous phosphor-like edges, mild CRT curvature. The line is the actual analyzed waveform, not an animated sine-wave stand-in; amplitude and intensity follow the music. This is a waveform display, not a stereo XY scope or simulated persistence buffer.
- **Retro Spectrum:** 24 segmented LED columns across the log-frequency spectrum, green/amber/red height zones, pale peak markers, and a dim reflection. Each column takes the maximum across its covered bins. Peaks hold for 300 ms then fall at 0.65 units/second, independent of refresh rate, and settle fully on pause.
- **Vector Landscape:** an early-computer/synthwave-inspired magenta/cyan perspective grid, four angular spectrum-shaped ridges, and a striped sunset. Band energy deforms the grid/ridges; bass and percussion pulse the sun and drive travel. These are live frequency contours, not stored spectrum history.

The retro styles use original procedural graphics, not copied player skins or external assets. Their scanlines are stationary and low-contrast, without CRT flicker or a rolling refresh band. They share the existing response presets, render-resolution budgets, offscreen/paused behavior, and Reduce Motion. Saved IDs 0–4 remain unchanged; retro modes append IDs 5–7. Metal fragment buffer 3 contains the 64 peak-hold levels.

## Audio sampling and analysis cadence

- Analysis targets **60 updates/second**, up from approximately 30, using monotonic elapsed time and 1 ms timer leeway. The Hann-windowed FFT remains **2,048 samples**, with 64 log-frequency bands and 128 waveform points; overlapping windows retain bass-frequency resolution.
- A smaller `AVAudioNode` tap request alone does **not** increase fresh input cadence: the SDK documents 100–400 ms tap buffers. The physical iPhone delivered 4,410-frame/100 ms batches at 44.1 kHz despite a 512-frame request.
- [PaperGIFMusicRenderCapture](../paperGIF/PaperGIFMusicRenderCapture.swift) instead observes post-render PCM on a transparent EQ node between the player and main mixer (band bypassed, 0 dB gain). It reads the engine's native render batches without modifying samples or requesting a second render. The callback copies into independent preallocated channel rings using a nonblocking try-lock; sanitization, channel selection and FFT work stay on the analysis queue. The engine is stopped before observer removal and context release.
- The audio session requests an **8.33 ms I/O buffer duration**, not a different playback sample rate. Actual I/O duration remains route-dependent. If render observer setup fails, a conventional tap remains available as a slower fallback; its 512-frame request is advisory.
- Decay, envelope smoothing, reference adaptation, beat cooldown and missing-input grace use elapsed seconds, so doubling update cadence does not make effects fade twice as fast. Onset deltas are rate-normalized. A 100 ms missing-input grace also accommodates fallback tap batching.
- Capture frequency, FFT update frequency, PCM sample rate and display frame rate are distinct. Neither the I/O preference nor the 60 Hz timer guarantees end-to-end audiovisual latency, sustained frame rate, or identical behavior over Bluetooth/AirPlay.

## Correctness and lifecycle

- Consume each new audio window once. After a short allowance for normal tap cadence, missing input decays instead of repeatedly analyzing stale samples.
- Clear analysis synchronously on seeks, stops, and track changes; an in-flight FFT cannot republish an old track after reset.
- Bound logarithmic FFT indices to Nyquist, including lower sample rates; gate digital silence and sanitize non-finite PCM.
- Use an absolute-level soft gate before adaptive normalization: closed below 0.001 RMS (-60 dBFS), smoothly opening to full response at 0.012 RMS (about -38 dBFS). Apply it to spectrum, waveform and energy envelopes. Quiet beat candidates require gate gain above 0.25 and their pulse strength is multiplied by gain squared; near-silent fluctuations cannot receive the old unconditional minimum beat kick. Normal musical onsets retain their fast attack.
- Retain separate 4,096-sample histories for up to eight channels. Select a coherent 2,048-sample FFT window using channel power and 3 dB switching hysteresis, rather than splicing whichever channel wins each ~8 ms callback. This avoids both phase-inverted stereo cancellation and synthetic high-frequency spikes from channel switching. Support planar and interleaved float PCM. Playback audio is unchanged.
- Extract independent bass (30–250 Hz), mid (250 Hz–4 kHz), and treble (4–18 kHz) envelopes from linear FFT power with slow reference decay. Averaging log-scaled display bars flattened percussion; amplitude-preserving spectrum mapping and fast attack/slower release retain musical dynamics.
- Use adaptive spectral-flux, bass and energy onsets with a refractory interval. Waveforms search the longer channel history for a complete trace, interpolate the zero crossing between samples, and average buckets. Normalize against that trace's own peak, not a different FFT window. The previous 512-sample trigger search could miss bass cycles and jump to arbitrary phase.
- Apply shared, energy-adaptive temporal smoothing to levels, individual spectrum bins, waveform samples and beat pulses. Quiet passages ease toward their targets; energetic passages retain fast attacks, including first-frame strong beats. Travel integrates these filtered inputs. Avoid wrapped-coordinate derivatives and palette discontinuities in shaders.
- Decode/downsample album covers off the main thread, reject stale asynchronous results, and use an sRGB render target without double tone-mapping artwork.
- Suspend the stage when covered/offscreen or the scene is inactive. Paused visuals settle to a static frame. Reduce Motion freezes travel/rotation and suppresses beat kicks/refraction.
- Preserve the render clock across ordinary SwiftUI playback-progress updates; reset it only across an actual pause/resume, rather than repeatedly disrupting elapsed-time integration.
- The lowest quarter of the system/player volume control smoothly attenuates visual modulation; mute allows levels, waveforms, peaks and travel to settle. System output volume is read on the main/render thread, not the real-time audio callback. This is a visual gain curve, not an estimate of acoustic loudness. The extra volume attenuation is unity at settings of 0.25 and above; playback PCM and volume settings are never modified by the visualizer.
- Limit the render target's long edge to 1440 pixels (1024 under Low Power Mode or serious/critical thermal pressure). Playback targets 60 fps, constrained/Reduce Motion/settling targets 30 fps. These are budgets, not claims of sustained measured frame rate.

## Automatic energy-adaptive smoothing

All eight styles share the same automatic filter; there is no additional setting. It changes response speed rather than reducing steady-state values or mixing neighboring frequencies. The existing response presets still control effect strength.

- Overall analyzed energy, after the existing visual-volume gain, controls smoothing. A single normalized frequency bin or beat estimate cannot independently disable it. This is an adaptive signal level, not acoustic loudness or tempo/melody detection.
- A fast-attack energy follower with a 167 ms exponential release bridges brief dips. A continuous smoothstep from energy 0.12 to 0.75 chooses the filter rates, avoiding a quiet/loud mode switch.
- Quiet levels, spectrum and waveform use a 250 ms time constant. High energy approaches the previous rates: about 15 ms level/spectrum attack, 56–63 ms release, and 17 ms waveform smoothing.
- Quiet beat attacks ease in with up to a 180 ms time constant, continuously shortening toward an immediate strong pulse. Beat-driven zoom and travel therefore cannot bypass the quiet filter. Strong hits can respond immediately even after silence.
- All interpolation and energy release use elapsed seconds. With constant input energy, envelope results match at 30/60/120 Hz; changing-energy trajectories are sampled at the render cadence. Silence and mute still settle fully, peak markers retain their hold/fall behavior, and Reduce Motion still freezes travel.

## Validation

`PaperGIFMusicVisualizerTests` covers silence/noise, frequency mapping, stale-input decay, tap gaps, sample rates, interleaved and phase-inverted stereo, reset behavior, quiet onsets, repeated drums over sustained music, first-frame renderer response, waveform phase stability, malformed/partial PCM, render-size budgets, and artwork scaling. The Metal test renders every style with silent/reactive inputs in portrait, landscape, and at the full 1440-pixel budget. It additionally compares an analyzed sustained musical bed with a kick on the first rendered frame at identical animation time. It records PNG previews and single-frame GPU times in the test-result bundle.

Retro coverage also verifies saved mode IDs, peak hold/release at 30 and 60 Hz, and GPU rendering with Reduce Motion and Intense response. Every render path must bind the peak-level buffer, even when a different mode is selected.

Adaptive-filter coverage compares identical-amplitude fluctuations under low and high overall energy, checks unchanged steady-state details, strong-hit recovery after quiet input, continuous response across energy levels, constant-energy 30/60/120 Hz equivalence, and invalid elapsed-time handling. Soft onsets intentionally ease in instead of becoming unconditional first-frame kicks.

Manual checks on a physical device still matter: play bass-heavy and quiet acoustic tracks, pause/resume, seek/switch tracks rapidly, open/close full screen, rotate, background/foreground, and toggle Reduce Motion. Confirm perceived synchronization, long-running thermal behavior, and artwork appearance with actual music. Offscreen renders do not validate sustained playback or UI interactions.

### Verified 2026-09-13

- Device build and all **15 visualizer tests passed** on the connected iPhone 17 Pro Max; updated app installed.
- Result bundle: `build-device/VisualizerResponseVerified.xcresult`. Exported previews and timing attachment: `build-device/visualizer-response-previews/`.
- Single offscreen GPU frames at 810×1440: Ink Bloom 2.69 ms, Spectral Tunnel 0.79 ms, Wavefold 3.77 ms, Particle Field 6.35 ms, Album Diffraction 0.71 ms. These do not include presentation/CPU work and are not sustained frame-rate measurements.
- Reviewed rendered images; corrected particle grid-boundary streaks by taking derivatives before `floor`/`fract`, and removed polar palette seams with periodic coordinates.

### Retro additions verified 2026-09-13

- All **17 visualizer tests passed** on the physical iPhone 17 Pro Max, covering all eight modes, stable mode IDs, peak ballistics, and the additional retro Reduce Motion/Intense render cases.
- Result bundle: `build-device/RetroVisualizerTests.xcresult`; reviewed portrait/landscape PNGs in `build-device/retro-visualizer-previews/`.
- Single offscreen GPU frames at 810×1440: Phosphor Scope 0.73 ms, Retro Spectrum 0.91 ms, Vector Landscape 1.39 ms. These are render-only samples, not sustained frame-rate or thermal measurements.

### Higher-cadence capture verified 2026-09-13

- Device build and all **22 visualizer tests passed** on the physical iPhone 17 Pro Max. Result bundle: `build-device/VisualizerRenderCaptureTests.xcresult`; attachments: `build-device/render-capture-previews/`.
- The one-second capture probe recorded **122 accepted render batches**, maximum **368 frames** at **44.1 kHz** (about 8.34 ms of PCM per batch), versus **10 conventional tap callbacks**, each 4,410 frames. This verifies the batching bottleneck was bypassed on the tested route; it is not a callback-jitter or total-latency measurement.
- Offline engine rendering verified the capture node's settled stereo output matches input samples within 0.0001, and the analyzer receives the signal. Additional tests cover contiguous 512-frame ingestion, matching decay at 30/60/120 Hz, and real-time missing-input grace. The existing DSP and all-eight-mode GPU regressions continue to pass.

### Continuous-stream glitch regression 2026-09-13

- A native macOS probe using the production analyzer reproduced problems missed by repeated-identical-buffer tests. A continuous 110 Hz quadrature stereo tone fed in 368-frame chunks generated a false treble envelope of **0.911** and a false beat of **1.0**. A continuous 40 Hz mono tone produced a maximum mean waveform step of **0.694** between updates.
- With independent channel histories and the longer fractional trigger search, the same probe measured stereo treble about **0.000030**, false beat **0.000022**, and mono waveform steps below **0.000002**. Expanded native checks also passed for planar/interleaved right-only PCM, 44.1/48/96 kHz, loud-to-quiet waveform bounds, and reset.
- Four new device regressions cover continuous stereo, continuous bass, right-only audio/format changes, and transient bounds. The suite is explicitly serialized because its engine tests share an audio session. Initial iPhone validation was blocked by disconnection; the fix had not been installed on either device at that point.
- Subsequently, all **26 visualizer tests passed** on **iPad5k, iPad Pro 11-inch (M5), iOS 27.0**, with no failures or skips. Result bundle: `build-device/VisualizerGlitchIPadTests.xcresult`. The corrected app was explicitly installed and launched on that iPad at 17:56 on 2026-09-13. These DSP/GPU tests do not establish perceived smoothness or sustained display frame pacing with actual music.

### Near-silence response verified 2026-09-13

- Continuous quiet bass bursts/hiss reproduced excessive beat amplification: peak PCM amplitude 0.001 (0.1% full scale) generated a **0.703 beat**, and 0.003 generated **1.0**, despite barely audible content. The previous silence gate was already fully open at 0.0002 RMS (about -74 dBFS).
- The same 12-second native probe after the soft-gate/beat-cap fix produced **zero beats** at peak amplitudes 0.0005, 0.001, 0.003 and 0.006. The 0.003 case's maximum level fell from **0.191 to 0.00160**; the 0.03 case still generated a **0.885 beat**. These are synthetic-signal results, not sound-pressure measurements.
- All **30 visualizer tests passed on iPad5k**, no failures/skips. New coverage includes near-silence bursts after reference adaptation, settling tails and immediate recovery on musical onsets, a gradual gate at 30/60/120 Hz, and low-volume/mute dynamics. Existing strong-kick, continuous-stereo, waveform and all-eight-mode GPU tests still pass.
- Result bundle: `build-device/VisualizerQuietIPadTests.xcresult`; attachments: `build-device/quiet-ipad-validation/`. The update was explicitly installed and launched on the physical iPad at **18:17 on 2026-09-13**. Confirm perceived behavior with the original quiet passage; route volume controls are not calibrated acoustic meters.

### Energy-adaptive smoothing verified 2026-09-13

- All **34 visualizer tests passed on iPad5k**, no failures/skips. Result bundle: `build-device/VisualizerAdaptiveVerifiedIPadTests.xcresult`; complete attachments: `build-device/adaptive-ipad-validation-complete/`.
- For identical 10 Hz synthetic fluctuations, quiet overall energy reduced total frame-to-frame variation versus high overall energy by approximately **81% for levels, 83% for spectrum, 89% for waveform and 74% for beat**. Constant target values still converged to the same levels: this measures temporal filtering, not reduced steady-state sensitivity.
- First-frame strong-kick checks, soft-onset recovery, low-volume/mute settling, continuous stereo/bass stability, 30/60/120 Hz constant-energy filtering, strict peak hold/fall timing and all-eight-mode Metal rendering passed. The old quiet-spectrum assertion assumed a fixed 18/s release; coverage now verifies both the slower quiet decay bound and unchanged fast energetic decay, while retaining exact peak ballistics.
- The verified app was explicitly installed and launched on the physical **iPad at 18:55 on 2026-09-13**. These synthetic/DSP/GPU results do not establish perceived synchronization or smoothness for a particular song; listen to the original quiet passage for that comparison.