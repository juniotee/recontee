# recontee

End-to-end web reconnaissance pipeline that wraps best-in-class OSS tools into a single, repeatable workflow:

```
subfinder + amass  →  merge & dedupe  →  dnsx
→  naabu (port scan)  →  httpx/httprobe (live hosts)
→  katana (crawl)  +  gau (archives)  →  ffuf (content discovery)
```

- **OS:** Any modern Linux (Debian/Ubuntu/Fedora/Arch/openSUSE/Alpine).
- **Package managers:** Poetry (preferred) *or* plain `pip` fallback.

> Use only on targets you are authorized to test.

## Installation

### 1) System + tools (Go & recon suite)

```bash
./scripts/install_tools.sh
# reload env for current shell
source ~/.bashrc 2>/dev/null || source /etc/profile || exec $SHELL -l
```

### 2A) Python deps with Poetry (recommended)

```bash
poetry install -vv
```

### 2B) Python deps with plain pip (fallback)

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip wheel setuptools
pip install typer==0.12.3 rich==13.7.1 pyyaml==6.0.2
pip install -e .
```

## Usage

```bash
# Healthcheck
poetry run recontee healthcheck
# or without poetry:
python -m recontee.cli healthcheck

# Run
poetry run recontee run example.com --config config.yaml --resolvers resolvers.txt --force --rl-per-host 10
# or:
python -m recontee.cli run example.com --config config.yaml --resolvers resolvers.txt --force --rl-per-host 10
```

## Troubleshooting

- **Poetry stuck at “checking keyring availability”**: installer already disables keyring. If needed, export:
  ```bash
  export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring
  export POETRY_NO_INTERACTION=1
  export POETRY_VIRTUALENVS_IN_PROJECT=true
  ```
- **Go tools not found on PATH**: reload environment `source ~/.bashrc` or `exec $SHELL -l`.
