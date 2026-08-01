import AppKit
import BibimbapFeatures
import BibimbapLocalization
import SwiftUI

/// Shell premium commun aux six écrans.
///
/// Le périphérique reste visible dans l'en-tête plutôt que dans une troisième colonne :
/// la zone de travail gagne en largeur, sans perdre le modèle, la batterie ni le profil.
struct AppShell: View {
    @Bindable var model: AppModel
    var forcePendingBar = false
    var showsContent = true
    @State private var sidebarWidth = Theme.Shell.sidebarWidth
    @State private var sidebarDragStart: CGFloat?

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                AppSidebar(model: model)
                    .frame(width: sidebarWidth)

                Divider()

                detailColumn
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            }

            sidebarResizeHandle
                .offset(x: sidebarWidth - 4)
        }
        .background(PremiumPalette.canvas)
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            AppTitleBar(model: model)
            Divider()

            if model.section != .settings, model.snapshot != nil {
                DeviceStatusHeader(model: model)
                    .padding(.horizontal, Theme.Space.medium)
                    .padding(.vertical, Theme.Space.small)
            }

            if showsContent {
                AppDetail(model: model)
            } else {
                Color.clear
            }

            // Le conflit et l'état incertain ne dépendent pas de la section affichée :
            // ils bloquent l'application des modifications partout, y compris depuis
            // Réglages, et doivent donc rester visibles depuis Réglages.
            UncertainHardwareBanner(model: model)
            DraftRecoveryBanner(model: model)

            if model.section != .settings, model.snapshot != nil {
                Divider()
                PendingChangesBar(model: model)
                    .frame(minHeight: Theme.Shell.footerHeight)
            }
        }
    }

    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { isHovering in
                (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if sidebarDragStart == nil {
                            sidebarDragStart = sidebarWidth
                        }
                        sidebarWidth = clampedSidebarWidth(
                            (sidebarDragStart ?? sidebarWidth) + value.translation.width
                        )
                    }
                    .onEnded { _ in
                        sidebarDragStart = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(L10n.string("Resize sidebar"))
            .accessibilityValue("\(Int(sidebarWidth))")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    sidebarWidth = clampedSidebarWidth(sidebarWidth + 20)
                case .decrement:
                    sidebarWidth = clampedSidebarWidth(sidebarWidth - 20)
                @unknown default:
                    break
                }
            }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(
            max(width, Theme.Shell.sidebarMinimumWidth),
            Theme.Shell.sidebarMaximumWidth
        )
    }
}

private struct AppTitleBar: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Text("Bibimbap")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                if model.connection.isBusy {
                    if let progress = model.writeProgress,
                       case .writing = model.connection {
                        HStack(spacing: Theme.Space.small) {
                            ProgressView(value: progress.fraction)
                                .frame(width: 100)
                            Text(L10n.format(
                                "%d/%d",
                                progress.completed,
                                progress.total
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .padding(.trailing, Theme.Space.xlarge)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.string("Write progress"))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, Theme.Space.xlarge)
                    }
                }
            }
        }
        .frame(height: Theme.Shell.titleBarHeight)
        .background(PremiumPalette.canvas)
    }
}

private struct AppSidebar: View {
    @Bindable var model: AppModel

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandBlock
                .padding(.horizontal, Theme.Space.xlarge)
                .padding(.top, 62)
                .padding(.bottom, Theme.Space.page)

            Text(model.snapshot == nil
                 ? L10n.string("Pulsar mouse")
                 : model.deviceDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.page)
                .padding(.bottom, Theme.Space.small)

            VStack(spacing: Theme.Space.tight) {
                ForEach(model.availableSections.filter { $0 != .settings }) { section in
                    SidebarButton(
                        title: section.label,
                        systemImage: sidebarSymbol(for: section),
                        isSelected: model.section == section
                    ) {
                        model.section = section
                    }
                }

                SidebarButton(
                    title: AppModel.Section.settings.label,
                    systemImage: "gearshape",
                    isSelected: model.section == .settings
                ) {
                    model.section = .settings
                }
            }
            .padding(.horizontal, Theme.Space.large)

            Spacer()

            Button {
                BibimbapApplicationActions.openHelp()
            } label: {
                Label(L10n.string("Support"), systemImage: "questionmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.large)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(PremiumPalette.surface.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(PremiumPalette.hairline.opacity(0.65), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(Theme.Space.large)
            .help(L10n.string("Open Bibimbap help"))
        }
        .background(PremiumPalette.sidebar.opacity(0.92))
    }

