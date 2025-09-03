from __future__ import annotations
from pathlib import Path
from rich.console import Console
from ..utils import run
import json

console = Console()

def naabu_scan(subs_resolved: Path, out: Path, threads: int = 10000, top_ports: int = 1000, rate: int = 12000, retries: int = 1, timeout: int = 1200) -> Path:
    """Run naabu and save host:port pairs to web/naabu_ports.txt (via -json)."""
    out_file = out / "web" / "naabu_ports.txt"
    console.log("3) naabu (port scan)…")
    cmd = ["naabu","-list",str(subs_resolved),"-silent","-top-ports",str(top_ports),"-rate",str(rate),"-retries",str(retries),"-timeout",str(timeout),"-json"]
    lines = run(cmd)
    pairs = []
    for ln in lines:
        ln = ln.strip()
        if not ln: 
            continue
        try:
            obj = json.loads(ln)
            host = (obj.get("host") or obj.get("ip") or "").strip()
            port = obj.get("port")
            if host and port:
                pairs.append(f"{host}:{port}")
        except Exception:
            pass
    uniq = sorted(set(pairs))
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("\n".join(uniq), encoding="utf-8")
    console.log(f"   naabu found {len(uniq)} host:port pairs")
    return out_file
