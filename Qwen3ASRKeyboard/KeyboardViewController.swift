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
    /// so this bridge is deliberately limited to sideloaded builds. Prefer the
    /// responder-chain hand-off used by the original keyboard flow because it
    /// preserves the originating app's return stack more reliably. The scene
    /// request remains a fallback for newer hosts that hide `openURL:`.
    func openContainingApp(at url: URL, completion: @escaping (Bool) -> Void) {
        if invokeLegacyOpenURL(url) {
            completion(true)
            return
        }

        guard let scene = view.window?.windowScene ?? responderScene() else {
            completion(false)
            return
        }

        let options = UIScene.OpenExternalURLOptions()
        scene.open(url, options: options) { didOpen in
            completion(didOpen)
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
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private(set) var isKeyboardVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()

        installNormalKeyboardHeight()
        setupKeyboardView()
    }
    
    private func setupKeyboardView() {
        let keyboardView = KeyboardView(controller: self)
        let hostingController = UIHostingController(rootView: keyboardView)
        hostingController.view.backgroundColor = .clear
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isKeyboardVisible = true
        updateNormalKeyboardHeight()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isKeyboardVisible = false
        super.viewWillDisappear(animated)
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateNormalKeyboardHeight()
        }
    }

    /// The previous intrinsic SwiftUI height collapsed the input view to a
    /// short toolbar. Reserve a system-keyboard-sized surface so recording
    /// progress and multi-line diagnostics remain readable.
    private func installNormalKeyboardHeight() {
        let constraint = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        keyboardHeightConstraint = constraint
    }

    private func updateNormalKeyboardHeight() {
        let height = preferredKeyboardHeight
        guard keyboardHeightConstraint?.constant != height else { return }
        keyboardHeightConstraint?.constant = height
        view.setNeedsLayout()
    }

    private var preferredKeyboardHeight: CGFloat {
        if traitCollection.userInterfaceIdiom == .pad {
            return 300
        }
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape == true
        return isLandscape ? 200 : 260
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
