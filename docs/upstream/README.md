# Patches offered back upstream

Changes Vane carries against a third-party project, kept here so they stay
reviewable and so re-syncing a vendored dependency does not silently drop them.

## `rustls-platform-verifier-221.patch`

Targets [rustls/rustls-platform-verifier#221][221]. Applies to
`android/rustls-platform-verifier/src/main/java/org/rustls/platformverifier/CertificateVerifier.kt`
at tag `v/0.7.0`.

Vane already carries this change in its vendored copy at
`VaneKotlin/library/src/main/java/org/rustls/platformverifier/CertificateVerifier.kt`
— that file's header lists the local modifications and must stay in sync with
this patch.

**Not submitted yet.** Submitting it needs a GitHub account with a fork and is
an outward-facing action, so it is left to a maintainer rather than automated.
To submit: fork the repo, apply this patch to `v/0.7.0` or `main`, and open the
PR using the subject line and body above the diff.

[221]: https://github.com/rustls/rustls-platform-verifier/issues/221
