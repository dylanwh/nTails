import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let urlString: String
    private let context = CIContext()

    var body: some View {
        if let image = generateQRCode(from: urlString) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        } else {
            ContentUnavailableView {
                Label("Unable to generate QR code", systemImage: "qrcode")
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: outputImage.extent.width, height: outputImage.extent.height))
    }
}

#Preview {
    QRCodeView(urlString: "https://login.tailscale.com/a/sample-code-preview")
        .frame(width: 220, height: 220)
        .padding()
}
