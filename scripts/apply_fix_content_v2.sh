#!/usr/bin/env bash
set -euo pipefail

echo "[1/3] Backup do arquivo atual…"
mkdir -p .backup_fix
cp -a src/recontee/steps/content.py .backup_fix/content.py.$(date +%F-%H%M%S) 2>/dev/null || true

echo "[2/3] Atualizando src/recontee/steps/content.py…"
cat > src/recontee/steps/content.py <<'PY'
from __future__ import annotations
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import shutil, subprocess, os, json, time
from typing import Iterable
from rich.console import Console
from ..utils import run, ensure_dir
import tldextract  # PSL para domínio registrável

console = Console()

def _bin(path: str, fallback: str | None = None) -> str | None:
    p = shutil.which(path)
    if p:
        return p
    if fallback:
        cand = str(Path.home() / "go" / "bin" / fallback)
        if Path(cand).exists():
            return cand
    return None

def _write_dedup(lines: Iterable[str], dest: Path) -> int:
    uniq = sorted(set(s.strip() for s in lines if s and s.strip()))
    ensure_dir(dest.parent)
    dest.write_text("\n".join(uniq), encoding="utf-8")
    return len(uniq)

def _katana_supports(katana_bin: str, flag: str) -> bool:
    """Checa se a versão do katana suporta um flag (via -h)."""
    try:
        res = subprocess.run([katana_bin, "-h"], capture_output=True, text=True, timeout=5)
        helptext = (res.stdout or "") + (res.stderr or "")
        return f" {flag}" in helptext or f"{flag} " in helptext or f"{flag}\n" in helptext
    except Exception:
        return False

def katana_from_list(hosts_file: Path, outdir: Path, threads: int = 80, depth: int = 2) -> Path:
    """Roda Katana em URLs vivos; detecta flags suportadas dinamicamente e registra logs."""
    katana = _bin("katana", "katana")
    urls_out = outdir / "urls" / "katana.txt"
    if not katana:
        console.print("[yellow]katana não encontrado. Pulando.[/yellow]")
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    raw_json = outdir / "urls" / "katana_raw.jsonl"
    logs_dir = outdir / "logs"
    ensure_dir(urls_out.parent)
    ensure_dir(logs_dir)

    console.log("4) katana…")

    cmd = [
        katana, "-silent", "-list", str(hosts_file),
        "-depth", str(depth), "-jc", "-no-color",
        "-timeout", "40",  # maior tolerância
        "-threads", str(threads)
    ]
    # fontes passivas costumam aumentar muito a cobertura
    if _katana_supports(katana, "-ps"):
        cmd += ["-ps"]
    # auto-form fill (se suportado)
    if _katana_supports(katana, "-aff"):
        cmd += ["-aff"]
    # redirecionamentos, retries e rate-limit (se suportados)
    if _katana_supports(katana, "-max-redirects"):
        cmd += ["-max-redirects", "5"]
    if _katana_supports(katana, "-retries"):
        cmd += ["-retries", "2"]
    if _katana_supports(katana, "-rate-limit"):
        cmd += ["-rate-limit", "1500"]
    if os.environ.get("HTTP_PROXY") and _katana_supports(katana, "-http-proxy"):
        cmd += ["-http-proxy", os.environ["HTTP_PROXY"]]

    # Log do comando
    (logs_dir / "katana_cmd.txt").write_text(" ".join(cmd), encoding="utf-8")

    # Executa e guarda stderr para debug
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    lines = []
    assert proc.stdout is not None
    for ln in proc.stdout:
        lines.append(ln.rstrip("\n"))
    _, stderr = proc.communicate(timeout=600)
    (logs_dir / "katana_stderr.txt").write_text(stderr or "", encoding="utf-8")

    raw_json.write_text("\n".join(lines), encoding="utf-8")

    urls = []
    for ln in lines:
        try:
            obj = json.loads(ln)
            req = obj.get("request") or {}
            u = req.get("url")
            if isinstance(u, str) and u.startswith(("http://", "https://")):
                urls.append(u)
        except Exception:
            pass

    n = _write_dedup(urls, urls_out)
    if n == 0:
        console.print("[yellow]Katana retornou 0 URLs.[/yellow]")
    else:
        console.log(f"   URLs katana: {n}")
    return urls_out

