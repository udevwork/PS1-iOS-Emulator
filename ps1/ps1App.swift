//
//  ps1App.swift
//  ps1
//
//  Created by Denis Kotelnikov on 12.07.2026.
//

import SwiftUI

@main
struct ps1App: App {
    init() {
        // Инициализируем слежение за геймпадами с запуска приложения
        _ = GamepadManager.shared
    }

    var body: some Scene {
        WindowGroup {
            GameLibraryView()
        }
    }
}