    private var brandBlock: some View {
        HStack(spacing: Theme.Space.large) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text("Bibimbap")
                    .font(.headline)
                Text("v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sidebarSymbol(for section: AppModel.Section) -> String {
        switch section {
        case .overview: "scope"
        case .customize: "square.grid.2x2"
        case .performance: "chart.bar.fill"
        case .macros: "macwindow.badge.plus"
        case .power: "bolt.fill"
        case .settings: "gearshape"
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
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.medium)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(
                        isSelected
                            ? PremiumPalette.elevated.opacity(0.74)
                            : isHovering ? Color.primary.opacity(0.04) : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animates(isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DeviceStatusHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        if let snapshot = model.snapshot {
            PremiumPanel(padding: Theme.Space.large) {
                HStack(spacing: Theme.Space.xlarge) {
                    DeviceArtwork(model: model, maximumWidth: 70, maximumHeight: 108)
                        .frame(width: 82, height: 108)

                    Divider()
                        .frame(height: 74)

                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        Text(model.deviceDisplayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        PremiumStatusDot(label: connectionLabel, color: connectionColor)
                    }
                    .frame(minWidth: 190, alignment: .leading)

                    Spacer(minLength: Theme.Space.large)

                    PremiumMetric(
                        systemImage: snapshot.connection.isWired ? "cable.connector" : "wifi",
                        label: snapshot.connection.label,
                        value: connectionDetail
                    )

                    if let battery = snapshot.battery {
                        PremiumMetric(
                            systemImage: batterySymbol(battery.percentage, charging: battery.isCharging),
                            label: L10n.string("Battery"),
                            value: "\(battery.percentage)%",
                            tint: battery.percentage < 15 ? .red : .green
                        )
                    }

                    if model.capabilities?.supportsProfiles == true,
                       let profile = snapshot.activeProfile {
                        profilePicker(current: profile)
                    }

                    Menu {
                        Button(model.requiresExplicitReread
                               ? L10n.string("Récupérer l'état matériel")
                               : model.hasPendingChanges
                                   ? L10n.string("Relire et comparer")
                                   : L10n.string("Relire le périphérique")) {
                            Task {
                                if model.requiresExplicitReread {
                                    await model.recoverUncertainHardware()
                                } else {
                                    await model.rereadAndCompare()
                                }
                            }
                        }
                        Button(L10n.string("Exporter le diagnostic")) {
                            model.section = .settings
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .frame(minHeight: Theme.Shell.deviceHeaderHeight)
        }
    }

    private var connectionLabel: String {
        switch model.connection {
        case .connected: L10n.string("Connected")
        case .writing: L10n.string("Writing…")
        case .reading: L10n.string("Reading…")
        case .disconnectedDuringWrite: L10n.string("Hardware state uncertain")
        default: L10n.string("Disconnected")
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: .green
        case .writing, .reading: .accentColor
        case .disconnectedDuringWrite: .orange
        default: .red
        }
    }

    private var connectionDetail: String {
        if let signal = model.snapshot?.signalStrength {
            return "\(min(100, max(0, signal * 20)))%"
        }
        return model.snapshot?.connection.isWired == true ? L10n.string("Wired") : "100%"
    }

    private func profilePicker(current: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(L10n.string("Profil actif"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker(L10n.string("Profil actif"), selection: Binding(
                get: { current },
                set: { profile in
                    guard model.canChangeProfile else { return }
                    Task { await model.selectProfile(profile) }
                }
            )) {
                ForEach(model.supportedProfileIndices, id: \.self) { index in
                    Text(L10n.format("Profile %d", index + 1)).tag(index)
                }
            }
            .frame(width: 160)
            .disabled(!model.canChangeProfile)
            .help(model.activeHardwareLocationLabel)

            Text(model.activeHardwareLocationLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 160, alignment: .leading)
        }
    }

    private func batterySymbol(_ percentage: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        return switch percentage {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<70: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct AppDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.section == .settings {
                sectionScrollView
            } else {
                switch model.connection {
                case .idle, .scanning, .connecting, .reading:
                    ConnectionProgressView(state: model.connection)
                case .selectingDevice:
                    DeviceSelectionView(model: model)
                case .reconnecting(let attempt):
                    // Le brouillon survit à la coupure : l'écran le dit plutôt que de
                    // laisser croire à une remise à zéro.
                    ReconnectingView(attempt: attempt, model: model)
                case .permissionDenied:
                    PermissionDeniedView(model: model)
                case .handshakeTimedOut:
                    HandshakeTimeoutView(model: model)
                case .noDevice:
                    NoDeviceView(model: model)
                case .offline:
                    OfflineView(model: model)
                case .unrecognised(let cid, let mid):
                    UnrecognisedDeviceView(cid: cid, mid: mid, model: model)
                case .failed(let message):
                    FailureView(message: message, model: model)
                case .connected, .writing, .disconnectedDuringWrite:
                    model.snapshot == nil
                        ? AnyView(ConnectionProgressView(state: model.connection))
                        : AnyView(sectionScrollView)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PremiumPalette.canvas)
    }

    private var sectionScrollView: some View {
        ScrollView {
            SectionContent(model: model)
                .padding(.horizontal, Theme.Space.section)
                .padding(.top, model.section == .settings ? Theme.Space.section : Theme.Space.small)
                .padding(.bottom, Theme.Space.section)
                .frame(maxWidth: Theme.Shell.detailMaximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
