# Bibimbap — backlog produit

Backlog de référence pour faire évoluer le configurateur macOS Pulsar. Les priorités
reflètent l'impact utilisateur et le risque matériel, pas seulement la facilité
d'implémentation.

## Légende

- **P0** : bloquant ou risque de fiabilité matériel.
- **P1** : fonctionnalité importante pour une première version réellement complète.
- **P2** : amélioration de confort, de support ou de qualité.
- **P3** : idée long terme ou dépendante d'informations externes.

Types : **Fiabilité**, **Fonctionnalité**, **UX**, **Distribution**, **Technique**.

## État déjà couvert

- Interface native macOS avec Vue d'ensemble, Personnaliser, Performance, Macros,
  Alimentation et Réglages.
- Écritures prudentes : validation, relecture indépendante, rollback et remontée d'un
  état matériel incertain.
- DPI, polling, capteur, veille, profils, macros, appairage du récepteur, sauvegarde JSON,
  export diagnostic et accessoire de barre des menus.
- Catalogue embarqué versionné couvrant 31 familles et 127 identifiants de modèles.
- Apparence Système, largeur de sidebar ajustable et navigation clavier des macros.

## P0 — fiabilité et connexion

> **État au 2026-08-01 :** BIB-001 à BIB-003 sont implémentées et couvertes par les tests
> automatisés (`PulsarHIDTests`, `SimulatorFaultTests`, `DeviceControllerTests`,
> `AppModelTests`). La validation physique sur X2 CrazyLight et récepteur 8K reste à faire :
> tant qu'elle n'a pas eu lieu, ces trois items sont « automatisé validé, validation physique
> restante » et non clos. La procédure est décrite dans
> [docs/troubleshooting.md](docs/troubleshooting.md).

### BIB-001 — Stabiliser l'ouverture HID et le handshake sans fil

**Type :** Fiabilité  
**Constat :** le chemin `IOKitHIDTransport` / `DeviceController` doit être validé de
bout en bout sur un récepteur réel, notamment permissions macOS, ouverture de la bonne
interface de configuration et attente de la souris derrière le dongle.

**À faire :** journaliser les interfaces candidates, distinguer clairement permission,
ouverture refusée, souris hors ligne et timeout de handshake, puis ajouter une procédure
de réessai guidée.

**Fait :** `HIDTransportError` distingue désormais `permissionDenied` et
`managerOpenFailed` des autres codes `IOReturn`; le résultat de `IOHIDManagerOpen` est
vérifié au lieu d'être ignoré et l'ouverture reste non exclusive. `DeviceController`
applique une séquence stricte (découvrir → ouvrir → session → identifier → catalogue →
attente en ligne → driver → relecture complète) et referme systématiquement session et
transport à chaque échec. Les causes sont typées : permission, interface disparue,
handshake expiré, souris hors ligne, modèle inconnu, erreur de communication. Une seule
ré-énumération est tentée sur disparition transitoire, aucune sur permission refusée. Un
journal de connexion (phase, candidat, résultat, code système, horodatage) est exporté
avant les trames dans le rapport de diagnostic.

**Terminé quand :** USB et récepteur sont détectés, ouverts et relus de façon répétable
sur les appareils de référence, avec un message actionnable pour chaque échec.
→ *Reste : la validation sur matériel de référence.*

### BIB-002 — Choisir le périphérique quand plusieurs interfaces sont présentes

**Type :** Fiabilité / UX  
**Constat :** `AppModel.connect()` utilise actuellement le premier périphérique retourné
par `availableDevices()`.

**À faire :** afficher une liste de souris/récepteurs candidats avec nom, transport,
VID/PID, emplacement et état, puis mémoriser uniquement l'identifiant nécessaire pour
la reconnexion.

**Fait :** `HIDDeviceIdentifier.stableKey` identifie un périphérique indépendamment du
port et des tailles de rapport annoncées. `AppModel` expose `availableCandidates`,
`selectedStableKey`, `connect(to:)`, `cancelDeviceSelection()` et `retryConnection()`;
un seul candidat se connecte automatiquement, plusieurs passent par `DeviceSelectionView`.
Une unique tâche de connexion est partagée entre la fenêtre et la barre des menus. Après
l'échec d'un candidat, la liste reste disponible et aucun autre périphérique physique
n'est ouvert automatiquement.

**Terminé quand :** aucun périphérique voisin ne peut être sélectionné par erreur et
l'utilisateur peut changer de cible sans relancer l'application.
→ *Reste : la vérification avec deux périphériques physiques.*

