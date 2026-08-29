# Third-Party Licenses

Vane ships **prebuilt binary artifacts** — the `libvane.a` slices inside
`VaneSwift/RustFramework.xcframework` / `RustFramework.small.xcframework`, and
the `libvane.so` files under `VaneKotlin/library/src/main/jniLibs` (also
delivered inside the release AAR). These binaries statically contain
third-party code, so the attribution obligations below apply to anyone
redistributing the binaries, not only to the source tree.

Vane itself is `MIT OR Apache-2.0` (see LICENSE).

Generated from `cargo metadata --all-features` on 2026-08-29 against the
committed `Cargo.lock`. Regenerate after any dependency change — see
"Regenerating" at the end.

## Not covered by the crate table: BoringSSL

`quiche` and `boring-sys` vendor and statically link **BoringSSL**, whose own
source is licensed separately from the wrapper crates (the crates declare
`BSD-2-Clause` and `MIT`/`Apache-2.0` respectively; BoringSSL's tree is a mix
of the OpenSSL license, SSLeay, and ISC). BoringSSL's own `LICENSE` file is
authoritative and travels in the vendored source under the `boring-sys` and
`quiche` build directories. Anyone shipping Vane's binaries is shipping
BoringSSL and must carry that notice too.

## Licenses that need more than a notice

Everything in the graph is permissive; nothing requires releasing your
application's source. Two entries are worth calling out explicitly rather
than leaving in the table:

- **`uniffi*` (9 crates) — MPL-2.0.** File-level weak copyleft: modifications
  *to UniFFI's own source files* must be published. Vane does not fork
  UniFFI — it consumes it through `vane-bindgen/generate.sh` — so linking it
  into Vane's binaries carries a notice obligation only. Note that
  `VaneSwift/Sources/VaneSwift/VaneClient.swift` carries a hand-patch to
  UniFFI's *generated output* (see TODO.md); generated bindings are not
  UniFFI's own source files.
- **`webpki-root-certs` — CDLA-Permissive-2.0.** Permissive and notice-only,
  but an uncommon identifier that some automated license scanners flag as
  unknown rather than as approved. Expect to allowlist it.

## Summary by license

| License | Crates |
|---|---:|
| MIT OR Apache-2.0 | 144 |
| MIT | 40 |
| MIT/Apache-2.0 | 19 |
| Unicode-3.0 | 18 |
| Apache-2.0 OR MIT | 14 |
| MPL-2.0 | 9 |
| Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | 5 |
| Unlicense OR MIT | 3 |
| Apache-2.0 | 3 |
| Apache-2.0 OR ISC OR MIT | 3 |
| ISC | 3 |
| BSD-3-Clause | 2 |
| Apache-2.0/MIT | 2 |
| BSD-2-Clause | 2 |
| Unlicense/MIT | 2 |
| BSD-2-Clause OR Apache-2.0 OR MIT | 2 |
| Apache-2.0 / MIT | 1 |
| MIT OR Apache-2.0 OR LGPL-2.1-or-later | 1 |
| Apache-2.0 AND ISC | 1 |
| Apache-2.0 OR BSL-1.0 | 1 |
| (MIT OR Apache-2.0) AND Unicode-3.0 | 1 |
| CDLA-Permissive-2.0 | 1 |

## JVM dependencies (not statically bundled)

The Kotlin binding declares `net.java.dev.jna`, `kotlinx-coroutines-core`,
`kotlinx-serialization-json`, `retrofit` and `converter-gson` as ordinary
Gradle dependencies. They resolve from Maven at build time and are **not**
linked into `libvane.so`, so they are not in the table below; they carry
their own licenses (Apache-2.0 across all five at time of writing) to the
consuming app directly.

## Full crate list

