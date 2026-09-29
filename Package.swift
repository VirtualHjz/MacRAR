// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacRAR",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacRAR", targets: ["MacRAR"])
    ],
    targets: [
        // UnRAR SDK (C++) 解压引擎，通过 C wrapper 暴露给 Swift
        .target(
            name: "CUnrar",
            path: "Sources/CUnrar",
            exclude: [
                "include",
                // include-based 编译单元（被其他 .cpp #include）
                "sources/blake2s_sse.cpp", "sources/blake2sp.cpp",
                "sources/crypt1.cpp", "sources/crypt2.cpp", "sources/crypt3.cpp", "sources/crypt5.cpp",
                "sources/unpack15.cpp", "sources/unpack20.cpp", "sources/unpack30.cpp",
                "sources/unpack50.cpp", "sources/unpack50frag.cpp", "sources/unpack50mt.cpp",
                "sources/unpackinline.cpp", "sources/model.cpp", "sources/suballoc.cpp", "sources/coder.cpp",
                "sources/threadmisc.cpp", "sources/arccmt.cpp",
                "sources/hardlinks.cpp", "sources/ulinks.cpp", "sources/uowners.cpp",
                "sources/uisilent.cpp", "sources/uiconsole.cpp", "sources/uicommon.cpp",
                "sources/cmdfilter.cpp", "sources/cmdmix.cpp", "sources/log.cpp",
                "sources/recvol3.cpp", "sources/recvol5.cpp",
                // 未使用的独立文件
                "sources/isnt.cpp", "sources/motw.cpp", "sources/rarpch.cpp",
                "sources/win32acl.cpp", "sources/win32lnk.cpp", "sources/win32stm.cpp",
                "sources/recvol.cpp", "sources/rs.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("UNRAR"),
                .define("RARDLL"),
                .define("RAR_SMP"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
            ],
            linkerSettings: [
                .linkedLibrary("pthread")
            ]
        ),
        // 纯 Swift ZIP 引擎（基于 zlib）
        .target(
            name: "ZIPCore",
            dependencies: []
        ),
        // 核心引擎与模型（MacRAR UI 与测试共用）
        // 核心引擎、模型与服务（供 UI 与测试共用）
        .target(
            name: "MacRARCore",
            dependencies: ["CUnrar", "ZIPCore"],
            path: "Sources/MacRAR/Core"
        ),
        .executableTarget(
            name: "MacRAR",
            dependencies: ["MacRARCore", "CUnrar", "ZIPCore"],
            path: "Sources/MacRAR",
            exclude: ["Core"],
            resources: [
                .copy("Resources")
            ]
        ),
        // 命令行引擎验证工具
        .executableTarget(
            name: "EngineTest",
            dependencies: ["MacRARCore", "ZIPCore", "CUnrar"],
            path: "Sources/EngineTest"
        )
    ],
    cxxLanguageStandard: .cxx14
)