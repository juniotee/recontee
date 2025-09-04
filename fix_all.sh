cat > fix_all_and_push.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Usage example:
# ./fix_all_and_push.sh --target iana.org --config config.yaml --resolvers resolvers.txt --remote git@github.com:juniotee/recontee.git

TARGET=""
CONFIG="config.yaml"
RESOLVERS=""
REMOTE=""
RUN_AFTER_FIX=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; RUN_AFTER_FIX=true; shift 2;;
    --config) CONFIG="$2"; shift 2;;
    --resolvers) RESOLVERS="$2"; shift 2;;
    --remote) REMOTE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

root_check() {
  [[ -f "pyproject.toml" && -d "src/recontee/steps" ]] || {
    echo "[!] Run this script from the project root (where pyproject.toml is)."
    exit 1
  }
}

ensure_dir() {
  mkdir -p "$1"
}

root_check
echo "[1/8] Backups…"
ensure_dir .backup_fix
cp -a src/recontee/steps/content.py ".backup_fix/content.py.$(date +%F-%H%M%S)" 2>/dev/null || true

echo "[2/8] Updating src/recontee/steps/content.py (katana flag detection + GAU --subs + logs)…"
cat > src/recontee/steps/content.py <<'PY'
from __future__ import annotations
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import shutil, subprocess, os, json
from typing import Iterable
from rich.console import Console
from ..utils import run, ensure_dir
import tldextract  # PSL for registrable domain

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
    """Check if installed katana supports a flag (-h)."""
    try:
        res = subprocess.run([katana_bin, "-h"], capture_output=True, text=True, timeout=5)
        helptext = (res.stdout or "") + (res.stderr or "")
        return f" {flag}" in helptext or f"{flag} " in helptext or f"{flag}\n" in helptext
    except Exception:
        return False

def katana_from_list(hosts_file: Path, outdir: Path, threads: int = 80, depth: int = 2) -> Path:
    """Run katana; only add flags that the installed version supports; save logs."""
    katana = _bin("katana", "katana")
    urls_out = outdir / "urls" / "katana.txt"
    if not katana:
        console.print("[yellow]katana not found. Skipping.[/yellow]")
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    raw_json = outdir / "urls" / "katana_raw.jsonl"
    logs_dir = outdir / "logs"
    ensure_dir(urls_out.parent); ensure_dir(logs_dir)

    console.log("4) katana…")

    # base command
    cmd = [katana, "-silent", "-list", str(hosts_file),
           "-depth", str(depth), "-jc", "-no-color", "-timeout", "40", "-threads", str(threads)]

    # conditionally append optional flags
    if _katana_supports(katana, "-ps"):
        cmd += ["-ps"]
    if _katana_supports(katana, "-aff"):
        cmd += ["-aff"]
    if _katana_supports(katana, "-max-redirects"):
        cmd += ["-max-redirects", "5"]
    if _katana_supports(katana, "-retries"):
        cmd += ["-retries", "2"]
    if _katana_supports(katana, "-rate-limit"):
        cmd += ["-rate-limit", "1500"]
    if os.environ.get("HTTP_PROXY") and _katana_supports(katana, "-http-proxy"):
        cmd += ["-http-proxy", os.environ["HTTP_PROXY"]]

    # log the command
    (logs_dir / "katana_cmd.txt").write_text(" ".join(cmd), encoding="utf-8")

    # run and capture both streams
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
        console.print("[yellow]Katana returned 0 URLs.[/yellow]")
    else:
        console.log(f"   katana URLs: {n}")
    return urls_out

def _gau_one(domain: str, providers: str) -> list[str]:
    gau = _bin("gau", "gau")
    if not gau:
        return []
    # NOTE: gau uses --subs (no short -s anymore)
    cmd = [gau, "--subs", "--providers", providers]
    try:
        proc = subprocess.run(cmd, input=domain.encode(), capture_output=True, timeout=240)
        if proc.returncode != 0:
            return []
        out = proc.stdout.decode(errors="ignore").splitlines()
        # Keep only URLs that include our domain
        out = [l.strip() for l in out if domain in l]
        return out
    except Exception:
        return []

