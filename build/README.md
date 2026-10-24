# Zipper build tools

This folder contains the local build script for packaging the repository's Zipper.ps1 as a single Windows executable.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or a compatible PowerShell host on Windows.
- Internet access on the first build, so the script can install the pinned PS2EXE 1.0.18 module from PowerShell Gallery.
- No Visual Studio or separately installed .NET SDK is required by this build process.

## Build locally

Run these commands from the repository root:

    .\build\build.ps1

The script reads the app version from Zipper.ps1, installs PS2EXE 1.0.18 for the current user if needed, and writes:

- dist\Zipper.exe — GUI application, STA, requests administrator permission through UAC.
- dist\Zipper.exe.sha256 — SHA-256 checksum for verifying the EXE.

Generated files are ignored by Git and are not committed to the source tree. The script removes only its own old EXE and checksum before compiling, to avoid leaving a stale binary after a failed build.

If your PowerShell execution policy blocks a locally downloaded script, you can run it in a process-scoped session without changing the machine or user policy:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\build.ps1

## GitHub Releases

The workflow at .github/workflows/release.yml builds the EXE on a Windows runner when a version tag (V* or v*) is pushed. It first checks that the version in the tag matches the version in Zipper.ps1, then creates a GitHub Release containing the EXE and checksum. A manual run from the Actions tab builds and uploads an artifact but does not publish a release unless the selected ref is a tag.

Example for the current source version:

    git tag V1.2
    git push origin V1.2

Before creating a new version tag, update the version in Zipper.ps1 and commit that change. Version tags with two, three, or four numeric components are accepted as long as they represent the same four-part Windows file version.

## Notes

- This packages the existing PowerShell source; it does not rewrite the app's compression engine.
- PS2EXE embeds the PowerShell script into the EXE, but the source can still be extracted. This is suitable for an open-source project.
- Test the generated executable on Windows before announcing a release. The automated workflow verifies that packaging succeeds and that the EXE/checksum exist; it does not run a full interactive compression test.
- To provide an application icon, add assets\Zipper.ico to the repository; the build script will use it automatically.