### BIB-003 — Reconnexion automatique et gestion du réveil

**Type :** Fiabilité  
**À faire :** réagir aussi aux événements d'attachement, aux sorties de veille macOS et
au retour de la souris derrière le récepteur; proposer de récupérer les modifications
non appliquées au lieu de les perdre silencieusement.

**Fait :** un débranchement subi ne passe plus par `disconnect()` — le brouillon, sa base
et la cible restent en mémoire. La reprise est bornée (5 tentatives, 250 ms → 2 s, ~10 s
au total), non concurrente, insensible aux évènements dupliqués, et déclenchée aussi par
`NSWorkspace.didWakeNotification`. Toute reconnexion relit un instantané complet. Si le
brouillon et l'état relu divergent, `DraftRecovery` présente les changements locaux,
distants et en conflit, et Apply reste fermé jusqu'au choix entre « Conserver mon
brouillon » et « Adopter les réglages relus » — aucune de ces actions n'écrit. Une
écriture interrompue conserve l'état incertain et exige une relecture explicite.

**Terminé quand :** un débranchement/rebranchement conserve un état explicite, ne lance
pas deux scans concurrents et ne détruit jamais un brouillon sans avertissement.
→ *Reste : débranchement/rebranchement et veille/réveil sur matériel réel.*

## P1 — compléter le produit

### BIB-010 — Rendre les paramètres de boutons réellement configurables

**Type :** Fonctionnalité  
**Constat :** la liste permet de choisir une fonction, mais plusieurs paramètres restent
des valeurs par défaut. Le protocole possède déjà `FlashMap.shortcut`, tandis que la
lecture/écriture des raccourcis clavier et des cibles DPI/profil n'est pas complète.

**À faire :** ajouter des éditeurs contextuels pour bouton souris, DPI cible, profil,
macro, cadence, éclairage et raccourci clavier; modéliser leur encodage, leur lecture,
leur validation et leur rollback.

**Terminé quand :** chaque fonction affichée dans Customize peut être paramétrée, relue
et restaurée sans octet laissé à une valeur arbitraire.

### BIB-011 — Améliorer l'éditeur de macros

**Type :** Fonctionnalité / UX  
**À faire :** ajouter sélecteurs de touches et médias, enregistrement depuis le clavier
et la souris, insertion/suppression multiple, réordonnancement, duplication et aperçu
lisible des délais; signaler les limites en octets et étapes pendant l'édition.

**Terminé quand :** une macro courante peut être créée sans saisir de codes numériques,
puis relue identique depuis le périphérique.

### BIB-012 — Compléter la configuration DPI et de l'éclairage

**Type :** Fonctionnalité / UX  
**Constat :** la couleur d'un palier est affichée comme un indicateur mais n'est pas
éditable, le contrôle principal ne permet pas de régler clairement X et Y séparément,
et `DPIEffect.speed` est stocké/écrit sans contrôle visible.

**À faire :** ajouter ColorPicker/palettes, édition X/Y avec verrouillage des axes,
contrôle de vitesse, aperçu de l'effet et affichage des valeurs réellement
représentables par le capteur.

**Terminé quand :** chaque champ affiché est modifiable, validé selon le codec du capteur
et confirmé par une relecture.

### BIB-013 — Donner accès aux réglages avancés du récepteur

**Type :** Fonctionnalité  
**À faire :** compléter l'éclairage du dongle au-delà du simple on/off : mode, couleurs,
effets et, si le modèle le permet, éclairage DPI et bouton du récepteur. N'afficher que
les commandes sondées comme supportées.

**Terminé quand :** les couleurs sont préservées lors d'un on/off, chaque écriture est
relue et les modèles incompatibles n'affichent pas de faux contrôles.

### BIB-014 — Exposer les capacités déjà décrites mais non reliées à l'UI

**Type :** Fonctionnalité / Technique  
**Constat :** le catalogue et le protocole préparent notamment `fanMode`, le mode capteur
et certains niveaux de performance, mais ils ne forment pas encore un flux complet
`DeviceSettings` → validation → `WritePlan` → relecture → interface.

**À faire :** décider, pour chaque capacité, si elle est supportée, expérimentale ou à
retirer du catalogue; implémenter le chemin complet ou la masquer explicitement.

**Terminé quand :** aucune capacité n'est annoncée sans comportement vérifié et aucun
champ mort ne peut créer un état différent entre l'écran et le matériel.

