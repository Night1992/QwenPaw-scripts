# Build the slim (headless API) QwenPaw backend with PyInstaller (Windows).
# Creates a self-contained onedir bundle at dist\pyinstaller\qwenpaw-slim\
# containing a single qwenpaw.exe CLI/API executable plus an embedded Python
# runtime. No Python/Node environment is required on the target machine.
#
# Unlike build_pyinstaller.ps1, this:
#   * uses qwenpaw-slim.spec (no web console, no desktop sidecar),
#   * does not stage the Node runtime / Chrome native-messaging host,
#   * does not build the computer-use Rust helper, and
#   * does not copy into the Tauri binaries directory.
#
# Usage:
#   powershell ./scripts/pack-tauri/build_slim.ps1
#
# Prerequisites (build machine only):
#   - Python 3.10+ on PATH (used only to bootstrap the bundled runtime)
#   - PyInstaller 6.0+ (will be installed if not present)

param()

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $REPO_ROOT

$DIST = if ($env:DIST) { $env:DIST } else { "dist" }
if (-not [System.IO.Path]::IsPathRooted($DIST)) {
    $DIST = Join-Path $REPO_ROOT $DIST
}
$BINARIES_DIR = Join-Path $REPO_ROOT "console\src-tauri\binaries"
$PYTHON_RUNTIME_DIR = Join-Path $BINARIES_DIR "python-runtime"
$RUNTIME_PYTHON_DIR = Join-Path $PYTHON_RUNTIME_DIR "python"
$NATIVE_HOST_PYTHON = Join-Path $RUNTIME_PYTHON_DIR "python.exe"
$BUILD_VENV = Join-Path $DIST "pyinstaller-venv"
$PYTHON_BIN = Join-Path $BUILD_VENV "Scripts\python.exe"
$VERSION_FILE = "src\qwenpaw\__version__.py"

function Assert-LastExit {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) { throw $Message }
}

# Extract version
if (Test-Path $VERSION_FILE) {
    $content = Get-Content $VERSION_FILE -Raw
    if ($content -match '__version__\s*=\s*"([^"]+)"') {
        $VERSION = $Matches[1]
    } else {
        throw "Failed to extract version from $VERSION_FILE"
    }
} else {
    throw "Version file not found: $VERSION_FILE"
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "QwenPaw Slim Backend Build - Windows" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Version: $VERSION"
Write-Host "Repository: $REPO_ROOT"
Write-Host ""

# Check prerequisites
Write-Host "== Checking prerequisites ==" -ForegroundColor Yellow

$UV_BIN = (Get-Command uv -ErrorAction SilentlyContinue).Source
$BOOTSTRAP_PYTHON = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $BOOTSTRAP_PYTHON -or -not (Test-Path $BOOTSTRAP_PYTHON)) {
    throw "Python not found on PATH; it is required to stage the bundled runtime"
}

New-Item -ItemType Directory -Force -Path $BINARIES_DIR | Out-Null

# The staged python-build-standalone runtime is the canonical source for the
# build environment. The PATH Python only selects the X.Y version to download
# and runs the staging script.
Write-Host "== Staging canonical Python runtime ==" -ForegroundColor Yellow
& $BOOTSTRAP_PYTHON `
    (Join-Path $REPO_ROOT "scripts\pack-tauri\stage_python_runtime.py") `
    --dest $PYTHON_RUNTIME_DIR
Assert-LastExit "Failed to stage bundled Python runtime"
if (-not (Test-Path $NATIVE_HOST_PYTHON -PathType Leaf)) {
    throw "Bundled Python interpreter not found at $NATIVE_HOST_PYTHON"
}

Write-Host "== Creating PyInstaller build environment ==" -ForegroundColor Yellow
& $NATIVE_HOST_PYTHON -m venv --clear $BUILD_VENV
Assert-LastExit "Failed to create PyInstaller environment from bundled Python"

$pythonVersion = & $PYTHON_BIN --version
Write-Host "Python: $pythonVersion" -ForegroundColor Green
Write-Host ""