def _waybackurls_one(domain: str) -> list[str]:
    wb = _bin("waybackurls", "waybackurls")
    if not wb:
        return []
    try:
        proc = subprocess.run([wb], input=(domain + "\n").encode(), capture_output=True, timeout=240)
        if proc.returncode != 0:
            return []
        out = [l.strip() for l in proc.stdout.decode(errors="ignore").splitlines() if l.strip()]
        out = [l for l in out if domain in l]
        return out
    except Exception:
        return []

def gau_from_subs(subs_file: Path, outdir: Path, max_workers: int = 10) -> Path:
    """GAU: registrable domains (PSL) + fallback per-subdomain + fallback waybackurls; logs for troubleshooting."""
    gau = _bin("gau", "gau")
    urls_out = outdir / "urls" / "gau.txt"
    logs_dir = outdir / "logs"
    ensure_dir(urls_out.parent); ensure_dir(logs_dir)

    if not gau:
        console.print("[yellow]gau not found. Skipping.[/yellow]")
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    console.log("5) gau…")
    subs = [l.strip() for l in subs_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not subs:
        urls_out.write_text("", encoding="utf-8")
        return urls_out

    # PSL → registrable domains
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

    # fallback per subdomain
    if not results:
        (logs_dir / "gau_note.txt").write_text("registrable empty; trying per-subdomain", encoding="utf-8")
        with ThreadPoolExecutor(max_workers=max_workers) as ex:
            futs = {ex.submit(_gau_one, s, providers): s for s in subs}
            for f in as_completed(futs):
                try:
                    results.extend(f.result() or [])
                except Exception:
                    pass

    # fallback waybackurls
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
        console.print("[yellow]GAU returned 0 URLs.[/yellow]")
    else:
        console.log(f"   gau URLs: {n}")
    return urls_out

def merge_urls(outdir: Path) -> Path:
    """Merge katana + gau into urls/all_urls.txt (dedup)."""
    all_out = outdir / "urls" / "all_urls.txt"
    parts = []
    for p in [outdir / "urls" / "katana.txt", outdir / "urls" / "gau.txt"]:
        if p.exists():
            parts += p.read_text(encoding="utf-8").splitlines()
    n = _write_dedup(parts, all_out)
    console.log(f"   URLs pre-bruteforce (katana+gau): {n}")
    return all_out
PY

echo "[3/8] Ensuring tldextract is a dependency…"
# Append to pyproject if missing
if ! grep -q '^tldextract' pyproject.toml; then
  # Insert after pyyaml/rich/typer block (best effort)
  sed -i 's/^\(pyyaml =.*\)$/\1\ntldextract = "^5.1.2"/' pyproject.toml || true
fi

echo "[4/8] Poetry install + add tldextract…"
if command -v poetry >/dev/null 2>&1; then
  poetry add -n tldextract || true
  poetry install -n
else
  echo "[!] Poetry not found; please install Poetry or pip install -r requirements."
  exit 1
fi

echo "[5/8] Healthcheck…"
poetry run recontee healthcheck || true

if $RUN_AFTER_FIX; then
  echo "[6/8] Running pipeline on target: ${TARGET}"
  RUN_CMD=(poetry run recontee run "${TARGET}" --config "${CONFIG}" --force)
  if [[ -n "${RESOLVERS}" ]]; then RUN_CMD+=(--resolvers "${RESOLVERS}"); fi
  RUN_CMD+=(--rl-per-host 10)
  echo "CMD: ${RUN_CMD[*]}"
  "${RUN_CMD[@]}" || true
fi

# Git ops (optional)
echo "[7/8] Git commit…"
git add -A
git commit -m "fix: katana flag detection; GAU uses --subs; add tldextract; logs for troubleshooting" || true

if [[ -n "${REMOTE}" ]]; then
  echo "[8/8] Setting remote and pushing…"
  if ! git remote | grep -q '^origin$'; then
    git remote add origin "${REMOTE}"
  fi
  git fetch origin || true
  git branch --set-upstream-to=origin/main main 2>/dev/null || true
  git pull --rebase origin main || true
  git push -u origin main
else
  echo "[8/8] Skipping push (no --remote provided)."
fi

echo "Done."
EOS

chmod +x fix_all_and_push.sh
