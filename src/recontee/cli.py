import typer, yaml, shutil, subprocess, os
from pathlib import Path
from rich.console import Console
from rich import print
from .pipeline import Context
from .utils import ensure_dir
from .steps import subenum, webprobe, content, bruteforce, dnsresolve, ports

app = typer.Typer(help="Recontee – unified reconnaissance pipeline.")
console = Console()

def _version_of(bin_name: str) -> str:
    try:
        res = subprocess.run([bin_name, "-version"], capture_output=True, text=True, timeout=5)
        if res.returncode != 0:
            res = subprocess.run([bin_name, "--version"], capture_output=True, text=True, timeout=5)
        line = (res.stdout or res.stderr or "").splitlines()[0] if (res.stdout or res.stderr) else ""
        return line.strip()
    except Exception:
        return ""

def assert_prereqs():
    """Verify that required binaries exist in PATH."""
    bins = ["subfinder","amass","dnsx","naabu","httprobe","httpx","katana","gau","ffuf","jq","curl"]
    missing = [b for b in bins if shutil.which(b) is None]
    if missing:
        console.print(f"[red]Missing binaries:[/red] {', '.join(missing)}")
        console.print("Install them with scripts/install_tools.sh and ensure they are on PATH.")
        raise SystemExit(1)
    console.print("[green]✓ All binaries found.[/green]")

@app.command()
def healthcheck():
    """Check installation and connectivity."""
    assert_prereqs()
    console.print("[bold cyan]Versions[/bold cyan]")
    for b in ["subfinder","amass","dnsx","naabu","httprobe","httpx","katana","gau","ffuf"]:
        ver = _version_of(b)
        console.print(f"[green]✓[/green] {b}: [dim]{ver}[/dim]")
    console.print("[bold cyan]\nConnectivity[/bold cyan]")
    try:
        subprocess.run(["curl","-Is","https://github.com","-m","5"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        console.print("[green]✓[/green] curl -> github.com OK")
    except Exception:
        console.print("[red]✗[/red] curl failed")

@app.command()
def run(
    target: str = typer.Argument(..., help="Target domain"),
    config: Path = typer.Option("config.yaml", help="YAML config file"),
    resolvers: Path = typer.Option(None, help="Resolvers file"),
    resume: bool = typer.Option(False, help="Resume when possible"),
    force: bool = typer.Option(False, help="Force re-run of steps"),
    proxy: str = typer.Option(None, help="HTTP proxy, e.g., http://127.0.0.1:8080"),
    rl_per_host: int = typer.Option(None, help="ffuf rate limit per host")
):
    """Execute full pipeline."""
    assert_prereqs()
    cfg = yaml.safe_load(Path(config).read_text(encoding="utf-8"))
    outdir = ensure_dir(Path(cfg.get("outputs","out")) / target)
    ctx = Context(target, outdir, cfg.get("threads",80), Path(cfg.get("wordlist")))
    steps_cfg = cfg.get("steps", {})
    ffuf_cfg = cfg.get("ffuf", {})

    if proxy:
        os.environ["HTTP_PROXY"] = proxy
        os.environ["HTTPS_PROXY"] = proxy
        console.print(f"[yellow]Proxy set: {proxy}[/yellow]")

    print(f"[bold cyan]Target:[/bold cyan] {target}")
    print(f"[bold cyan]Wordlist:[/bold cyan] {ctx.wordlist}")

    # 1) Subdomain enumeration
    if steps_cfg.get("subfinder", True):
        subenum.subfinder(target, outdir)
    if steps_cfg.get("amass", True):
        subenum.amass_passive(target, outdir)
    subs = subenum.merge(outdir)
    subs_count = sum(1 for _ in subs.read_text(encoding="utf-8").splitlines() if _)
    print(f"[green]Unique subdomains:[/green] {subs_count}")
    if subs_count == 0:
        subenum.crtsh_fallback(target, outdir)
        subs = subenum.merge(outdir)
        subs_count = sum(1 for _ in subs.read_text(encoding="utf-8").splitlines() if _)
        print(f"[green]Unique subdomains after fallback:[/green] {subs_count}")
        if subs_count == 0:
            print("[yellow]No subdomains found. Exiting.[/yellow]")
            return

    # 2) dnsx
    subs_resolved = dnsresolve.dnsx_filter(subs, outdir, threads=ctx.threads, resolvers=resolvers, force=force)
    subr_count = sum(1 for _ in subs_resolved.read_text(encoding="utf-8").splitlines() if _)
    print(f"[green]Subdomains that resolve (DNS):[/green] {subr_count}")
    if subr_count == 0:
        print("[yellow]No resolvable subdomains. Exiting.[/yellow]")
        return

    # 3) naabu + httpx/httprobe
    naabu_ports = ports.naabu_scan(subs_resolved, outdir, threads=10000, top_ports=1000, rate=12000, retries=1, timeout=1200) if steps_cfg.get("naabu", True) else None
    hosts = webprobe.webprobe_with_httprobe(subs_resolved, outdir, ctx.threads, naabu_ports_file=naabu_ports)
    hosts_count = sum(1 for _ in hosts.read_text(encoding="utf-8").splitlines() if _)
    print(f"[green]HTTP(s) live hosts:[/green] {hosts_count}")
    if hosts_count == 0:
        print("[yellow]No HTTP(s) hosts. Skipping katana/gau/ffuf to avoid noise.[/yellow]")
        steps_cfg["katana"] = False
        steps_cfg["gau"] = False
        steps_cfg["ffuf"] = False

    # 4) katana
    if steps_cfg.get("katana", True):
        content.katana_from_list(hosts, outdir, ctx.threads, depth=2)

    # 5) gau
    if steps_cfg.get("gau", True):
        content.gau_from_subs(subs, outdir)

    # 6) merge katana+gau
    all_urls = content.merge_urls(outdir)

    # 7) ffuf
    if steps_cfg.get("ffuf", True):
        bruteforce.ffuf_multi(
            hosts, ctx.wordlist, outdir,
            threads=ffuf_cfg.get("threads", 20),
            rate_limit=rl_per_host,
            extensions=ffuf_cfg.get("extensions", ""),
            allowed=ffuf_cfg.get("allowed_status", "200,204,301,302,307,308"),
            max_workers=ffuf_cfg.get("max_workers", 6),
            maxtime=ffuf_cfg.get("maxtime", 300),
            maxtime_job=ffuf_cfg.get("maxtime_job", 60),
        )
        ff = outdir / "ffuf" / "ffuf_found.txt"
    else:
        ff = outdir / "ffuf" / "ffuf_found.txt"

    # Final report
    final = outdir / "report" / "urls_final.txt"
    final.parent.mkdir(parents=True, exist_ok=True)
    union: set[str] = set()
    for p in [all_urls, ff]:
        if p.exists():
            for line in p.read_text(encoding="utf-8").splitlines():
                s = line.strip()
                if s: union.add(s)
    final.write_text("\n".join(sorted(union)), encoding="utf-8")
    print(f"[bold green]Done! Final report:[/bold green] {final}")
    print(f"[green]Total collected URLs:[/green] {len(union)}")

if __name__ == "__main__":
    app()
