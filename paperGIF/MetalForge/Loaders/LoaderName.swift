import SwiftUI

public enum LoaderName: String, CaseIterable, Identifiable, Hashable {
    case signal = "signal"

    public var id: String { rawValue }

    public var title: String { spec.title }

    public var group: String { spec.group }

    public var spec: LoaderSpec { LoaderCatalog.byId[rawValue] ?? LoaderCatalog.all[0] }

    public var swiftCase: String {
        rawValue.split(separator: "-").enumerated().map { index, part in
            index == 0 ? String(part) : part.capitalized
        }.joined()
    }
}
