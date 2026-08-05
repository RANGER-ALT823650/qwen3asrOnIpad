#if DEBUG
import SwiftUI

struct KeyboardCanvasPreview: PreviewProvider {
    static var previews: some View {
        KeyboardView()
            .frame(width: 1024, height: 300)
            .previewLayout(.fixed(width: 1024, height: 300))
            .previewDisplayName("iPad Keyboard")
    }
}
#endif
