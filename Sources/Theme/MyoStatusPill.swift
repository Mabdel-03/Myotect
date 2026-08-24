import SwiftUI

/// The gold status-pill presets (`applyStatusPillStyle` + DistanceGuidanceView): rounded-rect
/// pill, 1pt border, soft shadow, optional uppercase badge line above the message.
enum MyoPillPreset {
    case warning, ok, moveCloser, moveFarther, holdSteady

    var background: Color {
        switch self {
        case .warning: return .myoWarnBg
        case .ok: return .myoOkBg
        case .moveCloser, .holdSteady: return .myoMist
        case .moveFarther: return .myoBlush
        }
    }

    var border: Color {
        switch self {
        case .warning: return .myoWarnAccent.opacity(0.35)
        case .ok: return .myoOkGreen.opacity(0.30)
        case .moveCloser, .holdSteady: return .myoTeal.opacity(0.22)
        case .moveFarther: return .myoMagenta.opacity(0.22)
        }
    }

    /// Badge/icon tint.
    var accent: Color {
        switch self {
        case .warning: return .myoWarnAccent
        case .ok: return .myoOkGreen
        case .moveCloser, .holdSteady: return .myoTeal
        case .moveFarther: return .myoMagenta
        }
    }
}

/// The pill chrome alone (gold `applyStatusPillStyle`): use directly when the content is custom
/// (e.g. the capture countdown); `MyoStatusPill` composes it for the common badge+title shape.
struct MyoPillChrome<Content: View>: View {
    let preset: MyoPillPreset
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(preset.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(preset.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

/// Gold guidance pill: optional icon, optional uppercase badge line, 18pt semibold message.
struct MyoStatusPill: View {
    let preset: MyoPillPreset
    var badge: String? = nil
    let title: String
    var icon: String? = nil

    var body: some View {
        MyoPillChrome(preset: preset) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(preset.accent)
                }
                VStack(spacing: 2) {
                    if let badge {
                        Text(badge).myoBadgeCaps(preset.accent)
                    }
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

/// Gold "VOICE INPUT ACTIVE" pill: compact mist capsule with 14pt black-weight teal text. Used
/// for operator status over the black trial field (mist keeps strong contrast on black).
struct MyoMicPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(Color.myoTeal)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.myoMist)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.myoTeal.opacity(0.20), lineWidth: 1)
            )
    }
}
