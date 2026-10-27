import UIKit
import Flutter
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private static let destinationBookmarkKey = "destinationFolderBookmark"

  private var pendingPickResult: FlutterResult?
  private var directoryPicker: UIDocumentPickerViewController?
  private var accessedDirectoryUrl: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Resume access to the user chosen receive folder before anything is written.
    restoreDestinationFolderAccess()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let channel = FlutterMethodChannel(
        name: "ios-delegate-channel",
        binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard let self = self else {
          result(FlutterMethodNotImplemented)
          return
        }
        switch call.method {
        case "isReduceMotionEnabled":
          result(UIAccessibility.isReduceMotionEnabled)
        case "pickDirectory":
          self.presentDirectoryPicker(result: result)
        case "persistDestinationFolderAccess":
          if let path = call.arguments as? String, !path.isEmpty {
            self.storeBookmark(for: URL(fileURLWithPath: path))
            result(true)
          } else {
            result(false)
          }
        case "removeDestinationFolderAccess":
          self.clearBookmark()
          result(true)
        case "hasDestinationFolderAccess":
          result(UserDefaults.standard.data(forKey: AppDelegate.destinationBookmarkKey) != nil)
        default:
          result(FlutterMethodNotImplemented)
        }
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - Folder picker

  private func topViewController() -> UIViewController? {
    let window = self.window
      ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })
      ?? UIApplication.shared.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private func presentDirectoryPicker(result: @escaping FlutterResult) {
    guard pendingPickResult == nil else {
      // Only one picker at a time.
      result(nil)
      return
    }
    guard let root = topViewController() else {
      result(nil)
      return
    }
    pendingPickResult = result

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    directoryPicker = picker
    root.present(picker, animated: true, completion: nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pendingPickResult
    pendingPickResult = nil
    directoryPicker = nil
    guard let url = urls.first else {
      result?(nil)
      return
    }
    _ = url.startAccessingSecurityScopedResource()
    accessedDirectoryUrl?.stopAccessingSecurityScopedResource()
    accessedDirectoryUrl = url
    result?(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingPickResult
    pendingPickResult = nil
    directoryPicker = nil
    result?(nil)
  }

  // MARK: - Security scoped bookmark
  // iOS has no `.withSecurityScope` bookmark option (that is macOS only),
  // `.minimalBookmark` plus startAccessingSecurityScopedResource() is the way.

  private func storeBookmark(for url: URL) {
    _ = url.startAccessingSecurityScopedResource()
    accessedDirectoryUrl?.stopAccessingSecurityScopedResource()
    accessedDirectoryUrl = url
    do {
      let data = try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(data, forKey: AppDelegate.destinationBookmarkKey)
    } catch {
      UserDefaults.standard.removeObject(forKey: AppDelegate.destinationBookmarkKey)
    }
  }

  private func clearBookmark() {
    UserDefaults.standard.removeObject(forKey: AppDelegate.destinationBookmarkKey)
    accessedDirectoryUrl?.stopAccessingSecurityScopedResource()
    accessedDirectoryUrl = nil
  }

  private func restoreDestinationFolderAccess() {
    guard let data = UserDefaults.standard.data(forKey: AppDelegate.destinationBookmarkKey) else {
      return
    }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      _ = url.startAccessingSecurityScopedResource()
      accessedDirectoryUrl = url
      if isStale,
         let refreshed = try? url.bookmarkData(
           options: .minimalBookmark,
           includingResourceValuesForKeys: nil,
           relativeTo: nil
         ) {
        UserDefaults.standard.set(refreshed, forKey: AppDelegate.destinationBookmarkKey)
      }
    } catch {
      UserDefaults.standard.removeObject(forKey: AppDelegate.destinationBookmarkKey)
    }
  }
}