| Crate | Version | License (SPDX, as declared) |
|---|---|---|
| `aho-corasick` | 1.1.4 | Unlicense OR MIT |
| `anyhow` | 1.0.98 | MIT OR Apache-2.0 |
| `askama` | 0.14.0 | MIT OR Apache-2.0 |
| `askama_derive` | 0.14.0 | MIT OR Apache-2.0 |
| `askama_parser` | 0.14.0 | MIT OR Apache-2.0 |
| `asn1-rs` | 0.7.2 | MIT OR Apache-2.0 |
| `asn1-rs-derive` | 0.6.0 | MIT OR Apache-2.0 |
| `asn1-rs-impl` | 0.2.0 | MIT/Apache-2.0 |
| `atomic-waker` | 1.1.2 | Apache-2.0 OR MIT |
| `autocfg` | 1.5.0 | Apache-2.0 OR MIT |
| `base64` | 0.22.1 | MIT OR Apache-2.0 |
| `basic-toml` | 0.1.10 | MIT OR Apache-2.0 |
| `bindgen` | 0.72.1 | BSD-3-Clause |
| `bit-set` | 0.8.0 | Apache-2.0 OR MIT |
| `bit-vec` | 0.8.0 | Apache-2.0 OR MIT |
| `bit-vec` | 0.9.1 | Apache-2.0 OR MIT |
| `bitflags` | 2.13.0 | MIT OR Apache-2.0 |
| `block-buffer` | 0.10.4 | MIT OR Apache-2.0 |
| `boring` | 4.22.0 | Apache-2.0 |
| `boring-sys` | 4.22.0 | MIT |
| `bumpalo` | 3.20.3 | MIT OR Apache-2.0 |
| `bytes` | 1.11.1 | MIT |
| `camino` | 1.1.10 | MIT OR Apache-2.0 |
| `cargo-platform` | 0.1.9 | MIT OR Apache-2.0 |
| `cargo_metadata` | 0.19.2 | MIT |
| `cc` | 1.2.63 | MIT OR Apache-2.0 |
| `cexpr` | 0.6.0 | Apache-2.0/MIT |
| `cfg-if` | 1.0.1 | MIT OR Apache-2.0 |
| `clang-sys` | 1.8.1 | Apache-2.0 |
| `cmake` | 0.1.58 | MIT OR Apache-2.0 |
| `combine` | 4.6.7 | MIT |
| `core-foundation` | 0.10.1 | MIT OR Apache-2.0 |
| `core-foundation-sys` | 0.8.7 | MIT OR Apache-2.0 |
| `cpufeatures` | 0.2.17 | MIT OR Apache-2.0 |
| `crypto-common` | 0.1.7 | MIT OR Apache-2.0 |
| `data-encoding` | 2.11.0 | MIT |
| `debug_panic` | 0.2.1 | MIT |
| `der-parser` | 10.0.0 | MIT OR Apache-2.0 |
| `deranged` | 0.5.8 | MIT OR Apache-2.0 |
| `digest` | 0.10.7 | MIT OR Apache-2.0 |
| `displaydoc` | 0.2.7 | MIT OR Apache-2.0 |
| `either` | 1.16.0 | MIT OR Apache-2.0 |
| `enum_dispatch` | 0.3.13 | MIT OR Apache-2.0 |
| `equivalent` | 1.0.2 | Apache-2.0 OR MIT |
| `errno` | 0.3.13 | MIT OR Apache-2.0 |
| `fastrand` | 2.3.0 | Apache-2.0 OR MIT |
| `find-msvc-tools` | 0.1.9 | MIT OR Apache-2.0 |
| `fnv` | 1.0.7 | Apache-2.0 / MIT |
| `foreign-types` | 0.5.0 | MIT/Apache-2.0 |
| `foreign-types-macros` | 0.2.3 | MIT/Apache-2.0 |
| `foreign-types-shared` | 0.3.1 | MIT/Apache-2.0 |
| `form_urlencoded` | 1.2.2 | MIT OR Apache-2.0 |
| `fs-err` | 2.11.0 | MIT/Apache-2.0 |
| `fs_extra` | 1.3.0 | MIT |
| `fslock` | 0.2.1 | MIT |
| `futures-channel` | 0.3.33 | MIT OR Apache-2.0 |
| `futures-core` | 0.3.33 | MIT OR Apache-2.0 |
| `futures-io` | 0.3.33 | MIT OR Apache-2.0 |
| `futures-sink` | 0.3.33 | MIT OR Apache-2.0 |
| `futures-task` | 0.3.33 | MIT OR Apache-2.0 |
| `futures-util` | 0.3.33 | MIT OR Apache-2.0 |
| `generic-array` | 0.14.7 | MIT |
| `getrandom` | 0.2.17 | MIT OR Apache-2.0 |
| `getrandom` | 0.3.3 | MIT OR Apache-2.0 |
| `glob` | 0.3.2 | MIT OR Apache-2.0 |
| `goblin` | 0.8.2 | MIT |
| `h2` | 0.4.15 | MIT |
| `hashbrown` | 0.15.4 | MIT OR Apache-2.0 |
| `heck` | 0.5.0 | MIT OR Apache-2.0 |
| `http` | 1.4.2 | MIT OR Apache-2.0 |
| `http-body` | 1.1.0 | MIT |
| `http-body-util` | 0.1.4 | MIT |
| `httparse` | 1.10.1 | MIT OR Apache-2.0 |
| `hyper` | 1.11.0 | MIT |
| `hyper-rustls` | 0.27.9 | Apache-2.0 OR ISC OR MIT |
| `hyper-util` | 0.1.20 | MIT |
| `icu_collections` | 2.2.0 | Unicode-3.0 |
| `icu_locale_core` | 2.2.0 | Unicode-3.0 |
| `icu_normalizer` | 2.2.0 | Unicode-3.0 |
| `icu_normalizer_data` | 2.2.0 | Unicode-3.0 |
| `icu_properties` | 2.2.0 | Unicode-3.0 |
| `icu_properties_data` | 2.2.0 | Unicode-3.0 |
| `icu_provider` | 2.2.0 | Unicode-3.0 |
| `idna` | 1.1.0 | MIT OR Apache-2.0 |
| `idna_adapter` | 1.2.2 | Apache-2.0 OR MIT |
| `indexmap` | 2.10.0 | Apache-2.0 OR MIT |
| `intrusive-collections` | 0.9.7 | Apache-2.0/MIT |
| `ipnet` | 2.12.0 | MIT OR Apache-2.0 |
| `itertools` | 0.13.0 | MIT OR Apache-2.0 |
| `itoa` | 1.0.15 | MIT OR Apache-2.0 |
| `jni` | 0.22.4 | MIT OR Apache-2.0 |
| `jni-macros` | 0.22.4 | MIT OR Apache-2.0 |
| `jni-sys` | 0.4.1 | MIT OR Apache-2.0 |
| `jni-sys-macros` | 0.4.1 | MIT OR Apache-2.0 |
| `js-sys` | 0.3.103 | MIT OR Apache-2.0 |
| `lazy_static` | 1.5.0 | MIT OR Apache-2.0 |
| `libc` | 0.2.174 | MIT OR Apache-2.0 |
| `libloading` | 0.8.9 | ISC |
| `libm` | 0.2.16 | MIT |
| `linux-raw-sys` | 0.9.4 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `litemap` | 0.8.2 | Unicode-3.0 |
| `log` | 0.4.27 | MIT OR Apache-2.0 |
| `memchr` | 2.7.5 | Unlicense OR MIT |
| `memoffset` | 0.9.1 | MIT |
| `minimal-lexical` | 0.2.1 | MIT/Apache-2.0 |
| `mio` | 1.1.0 | MIT |
| `nom` | 7.1.3 | MIT |
| `num-bigint` | 0.4.8 | MIT OR Apache-2.0 |
| `num-conv` | 0.2.2 | MIT OR Apache-2.0 |
| `num-integer` | 0.1.46 | MIT OR Apache-2.0 |
| `num-traits` | 0.2.19 | MIT OR Apache-2.0 |
| `octets` | 0.3.5 | BSD-2-Clause |
| `oid-registry` | 0.8.1 | MIT OR Apache-2.0 |
| `once_cell` | 1.21.3 | MIT OR Apache-2.0 |
| `openssl-macros` | 0.1.1 | MIT/Apache-2.0 |
| `openssl-probe` | 0.2.1 | MIT OR Apache-2.0 |
| `pem` | 3.0.6 | MIT |
| `percent-encoding` | 2.3.1 | MIT OR Apache-2.0 |
| `pin-project-lite` | 0.2.17 | Apache-2.0 OR MIT |
| `plain` | 0.2.3 | MIT/Apache-2.0 |
| `potential_utf` | 0.1.5 | Unicode-3.0 |
| `powerfmt` | 0.2.0 | MIT OR Apache-2.0 |
| `ppv-lite86` | 0.2.21 | MIT OR Apache-2.0 |
| `proc-macro2` | 1.0.95 | MIT OR Apache-2.0 |
| `proptest` | 1.11.0 | MIT OR Apache-2.0 |
| `psl` | 2.1.223 | MIT/Apache-2.0 |
| `psl-types` | 2.0.11 | MIT/Apache-2.0 |
| `quiche` | 0.29.1 | BSD-2-Clause |
| `quick-error` | 1.2.3 | MIT/Apache-2.0 |
| `quote` | 1.0.45 | MIT OR Apache-2.0 |
| `r-efi` | 5.3.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later |
| `rand` | 0.9.5 | MIT OR Apache-2.0 |
| `rand_chacha` | 0.9.0 | MIT OR Apache-2.0 |
| `rand_core` | 0.9.5 | MIT OR Apache-2.0 |
| `rand_xorshift` | 0.4.0 | MIT OR Apache-2.0 |
| `rcgen` | 0.14.8 | MIT OR Apache-2.0 |
| `regex` | 1.12.3 | MIT OR Apache-2.0 |
| `regex-automata` | 0.4.14 | MIT OR Apache-2.0 |
| `regex-syntax` | 0.8.10 | MIT OR Apache-2.0 |
| `reqwest` | 0.13.4 | MIT OR Apache-2.0 |
| `ring` | 0.17.14 | Apache-2.0 AND ISC |
| `rustc-hash` | 2.1.1 | Apache-2.0 OR MIT |
| `rustc_version` | 0.4.1 | MIT OR Apache-2.0 |
| `rusticata-macros` | 4.1.0 | MIT/Apache-2.0 |
| `rustix` | 1.0.8 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `rustls` | 0.23.42 | Apache-2.0 OR ISC OR MIT |
| `rustls-native-certs` | 0.8.4 | Apache-2.0 OR ISC OR MIT |
| `rustls-pki-types` | 1.15.1 | MIT OR Apache-2.0 |
| `rustls-platform-verifier` | 0.7.0 | MIT OR Apache-2.0 |
| `rustls-platform-verifier-android` | 0.1.1 | MIT OR Apache-2.0 |
| `rustls-webpki` | 0.103.13 | ISC |
| `rustversion` | 1.0.23 | MIT OR Apache-2.0 |
| `rusty-fork` | 0.3.1 | MIT/Apache-2.0 |
| `ryu` | 1.0.20 | Apache-2.0 OR BSL-1.0 |
| `same-file` | 1.0.6 | Unlicense/MIT |
| `schannel` | 0.1.29 | MIT |
| `scroll` | 0.12.0 | MIT |
| `scroll_derive` | 0.12.1 | MIT |
| `security-framework` | 3.7.0 | MIT OR Apache-2.0 |
| `security-framework-sys` | 2.17.0 | MIT OR Apache-2.0 |
| `semver` | 1.0.26 | MIT OR Apache-2.0 |
| `serde` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_core` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_derive` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_json` | 1.0.140 | MIT OR Apache-2.0 |
| `serde_spanned` | 1.1.1 | MIT OR Apache-2.0 |
| `sha2` | 0.10.9 | MIT OR Apache-2.0 |
| `shlex` | 1.3.0 | MIT OR Apache-2.0 |
| `shlex` | 2.0.1 | MIT OR Apache-2.0 |
| `simd_cesu8` | 1.2.0 | Apache-2.0 OR MIT |
| `simdutf8` | 0.1.5 | MIT OR Apache-2.0 |
| `siphasher` | 1.0.3 | MIT/Apache-2.0 |
| `slab` | 0.4.10 | MIT |
| `smallvec` | 1.15.1 | MIT OR Apache-2.0 |
| `smawk` | 0.3.2 | MIT |
| `socket2` | 0.6.5 | MIT OR Apache-2.0 |
| `stable_deref_trait` | 1.2.1 | MIT OR Apache-2.0 |
| `static_assertions` | 1.1.0 | MIT OR Apache-2.0 |
| `subtle` | 2.6.1 | BSD-3-Clause |
| `syn` | 2.0.104 | MIT OR Apache-2.0 |
| `syn` | 3.0.3 | MIT OR Apache-2.0 |
| `sync_wrapper` | 1.0.2 | Apache-2.0 |
| `synstructure` | 0.13.2 | MIT |
| `tempfile` | 3.20.0 | MIT OR Apache-2.0 |
| `textwrap` | 0.16.2 | MIT |
| `thiserror` | 2.0.12 | MIT OR Apache-2.0 |
| `thiserror-impl` | 2.0.12 | MIT OR Apache-2.0 |
| `time` | 0.3.54 | MIT OR Apache-2.0 |
| `time-core` | 0.1.9 | MIT OR Apache-2.0 |
| `time-macros` | 0.2.32 | MIT OR Apache-2.0 |
| `tinystr` | 0.8.3 | Unicode-3.0 |
| `tokio` | 1.50.0 | MIT |
| `tokio-rustls` | 0.26.4 | MIT OR Apache-2.0 |
| `tokio-util` | 0.7.19 | MIT |
| `toml` | 0.9.6 | MIT OR Apache-2.0 |
| `toml_datetime` | 0.7.5+spec-1.1.0 | MIT OR Apache-2.0 |
| `toml_parser` | 1.1.3+spec-1.1.0 | MIT OR Apache-2.0 |
| `toml_writer` | 1.1.2+spec-1.1.0 | MIT OR Apache-2.0 |
| `tower` | 0.5.3 | MIT |
| `tower-http` | 0.6.11 | MIT |
| `tower-layer` | 0.3.3 | MIT |
| `tower-service` | 0.3.3 | MIT |
| `tracing` | 0.1.44 | MIT |
| `tracing-core` | 0.1.36 | MIT |
| `try-lock` | 0.2.5 | MIT |
| `typenum` | 1.20.1 | MIT OR Apache-2.0 |
| `unarray` | 0.1.4 | MIT OR Apache-2.0 |
| `unicode-ident` | 1.0.18 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| `uniffi` | 0.31.2 | MPL-2.0 |
| `uniffi_bindgen` | 0.31.2 | MPL-2.0 |
| `uniffi_build` | 0.31.2 | MPL-2.0 |
| `uniffi_core` | 0.31.2 | MPL-2.0 |
| `uniffi_internal_macros` | 0.31.2 | MPL-2.0 |
| `uniffi_macros` | 0.31.2 | MPL-2.0 |
| `uniffi_meta` | 0.31.2 | MPL-2.0 |
| `uniffi_pipeline` | 0.31.2 | MPL-2.0 |
| `uniffi_udl` | 0.31.2 | MPL-2.0 |
| `untrusted` | 0.9.0 | ISC |
| `url` | 2.5.4 | MIT OR Apache-2.0 |
| `utf8_iter` | 1.0.4 | Apache-2.0 OR MIT |
| `version_check` | 0.9.5 | MIT/Apache-2.0 |
| `wait-timeout` | 0.2.1 | MIT/Apache-2.0 |
| `walkdir` | 2.5.0 | Unlicense/MIT |
| `want` | 0.3.1 | MIT |
| `wasi` | 0.11.1+wasi-snapshot-preview1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `wasi` | 0.14.2+wasi-0.2.4 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `wasm-bindgen` | 0.2.126 | MIT OR Apache-2.0 |
| `wasm-bindgen-futures` | 0.4.76 | MIT OR Apache-2.0 |
| `wasm-bindgen-macro` | 0.2.126 | MIT OR Apache-2.0 |
| `wasm-bindgen-macro-support` | 0.2.126 | MIT OR Apache-2.0 |
| `wasm-bindgen-shared` | 0.2.126 | MIT OR Apache-2.0 |
| `web-sys` | 0.3.103 | MIT OR Apache-2.0 |
| `webpki-root-certs` | 1.0.9 | CDLA-Permissive-2.0 |
| `weedle2` | 5.0.0 | MIT |
| `winapi` | 0.3.9 | MIT/Apache-2.0 |
| `winapi-i686-pc-windows-gnu` | 0.4.0 | MIT/Apache-2.0 |
| `winapi-util` | 0.1.11 | Unlicense OR MIT |
| `winapi-x86_64-pc-windows-gnu` | 0.4.0 | MIT/Apache-2.0 |
| `windows-link` | 0.2.1 | MIT OR Apache-2.0 |
| `windows-sys` | 0.52.0 | MIT OR Apache-2.0 |
| `windows-sys` | 0.59.0 | MIT OR Apache-2.0 |
| `windows-sys` | 0.60.2 | MIT OR Apache-2.0 |
| `windows-sys` | 0.61.2 | MIT OR Apache-2.0 |
| `windows-targets` | 0.52.6 | MIT OR Apache-2.0 |
| `windows-targets` | 0.53.2 | MIT OR Apache-2.0 |
| `windows_aarch64_gnullvm` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_aarch64_gnullvm` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_aarch64_msvc` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_aarch64_msvc` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_i686_gnu` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_i686_gnu` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_i686_gnullvm` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_i686_gnullvm` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_i686_msvc` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_i686_msvc` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_x86_64_gnu` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_x86_64_gnu` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_x86_64_gnullvm` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_x86_64_gnullvm` | 0.53.0 | MIT OR Apache-2.0 |
| `windows_x86_64_msvc` | 0.52.6 | MIT OR Apache-2.0 |
| `windows_x86_64_msvc` | 0.53.0 | MIT OR Apache-2.0 |
| `winnow` | 0.7.12 | MIT |
| `winnow` | 1.0.4 | MIT |
| `wit-bindgen-rt` | 0.39.0 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `writeable` | 0.6.3 | Unicode-3.0 |
| `x509-parser` | 0.18.1 | MIT OR Apache-2.0 |
| `yasna` | 0.6.0 | MIT OR Apache-2.0 |
| `yoke` | 0.8.3 | Unicode-3.0 |
| `yoke-derive` | 0.8.2 | Unicode-3.0 |
| `zerocopy` | 0.8.56 | BSD-2-Clause OR Apache-2.0 OR MIT |
| `zerocopy-derive` | 0.8.56 | BSD-2-Clause OR Apache-2.0 OR MIT |
| `zerofrom` | 0.1.8 | Unicode-3.0 |
| `zerofrom-derive` | 0.1.7 | Unicode-3.0 |
| `zeroize` | 1.9.0 | Apache-2.0 OR MIT |
| `zerotrie` | 0.2.4 | Unicode-3.0 |
| `zerovec` | 0.11.6 | Unicode-3.0 |
| `zerovec-derive` | 0.11.3 | Unicode-3.0 |

## Regenerating

```
cd vane-rs && cargo metadata --format-version 1 --all-features
```

A dependency change means regenerating this file in the same commit — the
same rule that applies to rebuilding the native artifacts (see TODO.md,
"Before you touch the build"). Nothing in CI checks this file for staleness.
