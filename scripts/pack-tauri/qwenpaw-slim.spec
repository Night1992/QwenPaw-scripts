# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the slim (headless API) QwenPaw backend.

Differences from ``qwenpaw.spec``:

* Excludes the web console static assets (served by a separate frontend).
* Excludes the desktop sidecar executable (``qwenpaw-backend``) — there is no
  Tauri shell to drive, so only the ``qwenpaw`` CLI/API executable is built.
* Everything the API needs at runtime is still collected: tokenizer, agent
  skills, security rule data, channel protos, provider data, ReMe/Codex/Qoder
  assets, and package metadata.

Builds an onedir bundle so the API loads Python directly without onefile
extraction. Shared for both macOS and Windows.
"""

import os
import sys
from pathlib import Path

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_submodules,
    copy_metadata,
    get_package_paths,
)

REPO_ROOT = Path(SPECPATH).parent.parent

SRC = REPO_ROOT / "src" / "qwenpaw"
MAIL_MCP_SRC = REPO_ROOT / "packages" / "qwenpawmail-mcp" / "src"

if sys.platform == "darwin":
    codesign_identity = os.environ.get(
        "PYINSTALLER_CODESIGN_IDENTITY"
    ) or os.environ.get("APPLE_SIGNING_IDENTITY")
else:
    codesign_identity = None

_data_dirs = [
    ("agents/skills", "qwenpaw/agents/skills"),
    ("agents/md_files", "qwenpaw/agents/md_files"),
    ("tokenizer", "qwenpaw/tokenizer"),
    ("security/tool_guard/rules", "qwenpaw/security/tool_guard/rules"),
    ("security/skill_scanner/rules", "qwenpaw/security/skill_scanner/rules"),
    ("security/skill_scanner/data", "qwenpaw/security/skill_scanner/data"),
    ("app/channels/yuanbao/proto", "qwenpaw/app/channels/yuanbao/proto"),
    ("providers/data", "qwenpaw/providers/data"),
]
datas = [
    (str(SRC / src), dst) for src, dst in _data_dirs if (SRC / src).is_dir()
]
datas.append(
    (
        str(SRC / "browser/control_link/injected/engine.js"),
        "qwenpaw/browser/control_link/injected",
    ),
)

# ReMe + agentscope package data files (configs, tool yamls, plugin manifests).
# Discovered through importlib.metadata entry points, so PyInstaller cannot
# infer their modules or data files from static imports.
datas += collect_data_files("reme")
datas += collect_data_files("reme_auto_fin")
datas += collect_data_files("reme_daily_paper")
datas += collect_data_files("whisper")
datas += collect_data_files("agentscope")
datas += collect_data_files(
    "agentscope.tool._builtin._scripts",
    include_py_files=True,
)
datas += collect_data_files(
    "agentscope.workspace._mcp_gateway",
    include_py_files=True,
)

# The Qoder SDK ships a platform-specific qodercli executable. Classify it as
# a binary so PyInstaller preserves executable permissions and signs it with
# the rest of the macOS bundle.
_, _qoder_sdk_dir = get_package_paths("qoder_agent_sdk")
_qoder_cli_name = "qodercli.exe" if sys.platform == "win32" else "qodercli"
_qoder_cli = Path(_qoder_sdk_dir) / "_bundled" / _qoder_cli_name
if not _qoder_cli.is_file():
    raise SystemExit(
        f"Qoder SDK CLI not found at {_qoder_cli}; reinstall qoder-agent-sdk"
    )
qoder_binaries = [
    (str(_qoder_cli), "qoder_agent_sdk/_bundled"),
]

# The official Codex Python SDK depends on a platform wheel exposing a stable
# bundled_codex_path() API. Preserve its runtime layout because Codex resolves
# sibling hosts and resources relative to the main executable.
_, _codex_bin_dir = get_package_paths("codex_cli_bin")
_codex_bin_dir = Path(_codex_bin_dir)
_codex_executable = "codex.exe" if sys.platform == "win32" else "codex"
_codex_cli = _codex_bin_dir / "bin" / _codex_executable
if not _codex_cli.is_file():
    raise SystemExit(
        f"Codex SDK CLI not found at {_codex_cli}; reinstall openai-codex"
    )
codex_binaries = [
    (
        str(path),
        str(Path("codex_cli_bin") / path.relative_to(_codex_bin_dir).parent),
    )
    for directory_name in ("bin", "codex-path", "codex-resources")
    for path in (_codex_bin_dir / directory_name).rglob("*")
    if path.is_file()
]
datas.append(
    (
        str(_codex_bin_dir / "codex-package.json"),
        "codex_cli_bin",
    ),
)

# Collect package metadata for packages queried via importlib.metadata at
# runtime. Keep this allowlist in sync when adding runtime dependencies that
# query importlib.metadata, otherwise packaged backends may fail only after
# install.
_metadata_pkgs = [
    "qwenpaw",
    "fastmcp",
    "mcp",
    "httpx",
    "httpcore",
    "anyio",
    "sniffio",
    "starlette",
    "pydantic",
    "pydantic-core",
    "pydantic-settings",
    "uvicorn",
    "openai",
    "anthropic",
    "tiktoken",
    "agentscope",
    "agentscope-runtime",
    "reme-ai",
    "reme-auto-fin",
    "reme-daily-paper",
    "huggingface_hub",
    "modelscope",
    "openai-whisper",
    "openai-codex",
    "openai-codex-cli-bin",
    "qoder-agent-sdk",
]
for _pkg in _metadata_pkgs:
    try:
        datas += copy_metadata(_pkg)
    except Exception:
        pass

ENTRY = SRC / "tauri" / "slim_entry.py"

a = Analysis(
    [str(ENTRY)],
    pathex=[str(REPO_ROOT), str(REPO_ROOT / "src"), str(MAIL_MCP_SRC)],
    binaries=[*qoder_binaries, *codex_binaries],
    datas=datas,
    hiddenimports=[
        "codex_cli_bin",
        # uvicorn internals (not auto-discovered by PyInstaller)
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        # All CLI sub-commands (dynamically loaded by Click)
        *collect_submodules("qwenpaw.cli"),
        # The mail MCP package lives under a second setuptools source root.
        *collect_submodules("qwenpawmail_mcp"),
        # All channel adapters (imported on-demand at runtime)
        *collect_submodules("qwenpaw.app.channels"),
        # ACP runner support is lazily imported by delegate_external_agent.
        *collect_submodules("qwenpaw.agents.acp"),
        # PawApp SDK modules are imported by installed app plugins at runtime.
        *collect_submodules("qwenpaw.pawapp"),
        # ASGI app entry points
        "qwenpaw.app._app",
        "qwenpaw.app.multi_agent_manager",
        "qwenpaw.app.chats",
        "qwenpaw.app.task_tracker",
        "qwenpaw.runtime.commands",
        # Backup modules are exposed through qwenpaw.backup.__getattr__, which
        # PyInstaller cannot discover from static imports.
        *collect_submodules("qwenpaw.backup"),
        # ReMe loads these plugin backends from plugin.yaml targets exposed by
        # distribution entry points, which are invisible to static analysis.
        *collect_submodules("reme_auto_fin"),
        *collect_submodules("reme_daily_paper"),
        # Third-party packages that use dynamic imports.
        *collect_submodules("dotenv"),
        "dotenv",
        *collect_submodules("acp"),
        "acp",
        "psutil",
        "multipart",
        "websockets",
        "modelscope",
        "modelscope.hub.api",
        "modelscope.hub.snapshot_download",
        *collect_submodules("agentscope.tool._builtin._scripts"),
        *collect_submodules("agentscope.workspace._mcp_gateway"),
        *collect_submodules("whisper"),
        *collect_submodules("chromadb"),
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    name="qwenpaw",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    # UPX triggers antivirus false positives and can corrupt binaries.
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=codesign_identity,
    exclude_binaries=True,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="qwenpaw-slim",
)
