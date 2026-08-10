import CoreImage.CIFilterBuiltins
import SwiftUI

struct TojQRCode: View {
    let value: String
    var size: CGFloat = 180

    var body: some View {
        Group {
            if let image = Self.image(for: value) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("QR code")
        .accessibilityValue(value)
    }

    nonisolated private static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let transformed = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
