import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.22, green: 0.37, blue: 0.30)
    static let ink = Color(red: 0.16, green: 0.20, blue: 0.18)
    static let secondary = Color(red: 0.43, green: 0.46, blue: 0.42)
    static let background = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let sidebar = Color(red: 0.92, green: 0.93, blue: 0.89)
}

struct ShareFile: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension PaperStyle {
    var symbol: String {
        switch self {
        case .blank: return "rectangle"
        case .ruled: return "line.3.horizontal"
        case .grid: return "square.grid.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }
}
