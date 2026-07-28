import AppKit

/// L'icône affichée dans la barre des menus.
///
/// Elle est dessinée plutôt que composée à partir de symboles système, pour une raison
/// précise : un `Image(systemName:)` suivi d'un texte de pourcentage s'étire en largeur et
/// bouge à chaque point de batterie perdu. Ici l'emprise est un carré fixe de 18 × 18, et
/// le niveau de batterie est le remplissage du corps de la souris — l'icône change d'aspect
/// sans jamais changer de taille.
///
/// L'image est marquée `isTemplate`, donc teintée par le système : elle suit le thème clair
/// ou sombre, la barre translucide et la sélection du menu, sans code de couleur ici.
public enum MenuBarIcon {
    /// Côté du carré, en points. Taille standard d'un accessoire de barre des menus.
    public static let side: CGFloat = 18

    /// - Parameters:
    ///   - batteryPercent: niveau relu, ou `nil` en filaire et quand il n'est pas connu.
    ///   - isCharging: remplace le niveau par un éclair, comme le fait le système.
    ///   - isConnected: à faux, l'icône s'estompe au lieu de disparaître.
    public static func image(
        batteryPercent: Int?,
        isCharging: Bool = false,
        isConnected: Bool = true
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            let alpha: CGFloat = isConnected ? 1 : 0.4
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()

            draw(batteryPercent: batteryPercent, isCharging: isCharging && isConnected)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(
            batteryPercent: batteryPercent, isCharging: isCharging, isConnected: isConnected
        )
        return image
    }

    // MARK: Tracé

    /// Corps de la souris : une capsule verticale, centrée dans le carré.
    private static var body: NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: 4, y: 1.5, width: 10, height: 15),
            xRadius: 5, yRadius: 5
        )
    }

    private static func draw(batteryPercent: Int?, isCharging: Bool) {
        let outline = body
        outline.lineWidth = 1.4
        outline.stroke()

        if isCharging {
            fillInterior(fraction: 1)
            punchBolt()
        } else if let percent = batteryPercent {
            fillInterior(fraction: CGFloat(min(max(percent, 0), 100)) / 100)
        }

        // La molette, dessinée en dernier : c'est le détail qui fait reconnaître une souris
        // plutôt qu'une pastille, et le remplissage l'avalerait s'il passait par-dessus.
        // Elle est posée dans une réserve creusée dans le remplissage, donc elle se lit
        // aussi bien sur un corps plein que sur un corps vide.
        punchWheelClearance()
        let wheel = NSBezierPath()
        wheel.move(to: NSPoint(x: 9, y: 11.2))
        wheel.line(to: NSPoint(x: 9, y: 13.9))
        wheel.lineWidth = 1.4
        wheel.lineCapStyle = .round
        wheel.stroke()
    }

    private static func punchWheelClearance() {
        let clearance = NSBezierPath(
            roundedRect: NSRect(x: 7.3, y: 10.1, width: 3.4, height: 4.9),
            xRadius: 1.7, yRadius: 1.7
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        clearance.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Remplit l'intérieur du corps depuis le bas, à hauteur du niveau de batterie.
    private static func fillInterior(fraction: CGFloat) {
        guard fraction > 0 else { return }
        let interior = NSBezierPath(
            roundedRect: NSRect(x: 5.4, y: 2.9, width: 7.2, height: 12.2),
            xRadius: 3.6, yRadius: 3.6
        )
        NSGraphicsContext.saveGraphicsState()
        interior.addClip()
        NSBezierPath(rect: NSRect(x: 5.4, y: 2.9, width: 7.2, height: 12.2 * fraction)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Découpe un éclair dans le remplissage, plutôt que de le poser par-dessus :
    /// sur une image teintée, un éclair plein sur un fond plein serait invisible.
    private static func punchBolt() {
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 10.1, y: 10.0))
        bolt.line(to: NSPoint(x: 7.6, y: 6.3))
        bolt.line(to: NSPoint(x: 9.1, y: 6.3))
        bolt.line(to: NSPoint(x: 8.0, y: 3.4))
        bolt.line(to: NSPoint(x: 10.5, y: 7.1))
        bolt.line(to: NSPoint(x: 9.0, y: 7.1))
        bolt.close()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func accessibilityDescription(
        batteryPercent: Int?, isCharging: Bool, isConnected: Bool
    ) -> String {
        guard isConnected else { return String(localized: "Bibimbap, aucune souris") }
        guard let percent = batteryPercent else { return String(localized: "Bibimbap") }
        return isCharging
            ? String(localized: "Bibimbap, batterie \(percent) %, en charge")
            : String(localized: "Bibimbap, batterie \(percent) %")
    }
}
