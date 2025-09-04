from __future__ import annotations
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import shutil, subprocess, os, json
from typing import Iterable
from rich.console import Console
from ..utils import run, ensure_dir

console = Console()

def _bin(path: str, fallback: str | None = None) -> str | None:
    p = shutil.which(path)
    if p: return p
    if fallback:
        cand = str(Path.home()/ "go"/ "bin"/ fallback)
        if Path(cand).exists(): return cand
    return None

def _write_dedup(lines: Iterable[str], dest: Path) -> int:
    uniq = sorted(set(s.strip() for s in lines if s and s.strip()))
    ensure_dir(dest.parent)
    dest.write_text("\n".join(uniq), encoding="utf-8")
    return len(uniq)

def _katana_supports(katana_bin: str, flag: str) -> bool:
    try:
        res = subprocess.run([katana_bin, "-h"], capture_output=True, text=True, timeout=5)
        helptext = (res.stdout or "") + (res.stderr or "")
        return f" {flag}" in helptext or f"{flag} " in helptext or f"{flag}\n" in helptext
    except Exception:
        return False

def katana_from_list(hosts_file: Path, outdir: Path, threads: int = 80, depth: int = 2) -> Path:
    """Run Katana against live URLs list; auto-detect supported flags."""
    katana = _bin("katana","katana")
    urls_out = outdir/ "urls"/ "katana.txt"
    if not katana:
        console.print("[yellow]katana not found. Skipping.[/yellow]")
        urls_out.write_text("",encoding="utf-8"); return urls_out
    raw_json = outdir/ "urls"/ "katana_raw.jsonl"
    ensure_dir(urls_out.parent)
    console.log("4) katana…")
    cmd = [katana, "-silent","-list",str(hosts_file),"-depth",str(depth),"-jc","-aff","-timeout","20","-no-color","-max-redirects","3","-threads",str(threads)]
    if _katana_supports(katana,"-retries"): cmd += ["-retries","2"]
    if _katana_supports(katana,"-rate-limit"): cmd += ["-rate-limit","1000"]
    if os.environ.get("HTTP_PROXY") and _katana_supports(katana,"-http-proxy"): cmd += ["-http-proxy", os.environ["HTTP_PROXY"]]
    lines = list(run(cmd))
    raw_json.write_text("\n".join(lines), encoding="utf-8")
    urls = []
    for ln in lines:
        try:
            obj=json.loads(ln); req=obj.get("request") or {}; u=req.get("url")
            if isinstance(u,str) and u.startswith(("http://","https://")): urls.append(u)
        except Exception: pass
    n=_write_dedup(urls, urls_out)
    if n==0: console.print("[yellow]Katana returned 0 URLs.[/yellow]")
    else: console.log(f"   katana URLs: {n}")
    return urls_out

def _gau_one(domain: str) -> list[str]:
    gau = _bin("gau","gau")
    if not gau: return []
    cmd = [gau, "-subs", "--providers", "wayback,commoncrawl,otx"]
    try:
        proc = subprocess.run(cmd, input=domain.encode(), capture_output=True, timeout=180)
        if proc.returncode != 0: return []
        out = proc.stdout.decode(errors="ignore").splitlines()
        out = [l.strip() for l in out if domain in l]
        return out
    except Exception:
        return []

def gau_from_subs(subs_file: Path, outdir: Path, max_workers: int = 8) -> Path:
    """Run GAU over base domains extracted from subdomain list."""
    gau = _bin("gau","gau")
    urls_out = outdir/ "urls"/ "gau.txt"
    ensure_dir(urls_out.parent)
    if not gau:
        console.print("[yellow]gau not found. Skipping.[/yellow]")
        urls_out.write_text("",encoding="utf-8"); return urls_out
    console.log("5) gau…")
    subs = [l.strip() for l in subs_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not subs: urls_out.write_text("",encoding="utf-8"); return urls_out
    bases=set()
    for s in subs:
        parts=s.split(".")
        if len(parts)>=2: bases.add(".".join(parts[-2:]))
    results: list[str]=[]
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs={ex.submit(_gau_one,b):b for b in sorted(bases)}
        for f in as_completed(futs):
            try: results.extend(f.result() or [])
            except Exception: pass
    n=_write_dedup(results, urls_out)
    if n==0: console.print("[yellow]GAU returned 0 URLs.[/yellow]")
    else: console.log(f"   gau URLs: {n}")
    return urls_out

def merge_urls(outdir: Path) -> Path:
    """Merge katana + gau URLs into urls/all_urls.txt (deduped)."""
    all_out = outdir/ "urls"/ "all_urls.txt"
    parts=[]
    for p in [outdir/ "urls"/ "katana.txt", outdir/ "urls"/ "gau.txt"]:
        if p.exists(): parts += p.read_text(encoding="utf-8").splitlines()
    n=_write_dedup(parts, all_out)
    console.log(f"   pre-bruteforce URLs (katana+gau): {n}")
    return all_out
