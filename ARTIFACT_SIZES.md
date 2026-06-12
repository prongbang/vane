# Vane Artifact Sizes

Measured on 2026-06-12 after removing the `reqwest` HTTP/1.1/HTTP/2 fallback
backend. The default profile is HTTP/3-only through `quiche` with certificate
pinning, connection pooling, retry policy, Swift/Kotlin request helper work, the
opt-in in-memory cookie jar, configurable request/response body limits, and the
Swift static XCFramework migration.

## Swift XCFramework

Full production profile: `quiche` HTTP/3 only, SPKI and cert DER certificate
pins, cookies, retries, connection pooling, and body limits.

| Slice | File | Size |
|-------|------|------|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.xcframework/macos-arm64_x86_64/libvane.a` | 45,558,840 bytes |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 56,986,840 bytes |
| iOS arm64 | `VaneSwift/RustFramework.xcframework/ios-arm64/libvane.a` | 28,179,152 bytes |

Small Swift profile: built with `make build_swift_small`. This profile removes
the SPKI pin parser to reduce size. It supports HTTP/3 and
`sha256-cert/<base64-cert-der-sha256>` certificate pins.

| Slice | File | Size |
|-------|------|------|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/macos-arm64_x86_64/libvane.a` | 45,520,048 bytes |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 56,948,240 bytes |
| iOS arm64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64/libvane.a` | 28,159,464 bytes |

## Android Native Libraries

| ABI | File | Size |
|-----|------|------|
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libvane.so` | 1,298,480 bytes |
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libquiche-9ba03ec8fd817fcc.so` | 7,788 bytes |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libvane.so` | 2,095,044 bytes |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libquiche-c08af2fa3a1d6e20.so` | 336,028 bytes |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libvane.so` | 2,091,440 bytes |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libquiche-eb14d55ca50fe1b4.so` | 310,416 bytes |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libvane.so` | 2,342,400 bytes |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libquiche-5dae9f4773a7013a.so` | 340,632 bytes |

## Android AAR

| Artifact | File | Size |
|----------|------|------|
| Release AAR | `VaneKotlin/library/build/outputs/aar/library-release.aar` | 4,517,048 bytes |
