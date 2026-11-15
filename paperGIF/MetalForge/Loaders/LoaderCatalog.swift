import SwiftUI

public enum LoaderDefaults {
    public static let size: CGFloat = 96
    public static let speed: Double = 1.5
}

enum LoaderCatalog {

    static let keyframes: [String: [LoaderKeyStop]] = [
        "om-scroll-tick": [
            LoaderKeyStop(1, transform: [.translateX(-14)])
        ],
        "om-scroll-wave": [
            LoaderKeyStop(1, transform: [.translateX(-56)])
        ]
    ]

    static let all: [LoaderSpec] = [
        makeSignal()
    ]

    static let byId: [String: LoaderSpec] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    private static func makeSignal() -> LoaderSpec {
        LoaderSpec(
            id: "signal",
            title: "Signal",
            group: "compound",
            box: 56,
            root:
                LoaderNode(
                    .box,
                    frame: CGRect(x: 0, y: 0, width: 56, height: 56),
                    clip: true,
                    mask: .linear(axisY: false, 0, 0.16, 0.84, 1),
                    children: [
                        LoaderNode(
                            .box,
                            frame: CGRect(x: 0, y: 8, width: 112, height: 40),
                            gradient: .linearTicks(axisX: true, period: 14, width: 1, paint: .ink(0.09)),
                            anim: [LoaderTrack("om-scroll-tick", dur: 1.4)]
                        ),
                        LoaderNode(
                            .box,
                            frame: CGRect(x: 0, y: 28, width: 56, height: 1),
                            fill: .ink(0.1)
                        ),
                        LoaderNode(
                            .svg,
                            frame: CGRect(x: 0, y: 0, width: 112, height: 56),
                            anim: [LoaderTrack("om-scroll-wave", dur: 2.8)],
                            children: [
                                LoaderNode(
                                    .path("M0 28 h5 l3 -7 l3 14 l3 -7 h6 l2 -14 l2 24 l2 -10 h5 l3 6 l3 -6 h4 l2 -4 l2 8 l2 -4 h9 h5 l3 -7 l3 14 l3 -7 h6 l2 -14 l2 24 l2 -10 h5 l3 6 l3 -6 h4 l2 -4 l2 8 l2 -4 h9"),
                                    fill: .clear,
                                    stroke: .accent(1),
                                    strokeWidth: 1.6,
                                    roundCap: true,
                                    roundJoin: true
                                )
                            ]
                        )
                    ]
                )
        )
    }
}
