//
//  QuickCaptureOverlay.swift
//  Constella Horizon
//
//  Created by AI Assistant on 5/15/25.
//

import Cocoa
import Carbon
import SwiftUI
import Combine

/// Manages an always-on-top overlay for quick capture input at the top of the screen
class QuickCaptureOverlay {

    private let overlayWindow: QuickCaptureWindow

    private var targetWindowElement: AXUIElement?
    private var observer: AXObserver?

    static let instance = QuickCaptureOverlay()
    
    private var isFullScreen = false
    
    // Add reference to context manager
    private let contextManager = AIContextManager.shared
    
    init() {
        overlayWindow = QuickCaptureWindow(rect: NSRect(x: 0, y: 0, width: 100, height: 100))
        overlayWindow.level = .floating
        
        // TODO: delete
        // overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // overlayWindow.sharingType = .none
    }

    func start() {
        updateFrame()
        overlayWindow.makeKeyAndOrderFront(nil)
        // Ensure the app is active and the window can receive keyboard input
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow.makeFirstResponder(overlayWindow.contentView)
    }
    
    func stop(){
        if overlayWindow.isVisible{
            overlayWindow.orderOut(nil)
        }
    }
    
    
    func toggle(){
        if overlayWindow.isVisible{
            stop()
        } else {
            // Clear any previous selected text before starting capture
            contextManager.didChangeSelectedText = false
            contextManager.selectedText = ""
            
            // Show the overlay immediately for better UX
            start()
            
            // Capture the current foreground window text and selected text after showing the overlay
            Task {
                // 2. Selected-text context - this will update the contextManager.selectedText
                // which will trigger the onChange in QuickCaptureView
                let selectedText = await AIContextManager.shared.getAllSelectedTextFromOtherApps() ?? ""
                await MainActor.run {
                    self.contextManager.selectedText = selectedText
                    self.contextManager.didChangeSelectedText = true
                }

                
                // 1. OCR context (non-blocking if it fails)
                let results = try await WindowCaptureManager.shared.captureAndProcessText()
                if !results.isEmpty {
                    print("Successfully captured and processed text from foreground window. Found \(results.count) text elements.")
                    let combinedText = results.map { $0.text }.joined(separator: " || ")
                    print("Combined text: \(combinedText)")
                } else {
                    print("No text found in foreground window")
                }

            }
        }
    }
    
    private func updateFrame() {
        DispatchQueue.main.async {
            // 1. Determine current mouse position in global screen coordinates
            let mousePoint = NSEvent.mouseLocation
            
            // 2. Identify the screen containing the mouse (fallback to main)
            let targetScreen = NSScreen.screens.first { NSMouseInRect(mousePoint, $0.frame, false) } ?? NSScreen.main
            
            var x = 0 as CGFloat, y = 0 as CGFloat, w = 721 as CGFloat, h = 80 as CGFloat
            var padding = NSEdgeInsets()
            
            if let screen = targetScreen {
                padding = NSEdgeInsets()
                // Center the overlay horizontally on the screen
                x = screen.frame.minX + (screen.frame.size.width - w) / 2
                y = 80 // Position from t
                w = 721
                // Reduced height for single row layout
                h = 80
                
                // Convert y coordinate to screen-relative coordinates
                y = screen.frame.height - y - h + screen.frame.minY
            }
            
            let origin = CGPoint(
                x: x - padding.left,
                y: y - padding.bottom
            )
            let size = CGSize(
                width: w + padding.left + padding.right,
                height: h + padding.top + padding.bottom
            )
            
            let frame = NSRect(origin: origin, size: size)
            
            if self.overlayWindow.frame != frame {
                self.overlayWindow.setFrame(frame, display: true)
            }
        }
    }
}

