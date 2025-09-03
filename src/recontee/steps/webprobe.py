from __future__ import annotations
from pathlib import Path
from rich.console import Console
from ..utils import run_sh, run
import shutil, subprocess, json
from pathlib import Path as _P

console = Console()

def _write_dedup(lines, dest: Path) -> int:
    uniq = sorted(set(s.strip() for s in lines if s and s.strip()))
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(uniq), encoding="utf-8")
    return len(uniq)

def _pd_httpx_bin() -> str | None:
    cands = [shutil.which("httpx"), str(_P.home()/ "go"/ "bin"/ "httpx"), "/usr/local/bin/httpx"]
    for c in cands:
        if not c: continue
        try:
            res = subprocess.run([c,"-version"], capture_output=True, text=True, timeout=3)
            low = (res.stdout or res.stderr).lower()
            if "projectdiscovery" in low or "httpx version" in low:
                return c
        except Exception:
            continue
    return None

_PORTS_FALLBACK = ",".join(map(str, [80,81,443,8080,8443,8008,8081,9000,9090,7001,7002,8888,9443,10443,3000,5000]))

def webprobe_with_httprobe(subs_file: Path, out: Path, threads: int, naabu_ports_file: Path | None = None) -> Path:
    """Detect live HTTP(S) endpoints using httpx/httprobe with fallbacks."""
    hosts = out / "web" / "hosts.txt"
    if hosts.exists() and hosts.stat().st_size>0:
        return hosts
    httpx_bin = _pd_httpx_bin()

    # httpx + naabu ports
    if naabu_ports_file and naabu_ports_file.exists() and naabu_ports_file.stat().st_size>0 and httpx_bin:
        console.log("3) httpx + naabu ports…")
        raw = out / "web" / "httpx_naabu_raw.jsonl"
        cmd = [httpx_bin, "-silent","-l",str(subs_file),"-ports-file",str(naabu_ports_file),"-json","-follow-redirects","-timeout","25","-retries","3","-threads",str(threads)]
        lines = run(cmd)
        raw.write_text("\n".join(lines), encoding="utf-8")
        urls = []
        for ln in lines:
            try:
                obj=json.loads(ln); u=obj.get("url")
                if u: urls.append(u)
            except Exception: pass
        if _write_dedup(urls, hosts)>0:
            return hosts

    console.log("3) httprobe (quick)…")
    lines = run_sh(f"cat {subs_file} | httprobe -c {threads} -prefer-https -timeout 12")
    if _write_dedup(lines, hosts)>0:
        return hosts

    console.log("3) httprobe (80,443,8080,8443)…")
    lines = run_sh(f"cat {subs_file} | httprobe -c {threads} -p http:80,http:8080,https:443,https:8443 -timeout 15")
    if _write_dedup(lines, hosts)>0:
        return hosts

    if not httpx_bin:
        console.print("[yellow]httpx (PD) not found on PATH.[/yellow]")
        return hosts
    console.log("3) httpx fallback (multiport)…")
    raw = out / "web" / "httpx_raw.jsonl"
    cmd = [httpx_bin, "-l",str(subs_file),"-silent","-json","-follow-redirects","-ports",_PORTS_FALLBACK,"-timeout","25","-retries","3","-threads",str(threads)]
    lines = run(cmd)
    raw.write_text("\n".join(lines), encoding="utf-8")
    urls = []
    for ln in lines:
        try:
            obj=json.loads(ln); u=obj.get("url")
            if u: urls.append(u)
        except Exception: pass
    _write_dedup(urls, hosts)
    return hosts
