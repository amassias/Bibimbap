import AppKit
import BibimbapFeatures
import BibimbapLocalization
import PulsarCatalog
import SwiftUI
import UniformTypeIdentifiers

/// Settings B : aperçu de thème, préférences essentielles et outils de maintenance.
struct SettingsSection: View {
    @Bindable var model: AppModel
    @Bindable var preferences = MenuBarPreferences.shared

    @State private var isConfirmingReset = false
    @State private var isPreparingDiagnostic = false
    @State private var diagnosticExportError: String?
    @State private var archive: ProfileArchive?
    @State private var isExportingProfile = false
    @State private var isImportingProfile = false
    @State private var lastImportSkipped: [String]?
    @State private var importError: String?
    @State private var compareLeft = 0
    @State private var compareRight = 1
    @State private var copyTarget = 1

    private let catalog = DeviceCatalog.embedded

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
            PremiumSectionHeader(title: L10n.string("Settings"))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.large) {
                    interfacePanel
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.Space.large) {
                        appBehaviorPanel
                        updatesPanel
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(spacing: Theme.Space.large) {
                    interfacePanel
                    appBehaviorPanel
                    updatesPanel
                }
            }

            privacyPanel

            if model.snapshot != nil {
                if model.capabilities?.supportsProfiles == true {
                    profileManagerPanel
                }
                deviceToolsPanel
            }

            HStack(spacing: Theme.Space.large) {
                Button(L10n.string("About Bibimbap")) {
                    BibimbapApplicationActions.showAbout()
                }
                .buttonStyle(.link)
                Divider().frame(height: 16)
                Button(L10n.string("Help")) {
                    BibimbapApplicationActions.openHelp()
                }
                .buttonStyle(.link)
                Divider().frame(height: 16)
                Text(L10n.format("Catalog v%@", catalog.sourceVersion))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Space.small)
        }
        .confirmationDialog(
            L10n.string("Reset the mouse?"),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Reset"), role: .destructive) {
                Task { await model.factoryReset() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "All settings, button assignments and macros stored in the mouse will be replaced by factory defaults."
                )
            )
        }
        .fileExporter(
            isPresented: $isExportingProfile,
            document: ProfileDocument(archive: archive),
            contentType: .json,
            defaultFilename: "bibimbap-profile-\((model.activeProfileIndex ?? 0) + 1)"
        ) { _ in }
        .fileImporter(
            isPresented: $isImportingProfile,
            allowedContentTypes: [.json]
        ) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                let loaded = try ProfileArchive.decode(from: Data(contentsOf: url))
                guard model.previewProfileImport(loaded) != nil else {
                    importError = L10n.string("Aucun périphérique compatible n'est connecté.")
                    lastImportSkipped = nil
                    return
                }
                lastImportSkipped = nil
                importError = nil
            } catch {
                importError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                lastImportSkipped = nil
            }
        }
        .alert(
            L10n.string("Unreadable backup"),
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(
            L10n.string("Diagnostic export failed"),
            isPresented: Binding(
                get: { diagnosticExportError != nil },
                set: { if !$0 { diagnosticExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticExportError ?? "")
        }
    }

    private var interfacePanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.xlarge) {
                Text(L10n.string("Interface"))
                    .font(.headline)

                VStack(alignment: .leading, spacing: Theme.Space.medium) {
                    Text(L10n.string("Appearance"))
                        .font(.callout.weight(.medium))

                    HStack(spacing: Theme.Space.medium) {
                        appearanceOption(
                            title: L10n.string("Dark"),
                            mode: .dark,
                            isSelected: preferences.appearance == .dark
                        )
                        appearanceOption(
                            title: L10n.string("System"),
                            mode: .system,
                            isSelected: preferences.appearance == .system
                        )
                        appearanceOption(
                            title: L10n.string("Light"),
                            mode: .light,
                            isSelected: preferences.appearance == .light
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Label(
                        appearanceDescription,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: Theme.Space.medium) {
                    Text(L10n.string("Language"))
                        .font(.callout.weight(.medium))

                    Picker("", selection: $preferences.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(L10n.string("Language"))
                }
            }
        }
    }

    private var appBehaviorPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Menu bar & startup"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                PremiumRow(label: L10n.string("Show in menu bar")) {
                    Toggle("", isOn: $preferences.isMenuBarIconVisible)
                        .labelsHidden()
                        .disabled(preferences.isDockIconHidden)
                }

                PremiumRow(
                    label: L10n.string("Hide Dock icon"),
                    detail: L10n.string("Bibimbap remains available from the menu bar."),
                    showsDivider: false
                ) {
                    Toggle("", isOn: $preferences.isDockIconHidden)
                        .labelsHidden()
                }
            }
        }
    }

    private var updatesPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                Text(L10n.string("Versions"))
                    .font(.headline)

                HStack(spacing: Theme.Space.large) {
                    ZStack {
                        Circle()
                            .stroke(PremiumPalette.hairline, lineWidth: 1)
                            .frame(width: 70, height: 70)
                        Image(systemName: "checkmark")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(L10n.string("Bibimbap is ready"))
                            .font(.headline)
                        Text(
                            L10n.format(
                                "Version %@ · Catalog v%@",
                                appVersion,
                                catalog.sourceVersion
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let snapshot = model.snapshot {
                    Divider()
                    PremiumRow(
                        label: L10n.string("Mouse firmware"),
                        showsDivider: snapshot.dongleVersion != nil
                    ) {
                        Text(snapshot.firmwareVersion)
                            .monospacedDigit()
                    }
                    if let dongle = snapshot.dongleVersion {
                        PremiumRow(
                            label: L10n.string("Receiver firmware"),
                            showsDivider: false
                        ) {
                            Text(dongle)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var privacyPanel: some View {
        PremiumPanel {
            HStack(spacing: Theme.Space.xlarge) {
                Image(systemName: "shield")
                    .font(.system(size: 42, weight: .ultraLight))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64)

                SettingLabel(
                    title: L10n.string("Privacy & diagnostics"),
                    detail: L10n.string(
                        "Device settings stay on this Mac. The exported report contains protocol frames but no personal data."
                    )
                )

                Spacer()

                Button {
                    exportDiagnostic()
                } label: {
                    if isPreparingDiagnostic {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L10n.string("Export diagnostics"))
                    }
                }
                .disabled(isPreparingDiagnostic)
            }
        }
    }

    private var profileManagerPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: Theme.Space.large) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        Text(L10n.string("Hardware profiles"))
                            .font(.headline)
                        Text(L10n.format(
                            "Active: %@ · %@",
                            model.activeProfileLabel,
                            model.activeHardwareLocationLabel
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        L10n.string("Read back from device"),
                        systemImage: "checkmark.seal"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }

                HStack(spacing: Theme.Space.medium) {
                    Button(L10n.string("Importer…")) {
                        isImportingProfile = true
                    }
                    Button(L10n.string("Exporter le profil actif")) {
                        archive = model.exportProfile()
                        isExportingProfile = archive != nil
                    }
                    .disabled(model.exportProfile() == nil)
                    Spacer()
                    Text(L10n.string("The selected slot is included in the archive."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let preview = model.profileImportPreview {
                    profilePreviewSection(
                        title: L10n.string("Aperçu de l'import — aucun réglage appliqué"),
                        subtitle: L10n.format(
                            "%@ vers %@",
                            preview.archive.profileLabel,
                            preview.targetProfile.map { L10n.format("Profil %d", $0 + 1) }
                                ?? L10n.string("profil actif")
                        ),
                        changes: preview.changes,
                        skipped: preview.skipped
                    ) {
                        HStack(spacing: Theme.Space.medium) {
                            Button(L10n.string("Charger dans les modifications")) {
                                lastImportSkipped = preview.skipped
                                model.confirmProfileImportPreview()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.draftRecovery != nil)
                            Button(L10n.string("Annuler")) {
                                model.dismissProfileImportPreview()
                            }
                        }
                    }
                }

                Divider()

                Text(L10n.string("Comparer deux profils"))
                    .font(.callout.weight(.medium))
                HStack(spacing: Theme.Space.medium) {
                    profilePicker(selection: $compareLeft)
                    Image(systemName: "arrow.left.and.right")
                        .foregroundStyle(.secondary)
                    profilePicker(selection: $compareRight)
                    Button(L10n.string("Relire et comparer")) {
                        Task { await model.compareProfiles(compareLeft, compareRight) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canUseProfileAction || compareLeft == compareRight)
                }

                if let comparison = model.profileComparison {
                    comparisonSection(comparison)
                }

                Divider()

                Text(L10n.string("Copier le profil actif"))
                    .font(.callout.weight(.medium))
                HStack(spacing: Theme.Space.medium) {
                    Text(L10n.format("%@ →", model.activeProfileLabel))
                        .foregroundStyle(.secondary)
                    profilePicker(selection: $copyTarget)
                    Button(L10n.string("Prévisualiser la copie")) {
                        Task { await model.previewProfileCopy(to: copyTarget) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canUseProfileAction || copyTarget == model.activeProfileIndex)
                }

                if let preview = model.profileCopyPreview {
                    profilePreviewSection(
                        title: L10n.string("Aperçu de la copie — aucun réglage appliqué"),
                        subtitle: L10n.format(
                            "%@ → %@ · l'actif sera restauré après l'opération",
                            preview.source.profileLabel,
                            preview.target.profileLabel
                        ),
                        changes: preview.changes,
                        skipped: []
                    ) {
                        HStack(spacing: Theme.Space.medium) {
                            Button(L10n.string("Copier et appliquer")) {
                                Task { await model.applyProfileCopyPreview() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canUseProfileAction)
                            Button(L10n.string("Annuler")) {
                                model.discardProfileCopyPreview()
                            }
                        }
                    }
                }

                if let skipped = lastImportSkipped, !skipped.isEmpty {
                    Label(
                        L10n.string("Certains réglages n'ont pas été chargés : ")
                            + skipped.joined(separator: ", "),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var canUseProfileAction: Bool {
        !model.connection.isBusy
            && !model.hasPendingChanges
            && model.draftRecovery == nil
            && !model.requiresExplicitReread
    }

    private func profilePicker(selection: Binding<Int>) -> some View {
        Picker(L10n.string("Profil"), selection: selection) {
            ForEach(model.supportedProfileIndices, id: \.self) { index in
                Text(L10n.format("Profil %d", index + 1)).tag(index)
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    @ViewBuilder
    private func profilePreviewSection<Actions: View>(
        title: String,
        subtitle: String,
        changes: [PendingChange],
        skipped: [String],
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if changes.isEmpty {
                Text(L10n.string("Aucun réglage ne serait modifié."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                changeRows(changes)
            }
            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    ForEach(skipped, id: \.self) { item in
                        Label(item, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            actions()
        }
        .padding(Theme.Space.medium)
        .background(PremiumPalette.elevated.opacity(0.42), in: .rect(cornerRadius: Theme.Radius.control))
    }

    private func comparisonSection(_ comparison: ProfileComparison) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            Text(L10n.format(
                "%@ · %@",
                comparison.left.profileLabel,
                comparison.right.profileLabel
            ))
            .font(.caption.weight(.medium))
            if comparison.isIdentical {
                Label(
                    L10n.string("Les deux profils sont identiques après relecture."),
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    ForEach(comparison.differences) { difference in
                        HStack(spacing: Theme.Space.small) {
                            Text(difference.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(difference.before)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(difference.after)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(Theme.Space.medium)
        .background(PremiumPalette.surface.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.control))
    }

    private func changeRows(_ changes: [PendingChange]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            ForEach(changes) { change in
                HStack(spacing: Theme.Space.small) {
                    Text(change.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(change.before)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(change.after)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private var deviceToolsPanel: some View {
        PremiumPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.string("Device tools"))
                    .font(.headline)
                    .padding(.bottom, Theme.Space.medium)

                PremiumRow(
                    label: L10n.string("Pair wireless receiver"),
                    detail: pairingHelp
                ) {
                    Button(pairingButtonLabel) {
                        switch model.pairing {
                        case .searching:
                            model.cancelPairing()
                        default:
                            Task { await model.startPairing() }
                        }
                    }
                }

                PremiumRow(
                    label: L10n.string("Factory reset"),
                    detail: L10n.string("Erases macros and custom button assignments."),
                    showsDivider: false
                ) {
                    Button(L10n.string("Reset…"), role: .destructive) {
                        isConfirmingReset = true
                    }
                }
            }
        }
    }

    private func appearanceOption(
        title: String,
        mode: AppAppearance,
        isSelected: Bool
    ) -> some View {
        Button {
            preferences.appearance = mode
        } label: {
            VStack(spacing: Theme.Space.small) {
                AppearancePreview(mode: mode)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .strokeBorder(
                                isSelected ? Color.accentColor : PremiumPalette.hairline,
                                lineWidth: isSelected ? 2 : 0.5
                            )
                        )

                HStack(spacing: Theme.Space.snug) {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.5),
                            lineWidth: 1
                        )
                        .frame(width: 14, height: 14)
                        .overlay {
                            if isSelected {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    Text(title)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var appearanceDescription: String {
        switch preferences.appearance {
        case .dark: L10n.string("Dark appearance is active")
        case .system: L10n.string("Automatically follows macOS")
        case .light: L10n.string("Light appearance is active")
        }
    }

    private func exportDiagnostic() {
        guard !isPreparingDiagnostic else { return }
        isPreparingDiagnostic = true

        Task {
            let report = await model.diagnosticReport()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "bibimbap-diagnostic.txt"
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK, let url = panel.url else {
                isPreparingDiagnostic = false
                return
            }

            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                diagnosticExportError = nil
            } catch {
                diagnosticExportError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
            isPreparingDiagnostic = false
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    private var pairingHelp: String? {
        switch model.pairing {
        case .idle:
            L10n.string("Connect the receiver before starting.")
        case .searching(let seconds):
            L10n.format("Searching · %d s remaining", seconds)
        case .succeeded:
            L10n.string("Pairing succeeded.")
        case .failed(let reason):
            reason
        }
    }

    private var pairingButtonLabel: String {
        if case .searching = model.pairing {
            return L10n.string("Cancel")
        }
        return L10n.string("Pair")
    }
}

private struct AppearancePreview: View {
    let mode: AppAppearance

    var body: some View {
        HStack(spacing: 0) {
            switch mode {
            case .dark:
                previewHalf(background: .black, foreground: .white)
            case .light:
                previewHalf(background: .white, foreground: .black)
            case .system:
                previewHalf(background: .black, foreground: .white)
                previewHalf(background: .white, foreground: .black)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 86)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    private func previewHalf(
        background: Color,
        foreground: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.yellow).frame(width: 5, height: 5)
                Circle().fill(.green).frame(width: 5, height: 5)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(foreground.opacity(0.16))
                .frame(width: 28, height: 8)
            RoundedRectangle(cornerRadius: 2)
                .fill(foreground.opacity(0.12))
                .frame(width: 42, height: 8)
        }
        .padding(Theme.Space.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }
}

struct ProfileDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    var archive: ProfileArchive?

    init(archive: ProfileArchive?) {
        self.archive = archive
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        archive = try ProfileArchive.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try archive?.encoded() ?? Data())
    }
}

struct DiagnosticDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8
        ) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
