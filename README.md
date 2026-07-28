# Bibimbap

Configurateur macOS natif pour souris Pulsar, écrit en SwiftUI et Swift 6.

Projet personnel, sans affiliation avec Pulsar. Aucun logo ni code propriétaire n'est
redistribué. Le protocole est réimplémenté à partir d'observations documentées dans
[`docs/protocol.md`](docs/protocol.md).

## Pourquoi une application native

WebKit n'implémente pas WebHID : le configurateur web officiel ne fonctionne pas dans
Safari, et l'encapsuler dans une `WKWebView` ne changerait rien. L'application parle donc
directement au périphérique via `IOHIDManager`.

## État

| Couche | État |
|---|---|
| Transport HID (`PulsarHID`) | Validé sur matériel, en USB et derrière le dongle 8K |
| Protocole (`PulsarProtocol`) | Lecture et écriture validées sur matériel |
| Catalogue (`PulsarCatalog`) | 31 familles, 127 MID, instantané de `cfg.json` v1.3.11 |
| Simulateur (`PulsarSimulator`) | Chemin nominal et six scénarios de panne |
| Application (`BibimbapFeatures` + `BibimbapUI`) | Toutes les sections, appairage, sauvegardes JSON, diagnostic |
| Macros | Lecture, écriture, édition et validation, testées sur simulateur |
| Localisation | String Catalog français/anglais, 208 chaînes traduites |
| Firmware (phase 2) | Non commencé, commandes explicitement refusées par `PulsarSession` |

L'écriture est validée sur matériel pour les quatre formats du protocole : réglage
scalaire, bloc composé checksummé, écriture découpée sur plusieurs trames, et réécriture
d'une fonction de bouton. Chaque essai a été relu indépendamment puis restauré depuis les
octets d'origine tels que lus.

## Matrice de compatibilité

Trois niveaux distincts, à ne pas confondre :

| Niveau | Portée |
|---|---|
| Déclaré par le catalogue | 127 MID sous le CID 87, issus de `cfg.json` |
| Testé par fixtures | Capture réelle d'une X2 CrazyLight (CID 87 / MID 10), rejouée par les tests |
| Validé sur matériel | X2 CrazyLight, en USB filaire et derrière le dongle 8K |

Détail de ce qui est validé sur matériel :

| Opération | USB | Dongle 8K |
|---|---|---|
| Handshake, version, batterie, profil | ✅ | ✅ |
| Lecture de la zone de réglages | ✅ | ✅ |
| Décodage DPI, couleurs, boutons | ✅ | ✅ |
| Écriture d'un réglage scalaire | ✅ | ✅ |
| Écriture d'un bloc composé checksummé (palier DPI) | ✅ | ✅ |
| Écriture découpée sur plusieurs trames (bloc macro) | ✅ | ✅ |
| Réécriture d'une fonction de bouton | ✅ | ✅ |
| Relecture indépendante et restauration | ✅ | ✅ |
| Polling au-delà de 1 kHz | n/a | — |

Tous les mécanismes d'écriture sont validés dans les deux modes de connexion.

La branche haute du codec de polling n'est **pas atteignable en filaire** sur ce modèle :
la X2 CrazyLight plafonne à 1 kHz par câble et ne monte à 8 kHz qu'avec son dongle. Cette
ligne ne peut donc être fermée qu'en sans-fil, avec le risque de renégociation de liaison
décrit plus bas.

## Structure

```
Package.swift              Paquet cœur, testable sans Xcode
Sources/
  PulsarHID/               Découverte, ouverture, rapports HID (IOKit)
  PulsarProtocol/          Trames, checksums, carte flash, codecs, session
  PulsarCatalog/           Instantané versionné des capacités par modèle
  PulsarSimulator/         Périphérique simulé, avec injection de pannes
  BibimbapFeatures/        Brouillon, plan d'écriture, état observable
  BibimbapUI/              Vues SwiftUI, thème et primitives de mise en page
  pulsar-probe/            Sonde de diagnostic en lecture seule
  pulsar-writetest/        Essais d'écriture réversibles sur matériel
  bibimbap-render/         Rendu hors écran de l'interface, en PNG
App/
  Bibimbap.xcodeproj       Cible application
  Bibimbap/                Point d'entrée, entitlements, String Catalog
Tests/                     104 tests, dont une capture matérielle rejouée
Tools/generate_catalog.py  Régénération du catalogue depuis la source officielle
docs/protocol.md           Protocole observé
```

## Développement

Le paquet cœur se construit et se teste sans Xcode :

