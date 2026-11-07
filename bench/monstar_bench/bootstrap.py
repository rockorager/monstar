"""Fetch and prepare pinned workload inputs in the cache directory.

Everything here may use the network. Measurement never does: `run` only
reads what `bootstrap` left in the cache and refuses a stale cache."""

import hashlib
import io
import json
import os
import platform
import random
import shutil
import subprocess
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

from . import pins

BENCH_DIR = Path(__file__).resolve().parent.parent


def default_cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "monstar-bench"


class Cache:
    """Paths inside a bootstrapped cache."""

    def __init__(self, root):
        self.root = Path(root)

    nvim_bin = property(lambda self: self.root / "nvim" / "bin" / "nvim")
    lazyvim = property(lambda self: self.root / "lazyvim")
    nvim_file = property(lambda self: self.root / "files" / pins.NVIM_FILE[2])
    tte = property(lambda self: self.root / "tte")
    logo = property(lambda self: self.root / "omarchy" / "logo.txt")
    fonts = property(lambda self: self.root / "fonts")
    fontconfig = property(lambda self: self.root / "fonts.conf")
    corpus = property(lambda self: self.root / "corpus" / "text.txt")
    monstar_config = property(lambda self: self.root / "monstar.conf")
    manifest = property(lambda self: self.root / "manifest.json")

    def lazyvim_env(self, state_dir):
        """XDG dirs for LazyVim; state is per run so sessions never leak."""
        return {
            "XDG_CONFIG_HOME": str(self.lazyvim / "config"),
            "XDG_DATA_HOME": str(self.lazyvim / "data"),
            "XDG_CACHE_HOME": str(self.lazyvim / "cache"),
            "XDG_STATE_HOME": str(state_dir),
        }

    def check(self):
        """Return a problem string, or None when the cache matches the pins."""
        try:
            manifest = json.loads(self.manifest.read_text())
        except (OSError, ValueError):
            return f"no bootstrapped cache in {self.root}; run `monstar-bench bootstrap`"
        if manifest.get("pins") != pins.manifest():
            return f"cache in {self.root} was built for other pins; rerun `monstar-bench bootstrap`"
        return None

    def recorded(self):
        try:
            return json.loads(self.manifest.read_text())
        except (OSError, ValueError):
            return {}


def log(msg):
    print(f"[bootstrap] {msg}", flush=True)


def fetch(url, sha256):
    log(f"fetching {url}")
    with urllib.request.urlopen(url, timeout=120) as resp:
        data = resp.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        raise SystemExit(f"checksum mismatch for {url}: got {digest}, want {sha256}")
    return data


def machine_arch():
    arch = platform.machine()
    return {"amd64": "x86_64", "arm64": "aarch64"}.get(arch, arch)


