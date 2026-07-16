import SwiftUI

struct LabsBadge: View {
    static let message = "This is under active development and testing and may change before stable release."

    var body: some View {
        Text("Labs")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.warningAmber)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.warningAmber.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignSystem.Colors.warningAmber.opacity(0.28), lineWidth: 0.5)
            )
            .fixedSize()
            .help(Self.message)
            .accessibilityLabel("Labs")
            .accessibilityHint(Self.message)
    }
}

struct LabsNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            LabsBadge()

            Text(LabsBadge.message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
