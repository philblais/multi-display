# Project versioning

For each delivered change to this macOS app, increment the second component of `MARKETING_VERSION` in `project.yml` by one (1.1, 1.2, 1.3, ..., 1.9, 1.10) and increment `CURRENT_PROJECT_VERSION` by 1. Bump once per delivered change set, then regenerate the Xcode project and rebuild the packaged app. The menu must show the same version as the bundle metadata.
