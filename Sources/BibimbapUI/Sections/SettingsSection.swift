import BibimbapFeatures
import PulsarCatalog
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSection: View {
    @Bindable var model: AppModel

    @State private var isConfirmingReset = false
    @State private var diagnostic: String?
    @State private var isExportingDiagnostic = false
    @State private var archive: ProfileArchive?
    @State private var isExportingProfile = false
    @State private var isImportingProfile = false
    @State private var lastImportSkipped: [String]?
    @State private var importError: String?

    private let catalog = DeviceCatalog.embedded

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            aboutCard
            if model.snapshot != nil {
                backupCard
                pairingCard
                resetCard
            }
            diagnosticCard
            firmwareCard
        }
        .confirmationDialog(
            String(localized: "Réinitialiser la souris ?"),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Réinitialiser"), role: .destructive) {
                Task { await model.factoryReset() }
            }
            Button(String(localized: "Annuler"), role: .cancel) {}
        } message: {
            Text("Tous les réglages, affectations de boutons et macros enregistrés dans la souris seront effacés et remplacés par les valeurs d'usine. L'opération est irréversible.")
        }
        .fileExporter(
            isPresented: $isExportingDiagnostic,
            document: DiagnosticDocument(text: diagnostic ?? ""),
            contentType: .plainText,
            defaultFilename: "bibimbap-diagnostic"
        ) { _ in }
        .fileExporter(
            isPresented: $isExportingProfile,
            document: ProfileDocument(archive: archive),
            contentType: .json,
            defaultFilename: "bibimbap-profil"
        ) { _ in }
        .fileImporter(
            isPresented: $isImportingProfile,
            allowedContentTypes: [.json]
        ) { result in
            do {
                let url = try result.get()
                // Le bac à sable n'accorde l'accès qu'au fichier explicitement choisi.
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                let loaded = try ProfileArchive.decode(from: Data(contentsOf: url))
                lastImportSkipped = model.importProfile(loaded)
                importError = nil
            } catch {
                importError = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                lastImportSkipped = nil
            }
        }
        .alert(
            String(localized: "Sauvegarde illisible"),
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Cartes

    private var aboutCard: some View {
        SettingsGroup(
            title: String(localized: "À propos"),
            subtitle: String(localized: "Projet personnel, sans affiliation avec Pulsar.")
        ) {
            SettingsRow(label: String(localized: "Version du catalogue")) {
                Text("v\(catalog.sourceVersion)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SettingsRow(label: String(localized: "Modèles reconnus")) {
                Text("\(catalog.families.reduce(0) { $0 + $1.mids.count })")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            SettingsRow(label: String(localized: "Transport"), showsDivider: false) {
                Text(model.isSimulated ? String(localized: "Simulé") : String(localized: "IOKit / IOHIDManager"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingCard: some View {
        SettingsGroup(
            title: String(localized: "Appairage du récepteur"),
            subtitle: String(localized: "Branchez le récepteur, puis lancez l'appairage et allumez la souris à proximité.")
        ) {
            SettingsRow(
                label: String(localized: "Appairer un récepteur"),
                help: pairingHelp,
                showsDivider: false
            ) {
                switch model.pairing {
                case .searching(let seconds):
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("\(seconds) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Arrêter") { model.cancelPairing() }
                    }
                default:
                    Button("Lancer") {
                        Task { await model.startPairing() }
                    }
                }
            }
        }
    }

    private var pairingHelp: String? {
        switch model.pairing {
        case .idle:
            nil
        case .searching:
            String(localized: "Le récepteur écoute. Allumez la souris à proximité.")
        case .succeeded:
            String(localized: "Appairage réussi.")
        case .failed(let reason):
            reason
        }
    }

    private var resetCard: some View {
        SettingsGroup(
            title: String(localized: "Réinitialisation"),
            subtitle: String(localized: "Restaure les réglages d'usine enregistrés dans la souris.")
        ) {
            SettingsRow(
                label: String(localized: "Réinitialisation complète"),
                help: String(localized: "Irréversible. Les macros et affectations personnalisées seront perdues."),
                showsDivider: false
            ) {
                Button(String(localized: "Réinitialiser…"), role: .destructive) {
                    isConfirmingReset = true
                }
            }
        }
    }

    private var backupCard: some View {
        SettingsGroup(
            title: String(localized: "Sauvegardes"),
            subtitle: String(localized: "Fichier JSON versionné. L'import remplit le brouillon ; rien n'atteint la souris avant Appliquer.")
        ) {
            SettingsRow(label: String(localized: "Exporter les réglages")) {
                Button("Exporter…") {
                    archive = model.exportProfile()
                    isExportingProfile = archive != nil
                }
                .disabled(model.snapshot == nil)
            }

            SettingsRow(
                label: String(localized: "Importer une sauvegarde"),
                help: importSummary,
                showsDivider: false
            ) {
                Button("Importer…") { isImportingProfile = true }
                    .disabled(model.snapshot == nil)
            }
        }
    }

    private var importSummary: String? {
        guard let skipped = lastImportSkipped else { return nil }
        return skipped.isEmpty
            ? String(localized: "Sauvegarde chargée dans le brouillon.")
            : String(localized: "Chargée, en écartant ce que ce modèle ne peut pas représenter : ")
                + skipped.joined(separator: ", ")
    }

    private var diagnosticCard: some View {
        SettingsGroup(
            title: String(localized: "Diagnostic"),
            subtitle: String(localized: "Rapport texte contenant les dernières trames échangées, sans donnée personnelle.")
        ) {
            SettingsRow(label: String(localized: "Exporter un rapport"), showsDivider: false) {
                Button(String(localized: "Exporter…")) {
                    Task {
                        diagnostic = await model.diagnosticReport()
                        isExportingDiagnostic = true
                    }
                }
            }
        }
    }

    private var firmwareCard: some View {
        SettingsGroup(
            title: String(localized: "Firmware"),
            subtitle: String(localized: "La mise à jour arrive en phase 2, une fois la phase 1 validée sur matériel.")
        ) {
            if let snapshot = model.snapshot {
                SettingsRow(label: String(localized: "Version installée")) {
                    Text(snapshot.firmwareVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let published = snapshot.family.firmware.deviceVersion {
                    SettingsRow(label: String(localized: "Version publiée par le fabricant")) {
                        Text(published)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            SettingsRow(
                label: String(localized: "Mise à jour"),
                help: String(localized: "Le module de flash reste désactivé tant que les écritures de la phase 1 n'ont pas été validées sur matériel réel. Aucun site n'est ouvert automatiquement."),
                showsDivider: false
            ) {
                Text(String(localized: "Indisponible"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Enveloppe pour exporter une sauvegarde de réglages.
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

/// Enveloppe minimale pour exporter le rapport de diagnostic.
struct DiagnosticDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
