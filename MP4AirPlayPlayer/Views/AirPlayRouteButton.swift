import AVKit
import SwiftUI

struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .systemBlue
        view.activeTintColor = .systemGreen
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

