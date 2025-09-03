from __future__ import annotations
from pathlib import Path
from rich.console import Console
from ..utils import run, run_sh, ensure_dir

console = Console()

def subfinder(target: str, outdir: Path) -> Path:
    """Run subfinder and save raw output."""
    out = outdir / "raw" / "subs_subfinder.txt"
    ensure_dir(out.parent)
    console.log("1) subfinder…")
    cmd = ["subfinder", "-silent", "-d", target, "-all", "-recursive", "-nW", "-timeout", "30", "-t", "80", "-o", str(out)]
    run(cmd)
    return out

def amass_passive(target: str, outdir: Path) -> Path:
    """Run amass in passive mode and save output."""
    out = outdir / "raw" / "subs_amass.txt"
    ensure_dir(out.parent)
    console.log("1) amass (passive)…")
    cmd = ["amass", "enum", "-passive", "-d", target, "-timeout", "30"]
    lines = run(cmd)
    out.write_text("\n".join(lines), encoding="utf-8")
    return out

def merge(outdir: Path) -> Path:
    """Merge subfinder/amass/crtsh into subs.txt (deduped)."""
    raw_dir = outdir / "raw"
    dest = raw_dir / "subs.txt"
    all_lines: list[str] = []
    for f in [raw_dir / "subs_subfinder.txt", raw_dir / "subs_amass.txt", raw_dir / "subs_crtsh.txt"]:
        if f.exists():
            all_lines += [l.strip().lower() for l in f.read_text(encoding="utf-8").splitlines() if l.strip()]
    uniq = sorted(set(all_lines))
    dest.write_text("\n".join(uniq), encoding="utf-8")
    console.log(f"   merge total: {len(uniq)}")
    return dest

def crtsh_fallback(target: str, outdir: Path) -> Path:
    """Fallback via crt.sh JSON → jq → dedupe."""
    out = outdir / "raw" / "subs_crtsh.txt"
    ensure_dir(out.parent)
    console.log("1) crt.sh fallback…")
    cmd = f'curl -s "https://crt.sh/?q=%25.{target}&output=json" | jq -r ".[] .name_value" | tr "\r" "\n" | sed "s/^\*\.//" | sort -u'
    lines = run_sh(cmd)
    out.write_text("\n".join(lines), encoding="utf-8")
    return out