def _gau_one(domain: str, providers: str) -> list[str]:
    """Executa GAU para um único domínio/registrável."""
    gau = _bin("gau", "gau")
    if not gau:
        return []
    cmd = [gau, "-subs", "--providers", providers]
    try:
        proc = subprocess.run(cmd, input=domain.encode(), capture_output=True, timeout=240)
        if proc.returncode != 0:
            return []
        out = proc.stdout.decode(errors="ignore").splitlines()
        out = [l.strip() for l in out if domain in l]
        return out
    except Exception:
        return []

def _waybackurls_one(domain: str) -> list[str]:
    """Fallback para waybackurls (se instalado)."""
    wb = _bin("waybackurls", "waybackurls")
    if not wb:
        return []
    try:
        proc = subprocess.run([wb], input=(domain + "\n").encode(), capture_output=True, timeout=240)
        if proc.returncode != 0:
            return []
        out = proc.stdout.decode(errors="ignore").splitlines()
        out = [l.strip() for l in out if l.strip()]
        # filtra para o domínio alvo para evitar excesso
        out = [l for l in out if domain in l]
        return out
    except Exception:
        return []

def gau_from_subs(subs_file: Path, outdir: Path, max_workers: int = 10) -> Path:
    """
    Roda GAU usando:
      1) domínios registráveis (PSL),
      2) fallback por subdomínio,
      3) fallback waybackurls (se existir),
    salvando logs para troubleshooting.
    """
    gau = _bin("gau", "gau")
    urls_out = outdir / "urls" / "gau.txt"
    logs_dir = outdir / "logs"
    ensure_dir(urls_out.parent)
    ensure_dir(logs_dir)

    if not gau:
        console.print("[yellow]gau não encontrado. Pulando.[/yellow]")
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    console.log("5) gau…")
    subs = [l.strip() for l in subs_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not subs:
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    # 1) dominios registráveis (PSL)
    bases: set[str] = set()
    for s in subs:
        ext = tldextract.extract(s)
        if ext.registered_domain:
            bases.add(ext.registered_domain)

    providers = "wayback,commoncrawl,otx,urlscan,wrap"
    (logs_dir / "gau_cmd.txt").write_text(f"providers={providers}\nregistrable={len(bases)}", encoding="utf-8")

    results: list[str] = []
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = {ex.submit(_gau_one, b, providers): b for b in sorted(bases)}
        for f in as_completed(futs):
            try:
                results.extend(f.result() or [])
            except Exception:
                pass

    # 2) fallback por subdomínio se ainda vazio
    if not results:
        (logs_dir / "gau_note.txt").write_text("registrable empty; trying per-subdomain", encoding="utf-8")
        with ThreadPoolExecutor(max_workers=max_workers) as ex:
            futs = {ex.submit(_gau_one, s, providers): s for s in subs}
            for f in as_completed(futs):
                try:
                    results.extend(f.result() or [])
                except Exception:
                    pass

    # 3) fallback waybackurls (se ainda vazio)
    if not results:
        (logs_dir / "waybackurls_note.txt").write_text("gau empty; trying waybackurls", encoding="utf-8")
        with ThreadPoolExecutor(max_workers=max_workers) as ex:
            futs = {ex.submit(_waybackurls_one, b): b for b in sorted(bases)}
            for f in as_completed(futs):
                try:
                    results.extend(f.result() or [])
                except Exception:
                    pass

    n = _write_dedup(results, urls_out)
    if n == 0:
        console.print("[yellow]GAU retornou 0 URLs.[/yellow]")
    else:
        console.log(f"   URLs gau: {n}")
    return urls_out

def merge_urls(outdir: Path) -> Path:
    """Une katana + gau em urls/all_urls.txt (deduplicado)."""
    all_out = outdir / "urls" / "all_urls.txt"
    parts = []
    for p in [outdir / "urls" / "katana.txt", outdir / "urls" / "gau.txt"]:
        if p.exists():
            parts += p.read_text(encoding="utf-8").splitlines()
    n = _write_dedup(parts, all_out)
    console.log(f"   URLs pré-bruteforce (katana+gau): {n}")
    return all_out
PY

echo "[3/3] Feito. Agora rode novamente:"
echo "   poetry run recontee run <alvo> --config config.yaml --resolvers resolvers.txt --force --rl-per-host 10"
