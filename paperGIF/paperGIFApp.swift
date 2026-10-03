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
    init() {
        setenv("MTL_HUD_ENABLED", "0", 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
