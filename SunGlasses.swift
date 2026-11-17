import AppKit
import os
import Security
import ServiceManagement

let log = Logger(subsystem: "com.josearci.SunGlasses", category: "fold")

// ⌘-drag a menu bar icon onto the sunglasses to put its app inside; ⌘-drag it anywhere else (while unfolded) to take it out.
// macOS 27 draws the menu bar as one window, so the old "stretch a divider off-screen" trick is gone.
// Instead we drive the menu bar's exam-lockdown allow-list (private MenuBarClientCore, same as Hidden Bar 1.11.1):
// apps inside the glasses are left off the list, so macOS hides them.
final class SunGlasses: NSObject, NSApplicationDelegate {
    let glasses = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var assertion: NSObject?  // active restriction; nil = unfolded
    var inside = Set(UserDefaults.standard.stringArray(forKey: "inside") ?? []) {
        didSet { UserDefaults.standard.set(Array(inside), forKey: "inside") }
    }
    var down: (at: CGPoint, glasses: ClosedRange<CGFloat>)?  // where a ⌘-drag started
    var grabbed: String?  // bundle id of the icon being ⌘-dragged
    var synthesizing = false  // our own ⌘-drags, not the user's
    var peeking = false  // folded, but lifted for a moment so Notification Center can open
    let updater = Updater()
    let axQueue = DispatchQueue(label: "SunGlasses.ax")

