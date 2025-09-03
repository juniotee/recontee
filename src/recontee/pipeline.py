from __future__ import annotations
from pathlib import Path
from .utils import ensure_dir

class Context:
    """Execution context per target."""
    def __init__(self, target: str, outdir: Path, threads: int, wordlist: Path):
        self.target = target
        self.outdir = ensure_dir(outdir)
        self.threads = threads
        self.wordlist = wordlist
        self.raw = ensure_dir(self.outdir / "raw")
        self.web = ensure_dir(self.outdir / "web")
        self.urls = ensure_dir(self.outdir / "urls")
        self.ffuf = ensure_dir(self.outdir / "ffuf")
        self.report = ensure_dir(self.outdir / "report")
