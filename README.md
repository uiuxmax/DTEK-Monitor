# DTEK Monitor — Apple Silicon fixture app

This repository contains a protected synthetic-only macOS development app
and core probe. The app has a native menu-bar panel, address form, themes,
fixture states and a scrollable schedule window. It is not a live outage monitor.

GitHub Actions uses the standard public-repository `macos-15` Apple Silicon
runner. It compiles Swift → Objective-C++ → C++20 and checks 67 portable cases,
60 Foundation Europe/Kyiv cases (including the same 42 vectors as Windows),
111 Foundation JSON/profile/receipt cases plus a five-case fresh-process restore,
three bridge scenarios, six invalid test envelopes, source hashes, arm64 and
the local ad-hoc signature. Evidence is printed in the Actions log. The workflow
uploads no artifacts and uses no caches, private or larger runners.

```bash
/bin/bash tools/macos/check.sh --public-probe
/bin/bash tools/macos/check-ui.sh --public-probe
/bin/bash tools/macos/check-https.sh --network-candidate --public-probe
```

The executable requires the harness envelope and uses fixed synthetic fixtures.
The app also requires this envelope. The harness prepares unique profiles under
out/macos; XCUITest exercises the app serially and terminates only its test instance.
Fixture UI address/theme changes are in memory. Data tests write only into
the harness profile, including native atomic-save/error/permission/symlink checks.
There are no provider requests or Login Items. The fixed public provider URL in
the parser identifies its source; no captured provider payload is included.
An isolated M5 URLSession candidate is measured against a generated loopback TLS
server with per-trust-object anchors, without changing system trust stores.
Its recorded header/retry contract failures motivated a Network.framework
candidate with bounded raw HTTP/1 parsing. The workflow now checks 213 parser
cases and 27 controlled TLS/wire/DNS cases; native acceptance remains pending
until their primary results are reviewed. Only a fixed reserved .invalid name
is used for the DNS failure test, in addition to owned loopback TLS.
Measurement execution and transport readiness are reported separately; PARTIAL
readiness does not authorize live integration. The protected candidate rejects
the provider endpoint. Its production branch is compiled but never executed.
The UI data is synthetic. The separately tested Foundation Kyiv adapter handles
strict Gregorian dates and DST gap/fold cases; this is not acceptance of
networking, physical displays, VoiceOver, sleep/wake, Gatekeeper or sign-in behavior.

The export excludes private Git history, historical binaries/settings/logs,
provider samples and product images. Code is licensed under MIT.

No release or application update feed has been published by this probe.
