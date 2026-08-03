import UIKit
import SwiftUI

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

    override func textWillChange(_ textInput: UITextInput?) {
        // Called when text is about to change
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        // Called when text has changed
    }
}