### BIB-015 — Gestionnaire de profils plus complet

**Type :** Fonctionnalité / UX  
**À faire :** afficher clairement le profil actif, comparer deux profils, copier les
réglages vers un autre profil, importer avec aperçu des changements et exporter le
profil sélectionné plutôt qu'un état ambigu.

**Terminé quand :** l'utilisateur peut sauvegarder, prévisualiser et appliquer un profil
en sachant exactement quel emplacement matériel sera modifié.

### BIB-016 — Rendre les changements et erreurs plus lisibles

**Type :** UX / Fiabilité  
**À faire :** remplacer les diffusions d'octets brutes par des valeurs utilisateur
(`800 → 1600 DPI`, `1 kHz → 4 kHz`), afficher la progression par opération, fournir
"Relire et comparer", "Exporter le diagnostic" et une récupération dédiée pour un état
matériel incertain.

**Terminé quand :** avant et après une écriture, l'utilisateur comprend ce qui sera
modifié, ce qui a réussi et ce qui doit être vérifié.

### BIB-017 — Préparer une distribution installable

**Type :** Distribution  
**À faire :** produire un ZIP/DMG versionné, signé et documenté, avec contrôle de
notarisation si possible, instructions de permission HID et notes de version. Ajouter
une page de téléchargement reproductible depuis GitHub Actions.

**Terminé quand :** une personne qui ne possède pas Xcode peut installer, ouvrir et
mettre à jour Bibimbap sans lancer de commande Swift.

### BIB-018 — Élargir la matrice de validation matérielle

**Type :** Technique / Fiabilité  
**À faire :** sélectionner des appareils représentatifs par capteur, connexion et
famille; conserver fixtures, version firmware, opérations validées et limites connues.
Tester en particulier les cadences sans fil supérieures à 1 kHz.

**Terminé quand :** la documentation distingue clairement modèle déclaré au catalogue,
modèle simulé, fixture capturée et modèle validé physiquement.

## P2 — qualité et confort

### BIB-020 — Persister les préférences d'interface utiles

Mémoriser largeur de sidebar, taille de fenêtre et éventuellement dernière position,
avec une valeur par défaut stable. Conserver l'ouverture sur Vue d'ensemble au lancement.

### BIB-021 — Alertes et actions liées à la batterie

Ajouter seuil configurable, indication de charge plus visible, rappel lorsque la batterie
est faible et rafraîchissement contrôlé sans écraser un brouillon en cours.

### BIB-022 — Audit accessibilité et localisation

Passer en revue VoiceOver, navigation clavier, focus, contrastes, tailles de fenêtre et
libellés anglais/français. Ajouter des tests pour les contrôles critiques et supprimer
les chaînes qui ne suivent pas le sélecteur de langue.

### BIB-023 — Enrichir l'accessoire de barre des menus

Ajouter un résumé de synchronisation, l'état d'un brouillon, un accès à la reconnexion,
les alertes batterie et les actions profil uniquement lorsqu'elles sont sûres et
disponibles pour le modèle.

### BIB-024 — Documentation et support utilisateur

Remplacer le placeholder de captures d'écran, ajouter un tableau de compatibilité réel,
un guide de permission macOS, une FAQ HID et un modèle de rapport de bug avec diagnostic.

### BIB-025 — Renforcer la CI et les tests UI

Traiter le blocage de terminaison observé sur la suite complète, ajouter des tests pour
permissions/handshake/multi-périphériques/conflits, et compléter les tests UI des flux
Customize, Performance, Power, import et erreur d'écriture.

## P3 — à étudier séparément

### BIB-030 — Mise à jour firmware

Conserver la fonctionnalité bloquée tant que le protocole, les images officielles,
les contrôles d'intégrité, les conditions USB/batterie et une stratégie de récupération
ne sont pas documentés. Commencer par une note de cadrage en lecture seule, sans envoyer
de commande de mise à jour au matériel.

## Ordre recommandé

1. **BIB-001 → BIB-003** : rendre la connexion réelle prévisible.
2. **BIB-016** : sécuriser la compréhension et la récupération des écritures.
3. **BIB-010 → BIB-012** : fermer les trous les plus visibles dans Customize, Macros et DPI.
4. **BIB-015, BIB-018 et BIB-017** : profils, validation matérielle et distribution.
5. **BIB-013, BIB-014 puis P2** : compléter les capacités et polir l'expérience.

