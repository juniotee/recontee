from __future__ import annotations
from pathlib import Path
from rich.console import Console
import subprocess, os

console = Console()

def ensure_dir(p: Path) -> Path:
    """Ensure directory exists."""
    p.mkdir(parents=True, exist_ok=True)
    return p

def run(cmd: list[str]) -> list[str]:
    """Run a binary (argv list). Return stdout lines."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate()
    return out.splitlines()

def run_sh(cmd: str) -> list[str]:
    """Run a shell pipeline string. Return stdout lines."""
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, executable=os.environ.get("SHELL","/bin/bash"))
    out, err = proc.communicate()
    return out.splitlines()
