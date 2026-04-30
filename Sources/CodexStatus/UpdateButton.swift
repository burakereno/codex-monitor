import AppKit
import SwiftUI

struct UpdateButton: View {
    let version: String
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        Button {
            updater.downloadAndInstall()
        } label: {
            HStack(spacing: 4) {
                if updater.isDownloading {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10, weight: .semibold))

                    Text("\(Int(updater.downloadProgress * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10, weight: .semibold))

                    Text("Update \(version)")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green)
            }
        }
        .buttonStyle(.plain)
        .disabled(updater.isDownloading)
        .onHover { hovering in
            if hovering && !updater.isDownloading { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .help(updater.isDownloading ? "Downloading update" : "Download Codex Monitor \(version)")
    }
}
