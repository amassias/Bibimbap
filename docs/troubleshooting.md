# Connexion — diagnostic et validation

Ce document couvre ce qui peut empêcher Bibimbap de parler à une souris Pulsar, ce que
l'application affiche dans chaque cas, et la procédure de validation manuelle attendue
avant de considérer la connexion comme éprouvée.

## Ce qui doit être vrai pour qu'une connexion aboutisse

Une souris Pulsar expose plusieurs collections HID. Une seule porte le canal de
configuration : celle dont la page d'usage vaut `0xFF05` et dont les rapports d'entrée et
de sortie tiennent au moins 17 octets (16 de trame plus le report ID). Les autres
collections répondent aux mêmes VID/PID mais servent au pointage : les ouvrir ne donnerait
rien d'exploitable.

La connexion suit ensuite une séquence stricte, et l'état `connected` n'est atteint qu'à
la toute fin :

1. **discover** — énumérer les collections candidates ;
2. **open** — ouvrir celle qui a été choisie, sans exclusivité ;
3. **session** — démarrer la pompe de rapports d'entrée ;
4. **identify** — obtenir CID/MID et type de connexion ;
5. **catalogue** — vérifier que le modèle est connu ;
6. **online** — attendre que la souris se signale derrière son récepteur ;
7. **driver** — signaler qu'un logiciel prend la main ;
8. **snapshot** — relire l'intégralité des réglages.

Tout échec après l'étape 2 referme la session *et* le transport. Aucune collection ne doit
rester ouverte en arrière-plan après une erreur : c'est ce que vérifie le test
« Aucune session ne survit à un échec, quelle qu'en soit la cause ».

## Messages et gestes correspondants

| Ce que Bibimbap affiche | Cause | Ce qu'il faut faire |
|---|---|---|
| **Accès HID refusé** | macOS n'accorde pas « Surveillance de l'entrée » | Ouvrir Réglages Système › Confidentialité et sécurité › Surveillance de l'entrée, autoriser Bibimbap, puis relancer l'application. L'application ne réessaie pas toute seule : une fois le refus enregistré, macOS ne réaffiche plus la demande. |
| **Aucune souris détectée** | Aucune collection `0xFF05` énumérée, ou la cible a disparu | Brancher la souris en USB ou son récepteur 2,4 GHz, puis Actualiser. |
| **Choisir un périphérique** | Plusieurs candidats répondent | Choisir la ligne voulue : nom, transport, VID/PID et emplacement permettent de les distinguer. Rien n'est ouvert tant qu'aucun choix n'est fait. |
| **Pas de réponse du périphérique** | L'interface s'est ouverte, le handshake a expiré | Bouger ou cliquer la souris pour la réveiller, puis Réessayer. |
| **Souris hors ligne** | Le récepteur répond, la souris ne se signale pas | Vérifier qu'elle est allumée, chargée et à portée. |
| **Périphérique non reconnu** | CID/MID absent du catalogue embarqué | Aucun réglage n'est proposé : deviner les limites d'un modèle inconnu reviendrait à écrire au hasard dans sa flash. Ouvrir un ticket avec le CID/MID affiché. |
| **Reconnexion… (tentative n sur 5)** | Débranchement ou réveil de macOS | Attendre : cinq tentatives sur environ dix secondes. Le brouillon est conservé pendant toute la coupure. |
| **État matériel incertain** | Une écriture a été interrompue | Relire le périphérique. Rien ne sera réécrit automatiquement, et Apply reste fermé jusqu'à cette relecture. |

## Reconnexion et brouillon

Un débranchement subi ne détruit jamais le brouillon. La session HID est refermée, mais le
brouillon, les réglages qui lui servaient de base et la cible retenue restent en mémoire,
et le flux d'évènements HID reste écouté pour voir revenir le périphérique.

Au retour, Bibimbap relit systématiquement un instantané complet, puis compare :

- pas de brouillon local → l'instantané relu est adopté ;
- brouillon local, matériel inchangé → le brouillon est conservé, sans question ;
- brouillon local, matériel changé → une bannière présente le nombre de changements
  locaux, distants et en conflit, et Apply reste fermé jusqu'au choix entre
  **Conserver mon brouillon** (l'état relu devient la nouvelle base, les valeurs préparées
  sont gardées, le plan est recalculé) et **Adopter les réglages relus** (le brouillon est
  remplacé). Aucune des deux actions n'écrit au périphérique : seul Apply écrit.

La même règle s'applique aux notifications émises par la souris elle-même quand on agit
directement dessus.

Le brouillon et la cible sélectionnée vivent uniquement en mémoire : rien n'est persisté
sur disque dans cette version.

## Rapport de diagnostic

Réglages › Exporter le diagnostic produit un rapport contenant, dans cet ordre :
identification de l'application et du catalogue, périphérique connecté le cas échéant,
**journal de connexion**, cible retenue, liste des candidats, puis les dernières trames HID.

Le journal de connexion vient avant les trames volontairement : lorsque l'échec précède la
création de la session — permission refusée, ouverture refusée, interface disparue — aucune
trame n'a pu être échangée, et c'est la seule partie du rapport qui contienne quelque chose.
Chaque ligne porte la phase (`discover`, `permission`, `open`, `identify`, `online`,
`snapshot`), le candidat concerné, le résultat, le code système éventuel et l'horodatage.

## Validation

### Automatisée

```bash
swift build
swift test --filter PulsarHIDTests
swift test --filter DeviceControllerTests
swift test --filter SimulatorFaultTests
swift test --filter AppModelTests
```

```bash
xcodebuild -project App/Bibimbap.xcodeproj -scheme Bibimbap -configuration Release -sdk macosx -destination 'platform=macOS,arch=arm64' build
```

La suite complète (`swift test`) exécute bien l'intégralité des tests mais le processus ne
se termine pas de lui-même ensuite ; c'est le blocage de terminaison suivi par BIB-025. Les
suites ciblées ci-dessus se terminent normalement et doivent être utilisées pour conclure.

### Manuelle, sur l'application Release signée

Cette partie ne peut pas être automatisée et n'est pas encore effectuée.

1. Réinitialiser temporairement l'autorisation Surveillance de l'entrée
   (`tccutil reset ListenEvent gg.pulsar.bibimbap`) et vérifier que le message de permission
   apparaît, avec un bouton qui ouvre le bon volet des Réglages Système.
2. Connexion USB avec la X2 CrazyLight de référence.
3. Récepteur 8K avec souris active, endormie, puis hors de portée.
4. Débrancher/rebrancher avec et sans brouillon en cours.
5. Veille puis réveil de macOS.
6. Vérifier qu'une modification locale n'est jamais écrite automatiquement après une
   reconnexion.
7. Vérifier le choix entre brouillon et état relu.
8. Vérifier le comportement à plusieurs candidats — simulateur, et si possible deux
   périphériques physiques.
9. Vérifier qu'aucune session HID ne reste ouverte après chaque erreur.
10. Vérifier le rapport de diagnostic produit après un échec d'ouverture ou de handshake.
