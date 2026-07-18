# Toj WebRTC binary

This directory pins both the upstream WebRTC source commit and the `depot_tools` commit used to
build Toj's iOS XCFramework. The binary is intentionally not stored in git.

The `WebRTC XCFramework` workflow builds the official upstream source, validates every framework
slice, installs the local pod into Toj, compiles the real `canImport(WebRTC)` implementation, and
runs the app test suite. That build job has read-only repository access. A separate publish job
downloads the workflow artifact, creates GitHub/Sigstore provenance attestations, and uploads
immutable release assets.

Install the pinned release with:

```sh
scripts/fetch-webrtc-xcframework.sh
pod install
```

The fetch script verifies the repository pin, SHA-256 sidecar, archive paths, and signed provenance
from `.github/workflows/webrtc-xcframework.yml` at the expected release tag. It rejects attestations
from self-hosted runners. A developer testing a custom, unattested local release can explicitly set
`TOJ_WEBRTC_ALLOW_UNATTESTED=1`; CI rejects that escape hatch, and release/deployment builds must
never use it.