```bash
swift test
```

Sonder une souris branchée, sans rien y écrire :

```bash
swift run pulsar-probe
```

Essais d'écriture réversibles. Chacun lit l'état d'origine, écrit une valeur d'essai, relit
indépendamment, puis restaure les octets d'origine **tels que lus** et vérifie la
restauration :

```bash
swift run pulsar-writetest
```

Quatre essais par défaut, sélectionnables individuellement :

| Essai | Zone | Ce qu'il éprouve |
|---|---|---|
| `scalar` | Temps de rebond, 2 octets | Cadrage d'écriture, checksum scalaire |
| `dpi` | Dernier palier DPI, 4 octets | Empaquetage bits hauts + exposant, checksum de bloc |
| `macro` | Emplacement macro libre, 53 octets | Découpage d'une écriture sur six trames |
| `button` | Dernier bouton, 4 octets | Acceptation d'une fonction réécrite par le firmware |

En complément, l'outil relève l'empreinte des 256 octets de la zone de réglages avant et
après les essais, et signale tout octet qui aurait bougé **hors** des zones visées. C'est
la seule façon de distinguer un défaut d'adressage d'un changement venu d'ailleurs.

Un cinquième essai existe mais **n'est pas lancé par défaut** :

```bash
swift run pulsar-writetest polling
```

Il éprouve la branche haute du codec de polling, la dernière formule jamais confrontée au
firmware. Changer la cadence de rapport peut faire renégocier la liaison sans fil ; une
coupure à cet instant laisserait la valeur d'essai en place sans possibilité de restaurer.
À lancer de préférence en USB, où ce risque disparaît.

Ces outils exigent que la souris soit réveillée : derrière un dongle, le récepteur répond
pour lui-même alors que la souris dort encore. Ils s'arrêtent proprement en le disant.

Construire l'application :

```bash
xcodebuild -project App/Bibimbap.xcodeproj -scheme Bibimbap -configuration Debug build
```

Régénérer le catalogue depuis la source officielle :

```bash
python3 Tools/generate_catalog.py
```

Vérifier que le catalogue embarqué couvre toujours tous les modèles publiés :

```bash
BIBIMBAP_CHECK_CATALOG=1 swift test --filter CatalogSnapshotTests
```

## Regarder l'interface sans la lancer

`ImageRenderer` ne sait pas rendre `NavigationSplitView`, qui produit une image vide.
`bibimbap-render` recompose donc les mêmes vues — en-tête, contenu, barre d'actions — et
les écrit en PNG, dans les deux thèmes :

```bash
swift run bibimbap-render .render
```

Les contrôles AppKit (curseurs, interrupteurs, sélecteurs) apparaissent en aplat : le
rendu sert à juger hiérarchie, densité et alignements, pas l'aspect des contrôles
eux-mêmes. Le modèle est alimenté par le transport simulé, donc aucun matériel n'est
nécessaire.

## Localisation

Le français est la langue source ; l'anglais est fourni dans
`App/Bibimbap/Localizable.xcstrings`. Les 208 chaînes sans interpolation sont traduites.
Les quarante-deux chaînes interpolées seront ajoutées au catalogue par Xcode à la
prochaine compilation, avec les bons marqueurs de format — les écrire à la main
reviendrait à deviner le type de chaque expression, et une clé fausse échoue en silence.

Vérifier le rendu dans l'autre langue :

```bash
Bibimbap.app/Contents/MacOS/Bibimbap -AppleLanguages '(en)'
```

## Principes tenus par le code

- **Rien n'est écrit sans être relu.** Une écriture dont la relecture diverge est traitée
  comme un échec, et le lot est défait dans l'ordre inverse.
- **Un échec de restauration est nommé.** Les réglages dont l'état matériel n'est plus
  connu sont listés à l'utilisateur, jamais masqués derrière un message générique.
- **Les capacités absentes ne sont pas affichées.** Un modèle sans mode longue portée n'a
  pas de réglage grisé : il n'a pas la ligne.
- **Un modèle inconnu est refusé.** Deviner les limites d'un périphérique absent du
  catalogue reviendrait à écrire au hasard dans sa flash.
- **Une sauvegarde n'est pas une source de vérité.** L'import remplit le brouillon et
  écarte, en le disant, ce que le modèle connecté ne sait pas représenter.
- **Le catalogue n'est jamais téléchargé à l'exécution.** Une évolution du site déclenche
  une régénération volontaire du fichier embarqué, jamais l'exécution de code distant.
