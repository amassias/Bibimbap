# Protocole Pulsar `cMouse` — notes de rétro-ingénierie

Source : bundle public `https://bbb.pulsar.gg/cMouse/js/app.31d36e3c.js`, config `cfg.json`
v1.3.11 et table capteurs `sensor.json`, observés le 2026-07-26, croisés avec les descripteurs
HID de la X2 CrazyLight branchée en USB.

Aucun code du site n'est repris. Ce document décrit le format observé ; l'implémentation Swift
(`PulsarProtocol`) est écrite à partir de ces notes et validée par les fixtures de `Tests/`.

**État de validation.** Le format ci-dessous contient un relevé matériel historique daté du
2026-07-26 sur une X2 CrazyLight (CID 87, MID 10, firmware v3.05), dans deux configurations.
Ce relevé est conservé comme preuve documentaire; il n'a pas été rejoué par la CI ni par le
travail de distribution BIB-017/BIB-018. Les niveaux de preuve et les limites sont détaillés
dans [`docs/validation-matrix.md`](validation-matrix.md).

- **USB filaire**, en lecture seule (`swift run pulsar-probe`). Handshake, version, batterie,
  profil actif, mode longue portée, lecture de `0x0000..0x0100`, checksums scalaires,
  encodage DPI et fonctions de boutons décodent tous correctement. Le vidage obtenu est
  conservé dans `Tests/PulsarProtocolTests/Fixtures/x2-crazylight-core.json`.
- **Dongle 8K sans fil** (type de connexion 5, plafond 8 kHz), en lecture puis en
  **écriture** (`swift run pulsar-writetest`). Les mêmes valeurs sont relues qu'en filaire,
  ce qui recoupe les deux chemins. Trois formats d'écriture ont été éprouvés, chacun écrit,
  relu indépendamment, puis restauré depuis les octets d'origine :

  | Format | Zone | Écrit | Relu | Restauré |
  |---|---|---|---|---|
  | Scalaire, 2 octets | Rebond, `0x00A9` | `05 50` | `05 50` | `02 53` ✓ |
  | Bloc composé, 4 octets | Palier DPI 6, `0x0020` | `77 77 22 45` | `77 77 22 45` | `37 37 22 C5` ✓ |
  | Multi-trames, 53 octets | Macro, `0x0C00` | six trames | identique | `FF` × 53 ✓ |
  | Sémantique, 4 octets | Bouton 6, `0x0074` | `00 00 00 55` | `00 00 00 55` | `02 01 00 52` ✓ |

Sont donc validés sur matériel : le cadrage des trames, le checksum de trame, le checksum
de bloc scalaire et de bloc composé, l'empaquetage DPI (bits hauts et code d'exposant), le
découpage d'une écriture sur plusieurs trames, l'acceptation d'une fonction de bouton
réécrite, la prise de verrou, le cycle écriture-relecture et la restauration.

Reste non validé sur matériel : le **polling au-delà de 1 kHz sans fil**. C'est le dernier codec
dont la formule n'a jamais été confrontée au firmware. L'essai existe
(`swift run pulsar-writetest polling`) mais n'est pas lancé par défaut : changer la
cadence de rapport peut faire renégocier la liaison sans fil, et une coupure entre
l'écriture et la restauration laisserait la valeur d'essai en place. À faire en USB, où
ce risque n'existe pas.

### Pièges relevés à l'implémentation

- **Report ID.** `IOHIDDeviceSetReport` veut l'identifiant à la fois en paramètre *et* comme
  premier octet du tampon : la taille de sortie annoncée (17) vaut 1 + 16. Sans cela le
  périphérique accepte l'écriture sans jamais répondre.
- **Champ longueur.** Pour une lecture flash, l'octet 4 porte le nombre d'octets *demandés*,
  alors que la trame ne transporte aucune donnée. Le dériver de la charge utile fait ne lire
  qu'un octet par trame, avec un résultat trompeusement plausible.
- **Statut 1.** Voir §2 : acquittement sans données, pas erreur.
- **Sélection de collection.** Voir §1 : la taille annoncée est un maximum, pas une signature.
- **Attente de mise en ligne.** Derrière un dongle, le récepteur répond au handshake avant
  d'avoir joint la souris. Lire la flash à ce moment-là expire sans explication utile. Il
  faut interroger `DeviceOnLine` jusqu'à ce que l'octet 9 retombe à zéro — c'est ce que
  fait `waitUntilOnline()`.

