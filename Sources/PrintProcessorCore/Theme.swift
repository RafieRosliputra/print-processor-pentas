import Foundation

/// Dark Photoshop-like palette and brand constants. Pure data only (no AppKit here);
/// the executable target converts the hex values into NSColor.
public enum Theme {
    /// Panel / chrome background.
    public static let panelHex = "#323232"
    /// Border / divider color.
    public static let borderHex = "#535353"
    /// Canvas working-area background.
    public static let canvasHex = "#1E1E1E"
    /// Orange glow / accent used around the canvas and for the Process button.
    public static let glowHex = "#FF8C00"
    /// Dimmed secondary text.
    public static let dimTextHex = "#9A9A9A"

    /// Brand string as written (no space).
    public static let brand = "JohorStudio.com"
    /// UI font family (SF Pro is the macOS system font).
    public static let fontFamily = "SF Pro"
}
