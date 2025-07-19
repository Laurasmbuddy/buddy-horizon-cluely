//
//  AuthManager.swift
//  Constella Horizon
//
//  Created by AI Assistant on 5/15/25.
//

import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let authStatusChanged = Notification.Name("AuthStatusChanged")
    static let authCallbackReceived = Notification.Name("AuthCallbackReceived")
}

class AuthModel: ObservableObject {
    @Published var currentAuth: Auth?
    @AppStorage("SavedAuthData") private var savedAuthData: Data = Data()
    
    var isAuthenticated: Bool {
        return currentAuth?.isValidAuthentication ?? false
    }
    
    var tenantName: String? {
        return currentAuth?.tenantName
    }
    
    var email: String? {
        return currentAuth?.email
    }
    
    init() {
        loadSavedAuth()
    }
    
    func setAuth(_ auth: Auth) {
        currentAuth = auth
        saveAuth()
        NotificationCenter.default.post(name: .authStatusChanged, object: auth)
    }
    
    func clearAuth() {
        currentAuth = nil
        saveAuth()
        NotificationCenter.default.post(name: .authStatusChanged, object: nil)
    }
    
    private func saveAuth() {
        do {
            let data = try JSONEncoder().encode(currentAuth)
            savedAuthData = data
        } catch {
            print("Failed to save auth data: \(error)")
        }
    }
    
    private func loadSavedAuth() {
        guard !savedAuthData.isEmpty else { return }
        
        do {
            let auth = try JSONDecoder().decode(Auth.self, from: savedAuthData)
            print("Loaded auth data: \(auth)")

            // Only set if not expired
            if auth.isValidAuthentication {
                currentAuth = auth
            } else {
                // Clear expired auth
                clearAuth()
            }
        } catch {
            print("Failed to load saved auth data: \(error)")
            // Clear corrupted data
            savedAuthData = Data()
        }
    }
}

class AuthManager: NSObject {
    
    let model = AuthModel()
    
    static let shared = AuthManager()
    
    private var authCallbackServer: AuthCallbackServer?
    
    override init() {
        super.init()
        setupURLSchemeHandling()
    }
    
    // MARK: - Authentication Flow
    
    func startAuthFlow() {
        // Build the callback URL using the custom scheme that the app is registered for.
        // The web application will invoke this URL once authentication is complete.
        let callbackURL = "constellahorizon://open"
        let encodedCallback = callbackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let authURL = "https://onhorizon.ai/auth?fromHorizon=true&callback=\(encodedCallback)"
        
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    func handleAuthCallback(tenantName: String, email: String, authToken: String? = nil) {
        let auth = Auth(
            tenantName: tenantName,
            email: email,
            authToken: authToken,
            isAuthenticated: true,
            expiresAt: authToken != nil ? Date().addingTimeInterval(86400 * 30) : nil // 30 days if token provided
        )
        
        DispatchQueue.main.async {
            self.model.setAuth(auth)
            NotificationCenter.default.post(name: .authCallbackReceived, object: auth)
        }
        
        // Stop callback server
        stopCallbackServer()
    }
    
    func logout() {
        model.clearAuth()
        stopCallbackServer()
    }
    
    // MARK: - Callback Server
    
    private func startCallbackServer() {
        authCallbackServer = AuthCallbackServer { [weak self] tenantName, email, authToken in
            self?.handleAuthCallback(tenantName: tenantName, email: email, authToken: authToken)
        }
        authCallbackServer?.start()
    }
    
    private func stopCallbackServer() {
        authCallbackServer?.stop()
        authCallbackServer = nil
    }
    
    // MARK: - URL Scheme Handling (Alternative method)
    
    private func setupURLSchemeHandling() {
        // Register for URL events if using custom URL scheme
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        
        // Handle constellahorizon:// URL scheme
        if url.scheme == "constellahorizon" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            
            var tenantName = ""
            var email = ""
            var authToken: String? = nil
            
            for item in queryItems {
                switch item.name {
                case "tenant_name":
                    tenantName = item.value ?? ""
                case "email":
                    email = item.value ?? ""
                case "auth_token":
                    authToken = item.value
                default:
                    break
                }
            }
            
            if !tenantName.isEmpty && !email.isEmpty {
                handleAuthCallback(tenantName: tenantName, email: email, authToken: authToken)
            }
        }
    }
}

// MARK: - Simple HTTP Callback Server

class AuthCallbackServer {
    private var task: Process?
    private let onAuthReceived: (String, String, String?) -> Void
    
    init(onAuthReceived: @escaping (String, String, String?) -> Void) {
        self.onAuthReceived = onAuthReceived
    }
    
    func start() {
        // Start a simple Python HTTP server to handle the callback
        let script = """
        import http.server
        import socketserver
        import urllib.parse
        import json
        import sys
        
        class AuthCallbackHandler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith('/auth/callback'):
                    # Parse query parameters
                    parsed_url = urllib.parse.urlparse(self.path)
                    params = urllib.parse.parse_qs(parsed_url.query)
                    
                    tenant_name = params.get('tenant_name', [''])[0]
                    email = params.get('email', [''])[0]
                    auth_token = params.get('auth_token', [None])[0]
                    
                    # Send success response
                    self.send_response(200)
                    self.send_header('Content-type', 'text/html')
                    self.end_headers()
                    
                    success_html = '''
                    <html>
                    <head><title>Authentication Successful</title></head>
                    <body style="font-family: Arial, sans-serif; text-align: center; padding: 50px;">
                        <h1>✅ Authentication Successful!</h1>
                        <p>You can now close this window and return to Constella Horizon.</p>
                        <script>
                            setTimeout(function() { window.close(); }, 3000);
                        </script>
                    </body>
                    </html>
                    '''
                    self.wfile.write(success_html.encode())
                    
                    # Output auth data to stdout for the app to read
                    if tenant_name and email:
                        auth_data = {
                            'tenant_name': tenant_name,
                            'email': email,
                            'auth_token': auth_token
                        }
                        print(f"AUTH_CALLBACK:{json.dumps(auth_data)}")
                        sys.stdout.flush()
                    
                    # Shutdown server after handling the callback
                    import threading
                    def shutdown():
                        import time
                        time.sleep(1)
                        httpd.shutdown()
                    threading.Thread(target=shutdown).start()
                    
                else:
                    self.send_response(404)
                    self.end_headers()
        
        PORT = 3749
        httpd = socketserver.TCPServer(("", PORT), AuthCallbackHandler)
        print(f"AUTH_SERVER_STARTED:http://localhost:{PORT}")
        sys.stdout.flush()
        httpd.serve_forever()
        """
        
        let process = Process()
        process.launchPath = "/usr/bin/python3"
        process.arguments = ["-c", script]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            let output = String(data: data, encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: .newlines)
            
            for line in lines {
                if line.hasPrefix("AUTH_CALLBACK:") {
                    let jsonString = String(line.dropFirst("AUTH_CALLBACK:".count))
                    if let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tenantName = json["tenant_name"] as? String,
                       let email = json["email"] as? String {
                        let authToken = json["auth_token"] as? String
                        DispatchQueue.main.async {
                            self.onAuthReceived(tenantName, email, authToken)
                        }
                    }
                }
            }
        }
        
        process.launch()
        self.task = process
    }
    
    func stop() {
        task?.terminate()
        task = nil
    }
} 