## 1. Interface HID

La souris expose trois collections. Seule la collection vendor porte la configuration.

| Collection | Usage page | Usage | IN | OUT | Feature |
|---|---|---|---|---|---|
| Souris standard | `0x01` | `0x02` | 7 | — | — |
| Consumer/clavier | `0x01` | `0x06` | 8 | 1 | — |
| **Vendor (config)** | **`0xFF05`** | `0x00` | 17 ou 49 | 17 ou 49 | 8 |

Le canal de configuration est la collection de page d'usage `0xFF05`, sur le report ID **8**,
en trames de 16 octets — 17 avec le report ID.

**La taille annoncée n'est pas celle du rapport de configuration** : IOKit expose le
maximum de tous les rapports de la collection. La X2 CrazyLight en USB annonce 17, le
dongle 8K annonce 49 parce qu'il porte en plus un rapport de données rapide. Les deux
dialoguent pourtant en trames de 16 octets. Sélectionner la collection sur une égalité
stricte de taille fait rater tout le chemin sans fil.

## 2. Trame

Trame de 16 octets, identique dans les deux sens.

```
 0    1       2      3      4      5 .. 14     15
+----+-------+------+------+------+-----------+------+
|cmd |status |addrHi|addrLo| len  |  data[10] | csum |
+----+-------+------+------+------+-----------+------+
```

- `cmd` — code commande (§3), ré-émis tel quel par la souris dans sa réponse.
- `status` — `0` réponse porteuse de données, `1` acquittement sans données.

  **`1` ne veut pas dire « erreur ».** Pour une commande de lecture, l'absence de données
  vaut refus, et c'est ainsi que les capacités se détectent : `GetLongRangeMode` répondant
  `1` signifie « ce modèle n'a pas le mode longue portée ». Mais pour une commande
  d'action, `1` est l'acquittement normal — la prise de verrou `DeviceOnLine` répond `1`
  derrière un dongle. Traiter `1` comme une erreur générique bloque toute écriture sans fil.
- `addrHi`/`addrLo` — adresse flash big-endian, pour les commandes flash uniquement.
- `len` — nombre d'octets utiles dans `data`, **10 au maximum**.
- Pour les commandes non-flash, la charge utile commence à l'octet `5` et `len` en donne la taille.

### Checksum

La somme du report ID et des 16 octets de trame vaut `0x55` modulo 256 :

```
somme(reportID, trame[0..15]) ≡ 0x55  (mod 256)
```

soit `trame[15] = (0x55 − somme(trame[0..14]) − reportID) mod 256`.

Le même invariant sert de **checksum interne aux blocs de réglages** écrits en flash :
le dernier octet d'un bloc vaut `0x55 − somme(octets précédents)`, sans report ID.
Attention : pour le bloc macro, ce checksum est en plus diminué du nombre d'étapes.

### Acquittement

Après émission, la souris renvoie un rapport dont les premiers octets répètent la requête.
Le site compare **3 octets** (5 pour `ReadFlashData`), réessaie jusqu'à 5 fois, avec une
attente de 5 ms par tour et 40 tours au maximum, soit un timeout de ~200 ms par tentative.

## 3. Commandes

