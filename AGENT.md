# Agent Guide for EasyVM

This document serves as a guide for AI agents and contributors working on the **EasyVM** codebase. It outlines the project structure, development workflows, and coding conventions.

## 1. Project Overview

EasyVM is a macOS application for managing virtual machines.
- **Core Technology:** Apple's `Virtualization.framework`.
- **UI Framework:** SwiftUI.
- **Language:** Swift.
- **Target Platform:** macOS 13+ (Apple Silicon).

## 2. Repository Map

The repository is structured as follows:

- **`EasyVM/`**: Root project folder.
    - **`EasyVM.xcodeproj`**: Main Xcode project file.
    - **`EasyVM/`**: Source code directory.
        - **`Application/`**: UI layer, organized by functional areas.
            - **`Entry/`**: App entry points (`ContentView`, `Sidebar`).
            - **`Main/`**: App lifecycle (`MainApp`, `AppDelegate`).
            - **`Detail/`**: Detail views for sidebar selections (Machines, About, etc.).
            - **`Configuration/`**: Views for creating and editing VM configurations (Wizards, Settings).
        - **`Core/`**: Business logic and backend interaction.
            - **`VMKit/`**: Core virtualization logic.
                - **`VMOSRunner`**: Handles the execution of VMs.
                - **`VMOSCreator`**: Handles the creation/installation of VMs.
                - **`Model/`**: Data models for VM configuration (CPU, Memory, Devices).
        - **`Model/`**: App-level models (e.g., `AppConfigModel`).
        - **`Common/`**: Utility extensions and helpers (`MacKitUtil`, `Palettes`).
        - **`Assets.xcassets`**: App icons and colors.
- **`Assets/`**: Static assets for documentation (screenshots, logos).

## 3. How to Run Locally

Since this is an Xcode project, command-line execution is possible but typically requires `xcodebuild` or opening Xcode.

**Build and Run (CLI):**
```bash
# Build the project
xcodebuild -project EasyVM/EasyVM.xcodeproj -scheme EasyVM -destination 'platform=macOS,arch=arm64' build
```

**Open in IDE:**
```bash
open EasyVM/EasyVM.xcodeproj
```

## 4. Testing

- Currently, the project relies on manual testing.
- **Unit Tests:** If adding tests, place them in a dedicated Test target (currently not explicitly visible in the main source tree).
- **Manual Verification:**
    - Build and run the app.
    - Attempt to create a "Dummy" VM configuration to verify UI flows.
    - Full functional testing requires downloading large OS images (macOS IPSW or Linux ARM ISO).

## 5. Coding Style & Conventions

- **Language:** Swift 5+.
- **UI:** SwiftUI is the primary UI framework.
- **Architecture:** MVVM (Model-View-ViewModel) pattern is observed (e.g., `MachinesHomeStateObject`, `VMCreateViewStateObject`).
- **Formatting:** Follow standard Swift community guidelines.
    - Indentation: 4 spaces.
    - CamelCase for types, camelCase for properties/functions.
- **Comments:** Use documentation comments (`///`) for public APIs and complex logic.

## 6. How to Debug

- Use `print()` or standard Xcode breakpoints for debugging.
- Check the "Console" output in Xcode for runtime errors from `Virtualization.framework`.
- **Common Issues:**
    - Entitlements: Ensure `com.apple.security.virtualization` is enabled (checked in `EasyVM.entitlements`).
    - Hardware: This app **only** works on Apple Silicon Macs.

## 7. Rules for Contributions

- **Scope:** Keep changes focused. Avoid large, unrelated refactors.
- **Documentation:** Update `README.md` if user-facing features change.
- **Safety:** Do not commit personal signing identities or local configuration files.
- **UI Changes:** Verify changes across Light and Dark modes.

## 8. PR Checklist

- [ ] Code compiles without warnings.
- [ ] New features are manual-tested.
- [ ] Code follows existing Swift style.
- [ ] No regression in existing VM creation flows.
