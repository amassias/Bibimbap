import BibimbapFeatures
import SwiftUI

/// Composition principale de la fenêtre.
///
/// La navigation, le produit et les réglages ont chacun leur colonne. Cette structure
/// reste stable quand on change de section : l'utilisateur garde le périphérique et le
/// profil en contexte, tandis que seule la zone de travail évolue.
struct AppShell: View {
    @Bindable var model: AppModel
    var forcePendingBar = false
    var showsContent = true

    var body: some View {
        VStack(spacing: 0) {
            AppTopBar(model: model)
            Divider()

            HStack(spacing: 0) {
                AppSidebar(model: model)
                    .frame(width: Theme.Shell.sidebarWidth)

                Divider()

                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if model.snapshot != nil && proxy.size.width >= Theme.Shell.devicePaneThreshold {
                                DeviceShowcase(model: model)
                                    .frame(width: Theme.Shell.deviceWidth)
                                Divider()
                            }

                            if showsContent {
                                AppDetail(model: model)
                            } else {
                                Color.clear
                            }
                        }

                        if model.hasPendingChanges || model.lastResult != nil || forcePendingBar {
                            Divider()
                            PendingChangesBar(model: model)
                                .frame(minHeight: Theme.Shell.footerHeight)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AppTopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Text("Bibimbap")
                .font(.headline)
                .padding(.leading, 88)
                .frame(width: Theme.Shell.sidebarWidth, alignment: .leading)

            Divider()

            HStack(spacing: Theme.Space.small) {
                Text(model.section.label)
                    .font(.title3.weight(.semibold))

                if model.hasPendingChanges {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .padding(.leading, Theme.Space.small)
                    Text("Modifications non appliquées")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.connection.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.section)
        }
        .frame(height: Theme.Shell.topBarHeight)
        .background(.bar)
    }
}

private struct AppSidebar: View {
    @Bindable var model: AppModel

    private var navigationSections: [AppModel.Section] {
        [.customize, .performance, .macros, .power].filter(model.availableSections.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    deviceBlock
                    if model.capabilities?.supportsProfiles == true {
                        profilesBlock
                    }
                    navigationBlock
                }
                .padding(.horizontal, Theme.Space.medium)
                .padding(.top, Theme.Space.large)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: Theme.Space.small)
            Divider()

            SidebarButton(
                title: String(localized: "Réglages de l’app"),
                systemImage: "gearshape",
                isSelected: model.section == .settings
            ) {
                model.section = .settings
            }
            .padding(Theme.Space.medium)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var deviceBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            sidebarHeading(String(localized: "Périphériques"))

            Button {
                model.section = .overview
            } label: {
                HStack(spacing: Theme.Space.medium) {
                    Image("MouseX2", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 54)

                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(deviceName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(connectionLabel)
                            .font(.caption)
                            .foregroundStyle(connectionTint)
                    }

                    Spacer(minLength: 0)

                    if let battery = model.snapshot?.battery {
                        Image(systemName: batterySymbol(battery.percentage))
                            .foregroundStyle(battery.percentage < 15 ? .red : .green)
                    }
                }
                .padding(Theme.Space.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.group)
                        .fill(model.section == .overview
                              ? Color.accentColor.opacity(0.09)
                              : Color(nsColor: .textBackgroundColor).opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.group)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var profilesBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            sidebarHeading(String(localized: "Profils"))

            ForEach(0..<3, id: \.self) { profile in
                ProfileButton(
                    profile: profile,
                    isActive: model.snapshot?.activeProfile == profile
                ) {
                    Task { await model.selectProfile(profile) }
                }
            }
        }
    }

    private var navigationBlock: some View {
        VStack(spacing: Theme.Space.tight) {
            ForEach(navigationSections) { section in
                SidebarButton(
                    title: section.label,
                    systemImage: section.symbol,
                    isSelected: model.section == section
                ) {
                    model.section = section
                }
            }
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.small)
    }

    private var deviceName: String {
        guard let name = model.snapshot?.productName else { return String(localized: "Souris Pulsar") }
        return name.contains("(simulé)") ? "X2 CrazyLight" : name
    }

    private var connectionLabel: String {
        switch model.connection {
        case .connected: String(localized: "Connectée")
        case .writing: String(localized: "Écriture…")
        case .reading: String(localized: "Lecture…")
        case .offline: String(localized: "Hors ligne")
        default: String(localized: "Déconnectée")
        }
    }

    private var connectionTint: Color {
        switch model.connection {
        case .connected: .accentColor
        case .offline, .failed: .red
        default: .secondary
        }
    }

    private func batterySymbol(_ percentage: Int) -> String {
        switch percentage {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<70: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.medium)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.09)
                          : isHovering ? Color.primary.opacity(0.04) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animates(isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProfileButton: View {
    let profile: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.medium) {
                Text("P\(profile + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(isActive ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035))
                    )

                Text("\(String(localized: "Profil")) \(profile + 1)")
                Spacer()

                if isActive {
                    Text(String(localized: "Actif"))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Theme.Space.small)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isActive ? Color.accentColor.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isActive)
    }
}

private struct DeviceShowcase: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text(deviceName)
                .font(.headline)
                .padding(.top, Theme.Space.page)

            Spacer(minLength: Theme.Space.large)

            Image("MouseX2", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 255, maxHeight: 410)
                .accessibilityLabel("Vue de dessus de la souris \(deviceName)")

            HStack(spacing: Theme.Space.large) {
                if let battery = model.snapshot?.battery {
                    Label("\(battery.percentage) %", systemImage: "battery.75percent")
                }
                if let connection = model.snapshot?.connection {
                    Label(connection.label, systemImage: connection.isWired ? "cable.connector" : "wifi")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, Theme.Space.large)

            Spacer(minLength: Theme.Space.page)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var deviceName: String {
        guard let name = model.snapshot?.productName else { return "Souris Pulsar" }
        return name.contains("(simulé)") ? "X2 CrazyLight" : name
    }
}

private struct AppDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.connection {
            case .idle, .scanning, .connecting, .reading:
                ConnectionProgressView(state: model.connection)
            case .noDevice:
                NoDeviceView(model: model)
            case .offline:
                OfflineView(model: model)
            case .unrecognised(let cid, let mid):
                UnrecognisedDeviceView(cid: cid, mid: mid, model: model)
            case .failed(let message):
                FailureView(message: message, model: model)
            case .connected, .writing, .disconnectedDuringWrite:
                if model.snapshot != nil {
                    ScrollView {
                        SectionContent(model: model)
                            .padding(Theme.Space.section)
                            .frame(maxWidth: Theme.Shell.detailMaximumWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    ConnectionProgressView(state: model.connection)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.22))
    }
}
