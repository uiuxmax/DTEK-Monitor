# DTEK Monitor — Apple Silicon fixture app

This repository contains a protected synthetic-only macOS development app
and core probe. The app has a native menu-bar panel, address form, themes,
fixture states and a scrollable schedule window. It is not a live outage monitor.

GitHub Actions uses the standard public-repository `macos-15` Apple Silicon
runner. It compiles Swift → Objective-C++ → C++20 and checks 67 portable cases,
three bridge scenarios, six invalid test envelopes, source hashes, arm64 and
the local ad-hoc signature. Evidence is printed in the Actions log. The workflow
uploads no artifacts and uses no caches, private or larger runners.

```bash
/bin/bash tools/macos/check.sh --public-probe
/bin/bash tools/macos/check-ui.sh --public-probe
```

The executable requires the harness envelope and uses fixed synthetic fixtures.
The app also requires this envelope. XCUITest creates unique profiles under
out/macos, exercises the app serially, and terminates only its test instance.
All address/theme changes are in memory. No provider requests or Login Items.
The test timezone is synthetic; this is not acceptance of a macOS Kyiv adapter,
networking, physical displays, VoiceOver, sleep/wake, Gatekeeper or sign-in behavior.

The export excludes private Git history, historical binaries/settings/logs,
provider samples and product images. Code is licensed under MIT.

No release or application update feed has been published by this probe.
