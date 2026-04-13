# UnrealBuildRunTestScript

Reusable PowerShell toolkit for Unreal Engine projects on Windows.

It provides:

- build/run/test entry scripts for Unreal projects
- repo-local build/run scripts that sync `Config/UBT/BuildConfiguration.xml`
  into `Saved/UnrealBuildTool/BuildConfiguration.xml` before invoking UBT
- a configurable `Verify.ps1` implementation for project-wide verification
- an installer that scaffolds a repo-local verify wrapper, config, and
  pre-commit hook

## Install reusable Verify into another project

1. Add this repository to the target Unreal project, typically as a submodule:

```powershell
git submodule add https://github.com/metyatech/UnrealBuildRunTestScript.git UnrealBuildRunTestScript
```

2. Run the installer from the target project root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\UnrealBuildRunTestScript\Install-UnrealProjectVerify.ps1
```

3. Commit the generated files:

- `Verify.ps1`
- `UnrealProjectVerify.config.psd1`
- `.githooks/pre-commit`

The installer also runs `git config core.hooksPath .githooks`, so the hook is
active immediately in that repository.

If the repository has exactly one `.uproject` at its root, the installer and
shared verify entry point auto-detect both `ProjectName` and `UProjectPath`.
Only set those fields explicitly when the project file is not at the repo root
or when multiple root-level `.uproject` files exist.

## Generated files

### `Verify.ps1`

Thin repo-local wrapper that forwards all arguments to the shared toolkit entry
point.

### `UnrealProjectVerify.config.psd1`

Project-specific verify settings. The main fields are:

- `ProjectName`: optional override for the human-readable project label
- `UProjectPath`: optional repo-relative override for the `.uproject`
- `DefaultTestFilter`: default automation test filter
- `DefaultBranchRef`: default base ref for PR-style static analysis
- `StaticAnalysisPathspec`: repo-relative roots scanned by clang-format /
  clang-tidy selection
- `BuildImpactPatterns`: file patterns that trigger Unreal build/test work in
  local mode
- `AutomationSpecPatterns`: spec implementation globs used for safe local test
  narrowing
- `PowerShellLintPaths`: repo-relative paths linted with PSScriptAnalyzer
- `RegressionTests`: optional repo-specific regression scripts to run during
  verify
- `ShellHookRegressionScript`: optional shell-hook regression script

## Verify usage

Standard usage from the target project root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Verify.ps1
```

Full PR-style gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Verify.ps1 -StaticAnalysisScope pr -BuildAndTestScope all
```

## Shared-workstation CI engine isolation

If GitHub Actions runs on the same Windows machine used for interactive Unreal
development, set `UNREAL_VERIFY_CI_ENGINE_ROOT` to an installed engine tree
that is not used for local work. It may point either at the concrete engine
root or at a versioned parent such as `D:\UE_CI` containing `UE_5.6`,
`UE_5.5`, and so on. This avoids `UnrealBuildTool_Mutex_*` contention between
CI and local editor builds.

## Toolkit self-tests

Run the toolkit regression tests from this repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-toolkit-regression.ps1
```
