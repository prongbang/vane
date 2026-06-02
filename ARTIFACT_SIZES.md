# Vane Artifact Sizes

Measured on 2026-06-02 after the `quiche` HTTP/3 migration, certificate
pinning, connection pooling, retry policy, Swift/Kotlin interceptor work, the
opt-in in-memory cookie jar, configurable request/response body limits, the
`hyper`/`hyper-util`/`hyper-rustls` HTTP/2 plus HTTP/1.1 fallback backend, and
the Swift static XCFramework migration. The full profile also includes HTTP,
HTTPS endpoint, SOCKS5, and SOCKS5h proxy support for the TCP fallback backend.

## Swift XCFramework

Full production profile: HTTP/3 plus HTTP/2/HTTP/1.1 fallback, SPKI and cert
DER certificate pins.

| Slice | File | Size |
|-------|------|------|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.xcframework/macos-arm64_x86_64/libvane.a` | 91,121,336 bytes |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 101,902,272 bytes |
| iOS arm64 | `VaneSwift/RustFramework.xcframework/ios-arm64/libvane.a` | 50,338,128 bytes |

Small Swift profile: built with `make build_swift_small`. This profile removes
the HTTP/1.1/HTTP/2 fallback backend and SPKI pin parser to reduce size. It
supports HTTP/3 and `sha256-cert/<base64-cert-der-sha256>` certificate pins.

| Slice | File | Size |
|-------|------|------|
| macOS arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/macos-arm64_x86_64/libvane.a` | 45,520,048 bytes |
| iOS simulator arm64/x86_64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64_x86_64-simulator/libvane.a` | 56,948,240 bytes |
| iOS arm64 | `VaneSwift/RustFramework.small.xcframework/ios-arm64/libvane.a` | 28,159,464 bytes |

## Android Native Libraries

| ABI | File | Size |
|-----|------|------|
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libvane.so` | 2,436,980 bytes |
| armeabi-v7a | `VaneKotlin/library/src/main/jniLibs/armeabi-v7a/libquiche-6f7be110f9825b19.so` | 7,744 bytes |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libvane.so` | 4,095,468 bytes |
| x86 | `VaneKotlin/library/src/main/jniLibs/x86/libquiche-261ec5a8a5fb279f.so` | 336,128 bytes |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libvane.so` | 4,086,192 bytes |
| arm64-v8a | `VaneKotlin/library/src/main/jniLibs/arm64-v8a/libquiche-a4adceec94f6872e.so` | 310,640 bytes |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libvane.so` | 4,626,536 bytes |
| x86_64 | `VaneKotlin/library/src/main/jniLibs/x86_64/libquiche-78ecdb4dc1b858ef.so` | 341,016 bytes |

## Android AAR

| Artifact | File | Size |
|----------|------|------|
| Release AAR | `VaneKotlin/library/build/outputs/aar/library-release.aar` | 8,075,640 bytes |
