# Xcode Cloud → auto TestFlight on merge (model-free)

A clean Xcode Cloud checkout has **none** of the gitignored build inputs
(`OuraCore.xcframework`, `OuraApp.xcodeproj`, `oura.db`).
So CI rebuilds the Rust xcframework and generates the project from `project-ci.yml`
in `ci_scripts/ci_post_clone.sh`. The app has no models. It **syncs from a real ring
over BLE** and computes the summary on the phone.

## One-time setup (your Apple account)

1. In **App Store Connect → your app → Xcode Cloud** (or Xcode → Product → Xcode Cloud),
   create a workflow.
2. Source: this repo, **start condition = push to `main`** (or the PR branch).
3. Environment: latest Xcode. Xcode Cloud auto-runs `ci_scripts/ci_post_clone.sh`.
4. Action: **Archive** the `OuraApp` scheme → **Post-action: TestFlight (Internal)**.
5. Signing is automatic (Xcode Cloud manages it); the bundle id is `md.thomas.openoura`.

That's it — each merge to `main` produces a TestFlight build.