    func applicationDidFinishLaunching(_ n: Notification) {
        glasses.autosaveName = "SunGlasses"
        glasses.button?.target = self
        glasses.button?.action = #selector(clicked)
        glasses.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        glasses.button?.toolTip = "SunGlasses: click to fold/unfold. ⌘-drag an icon onto the glasses to hide it."
        updateIcon()
        // prompts for Accessibility the first time; needed to see drags and tell which icon is being dragged
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        waitForAccessibility()
        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch { log.error("login item: \(error, privacy: .public)") }
        }
        log.notice("login item status: \(SMAppService.mainApp.status.rawValue)")
        updater.start()
        let ws = NSWorkspace.shared.notificationCenter
        // apps launched while folded aren't on the allow-list yet, so refold to let them show
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [unowned self] _ in
            if assertion != nil { fold() }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [unowned self] _ in
            updateIcon()
        }
        // let the menu bar lay out first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.fold() }
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            if !AXIsProcessTrusted() {
                menu.addItem(withTitle: "⚠︎ Allow Accessibility so drag and drop works…", action: #selector(openAccessibility), keyEquivalent: "").target = self
                menu.addItem(.separator())
            }
            let login = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "SunGlasses \(Updater.version)", action: nil, keyEquivalent: "")
            if let ready = updater.ready {
                menu.addItem(withTitle: "Restart to Update to \(ready.version)", action: #selector(installUpdate), keyEquivalent: "").target = self
            } else if updater.canUpdate {
                menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit SunGlasses", action: #selector(NSApp.terminate), keyEquivalent: "q")
            glasses.menu = menu
            glasses.button?.performClick(nil)
            glasses.menu = nil
            return
        }
        peeking = false
        if assertion == nil {
            fold()
        } else {
            unfold()
        }
    }

    @objc func checkForUpdates() { updater.check() }

    @objc func installUpdate() {
        unfold()  // the restriction dies with this process anyway; drop it cleanly before relaunching
        updater.installAndRelaunch()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            log.error("login item: \(error, privacy: .public)")
        }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // Global mouse monitors see nothing until Accessibility is granted, so start watching once it is.
    func waitForAccessibility() {
        guard AXIsProcessTrusted() else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForAccessibility() }
        }
        log.notice("Accessibility granted, watching drags")
        watchDrags()
    }

    func unfold() {
        assertion?.perform(NSSelectorFromString("invalidate"))
        assertion = nil
        updateIcon()
        // no tucking here: it would grab the mouse just as the user goes to ⌘-drag an icon out
    }

    func fold() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        restrict(allowing: Array(running.subtracting(inside).union([Bundle.main.bundleIdentifier!])))
    }

    // MARK: drag and drop

    func watchDrags() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [unowned self] e in
            guard !synthesizing else { return }
            let m = Self.barPoint(NSEvent.mouseLocation)
            if e.type == .leftMouseDown {
                guard e.modifierFlags.contains(.command), let m, m.y < 40, let g = glassesSpan() else { return }
                down = (m, g)
                grabbed = nil
                let screens = NSScreen.screens.map(\.frame)
                let hidden = assertion != nil ? inside : []
                axQueue.async {
                    let id = Self.app(atBarX: m.x, screens: screens, skipping: hidden)?.bundleIdentifier
                    DispatchQueue.main.async { self.grabbed = id }
                }
            } else if let d = down {
                down = nil
                let g = glassesSpan()
                // queued behind the lookup started on mouse-down, so `grabbed` is set by then
                axQueue.async { DispatchQueue.main.async { self.dropped(at: m, from: d, glassesNow: g) } }
            } else if assertion != nil, let p = e.cgEvent?.location {
                axQueue.async {
                    guard Self.isClock(at: p) else { return }
                    DispatchQueue.main.async { self.peek(clickingAt: p) }
                }
            }
        }
    }

    // Exam lockdown also locks Notification Center, so clicking the clock does nothing while folded.
    // It only stops it opening, though: lift the restriction, pass the click on, and fold again straight after.
    func peek(clickingAt p: CGPoint) {
        guard assertion != nil else { return }
        assertion?.perform(NSSelectorFromString("invalidate"))
        assertion = nil
        peeking = true
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        // ponytail: fixed delay, measured on macOS 27 (50 ms sometimes too short, 150 ms always enough);
        // wait for Notification Center's window instead if a slower Mac needs it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            guard peeking else { return }  // the glasses were clicked meanwhile
            peeking = false
            fold()
        }
    }

    static func isClock(at p: CGPoint) -> Bool {
        var hit: AXUIElement?, id: CFTypeRef?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, let hit,
              AXUIElementCopyAttributeValue(hit, kAXIdentifierAttribute as CFString, &id) == .success
        else { return false }
        return id as? String == "com.apple.menuextra.clock"
    }

    func dropped(at m: CGPoint?, from d: (at: CGPoint, glasses: ClosedRange<CGFloat>), glassesNow: ClosedRange<CGFloat>?) {
        guard let id = grabbed else { return log.notice("⌘-drag: no app icon under the pointer") }
        grabbed = nil
        // macOS slides icons aside while you drag, so where the glasses were before or after both count
        let onGlasses = m.map { m in m.y < 40 && [d.glasses, glassesNow].contains { $0.map { $0.lowerBound - 4 ... $0.upperBound + 4 ~= m.x } ?? false } } ?? false
        if onGlasses {
            inside.insert(id)
            log.notice("put \(id, privacy: .public) inside")
            return tuck([id]) { [unowned self] in if assertion != nil { fold() } else { updateIcon() } }
        } else if m.map({ hypot($0.x - d.at.x, $0.y - d.at.y) > 5 }) ?? true, inside.remove(id) != nil {
            log.notice("took \(id, privacy: .public) out")
        } else {
            return
        }
        if assertion != nil { fold() } else { updateIcon() }
    }

    // Every display shows the same right-aligned icons, but AX reports an app's icons on whichever display
    // it last drew them. So positions are compared as distance from the screen's right edge (x) and top (y).
    static func barPoint(_ p: CGPoint, screens: [CGRect] = NSScreen.screens.map(\.frame)) -> CGPoint? {
        guard let s = screens.first(where: { $0.insetBy(dx: 0, dy: -4).contains(p) }) else { return nil }
        return CGPoint(x: s.maxX - p.x, y: s.maxY - p.y)
    }

    func glassesSpan() -> ClosedRange<CGFloat>? {
        guard let f = glasses.button?.window?.frame, let r = Self.barPoint(CGPoint(x: f.maxX - 1, y: f.midY)) else { return nil }
        return r.x ... r.x + f.width
    }

    // The app owning the menu bar icon at this distance from the right edge.
    // Hidden apps keep reporting where their icons last were, on top of the visible ones there now, so skip them.
    static func app(atBarX x: CGFloat, screens: [CGRect], skipping hidden: Set<String>) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy != .prohibited, let id = app.bundleIdentifier, !hidden.contains(id), app.processIdentifier != getpid(),
                  app.bundleURL?.path.hasPrefix("/System/") == false  // clock, wifi, control center always stay
            else { return false }
            return iconSpans(of: app, screens: screens).contains { $0 ~= x }
        }
    }

    // An app's menu bar icons, as ranges of distance from the right edge.
    static func iconSpans(of app: NSRunningApplication, screens: [CGRect]) -> [ClosedRange<CGFloat>] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.1)  // hung apps must not stall the drag
        var bar: CFTypeRef?, kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success,
              AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success
        else { return [] }
        return ((kids as? [AXUIElement]) ?? []).compactMap { item in
            var pv: CFTypeRef?, sv: CFTypeRef?
            var p = CGPoint.zero, size = CGSize.zero
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pv) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sv) == .success,
                  AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &size),
                  // AX is top-left origin on the primary screen; flip into Cocoa space
                  let r = barPoint(CGPoint(x: p.x + size.width - 1, y: screens[0].maxY - p.y - 1), screens: screens)
            else { return nil }
            return r.x ... r.x + size.width
        }
    }

    // macOS drops an icon on whichever side of the glasses you let go. Move any that land on the right
    // over to the left, so everything inside expands out of the same side when unfolded.
    func tuck(_ ids: [String], then done: @escaping () -> Void) {
        let screens = NSScreen.screens.map(\.frame)
        let apps = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard !apps.isEmpty, !synthesizing,
              let s = screens.first(where: { $0.insetBy(dx: 0, dy: -4).contains(NSEvent.mouseLocation) })  // the bar the mouse is on
        else { return done() }
        synthesizing = true
        axQueue.asyncAfter(deadline: .now() + 0.4) { [unowned self] in  // let macOS finish placing the icons
            let y = screens[0].maxY - s.maxY + 12  // CG coords: middle of this screen's menu bar
            for app in apps {
                for _ in 0..<3 {  // an app can have a few icons; re-read after each move since the bar reflows
                    guard let g = DispatchQueue.main.sync(execute: { glassesSpan() }),
                          let icon = Self.iconSpans(of: app, screens: screens).first(where: { $0.upperBound <= g.lowerBound + 2 })
                    else { break }
                    log.notice("moving \(app.localizedName ?? "?", privacy: .public) to the left of the glasses")
                    // drop just inside the glasses' left edge: macOS inserts it on their left
                    Self.cmdDrag(from: CGPoint(x: s.maxX - (icon.lowerBound + icon.upperBound) / 2, y: y),
                                 to: CGPoint(x: s.maxX - g.upperBound + 4, y: y))
                }
            }
            DispatchQueue.main.async { self.synthesizing = false; done() }
        }
    }

    static func cmdDrag(from: CGPoint, to: CGPoint) {
        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        let cursor = CGEvent(source: nil)?.location
        post(.mouseMoved, from); usleep(100_000)
        post(.leftMouseDown, from); usleep(250_000)
        for i in 1...10 {
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * CGFloat(i) / 10, y: from.y)); usleep(40_000)
        }
        usleep(300_000)
        post(.leftMouseUp, to); usleep(300_000)
        if let cursor { CGWarpMouseCursorPosition(cursor) }
    }

    // MARK: hiding

    func restrict(allowing bundleIDs: [String]) {
        dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
        guard let configClass = NSClassFromString("MBAssessmentModeConfiguration"),
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")  // RTLD_DEFAULT
        else { return log.error("MenuBarClientCore unavailable, staying unfolded") }
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
        typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void
        // system items are numeric ids (2 clock, 5 sound, 6 wifi, 8 control center...); allow them all
        let systemItems = (0..<64).map { NSNumber(value: $0) } as NSArray
        guard let config = unsafeBitCast(msgSend, to: Init.self)(
            class_createInstance(configClass, 0) as AnyObject,
            NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"), systemItems, bundleIDs as NSArray)
        else { return }
        let next = assertionClass.init()
        unsafeBitCast(msgSend, to: Activate.self)(next, NSSelectorFromString("activateWithConfiguration:completionHandler:"), config) { error in
            DispatchQueue.main.async {
                if let error { return log.error("fold failed: \(error, privacy: .public)") }
                // new restriction is up before the old one drops, so nothing flashes
                self.assertion?.perform(NSSelectorFromString("invalidate"))
                self.assertion = next
                self.updateIcon()
            }
        }
    }

    // Solid lenses while icons are tucked away; clear lenses when unfolded or nothing inside.
    func updateIcon() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        glasses.button?.image = Self.icon(dark: assertion != nil && !inside.isDisjoint(with: running))
    }

    static func icon(dark: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 14), flipped: false) { _ in
            // two rounded lenses joined by a bridge; no arms, they don't read at menu bar size
            let lenses = [NSRect(x: 0.75, y: 2.75, width: 9, height: 8.5), NSRect(x: 12.25, y: 2.75, width: 9, height: 8.5)]
                .map { NSBezierPath(roundedRect: $0, xRadius: 3, yRadius: 3) }
            let bridge = NSBezierPath()
            bridge.lineWidth = 1.5
            bridge.move(to: NSPoint(x: 9.5, y: 8))
            bridge.curve(to: NSPoint(x: 12.5, y: 8), controlPoint1: NSPoint(x: 10.25, y: 10.25), controlPoint2: NSPoint(x: 11.75, y: 10.25))
            NSColor.black.set()
            bridge.stroke()
            for lens in lenses {
                if dark {
                    lens.fill()
                } else {
                    NSColor.black.withAlphaComponent(0.18).set()  // faint tint so the clear lenses read as glass
                    lens.fill()
                    NSColor.black.set()
                    lens.lineWidth = 1.5
                    lens.stroke()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// Keeps SunGlasses current: checks the GitHub repo's latest release (at launch and every 6 hours), downloads
// a newer one in the background, and installs it when the user picks Restart to Update. The only thing sent
// anywhere is a plain GET of the public release info.
final class Updater {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static let repo = Bundle.main.object(forInfoDictionaryKey: "SunGlassesUpdateRepo") as? String
    var canUpdate: Bool { Self.repo != nil }
    private(set) var ready: (version: String, app: URL)?
    private var checking = false

    func start() {
        guard canUpdate else { return }
        check()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard let repo = Self.repo, ready == nil, !checking,
              let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                ready = try await fetchNewer(from: api)
                if let ready { log.notice("update \(ready.version, privacy: .public) is ready to install") }
            } catch {
                log.notice("update check: \(error, privacy: .public)")  // offline or rate-limited: try again later, quietly
            }
        }
    }

    // Releases are tagged v1.0.<build> by the release workflow and carry a SunGlasses.zip asset.
    private func fetchNewer(from api: URL) async throws -> (version: String, app: URL)? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = String(release.tag_name.drop(while: { $0 == "v" }))
        guard release.draft != true, release.prerelease != true,
              let build = version.split(separator: ".").last.flatMap({ Int($0) }), build > Self.build,
              let asset = release.assets.first(where: { $0.name == "SunGlasses.zip" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com"
        else { return nil }
        let (zip, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SunGlasses-update-\(build)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = folder.appendingPathComponent("SunGlasses.app")
        guard unzip.terminationStatus == 0, Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              Self.carriesOurSignature(app)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (version, app)
    }

    // The downloaded app must satisfy this app's designated requirement, i.e. be signed with the same
    // certificate: a different one would break the Accessibility grant, and it's not our build.
    static func carriesOurSignature(_ app: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs
        else { return false }
        return SecStaticCodeCheckValidity(theirs, [], requirement) == errSecSuccess
    }

    // Swaps the installed app for the downloaded one and relaunches.
    func installAndRelaunch() {
        guard let ready else { return }
        let installed = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: ready.app)
        } catch {
            return log.error("couldn't replace \(installed.path, privacy: .public): \(error, privacy: .public)")
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", installed.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = SunGlasses()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
