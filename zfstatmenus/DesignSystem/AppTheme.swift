import AppKit
import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.16, green: 0.42, blue: 0.78)
    static let accentSoft = accent.opacity(0.12)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = canvas
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.085)
    static let subtleFill = Color.primary.opacity(0.045)
    static let mutedText = Color.secondary
    static let success = Color(red: 0.18, green: 0.58, blue: 0.34)
    static let warning = Color(red: 0.86, green: 0.52, blue: 0.12)
    static let danger = Color(red: 0.78, green: 0.25, blue: 0.25)

    static let panelRadius: CGFloat = 14
    static let innerRadius: CGFloat = 9
    static let pagePadding: CGFloat = 24
    static let tokenPopoverWidth: CGFloat = 800
    static let tokenPopoverHeight: CGFloat = 640
    static let detailPopoverWidth = tokenPopoverWidth * (2.0 / 3.0)
    static let detailPopoverHeight = tokenPopoverHeight
}

struct AppPanelModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous)
                    .fill(AppTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 10, y: 3)
    }
}

extension View {
    func appPanel(padding: CGFloat = 14) -> some View {
        modifier(AppPanelModifier(padding: padding))
    }

    func tabularNumbers() -> some View {
        fontDesign(.monospaced)
    }

    func appPopoverScrolling() -> some View {
        scrollIndicators(.hidden)
    }
}

struct AppSectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AppIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? AppTheme.accentSoft : AppTheme.subtleFill)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? AppTheme.accent : .secondary)
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct AppStatusBadge: View {
    let title: String
    let systemName: String
    var color: Color = AppTheme.accent

    var body: some View {
        Label(title, systemImage: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct AppEmptyState: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }
}
