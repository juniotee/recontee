from __future__ import annotations
from pathlib import Path
from rich.console import Console
import concurrent.futures, json, time, threading, signal
from typing import Optional
from ..utils import run, ensure_dir

console = Console()
DEFAULT_ALLOWED = "200,204,301,302,307,308"
_stop = threading.Event()
def _handle_sigint(signum, frame):
    _stop.set()
signal.signal(signal.SIGINT, _handle_sigint)

def _parse_ffuf_json(json_path: Path, allowed_codes: set[str]) -> list[str]:
    """Parse ffuf JSON (-of json) and keep URLs with allowed status."""
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    urls: list[str] = []
    for item in data.get("results", []):
        try:
            code = str(item.get("status")); url = item.get("url")
            if url and code in allowed_codes: urls.append(url)
        except Exception: continue
    return urls

def ffuf_multi(
    hosts_file: Path, wordlist: Path, outdir: Path, threads: int = 20,
    rate_limit: Optional[int] = None, extensions: Optional[str] = None,
    allowed: str = DEFAULT_ALLOWED, max_workers: int = 6,
    maxtime: int = 300, maxtime_job: int = 60,
) -> Path:
    """Run ffuf across hosts with strict filters and time limits."""
    console.print(f"[yellow]6) ffuf (multi-host)…[/yellow]")
    ensure_dir(outdir / "ffuf")
    hosts = [l.strip() for l in hosts_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not hosts:
        console.print("[yellow]No hosts for ffuf.[/yellow]")
        return outdir / "ffuf" / "ffuf_found.txt"
    allowed_set = set(x.strip() for x in allowed.split(",") if x.strip())
    console.print(f"[cyan]   status filter (ffuf -mc):[/cyan] {','.join(sorted(allowed_set))}")
    console.print(f"[cyan]   limits:[/cyan] maxtime={maxtime}s  maxtime-job={maxtime_job}s  max-workers={max_workers}")
    start = time.time()

    def run_ffuf(host: str) -> Path | None:
        if _stop.is_set(): return None
        out_json = outdir / "ffuf" / (host.replace("https://","").replace("http://","").replace("/","_").replace(":","_") + ".json")
        cmd = ["ffuf","-u",f"{host}/FUZZ","-w",str(wordlist),"-mc",",".join(sorted(allowed_set)),"-ac","-t",str(threads),"-timeout","20","-of","json","-o",str(out_json),"-noninteractive","-maxtime-job",str(maxtime_job)]
        if extensions: cmd += ["-e", extensions]
        if rate_limit: cmd += ["-rate", str(rate_limit)]
        if maxtime and (time.time()-start)>=maxtime: return None
        try:
            console.print(f"[dim]   ffuf → {host}[/dim]")
            list(run(cmd))
            if out_json.exists() and out_json.stat().st_size>0: return out_json
        except Exception: return None
        return None

    json_files: list[Path] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = {ex.submit(run_ffuf, h): h for h in hosts}
        for f in concurrent.futures.as_completed(futs):
            if _stop.is_set(): break
            jf = f.result()
            if jf: json_files.append(jf)
            if maxtime and (time.time()-start)>=maxtime:
                console.print("[yellow]   Global maxtime reached; stopping ffuf.[/yellow]"); break

    found_out = outdir / "ffuf" / "ffuf_found.txt"
    all_urls: set[str] = set()
    for jf in json_files:
        for u in _parse_ffuf_json(jf, allowed_set): all_urls.add(u)
    found_out.write_text("\n".join(sorted(all_urls)), encoding="utf-8")
    console.print(f"[green]   FFUF valid results:[/green] {len(all_urls)}")
    return found_out
