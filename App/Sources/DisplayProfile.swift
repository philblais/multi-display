import Foundation

enum DisplayProfile: String, CaseIterable, Identifiable {
    case automatic
    case samsungHG50U701FNF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .samsungHG50U701FNF: return "Samsung HG50U701FNF"
        }
    }

    var modelCode: String? {
        self == .samsungHG50U701FNF ? "HG50U701FNFXZA" : nil
    }

    func resolved(reportedName: String, isBuiltIn: Bool) -> DisplayProfile {
        guard !isBuiltIn else { return .automatic }
        guard self == .automatic else { return self }
        // A generic "SAMSUNG" name cannot identify the model; the user can select it.
        let identifiers: Set<String> = [
            "HG50U701FNF", "HG50U701FNFXZA", "HG50U701F"
        ]
        let words = reportedName.uppercased().components(separatedBy: .alphanumerics.inverted)
        return words.contains(where: identifiers.contains) ? .samsungHG50U701FNF : .automatic
    }
}

enum BrightnessControl: Equatable {
    case unavailable
    case native
    case ddc
    case software

    var title: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .native: return "MacBook brightness"
        case .ddc: return "Hardware brightness"
        case .software: return "Software dimming"
        }
    }
}
