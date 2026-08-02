import SwiftUI

struct BeadsSetupAdvisoryBanner: View {
    let findings: [BeadsSetupFinding]
    let openSetup: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beads setup needs attention")
                    .font(.callout.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Review Setup", action: openSetup)
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Dismiss until the findings change")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        if findings.count == 1 { return findings[0].title }
        return "\(findings.count) differences were found from this checkout's intended setup."
    }
}
