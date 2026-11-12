# Public core probe instructions

- Read README.md. This tree contains only the arm64 synthetic development probe.
- app/macos/ owns the probe, research/schedule-engine/ owns the shared C++20 code.
- Run /bin/bash tools/macos/check.sh --public-probe on native Apple Silicon macOS.
- Keep the complete test envelope, disabled provider flag and isolated profile.
- Never register Login Items, change user settings or weaken signing/test guards.
- Keep synthetic data explicit; no provider samples, private history or images.
- Report checkout, commit, input hashes, results path and unverified behavior.
- A CI PASS is not UI, real timezone, networking, Gatekeeper or sign-in acceptance.
- Retain MIT attribution; no application release without a separate request.
