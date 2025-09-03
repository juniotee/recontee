from __future__ import annotations
from pathlib import Path
from rich.console import Console
from ..utils import run

console = Console()

def dnsx_filter(subs_file: Path, out: Path, threads: int = 150, resolvers: Path | None = None, force: bool = False) -> Path:
    """Use dnsx to keep only subdomains that resolve (A/AAAA/CNAME)."""
    out_file = out / "raw" / "subs_resolved.txt"
    if (not force) and out_file.exists() and out_file.stat().st_size > 0:
        return out_file
    console.log("2) dnsx (resolver)…")
    cmd = ["dnsx","-silent","-l",str(subs_file),"-a","-aaaa","-cname","-t",str(threads)]
    if resolvers:
        cmd += ["-r", str(resolvers)]
    lines = run(cmd)
    uniq = sorted(set([ln.strip() for ln in lines if ln.strip()]))
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(uniq), encoding="utf-8")
    console.log(f"   subdomains that resolve: {len(uniq)}")
    return out_file