| Code | Nom | Rôle |
|---|---|---|
| 1 | `EncryptionData` | Handshake. Requête : 4 octets aléatoires puis 4 zéros — une trame vide est rejetée. Réponse : `cid=data[9]`, `mid=data[10]`, `type=data[11]`, `dongleType=data[12]` |
| 2 | `PCDriverStatus` | Signale au périphérique qu'un logiciel est actif |
| 3 | `DeviceOnLine` | `online=data[5]`, adresse d'appairage `data[6..8]` (ordre inverse). Sert aussi de verrou : émise avec `data[5] = 1` avant un lot d'écritures et `0` après, en attendant que `data[9]` retombe à zéro |
| 4 | `BatteryLevel` | `niveau=data[5]`, `enCharge=data[6]`, `tension=(data[7]<<8)+data[8]` mV |
| 5 | `DongleEnterPair` | Passe le dongle en appairage |
| 6 | `GetPairState` | `état=data[5]` (1 en cours, 2 échec, 3 succès), `secondesRestantes=data[6]` |
| 7 | `WriteFlashData` | Écriture, 10 octets par trame |
| 8 | `ReadFlashData` | Lecture, 10 octets par trame |
| 9 | `ClearSetting` | Réinitialisation complète |
| 10 | `StatusChanged` | Notification spontanée : bitmask `data[5]` et `data[6]` des groupes à relire |
| 11 | `SetDeviceVidPid` | — |
| 12 | `SetDeviceDescriptorString` | — |
| 13 | `EnterUsbUpdateMode` | Phase 2 uniquement |
| 14 | `GetCurrentConfig` | Profil actif dans `data[5]` ; `status = 1` ⇒ modèle sans profils |
| 15 | `SetCurrentConfig` | Change de profil |
| 16 | `ReadCIDMID` | — |
| 17 | `EnterMTKMode` | Phase 2 uniquement |
| 18 | `ReadVersionID` | Version : `"v" + data[5] + "." + hex2(data[6])` |
| 20 | `Set4KDongleRGB` | `mode=data[5]`, puis trois couleurs RGB en `6`, `9`, `12` |
| 21 | `Get4KDongleRGBValue` | `mode=data[5]`, trois couleurs RGB en `6`, `9`, `12` |
| 22 | `SetLongRangeMode` | — |
| 23 | `GetLongRangeMode` | `actif=data[5]` ; `status = 1` ⇒ non supporté |
| 24 | `SetPulsarDongleLightParam` | — |
| 25 | `GetPulsarDongleLightParam` | `mode`, couleur `6..8`, `vitesse=9`, `luminosité=10`, `durée=11` |
| 29 | `GetDongleVersion` | Même format de version que `ReadVersionID` |
| 35 | `SetPulsarDongleKeyFunction` | — |
| 36 | `GetPulsarDongleKeyFunction` | — |
| 37 | `SetPulsarDongleDPILightParam` | — |
| 38 | `GetPulsarDongleDPILightParam` | — |
| 39 | `SetPulsarDongleOButtonCurrentMode` | — |
| 40 | `GetPulsarDongleOButtonCurrentMode` | — |
| 41 | `SetPulsarDongleOButtonFunction` | Index dans `data[5]`, mode `6`, couleur `7..9`, vitesse `10`, luminosité `11`, durée `12` |
| 42 | `GetPulsarDongleOButtonFunction` | — |
| 43 | `GetRSSIValue` | `rssi=data[5]` ; `status = 1` ⇒ non supporté |
| 176 | `MusicColorful` | — |
| 177 | `MusicSingleColor` | — |
| 240 | `WriteKBCIdMID` | Claviers |
| 241 | `ReadKBCIdMID` | Claviers |

### Type de connexion (`data[11]` du handshake)

| Type | Connexion | Polling maximal |
|---|---|---|
| 0 | sans fil | 1 kHz |
| 1 | sans fil | 4 kHz |
| 2 | filaire | 1 kHz |
| 3 | filaire | 8 kHz |
| 4 | sans fil | 2 kHz |
| 5 | sans fil | 8 kHz |

## 4. Carte des adresses flash

Les réglages vivent dans une flash de configuration lue en bloc de `0x0000` à `0x0100`
à la connexion, puis complétée par la zone DPI du capteur 3955 si nécessaire.

| Adresse | Champ | Taille |
|---|---|---|
| 0 | `ReportRate` | 2 |
| 2 | `MaxDpiStage` | 2 |
| 4 | `CurrentDPI` | 2 |
| 10 | `LOD` | 2 |
| 12 | `DPIValue` | 4 par palier |
| 44 | `DPIColor` | 4 par palier |
| 76 | `DPIEffectMode` | 2 |
| 78 | `DPIEffectBrightness` | 2 |
| 80 | `DPIEffectSpeed` | 2 |
| 82 | `DPIEffectState` | 2 |
| 96 | `KeyFunction` | 4 par bouton |
| 160 | `Light` | 7 |
| 169 | `DebounceTime` | 2 |
| 171 | `MotionSync` | 2 |
| 173 | `SleepTime` | 2 |
| 175 | `AngleSnap` | 2 |
| 177 | `RippleControl` | 2 |
| 179 | `MovingOffLight` | 2 |
| 181 | `PerformanceState` | 2 |
| 183 | `Performance` | 2 |
| 185 | `SensorMode` | 2 |
| 189 | `AngleTune` | 2 |
| 191 | `AngleTuneState` | 2 |
| 215 | `PowerSaveBattery` | 2 |
| 217 | `PowerSaveTime` | 2 |
| 231 | `FanMode` | 2 |
| 256 | `ShortcutKey` | 32 par emplacement |