def install_nvim(cache):
    arch = machine_arch()
    if arch not in pins.NVIM_TARBALLS:
        raise SystemExit(f"no pinned Neovim build for {arch}")
    url, sha = pins.NVIM_TARBALLS[arch]
    data = fetch(url, sha)
    dest = cache.root / "nvim"
    shutil.rmtree(dest, ignore_errors=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        top = tar.getnames()[0].split("/")[0]
        try:
            tar.extractall(cache.root, filter="tar")
        except TypeError:  # Python without extraction filters
            tar.extractall(cache.root)
    (cache.root / top).rename(dest)


def install_lazyvim(cache):
    if not shutil.which("git"):
        raise SystemExit("git is required to bootstrap LazyVim")
    root = cache.lazyvim
    shutil.rmtree(root, ignore_errors=True)
    config = root / "config" / "nvim"
    subprocess.run(["git", "clone", "--quiet", pins.LAZYVIM_STARTER_REPO, str(config)], check=True)
    subprocess.run(["git", "-C", str(config), "checkout", "--quiet", pins.LAZYVIM_STARTER_COMMIT], check=True)
    shutil.copy(BENCH_DIR / "pins" / "lazy-lock.json", config / "lazy-lock.json")
    # The only change to the stock starter: its update checker polls GitHub,
    # which would put network traffic inside measurements.
    lazy_lua = config / "lua" / "config" / "lazy.lua"
    text = lazy_lua.read_text()
    patched = text.replace("enabled = true, -- check for plugin updates periodically",
                           "enabled = false, -- monstar-bench: no network during measurement")
    if patched == text:
        raise SystemExit("LazyVim starter changed shape; cannot disable its update checker")
    lazy_lua.write_text(patched)
    env = dict(os.environ, **cache.lazyvim_env(root / "state"))
    env["PATH"] = f"{cache.nvim_bin.parent}:{env.get('PATH', '')}"
    log("restoring LazyVim plugins from lazy-lock.json")
    subprocess.run([str(cache.nvim_bin), "--headless", "+Lazy! restore", "+qa"], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    # Opening the file once lets Mason and nvim-treesitter install what
    # stock LazyVim installs on first start (parsers need a C compiler), and
    # loading blink.cmp fetches its prebuilt matcher, which it otherwise
    # downloads on the first insert during a measurement.
    needed = [root / "data" / "nvim" / "site" / "parser" / "c.so",
              root / "data" / "nvim" / "lazy" / "blink.cmp" / "target" / "release" / "libblink_cmp_fuzzy.so"]
    for _attempt in range(3):
        log("warming LazyVim (installs tree-sitter parsers, Mason tools and blink.cmp's matcher)")
        subprocess.run([str(cache.nvim_bin), "--headless", str(cache.nvim_file), "+Lazy! load blink.cmp",
                        "+lua vim.defer_fn(function() vim.cmd('qa!') end, 60000)"],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
        if all(p.exists() for p in needed):
            break
    missing = [str(p) for p in needed if not p.exists()]
    if missing:
        raise SystemExit(f"LazyVim warm-up did not produce {', '.join(missing)} (needs a C compiler and network)")
    shutil.rmtree(root / "state", ignore_errors=True)


def install_tte(cache):
    url, sha = pins.TTE_WHEEL
    data = fetch(url, sha)
    shutil.rmtree(cache.tte, ignore_errors=True)
    with zipfile.ZipFile(io.BytesIO(data)) as wheel:
        wheel.extractall(cache.tte)


def install_file(url, sha, dest):
    data = fetch(url, sha)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)


def install_font(cache):
    shutil.rmtree(cache.fonts, ignore_errors=True)
    cache.fonts.mkdir(parents=True)
    for (url, sha), files in ((pins.FONT_ZIP, pins.FONT_FILES), (pins.FALLBACK_FONT_ZIP, pins.FALLBACK_FONT_FILES)):
        with zipfile.ZipFile(io.BytesIO(fetch(url, sha))) as archive:
            for name in files:
                (cache.fonts / Path(name).name).write_bytes(archive.read(name))
    # Only the pinned fonts: no system configuration or fonts, so fallback
    # glyphs come from the same files on every machine.
    cache.fontconfig.write_text(f"""<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>{cache.fonts}</dir>
  <cachedir>{cache.root / "fontconfig-cache"}</cachedir>
</fontconfig>
""")


def write_monstar_config(cache):
    cache.monstar_config.write_text(
        f"font-family = {pins.FONT_FAMILY}\n"
        f"font-size = {pins.FONT_SIZE}\n"
        "linux-cgroup = never\n"
        "notify-on-command-finish = never\n"
    )


WORDS = ("the quick brown fox jumps over lazy dog render frame buffer vulkan wayland "
         "compositor scanout dmabuf latency").split()


def corpus_lines(seed=pins.CORPUS_SEED, lines=pins.CORPUS_LINES, columns=pins.CORPUS_COLUMNS):
    """research/gpu-renderer/gen-text.py's text.txt: colored words per line."""
    rng = random.Random(seed)
    for i in range(lines):
        parts, n = [], 0
        while n < columns:
            word = rng.choice(WORDS)
            color = rng.choice([31, 32, 33, 34, 35, 36, 37, 90, 0])
            parts.append(f"\x1b[{color}m{word}")
            n += len(word) + 1
        yield f"\x1b[2m{i:6d}\x1b[0m " + " ".join(parts) + "\x1b[0m\n"


def write_corpus(cache):
    cache.corpus.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(corpus_lines())
    cache.corpus.write_text(text)


def check_tools():
    """Tools taken from the system rather than pinned."""
    found = {}
    for tool in ("btop", "bash", "python3"):
        path = shutil.which(tool)
        found[tool] = path
    if not found["btop"]:
        log("btop is not installed; the btop workload will be skipped (install btop to include it)")
    return found


def bootstrap(cache_root, skip_lazyvim=False):
    cache = Cache(cache_root)
    cache.root.mkdir(parents=True, exist_ok=True)
    started = time.time()
    install_file(pins.NVIM_FILE[0], pins.NVIM_FILE[1], cache.nvim_file)
    install_file(pins.OMARCHY_LOGO[0], pins.OMARCHY_LOGO[1], cache.logo)
    install_tte(cache)
    install_font(cache)
    write_monstar_config(cache)
    write_corpus(cache)
    install_nvim(cache)
    if not skip_lazyvim:
        install_lazyvim(cache)
    tools = check_tools()
    cache.manifest.write_text(json.dumps({
        "pins": pins.manifest(),
        "lazyvim": not skip_lazyvim,
        "tools": tools,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }, indent=2))
    log(f"cache ready in {cache.root} ({time.time() - started:.0f} s)")
    return cache
