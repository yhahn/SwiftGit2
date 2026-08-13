// swift-tools-version: 5.9

import PackageDescription

// Matches the platforms declared below, for use with `.when(platforms:)`
// on Clibgit2's per-platform hash/transport backend selection.
let darwinPlatforms: [Platform] = [.macOS, .iOS, .tvOS, .visionOS, .macCatalyst]

let package = Package(
    name: "SwiftGit2",
    platforms: [
        .macOS(.v10_13),
        .iOS("15.5"),
        .tvOS(.v13),
        .visionOS(.v1),
        .macCatalyst(.v15),
    ],
    products: [
        .library(
            name: "SwiftGit2",
            targets: ["SwiftGit2"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Quick/Quick.git", from: "7.0.0"),
        .package(url: "https://github.com/Quick/Nimble.git", from: "13.0.0"),
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", from: "2.5.5"),
    ],
    targets: [
        .target(
            name: "SwiftGit2",
            dependencies: ["Clibgit2"]
        ),
        .testTarget(
            name: "SwiftGit2Tests",
            dependencies: ["SwiftGit2", "Clibgit2", "Quick", "Nimble", "ZipArchive"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "Clibgit2",
            path: "libgit2",
            exclude: [
                "deps/llhttp/CMakeLists.txt",
                "deps/llhttp/LICENSE-MIT",
                "deps/pcre/CMakeLists.txt",
                "deps/pcre/COPYING",
                "deps/pcre/LICENCE",
                "deps/pcre/cmake",
                "deps/pcre/config.h.in",
                "deps/xdiff/CMakeLists.txt",
                "deps/zlib/CMakeLists.txt",
                "deps/zlib/LICENSE",
                "src/libgit2/CMakeLists.txt",
                "src/libgit2/config.cmake.in",
                "src/libgit2/experimental.h.in",
                "src/libgit2/git2.rc",
                "src/util/CMakeLists.txt",
                "src/util/git2_features.h.in",
                // builtin.c/.h and collisiondetect.c/.h (the portable
                // Linux hash backends) are NOT excluded here, unlike
                // upstream mbernson/SwiftGit2 -- they're patched (in
                // github.com/yhahn/libgit2) to self-guard on the same
                // macros that select them below, so it's safe to always
                // compile them and let each platform's defines pick the
                // right backend.
                "src/util/hash/openssl.c",
                "src/util/hash/openssl.h",
                "src/util/hash/win32.c",
                "src/util/hash/win32.h",
                "src/util/win32",
            ],
            sources: [
                "deps/llhttp",
                "deps/pcre",
                "deps/xdiff",
                "deps/zlib",
                "src/libgit2",
                "src/util",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                  // Disable -fmodules flag. Clang finds (`struct entry`) in a different file (`search.h`).
                  "-fno-modules",
                  // Disable warning: "implicit conversion loses integer precision"
                  "-Wno-single-bit-bitfield-constant-conversion",
                  // Disable warning: "a function definition without a prototype is deprecated"
                  "-Wno-deprecated-non-prototype",
                ]),
                // glibc hides qsort_r's prototype without this, which is
                // what GIT_QSORT_GNU below needs to actually be declared.
                .unsafeFlags(["-D_GNU_SOURCE"], .when(platforms: [.linux])),

                .headerSearchPath("deps/llhttp"),
                .headerSearchPath("deps/pcre"),
                .headerSearchPath("deps/xdiff"),
                .headerSearchPath("deps/zlib"),
                .headerSearchPath("src/libgit2"),
                .headerSearchPath("src/util"),

                .define("LIBGIT2_NO_FEATURES_H"),
                .define("GIT_ARCH_64", to: "1"),
                .define("GIT_IO_POLL", to: "1"),

                // Git regex configuration
                .define("GIT_REGEX_BUILTIN", to: "1"),
                .define("PCRE_LINK_SIZE", to: "2"),
                .define("SUPPORT_PCRE8", to: "1"),
                .define("LINK_SIZE", to: "2"),
                .define("PARENS_NEST_LIMIT", to: "250"),
                .define("MATCH_LIMIT", to: "10000000"),
                .define("MATCH_LIMIT_RECURSION", to: "10000000"),
                .define("NEWLINE", to: "10"), // LF
                .define("NO_RECURSE", to: "1"),
                .define("POSIX_MALLOC_THRESHOLD", to: "10"),
                .define("BSR_ANYCRLF", to: "0"),
                .define("MAX_NAME_SIZE", to: "32"),
                .define("MAX_NAME_COUNT", to: "10000"),

                // Git SSH transport configuration. Unchanged on Linux: this
                // only shells out to a system ssh binary at runtime
                // (GIT_SSH_EXEC), which doesn't need anything Darwin-only
                // to compile.
                .define("GIT_SSH", to: "1"),
                .define("GIT_SSH_EXEC", to: "1"),

                // Git HTTPS transport configuration. GIT_HTTPPARSER_BUILTIN
                // just selects the bundled (portable, TLS-agnostic) llhttp
                // parser, so it's unconditional. GIT_HTTPS/
                // GIT_SECURE_TRANSPORT are Darwin-only: actually completing
                // a TLS handshake needs a real backend, and SecureTransport
                // is the only one wired up. Local git operations
                // (init/status/add/commit) don't need it, so it's simplest
                // to disable HTTPS transport entirely on Linux rather than
                // pull in OpenSSL/mbedTLS for a path we don't exercise
                // there.
                .define("GIT_HTTPPARSER_BUILTIN", to: "1"),
                .define("GIT_HTTPS", to: "1", .when(platforms: darwinPlatforms)),
                .define("GIT_SECURE_TRANSPORT", to: "1", .when(platforms: darwinPlatforms)),

                // Git cryptography configuration. Darwin uses CommonCrypto;
                // Linux uses libgit2's own portable backends (no external
                // dependency): CollisionDetection for SHA1, builtin for
                // SHA256 -- the same choices CMake's USE_SHA1/USE_SHA256
                // make when neither OpenSSL nor a platform-native backend
                // is available. Both GIT_QSORT_BSD and the hash defines
                // rely on the guards patched into github.com/yhahn/libgit2
                // (see that fork's `linux-portable-hash` branch) to select
                // the right backend per platform instead of colliding.
                .define("GIT_QSORT_BSD", to: "1", .when(platforms: darwinPlatforms)),
                .define("GIT_SHA1_COMMON_CRYPTO", to: "1", .when(platforms: darwinPlatforms)),
                .define("GIT_SHA256_COMMON_CRYPTO", to: "1", .when(platforms: darwinPlatforms)),

                .define("GIT_QSORT_GNU", to: "1", .when(platforms: [.linux])),
                .define("GIT_SHA1_COLLISIONDETECT", to: "1", .when(platforms: [.linux])),
                .define("GIT_SHA256_BUILTIN", to: "1", .when(platforms: [.linux])),
                .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1", .when(platforms: [.linux])),
                .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\"", .when(platforms: [.linux])),
                .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\"", .when(platforms: [.linux])),
            ]
        ),
    ]
)