function Test-PythonImport {
    param([string]$Statement)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $PYTHON_BIN -c $Statement *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Install-PythonPackages {
    param([string[]]$Packages)
    if ($UV_BIN) {
        & $UV_BIN pip install --python $PYTHON_BIN @Packages
    } else {
        & $PYTHON_BIN -m pip install @Packages
    }
    Assert-LastExit "Failed to install Python packages: $($Packages -join ', ')"
}

function Uninstall-PythonPackage {
    param([string]$Package)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($UV_BIN) {
            & $UV_BIN pip uninstall --python $PYTHON_BIN -y $Package *> $null
        } else {
            & $PYTHON_BIN -m pip uninstall -y $Package *> $null
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

# Install PyInstaller if not present
Write-Host "== Installing PyInstaller ==" -ForegroundColor Yellow
if (Test-PythonImport "import PyInstaller") {
    Write-Host "PyInstaller already installed" -ForegroundColor Green
} else {
    Write-Host "Installing PyInstaller..."
    Install-PythonPackages -Packages @("pyinstaller>=6.0.0")
    Write-Host "PyInstaller installed" -ForegroundColor Green
}

# Install python-dotenv if not present (required by PyInstaller collect_submodules)
if (Test-PythonImport "import dotenv") {
    Write-Host "python-dotenv already installed" -ForegroundColor Green
} else {
    Write-Host "Installing python-dotenv..."
    Install-PythonPackages -Packages @("python-dotenv")
    Write-Host "python-dotenv installed" -ForegroundColor Green
}

Write-Host ""

# Install project dependencies (ensures ALL runtime deps are importable).
# Pin setuptools <82: see build_pyinstaller.ps1 for the lark-oapi rationale.
Write-Host "== Installing project dependencies ==" -ForegroundColor Yellow
Install-PythonPackages -Packages @("-e", ".[full]", "setuptools<82")
Write-Host "Project dependencies installed with full extras" -ForegroundColor Green

# Fix agent-client-protocol namespace collision.
# PyPI has an empty 'acp' stub that shadows the real package.
if (-not (Test-PythonImport "from acp import Agent")) {
    Write-Host "Fixing agent-client-protocol namespace..."
    Uninstall-PythonPackage "acp"
    Install-PythonPackages -Packages @("agent-client-protocol>=0.9.0,<0.11.0")
    Write-Host "agent-client-protocol installed" -ForegroundColor Green
}
Write-Host ""

# Run PyInstaller
Write-Host "== Running PyInstaller ==" -ForegroundColor Yellow
Write-Host "Building onedir slim backend bundle..."

$SPEC_FILE = Join-Path $REPO_ROOT "scripts\pack-tauri\qwenpaw-slim.spec"
if (-not (Test-Path $SPEC_FILE)) {
    Write-Host "ERROR: Spec file not found at $SPEC_FILE" -ForegroundColor Red
    exit 1
}

& $PYTHON_BIN -m PyInstaller $SPEC_FILE `
    --distpath "${DIST}\pyinstaller" `
    --workpath "${DIST}\pyinstaller-build" `
    --clean `
    --noconfirm

if ($LASTEXITCODE -ne 0) {
    throw "PyInstaller build failed"
}

Write-Host "PyInstaller build complete" -ForegroundColor Green
Write-Host ""

# Verify output
$BACKEND_DIR = Join-Path $DIST "pyinstaller\qwenpaw-slim"
$CLI_EXE = Join-Path $BACKEND_DIR "qwenpaw.exe"
$MODEL_CATALOG = Join-Path $BACKEND_DIR `
    "_internal\qwenpaw\providers\data\model_catalog.json"
if (-not (Test-Path $BACKEND_DIR)) {
    Write-Host "ERROR: Backend bundle directory not found at $BACKEND_DIR" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $CLI_EXE)) {
    Write-Host "ERROR: CLI executable not found at $CLI_EXE" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $MODEL_CATALOG)) {
    Write-Host "ERROR: Model catalog not found at $MODEL_CATALOG" -ForegroundColor Red
    exit 1
}

$bundleSize = (Get-ChildItem $BACKEND_DIR -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host "Slim backend bundle created: $BACKEND_DIR" -ForegroundColor Green
Write-Host "Bundle size: $([math]::Round($bundleSize, 2)) MB"
Write-Host ""

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Slim Backend Build Complete!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Run the API on the target machine:"
Write-Host "  .\qwenpaw.exe init                 # first-time setup (LLM keys, etc.)"
Write-Host "  .\qwenpaw.exe app --host 0.0.0.0 --port 8088"
Write-Host ""
