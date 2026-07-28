import Foundation
import Testing
@testable import PulsarCatalog

@Suite("Catalogue embarqué")
struct CatalogTests {
    let catalog = DeviceCatalog.embedded

    @Test("Le catalogue se charge et déclare une source versionnée")
    func loads() {
        #expect(catalog.schemaVersion == 1)
        #expect(!catalog.sourceVersion.isEmpty)
        #expect(!catalog.families.isEmpty)
    }

    @Test("Les deux constructeurs déclarés par cMouse sont présents")
    func vendorIDs() {
        #expect(Set(catalog.vendorIDs) == [0x3710, 0x3554])
    }

    @Test("Aucun MID n'est déclaré dans deux familles à la fois")
    func midsAreUnique() {
        var seen: Set<String> = []
        for family in catalog.families {
            for mid in family.mids {
                let key = "\(family.cid)-\(mid)"
                #expect(!seen.contains(key), "MID \(key) dupliqué")
                seen.insert(key)
            }
        }
    }

    @Test("Chaque famille référence un capteur dont les plages DPI sont connues")
    func everyFamilyHasSensorRanges() {
        for family in catalog.families {
            #expect(catalog.sensorRanges(for: family) != nil,
                    "capteur \(family.sensor.type) absent de la table")
        }
    }

    @Test("Chaque famille déclare au moins un palier et un bouton")
    func familiesAreComplete() {
        for family in catalog.families {
            #expect(!family.dpi.stages.isEmpty, "CID \(family.cid) MID \(family.mids)")
            #expect(!family.buttons.isEmpty, "CID \(family.cid) MID \(family.mids)")
            #expect(family.dpi.maximum > 0)
            #expect(family.debounce.maximum >= family.debounce.default)
        }
    }

    @Test("Les paliers par défaut tiennent dans la plage du capteur")
    func defaultStagesAreRepresentable() throws {
        for family in catalog.families {
            let ranges = try #require(catalog.sensorRanges(for: family))
            for stage in family.dpi.stages {
                #expect(stage.value >= ranges.minimumDPI, "CID \(family.cid) : \(stage.value)")
                #expect(stage.value <= family.dpi.maximum, "CID \(family.cid) : \(stage.value)")
            }
        }
    }

    @Test("La X2 CrazyLight branchée en USB est reconnue")
    func recognisesX2CrazyLight() throws {
        #expect(catalog.recognizes(vendorID: 0x3710, productID: 0x3414))
        #expect(catalog.connection(forProductID: 0x3414) == .wired)
        let family = try #require(catalog.family(cid: 87, mid: 10))
        #expect(family.sensor.type == "pulsar x1")
    }

    @Test("Un modèle absent du catalogue n'est pas inventé")
    func unknownModelReturnsNil() {
        #expect(catalog.family(cid: 87, mid: 250) == nil)
        #expect(catalog.family(cid: 1, mid: 1) == nil)
        #expect(!catalog.recognizes(vendorID: 0x046D, productID: 0xC08B))
    }

    @Test("Les identifiants produit filaires et sans fil sont disjoints")
    func productIDsAreDisjoint() {
        let wired = Set(catalog.mouseProductIDs.wired)
        let wireless = Set(catalog.mouseProductIDs.wireless)
        #expect(wired.isDisjoint(with: wireless))
        #expect(catalog.mouseProductIDs.all.count == wired.count + wireless.count)
    }
}

@Suite("Instantané contre la source officielle")
struct CatalogSnapshotTests {
    /// Compare le catalogue embarqué au `cfg.json` publié.
    ///
    /// Le test ne s'exécute que si `BIBIMBAP_CHECK_CATALOG` est défini : la suite doit
    /// rester exécutable hors ligne, et une évolution du site ne doit pas faire échouer
    /// une compilation locale — elle doit déclencher une régénération volontaire.
    @Test("Le catalogue embarqué couvre tous les modèles publiés",
          .enabled(if: ProcessInfo.processInfo.environment["BIBIMBAP_CHECK_CATALOG"] != nil))
    func matchesUpstream() async throws {
        let url = try #require(URL(string: DeviceCatalog.embedded.sourceURL))
        let (data, _) = try await URLSession.shared.data(from: url)
        let upstream = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let groups = try #require(upstream?["mouse"] as? [[String: Any]])

        var publishedMIDs: Set<String> = []
        for group in groups {
            let cid = try #require(group["cid"] as? Int)
            for entry in try #require(group["cfg"] as? [[String: Any]]) {
                for mid in try #require(entry["mid"] as? [Int]) {
                    publishedMIDs.insert("\(cid)-\(mid)")
                }
            }
        }

        let embedded = Set(DeviceCatalog.embedded.families.flatMap { family in
            family.mids.map { "\(family.cid)-\($0)" }
        })
        let missing = publishedMIDs.subtracting(embedded).sorted()
        #expect(missing.isEmpty, "modèles publiés absents du catalogue : \(missing)")
    }
}