// Custom window class for QuickCapture
class QuickCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    
    convenience init(rect: NSRect){
        self.init(
            contentRect: rect,
            styleMask: [.resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        setup(rect: rect)
    }
    
    func setup(rect: NSRect){
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        
        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizingMask = [.width, .height]
        contentView = container
        
        let hosting = NSHostingView(rootView: QuickCaptureView(window: self))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// SwiftUI view for QuickCapture - only shows the search bar
struct QuickCaptureView: View {
    var window: NSWindow
    @State var query = ""
    @FocusState private var isTextFieldFocused: Bool
    @State var observation: NSKeyValueObservation? = nil
    // Observe the context manager for selected text
    @ObservedObject private var contextManager = AIContextManager.shared
    
    // Add environment variable to detect color scheme
    @Environment(\.colorScheme) var colorScheme
    
    // Track if we've already set the initial query
    @State private var hasSetInitialQuery = false
    
    // Add reference to NotesAPI
    private let notesAPI = NotesAPI.shared
    
    // Add state for API operations
    @State private var isCreatingNote = false
    @State private var createNoteError: Error?
    
    // Combine cancellables for this view
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack() {
                    Image(colorScheme == .dark ? "search-status-light" : "search-status")
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                .frame(width: 24, height: 24)
                
                // Replace the static text with an actual TextField
                TextField("Capture a note (p.s. give few words context for better tagging)", text: $query)
                    .font(.inter400Regular(16))
                    .foregroundColor(colorScheme == .dark ? Color.white : Color(red: 0, green: 0, blue: 0))
                    .focused($isTextFieldFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .disabled(isCreatingNote)
                    .onSubmit {
                        // Handle note saving here
                        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedQuery.isEmpty && !isCreatingNote {
                            createNote(title: trimmedQuery)
                        }
                    }
                
                // Move enter icon and "to save note" to the right side of the input
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ZStack() {
                            if isCreatingNote {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image("enter")
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .padding(4)
                    .frame(width: 32, height: 24)
                    .background(Color(red: 1, green: 1, blue: 1).opacity(0.92))
                    .cornerRadius(8)
                    Text(isCreatingNote ? "saving..." : "to save note")
                        .font(.inter400Italic(14))
                        .lineSpacing(22)
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.6) : Color(red: 0, green: 0, blue: 0).opacity(0.22))
                }
            }
            .padding(EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        }
        .frame(width: 721)
        .background(.regularMaterial)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .inset(by: 0.25)
                .stroke(Color(red: 1, green: 0.50, blue: 0), lineWidth: 0.25)
        )
        .background(
            // Fix shadow corners by using a background with rounded corners
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.clear)
                .shadow(
                    color: Color(red: 0, green: 0, blue: 0, opacity: 0.10), 
                    radius: 24, 
                    y: 12
                )
        )
        .onAppear {
            
            observation = self.window.observe(\.isVisible, options: [.new]) { _, change in
                if change.newValue == true {
                    didAppear()
                }
            }
        }
        .onChange(of: contextManager.selectedText) { _, newValue in
            // Update the query when selected text changes
            // Only update if we haven't manually edited the query yet
            query = newValue
            hasSetInitialQuery = true
            
            if window.isVisible{
                isTextFieldFocused = true
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }

        }
        .onChange(of: contextManager.didChangeSelectedText) { _, newValue in
            // Update the query when selected text changes
            // Only update if we haven't manually edited the query yet
            
            if window.isVisible{
                isTextFieldFocused = true
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }

        }
        .onDisappear {
            // Reset the flag when view disappears
            hasSetInitialQuery = false
        }
    }
    
    private func createNote(title: String) {
        // Immediately hide the overlay – we will bring it back only if something goes wrong
        QuickCaptureOverlay.instance.stop()

        isCreatingNote = true
        createNoteError = nil
        
        // Get tenant name from AuthManager
        guard let tenantName = AuthManager.shared.model.tenantName else {
            print("User not authenticated - closing overlay as part of onboarding flow")
            // Reset state and close immediately for onboarding
            isCreatingNote = false
            query = ""
            createNoteError = nil
            // Don't bring the overlay back - just close it
            return
        }

        print("Creating note \(title) with tenant name: \(tenantName)")
        
        notesAPI.createHorizonNote(title: title, tenantName: tenantName)
            .sink(
                receiveCompletion: { completion in
                    isCreatingNote = false
                    switch completion {
                    case .failure(let error):
                        createNoteError = error
                        print("Failed to create note: \(error.localizedDescription)")
                        // Show the overlay again with the user input still intact
                        DispatchQueue.main.async {
                            QuickCaptureOverlay.instance.start()
                        }
                    case .finished:
                        // Success – reset state for the next capture
                        query = ""
                        createNoteError = nil
                        // Overlay is already hidden, but make sure it's closed
                        DispatchQueue.main.async {
                            QuickCaptureOverlay.instance.stop()
                        }
                    }
                },
                receiveValue: { response in
                    print("Successfully created note with ID: \(response.uniqueid)")
                }
            )
            .store(in: &cancellables)
    }
    
    func didAppear(){
        // Reset the flag when view appears
        hasSetInitialQuery = false
        
        // Only clear the query if we are not resurfacing the overlay due to a previous error
        if createNoteError == nil {
            query = ""
        }

        isTextFieldFocused = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)


        // If selected text is already available, use it
        if !contextManager.selectedText.isEmpty {
            query = contextManager.selectedText
            hasSetInitialQuery = true
            
        }
    }
}
