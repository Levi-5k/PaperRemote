//
//  paperGIFApp.swift
//  paperGIF
//
//  Created by Levi Richards on 8/29/26.
//

import Darwin
import SwiftUI

@main
struct paperGIFApp: App {
    @AppStorage(PaperGIFSplashPreference.enabledKey) private var splashEnabled = false
    @AppStorage(PaperGIFSplashPreference.seenKey) private var hasSeenSplash = false
    @State private var showsSplash = false

    init() {
        setenv("MTL_HUD_ENABLED", "0", 1)
        let defaults = UserDefaults.standard
        let seen = defaults.bool(forKey: PaperGIFSplashPreference.seenKey)
        let enabled = defaults.bool(forKey: PaperGIFSplashPreference.enabledKey)
        _showsSplash = State(initialValue: !seen || enabled)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if showsSplash {
                    PaperGIFSplashView {
                        hasSeenSplash = true
                        withAnimation(.easeOut(duration: 0.35)) {
                            showsSplash = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
    }
}
