#!/usr/bin/env bash
# Build the slim (headless API) QwenPaw backend with PyInstaller.
#
# Produces a self-contained onedir bundle at dist/pyinstaller/qwenpaw-slim/
# containing a single `qwenpaw` CLI/API executable plus an embedded Python
# runtime. No Python/Node environment is required on the target machine.
#
# Unlike build_pyinstaller.sh, this:
#   * uses qwenpaw-slim.spec (no web console, no desktop sidecar),
#   * does not stage the Node runtime / Chrome native-messaging host, and
#   * does not copy into the Tauri binaries directory.
#
# Usage:
#   ./scripts/pack-tauri/build_slim.sh
#
# Prerequisites (build machine only):
#   - Python 3.10+ on PATH (used only to bootstrap the bundled runtime)
#   - PyInstaller 6.0+ (will be installed if not present)

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DIST="${DIST:-dist}"
BINARIES_DIR="${REPO_ROOT}/console/src-tauri/binaries"
PYTHON_RUNTIME_DIR="${BINARIES_DIR}/python-runtime"
RUNTIME_PYTHON_DIR="${PYTHON_RUNTIME_DIR}/python"
NATIVE_HOST_PYTHON="${RUNTIME_PYTHON_DIR}/bin/python3"
BUILD_VENV="${DIST}/pyinstaller-venv"
PYTHON_BIN="${BUILD_VENV}/bin/python"
VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)

echo "========================================="
echo "QwenPaw Slim Backend Build"
echo "========================================="
echo "Version: ${VERSION}"
echo "Repository: ${REPO_ROOT}"
echo ""

# Check prerequisites
echo "== Checking prerequisites =="
if command -v python3 >/dev/null 2>&1; then
    BOOTSTRAP_PYTHON=$(command -v python3)
elif command -v python >/dev/null 2>&1; then
    BOOTSTRAP_PYTHON=$(command -v python)
else
    echo "ERROR: Python not found on PATH; it is required to stage the bundled runtime"
    exit 1
fi

mkdir -p "${BINARIES_DIR}"

# The staged python-build-standalone runtime is the canonical source for the
# build environment. The PATH Python only selects the X.Y version to download
# and runs the staging script.
echo "== Staging canonical Python runtime =="
"$BOOTSTRAP_PYTHON" "${REPO_ROOT}/scripts/pack-tauri/stage_python_runtime.py" \
    --dest "${PYTHON_RUNTIME_DIR}"
if [ ! -f "$NATIVE_HOST_PYTHON" ]; then
    echo "ERROR: Bundled Python interpreter not found at ${NATIVE_HOST_PYTHON}"
    exit 1
fi

echo "== Creating PyInstaller build environment =="
"$NATIVE_HOST_PYTHON" -m venv --clear "$BUILD_VENV"

echo "Python: $("$PYTHON_BIN" --version)"
echo ""

install_python_packages() {
    if command -v uv &>/dev/null; then
        uv pip install --python "$PYTHON_BIN" "$@"
    else
        "$PYTHON_BIN" -m pip install "$@"
    fi
}

uninstall_python_package() {
    if command -v uv &>/dev/null; then
        uv pip uninstall --python "$PYTHON_BIN" -y "$1" >/dev/null 2>&1 || true
    else
        "$PYTHON_BIN" -m pip uninstall -y "$1" >/dev/null 2>&1 || true
    fi
}

# Install PyInstaller if not present
echo "== Installing PyInstaller =="
if ! "$PYTHON_BIN" -c "import PyInstaller" 2> /dev/null; then
    echo "Installing PyInstaller..."
    install_python_packages "pyinstaller>=6.0.0"
fi
echo "PyInstaller installed"

# Install project dependencies (ensures ALL runtime deps are importable).
# Pin setuptools <82: see build_pyinstaller.sh for the lark-oapi rationale.
echo "== Installing project dependencies =="
install_python_packages -e ".[full]" "setuptools<82"
echo "Project dependencies installed with full extras"

# Fix agent-client-protocol namespace collision.
# PyPI has an empty 'acp' stub that shadows the real package.
if ! "$PYTHON_BIN" -c "from acp import Agent" 2> /dev/null; then
    echo "Fixing agent-client-protocol namespace..."
    uninstall_python_package acp
    install_python_packages "agent-client-protocol>=0.9.0,<0.11.0"
fi
echo ""

# Run PyInstaller
echo "== Running PyInstaller =="
echo "Building onedir slim backend bundle..."

SPEC_FILE="${REPO_ROOT}/scripts/pack-tauri/qwenpaw-slim.spec"
if [ ! -f "$SPEC_FILE" ]; then
    echo "ERROR: Spec file not found at ${SPEC_FILE}"
    exit 1
fi

"$PYTHON_BIN" -m PyInstaller "$SPEC_FILE" \
    --distpath "${DIST}/pyinstaller" \
    --workpath "${DIST}/pyinstaller-build" \
    --clean \
    --noconfirm

echo "PyInstaller build complete"
echo ""

# Verify output
BACKEND_DIR="${DIST}/pyinstaller/qwenpaw-slim"
CLI_EXE="${BACKEND_DIR}/qwenpaw"
MODEL_CATALOG="${BACKEND_DIR}/_internal/qwenpaw/providers/data/model_catalog.json"
if [ ! -d "${BACKEND_DIR}" ]; then
    echo "ERROR: Backend bundle directory not found at ${BACKEND_DIR}"
    exit 1
fi
if [ ! -f "${CLI_EXE}" ]; then
    echo "ERROR: CLI executable not found at ${CLI_EXE}"
    exit 1
fi
if [ ! -f "${MODEL_CATALOG}" ]; then
    echo "ERROR: Model catalog not found at ${MODEL_CATALOG}"
    exit 1
fi
chmod +x "${CLI_EXE}"

echo "Slim backend bundle created: ${BACKEND_DIR}"
SIZE=$(du -sh "${BACKEND_DIR}" | cut -f1)
echo "Bundle size: ${SIZE}"
echo ""

echo "========================================="
echo "Slim Backend Build Complete!"
echo "========================================="
echo "Run the API on the target machine:"
echo "  ./qwenpaw init                 # first-time setup (LLM keys, etc.)"
echo "  ./qwenpaw app --host 0.0.0.0 --port 8088"
echo ""
