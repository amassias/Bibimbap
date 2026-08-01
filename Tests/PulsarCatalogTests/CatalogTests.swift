import Foundation
import Testing
@testable import PulsarCatalog

@Suite("Catalogue embarqué")
struct CatalogTests {
    let catalog = DeviceCatalog.embedded

    @Test("Le catalogue se charge et déclare une source versionnée")
    func loads() {
        #expect(catalog.schemaVersion == 3)
        #expect(!catalog.sourceVersion.isEmpty)
        #expect(!catalog.families.isEmpty)
    }

    @Test("Chaque MID possède son nom et son visuel officiels")
    func everyMIDHasPresentation() {
        let published = Set(catalog.families.flatMap { family in
            family.mids.map { "\(family.cid)-\($0)" }
        })
        let presented = Set(catalog.models.map(\.id))

        #expect(presented == published)
        #expect(catalog.models.allSatisfy { !$0.name.isEmpty && !$0.imageName.isEmpty })
        #expect(catalog.model(cid: 87, mid: 10)?.name == "X2 CrazyLight")
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

    @Test("Chaque bouton porte un rang d'affichage distinct, de 0 à N-1")
    func buttonsCarryAContiguousDisplayOrder() {
        for family in catalog.families {
            let orders = family.orderedButtons.map(\.order)
            #expect(orders == Array(0..<family.buttons.count),
                    "CID \(family.cid) MID \(family.mids) : \(orders)")
            // L'ordre officiel ne suit pas l'index firmware, et n'a pas à le suivre.
            #expect(Set(family.firmwareButtonIndices).count == family.buttons.count)
        }
    }

    @Test("Le rang d'affichage est repris de cfg.json, pas recalculé depuis l'index")
    func displayOrderComesFromTheSource() throws {
        // Le MID 111 est le seul à déclarer des index discontinus : 0, 1, 2, 6, 4, 3.
        let family = try #require(catalog.family(cid: 87, mid: 111))
        #expect(family.orderedButtons.map(\.index) == [0, 1, 2, 6, 4, 3])
        #expect(family.displayNumber(firmwareIndex: 6) == 4)
        #expect(family.displayNumber(firmwareIndex: 3) == 6)
        #expect(family.displayNumber(firmwareIndex: 5) == nil)
        #expect(family.firmwareButtonIndices == [0, 1, 2, 3, 4, 6])

        // Le MID 10 en est proche mais reste contigu : 0, 1, 2, 5, 4, 3.
        let contiguous = try #require(catalog.family(cid: 87, mid: 10))
        #expect(contiguous.orderedButtons.map(\.index) == [0, 1, 2, 5, 4, 3])
        #expect(contiguous.displayNumber(firmwareIndex: 5) == 4)
    }

    @Test("Les positions et lignes officielles sont chargées pour chaque bouton")
    func geometryIsLoaded() throws {
        for family in catalog.families {
            for button in family.orderedButtons {
                let geometry = try #require(
                    button.geometry,
                    "CID \(family.cid) MID \(family.mids) bouton \(button.index)"
                )
                // La ligne de rappel est le seul élément qui désigne le bouton :
                // une géométrie réduite à `top`/`left` ne suffirait pas.
                #expect(geometry.line != .init(x1: 0, y1: 0, x2: 0, y2: 0))

                let marker = geometry.normalizedMarker
                #expect(marker.x > 0 && marker.x < 1,
                        "CID \(family.cid) bouton \(button.index) : x = \(marker.x)")
                #expect(marker.y > 0 && marker.y < 1,
                        "CID \(family.cid) bouton \(button.index) : y = \(marker.y)")
            }
        }
    }

    @Test("Les repères des clics principal et secondaire encadrent l'axe de la souris")
    func markersAreCalibratedAgainstTheArtwork() throws {
        for family in catalog.families {
            guard let primary = family.buttons.first(where: { $0.role == .primaryClick })?.geometry,
                  let secondary = family.buttons.first(where: { $0.role == .secondaryClick })?.geometry
            else {
                Issue.record("CID \(family.cid) MID \(family.mids) : clics principaux absents")
                continue
            }
            let first = primary.normalizedMarker
            let second = secondary.normalizedMarker

            // Les deux clics tombent de part et d'autre de l'axe et à la même hauteur.
            // Lequel est à gauche dépend du modèle : les variantes gauchères inversent
            // les deux, ce qui est précisément ce que la géométrie du catalogue porte et
            // qu'une position codée en dur ne saurait pas rendre.
            #expect(min(first.x, second.x) < 0.5, "CID \(family.cid) MID \(family.mids)")
            #expect(max(first.x, second.x) > 0.5, "CID \(family.cid) MID \(family.mids)")
            #expect(abs(first.y - second.y) < 0.01, "CID \(family.cid) MID \(family.mids)")
            #expect(abs((first.x + second.x) / 2 - 0.5) < 0.02,
                    "CID \(family.cid) MID \(family.mids)")
        }
    }

    @Test("Les variantes gauchères inversent bien les deux clics principaux")
    func leftHandedModelsMirrorTheirMainClicks() throws {
        let rightHanded = try #require(catalog.family(cid: 87, mid: 10))
        let leftHanded = try #require(catalog.family(cid: 87, mid: 21))

        let rightPrimary = try #require(
            rightHanded.buttons.first { $0.role == .primaryClick }?.geometry?.normalizedMarker
        )
        let leftPrimary = try #require(
            leftHanded.buttons.first { $0.role == .primaryClick }?.geometry?.normalizedMarker
        )

        #expect(rightPrimary.x < 0.5)
        #expect(leftPrimary.x > 0.5)
        #expect(abs(rightPrimary.x + leftPrimary.x - 1) < 0.02)
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
