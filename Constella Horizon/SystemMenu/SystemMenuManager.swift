//
//  SystemMenuManager.swift
//  Constella Horizon
//
//  Created by occlusion on 5/5/25.
//

import Cocoa
import Sparkle

class SystemMenuManager {
    var statusItem: NSStatusItem!

    static let shared = SystemMenuManager()
    var showSettings:(()->Void)? = nil

    func setup(){
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            let icon = NSImage(named: "icon_template")
            icon?.isTemplate = false
            button.image = icon
        }

        let menu = NSMenu()
        
        let item1 = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent:"")
        item1.target = self
    
        let item2 = NSMenuItem(title: "Check For Update...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent:"")
        item2.target = AppDelegate.shared.updaterController
    
        let item3 = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent:"")
        item3.target = self
    
        menu.addItem(item1)
        menu.addItem(item2)
        menu.addItem(.separator())
        menu.addItem(item3)
        
        statusItem.menu = menu

    }
    
    
    @objc private func openSettings() {
        showSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
    
}
