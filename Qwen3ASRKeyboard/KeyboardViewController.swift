import UIKit
import SwiftUI

/// Private, sideload-only bridge from a keyboard extension to its containing
/// app. `NSExtensionContext.open` is intentionally unavailable to the custom
/// keyboard extension point, so the public API cannot start this hand-off.
///
/// This must never be treated as an App Store-supported keyboard capability.
/// iOS 27 routes the three-argument selector through the keyboard's UIScene,
/// so the options argument must be a UIScene.OpenExternalURLOptions object.
/// Passing UIApplication's dictionary crashes with `universalLinksOnly` sent
/// to NSDictionary, which is confirmed by the physical-device crash logs.
extension UIInputViewController {
    /// Custom keyboards have no supported API for opening their container app,
    /// so this bridge is deliberately limited to sideloaded builds. If the
    /// scene request is rejected, fall back to the older responder selector.
    func openContainingApp(at url: URL, completion: @escaping (Bool) -> Void) {
        guard let scene = view.window?.windowScene ?? responderScene() else {
            completion(invokeLegacyOpenURL(url))
            return
        }

        let options = UIScene.OpenExternalURLOptions()
        scene.open(url, options: options) { [weak self] didOpen in
            if didOpen {
                completion(true)
            } else {
                completion(self?.invokeLegacyOpenURL(url) ?? false)
            }
        }
    }

    private func responderScene() -> UIScene? {
        var responder: UIResponder? = self
        while let current = responder {
            if let scene = current as? UIScene {
                return scene
            }
            responder = current.next
        }
        return nil
    }

    /// Older iOS keyboard hosts expose only `openURL:` on the responder
    /// chain. Its Objective-C return type is BOOL, so call the IMP with the
    /// matching ABI instead of using `perform`, which assumes an object result.
    private func invokeLegacyOpenURL(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector), let implementation = current.method(for: selector) {
                typealias OpenURLImplementation = @convention(c) (
                    AnyObject,
                    Selector,
                    NSURL
                ) -> Bool

                let openURL = unsafeBitCast(implementation, to: OpenURLImplementation.self)
                return openURL(current, selector, url as NSURL)
            }
            responder = current.next
        }

        return false
    }
}

class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupKeyboardView()
    }
    
    private func setupKeyboardView() {
        let keyboardView = KeyboardView(controller: self)
        let hostingController = UIHostingController(rootView: keyboardView)
        self.hostingController = hostingController
        
        addChild(hostingController)
        view.addSubview(hostingController.view)
        
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        hostingController.didMove(toParent: self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    /// This keyboard supplies its own dictation control. Tell iOS not to add
    /// a second system-dictation key below the keyboard on supported devices.
    override var hasDictationKey: Bool {
        get { true }
        set { }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        // Called when text is about to change
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        // Called when text has changed
    }
}
