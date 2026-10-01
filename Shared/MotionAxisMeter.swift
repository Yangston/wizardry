import SwiftUI

/// A signed angle around the ready pose, with zero fixed at the centre.
struct MotionAxisMeter: View {
    let title: String
    let degrees: Double
    var tint: Color = .purple
    var body: some View {
        HStack(spacing:8) {
            Text(title).font(.caption2).frame(width:38,alignment:.leading)
            GeometryReader { geometry in
                let fraction = min(1,max(-1,degrees/180))
                let half = geometry.size.width/2
                ZStack(alignment:.leading) {
                    Capsule().fill(.gray.opacity(0.2))
                    Rectangle().fill(tint).frame(width:max(1,abs(fraction)*half))
                        .offset(x:fraction < 0 ? half+fraction*half : half)
                    Rectangle().fill(.secondary).frame(width:1).offset(x:half)
                }.clipShape(Capsule())
            }.frame(height:6)
            Text(String(format:"%+.0f°",degrees)).font(.caption2.monospacedDigit())
                .frame(width:44,alignment:.trailing)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format:"%+.0f degrees from ready pose",degrees))
    }
}
