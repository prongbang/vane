# Patches offered back upstream

Changes Vane carries against a third-party project, kept here so they stay
reviewable and so re-syncing a vendored dependency does not silently drop them.

Both patches target
[rustls/rustls-platform-verifier](https://github.com/rustls/rustls-platform-verifier),
file
`android/rustls-platform-verifier/src/main/java/org/rustls/platformverifier/CertificateVerifier.kt`.
Both are `git format-patch` output against upstream `main` at `a8d640d`
(2026-08-12) and were verified to apply cleanly with `git apply --check` from a
fresh clone, in order. Vane's vendored copy at
`VaneKotlin/library/src/main/java/org/rustls/platformverifier/CertificateVerifier.kt`
carries the same two changes; that file's header lists them and must stay in
sync with these patches.

## `0001-android-revocation-by-reason.patch`

Fixes [#221][221]: Android's `PKIXRevocationChecker` throws
`CertPathValidatorException` for *undeterminable* revocation status, not only
for a definitive revocation, and the verifier maps every such exception to
`StatusCode.Revoked`. Since Let's Encrypt retired OCSP, that makes a large and
growing share of the web unreachable. Only `BasicReason.REVOKED` blocks after
this change; a stapled "revoked" response is still refused.

## `0002-android-cache-trust-anchors.patch`

Performance, independent of #221 and applies on top of it.
`PKIXBuilderParameters(KeyStore, …)` re-enumerates the keystore and re-parses
every root certificate on each call — against AndroidCAStore that is a full
read of the system CA directory on **every** verification, measured at
46–310 ms per handshake. Extracting the anchors once per process takes a warm
non-resumed verification from 291–299 ms to 29–36 ms. No verdict is cached.

## Status: prepared, NOT submitted

Submitting is an outward-facing action — it needs a GitHub account, a fork, and
the author's name on a public PR — so it is left to a human rather than
automated.

Context worth reading before submitting, from [#221][221] as of 2026-08-05:
the issue is open and active, several projects report it as a blocker
("effectively kills reqwest on Android"), and the maintainer has stated the
holdup is sponsored time rather than disagreement. Their preferred long-term
fix is different from patch 0001 — parsing CCADB at packaging time and shipping
HTTP network allowances in the `.aar` manifest, so Android can actually fetch
CRLs. **These are complementary, not competing**, and the PR should say so:
0001 unblocks users now and does not preclude the manifest work, which would
later make revocation genuinely functional rather than soft-failed.

Expect pushback on the security posture of 0001. The evidence that answers it
is in the commit message and was measured on an API 35 emulator: network-fetched
OCSP is already inoperative on Android (responder URLs are cleartext `http://`
per RFC 6960, and `usesCleartextTraffic` defaults to false for targetSdk 28+),
so a genuinely revoked certificate connects successfully both before and after
the change. The strict mapping costs availability and buys nothing.

To submit:

```bash
git clone https://github.com/rustls/rustls-platform-verifier.git
cd rustls-platform-verifier
git checkout -b android-revocation-by-reason
git am /path/to/vane/docs/upstream/000*.patch
# push to your fork, then open the PR against rustls:main
```

Consider two PRs rather than one: 0001 is a correctness fix that closes an open
issue with people waiting on it, while 0002 is an unrelated performance change
that should not be held up by a policy debate about 0001.

[221]: https://github.com/rustls/rustls-platform-verifier/issues/221
