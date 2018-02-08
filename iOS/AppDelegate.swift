//
//  AppDelegate.swift
//  WikiMed
//
//  Created by Chris Li on 9/6/17.
//  Copyright © 2017 Chris Li. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, DirectoryMonitorDelegate {
    var window: UIWindow?
    let monitor = DirectoryMonitor(url: URL.documentDirectory)
    
    func applicationDidFinishLaunching(_ application: UIApplication) {
        Network.shared.restorePreviousState()
        URLProtocol.registerClass(KiwixURLProtocol.self)
        monitor.delegate = self
        Queue.shared.add(scanProcedure: ScanProcedure(url: URL.documentDirectory))
        monitor.start()
        Preference.upgrade()
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        updateShortcutItems(application: application)
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        Queue.shared.add(scanProcedure: ScanProcedure(url: URL.documentDirectory))
        monitor.start()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        monitor.stop()
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        let context = CoreDataContainer.shared.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print(error)
            }
        }
    }
    
    // MARK: - URL Handling
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey : Any] = [:]) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("kiwix") == .orderedSame else {return false}
        guard let rootNavigationController = window?.rootViewController as? UINavigationController,
            let mainController = rootNavigationController.topViewController as? MainController else {return false}
        mainController.presentedViewController?.dismiss(animated: false)
        mainController.load(url: url)
        return true
    }
    
    // MARK: - State Restoration
    
    func application(_ application: UIApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        return true
    }
    
    func application(_ application: UIApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        return true
    }
    
    // MARK: - Directory Monitoring
    
    func directoryContentDidChange(url: URL) {
        Queue.shared.add(scanProcedure: ScanProcedure(url: url))
    }
    
    // MARK: - Background
    
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Network.shared.backgroundEventsCompleteProcessing = completionHandler
    }
    
    // MARK: - Home Screen Quick Actions
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let rootNavigationController = window?.rootViewController as? UINavigationController,
            let mainController = rootNavigationController.topViewController as? MainController,
            let shortcutItemType = ShortcutItemType(rawValue: shortcutItem.type) else { completionHandler(false); return }
        switch shortcutItemType {
        case .search:
            break
        case .bookmark:
            mainController.presentedViewController?.dismiss(animated: false)
            mainController.presentBookmarkController(animated: false)
        case .continueReading:
            break
        }
        completionHandler(true)
    }
    
    private func updateShortcutItems(application: UIApplication) {
        let bookmark = UIApplicationShortcutItem(type: ShortcutItemType.bookmark.rawValue, localizedTitle: NSLocalizedString("Bookmark", comment: "3D Touch Menu Title"))
        let search = UIApplicationShortcutItem(type: ShortcutItemType.search.rawValue, localizedTitle: NSLocalizedString("Search", comment: "3D Touch Menu Title"))
        var shortcutItems = [bookmark, search]
        
        if let rootNavigationController = window?.rootViewController as? UINavigationController,
            let mainController = rootNavigationController.topViewController as? MainController,
            let title = mainController.currentWebController?.currentTitle, let url = mainController.currentWebController?.currentURL {
            shortcutItems.append(UIApplicationShortcutItem(type: ShortcutItemType.continueReading.rawValue,
                                                           localizedTitle: title , localizedSubtitle: NSLocalizedString("Continue Reading", comment: "3D Touch Menu Title"),
                                                           icon: nil, userInfo: ["URL": url.absoluteString]))
        }
        application.shortcutItems = shortcutItems
    }
}

enum ShortcutItemType: String {
    case search, bookmark, continueReading
}

fileprivate extension URL {
    static let documentDirectory = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
}