`SleepTime` et `Performance` contiennent le même code de délai, exprimé en unités
de 10 secondes. Les valeurs proposées par l'application officielle sont `1`, `3`,
`6`, `30`, `60` et `180`, soit 10 s, 30 s, 1 min, 5 min, 10 min et 30 min.
Toute modification du délai doit écrire la même valeur aux adresses 173 et 183.
| 768 | `Macro` | 384 par emplacement |
| 6912 | `Sensor3955DPI` | 6 par palier |

### Réglage scalaire

Tout réglage « taille 2 » s'écrit `[valeur, 0x55 − valeur]`. La relecture doit retrouver
les deux octets ; un second octet incohérent signale une flash corrompue.

### Palier DPI

Le DPI brut est encodé sur 18 bits répartis avec un facteur d'échelle (`dpiEx`) dépendant
du capteur. Pour les capteurs autres que 3955, 4 octets par palier :

```
data[0] = xVal & 0xFF
data[1] = yVal & 0xFF
data[2] = ((xVal >> 8) << 2) | ((yVal >> 8) << 6) | xEx | (yEx << 4)
data[3] = checksum
```

Pour le capteur 3955 (jusqu'à 42000 DPI), 6 octets par palier :

```
data[0..1] = xVal (little-endian)
data[2..3] = yVal (little-endian)
data[4]    = ((xVal >> 16) << 2) | ((yVal >> 16) << 6) | xEx | (yEx << 4)
data[5]    = checksum
```

### Couleur de palier

3 octets RGB puis un checksum, à `DPIColor + 4 × palier`.

### Fonction de bouton

4 octets à `KeyFunction + 4 × bouton` : `[type, param >> 8, param & 0xFF, checksum]`.
Exception `DPILock`, dont le paramètre est un DPI encodé : `[type, val & 0xFF, val >> 8, checksum]`.

Types de fonction :

| Code | Fonction |
|---|---|
| 0 | Désactivé |
| 1 | Bouton souris |
| 2 | Changement de DPI |
| 3 | Défilement horizontal |
| 4 | Tir rapide |
| 5 | Raccourci clavier |
| 6 | Macro |
| 7 | Changement de polling |
| 8 | Éclairage |
| 9 | Changement de profil |
| 10 | Verrouillage DPI |
| 11 | Défilement vertical |
| 256 | Clic gauche |

### Macro

Un emplacement par bouton : la macro du bouton *n* occupe 384 octets à `Macro + 384 × n`.
Le nombre de répétitions n'est pas stocké là mais dans l'octet de poids faible du
paramètre du bouton — le poids fort portant le numéro d'emplacement.

```
[0]              longueur du nom, en octets UTF-8 (1 à 30)
[1..30]          nom
[31]             nombre d'étapes (0 à 70)
[32 + 5n]        (état << 6) | nature
[32 + 5n + 1]    valeur, poids faible
[32 + 5n + 2]    valeur, poids fort
[32 + 5n + 3]    délai, poids fort
[32 + 5n + 4]    délai, poids faible
[32 + 5c]        checksum
```

La valeur est petit-boutiste et le délai gros-boutiste, dans le même bloc.
Le checksum couvre l'octet de comptage et les étapes, mais pas le nom.

**L'état est inversé par rapport à l'intuition** : un appui s'écrit `2`, un relâchement
`1`, et `0` marque une étape sans état. Se tromper produit une macro qui relâche avant
d'appuyer, sans qu'aucun checksum ne le signale.

Natures d'étape :

| Code | Nature | Valeur |
|---|---|---|
| 0 | Modificateur | Code HID de la touche |
| 1 | Touche | Code HID de la touche |
| 2 | Touche multimédia | Code consumer |
| 4 | Bouton souris | Masque : 1 gauche, 2 droit, 4 molette, 8 précédent, 16 suivant |
| 5 | Déplacement | `(y << 8) \| x`, chaque axe signé sur un octet, borné à ±127 |
| 6 | Molette | 1 vers le haut, 255 vers le bas |
| 7 | Touche menu | Code HID |

Les natures 4 à 6 portent un délai nul : leur cadence vient de l'étape précédente.
Le délai accepté par l'éditeur officiel va de 10 à 65535 ms.

Une macro se lit en deux temps : l'en-tête donne la longueur du nom et le nombre
d'étapes, ce qui détermine combien lire ensuite. Relire les 384 octets coûterait
trente-neuf trames au lieu de six.

### Raccourci clavier

Bloc de 32 octets à `ShortcutKey + 32 × emplacement`. Premier octet = `2 × nombre de touches`.
Puis, pour chaque touche dans l'ordre, `[0x80 | type, valeur & 0xFF, valeur >> 8]` (appui),
suivi des mêmes touches en ordre inverse avec `[0x40 | type, …]` (relâchement).
Une valeur de premier octet supérieure à 2 indique un raccourci multi-touches à relire
au-delà des 10 premiers octets.

## 5. Notifications `StatusChanged`

La souris pousse un rapport `cmd = 10` quand un réglage change côté matériel (bouton DPI,
changement de profil). Deux bitmasks indiquent les groupes à relire :

`data[5]` — bit 0 batterie, bit 1 réglages généraux, bit 2 reconnexion,
bit 3 éclairage, bit 5 profil, bit 6 version.
`data[6]` — bit 0 DPI, bit 1 boutons, bit 2 effet DPI, bit 3 dongle, bit 4 veille, bit 5 ventilateur.

L'application doit suspendre ses propres échanges pendant la relecture.

## 6. Catalogue

`cfg.json` déclare deux VID (`0x3710`, `0x3554`), 40 PID filaires et 7 sans fil pour les
souris, et un unique CID `87` regroupant 31 profils de capacités indexés par MID
(1 à 127). Chaque profil porte capteur, DPI maximal, nombre de boutons, paliers par défaut,
thème et binaires firmware. Le catalogue embarqué est un instantané versionné de ce fichier.

## 6 bis. Polling

L'octet à l'adresse `0` porte un diviseur jusqu'à 1 kHz et un multiple au-delà :

| Cadence | Code | Formule |
|---|---|---|
| 125 Hz | 8 | `1000 / hz` |
| 250 Hz | 4 | `1000 / hz` |
| 500 Hz | 2 | `1000 / hz` |
| 1 kHz | 1 | `1000 / hz` |
| 2 kHz | 16 | `hz / 125` |
| 4 kHz | 32 | `hz / 125` |
| 8 kHz | 64 | `hz / 125` |

Le bundle officiel expose **deux encodeurs contradictoires**. Celui qui est réellement
appelé avant l'écriture flash calcule `hz / 2000 × 16`, et le décodeur `code / 16 × 2000`
en est l'inverse exact. Un second encodeur, exporté dans l'objet utilitaire mais jamais
appelé, calculerait `hz / 1000 × 16`, soit le double — c'est du code mort. L'implémentation
Swift reprend le premier.

## 6 ter. Veille et performance

Deux adresses portent volontairement le même délai :

| Adresse | Champ | Exemple | Délai |
|---|---|---|---|
| `0x00AD` | `SleepTime` | 6 | 1 min |
| `0x00B7` | `Performance` | 6 | 1 min |

Le configurateur officiel écrit les deux champs à chaque changement. N'en modifier
qu'un laisse le second à sa valeur précédente ; le firmware peut alors utiliser ce
second délai et mettre la souris en veille bien plus tôt que ce qu'affiche l'interface.

## 7. Ce qui reste à vérifier sur matériel

- Branche haute du codec de polling : cohérente entre encodeur et décodeur officiels,
  mais jamais observée sur une souris réglée au-dessus de 1 kHz.
- Contenu des 7 octets à `Light` (160).
- Sémantique de `Performance` / `PerformanceState` / `SensorMode` par famille de capteur.
- Comportement de `MovingOffLight` et `FanMode` sur les modèles concernés.
