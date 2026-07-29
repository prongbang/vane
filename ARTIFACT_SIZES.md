# Vane Artifact Sizes

Measured on 2026-06-12 after removing the `reqwest` HTTP/1.1/HTTP/2 fallback
backend and stripping embedded bitcode/LLVM payloads from Swift static
archives. The default profile is HTTP/3-only through `quiche` with certificate
pinning, connection pooling, retry policy, Swift/Kotlin request helper work, the
opt-in in-memory cookie jar, configurable request/response body limits, and the
Swift static XCFramework migration.

## Swift XCFramework

Full production profile: `quiche` HTTP/3 only, SPKI and cert DER certificate
pins, cookies, retries, connection pooling, and body limits.

| Slice | File | Size |
|-------|------|------|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.xcframework/macos-arm64_x86_64/libvane.a` | 39,965,144 bytes |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 45,369,992 bytes |
| iOS arm64 | `VaneSwift/RustFramework.xcframework/ios-arm64/libvane.a` | 22,571,208 bytes |

Small Swift profile: built with `make build_swift_small`. This profile removes
the SPKI pin parser to reduce size. It supports HTTP/3 and
`sha256-cert/<base64-cert-der-sha256>` certificate pins.

It also drops the `psl` feature, so its cookie jar refuses a `Set-Cookie`
`Domain` that is a bare TLD (`com`) or an IP literal, but not one that is a
multi-label public suffix (`co.uk`, `github.io`). The full profile refuses
both. Cookies are off by default in either profile.

Measured cost of `psl` on the host macOS release dylib (`opt-level = "z"`,
fat LTO, stripped), recorded as the Phase 5 baseline:

| Profile | Size |
|---------|------|
| H3 only, no `psl` | 1,748,272 bytes |
| H3 only, with `psl` | 2,294,368 bytes (+546,096, +31%) |

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
