# -*- coding: utf-8 -*-
"""PyInstaller entry point for the slim (headless API) QwenPaw backend.

Unlike the desktop sidecar entry (``entry.py``), this does not set the desktop
app env, does not start the browser/control-link desktop runtime, and does not
bundle or serve the web console. It only applies a sensible default CORS
allowlist and then dispatches to the public Click CLI, so ``qwenpaw init`` and
``qwenpaw app`` behave exactly as they do in a source install.

The bundled web console is served separately (default ``http://localhost:8080``)
and calls this API cross-origin, hence the default allowlist.
"""

from __future__ import annotations

import multiprocessing as mp
import os

_CORS_ORIGINS_ENV = "QWENPAW_CORS_ORIGINS"
_DEFAULT_CORS_ORIGINS = "http://localhost:8080,http://127.0.0.1:8080"


def main() -> None:
    # PyInstaller replaces this function on every platform. It must run before
    # application initialization so multiprocessing workers do not re-enter the
    # backend entry point.
    mp.freeze_support()

    # Must run before qwenpaw.constant reads QWENPAW_CORS_ORIGINS at import
    # time (the FastAPI CORS middleware is configured from that value).
    # setdefault keeps an explicit operator value authoritative.
    os.environ.setdefault(_CORS_ORIGINS_ENV, _DEFAULT_CORS_ORIGINS)

    from qwenpaw.cli.main import cli

    cli()  # pylint: disable=no-value-for-parameter


if __name__ == "__main__":
    main()
