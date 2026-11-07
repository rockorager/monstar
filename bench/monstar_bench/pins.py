"""Pinned workload inputs. Bump a pin by changing it here and rerunning
`monstar-bench bootstrap`; results record the pins they were measured with."""

NVIM_VERSION = "v0.12.6"
NVIM_TARBALLS = {
    "x86_64": ("https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-x86_64.tar.gz",
               "474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87"),
    "aarch64": ("https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-arm64.tar.gz",
                "8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815"),
}

# Stock LazyVim starter. Plugin commits come from bench/pins/lazy-lock.json.
LAZYVIM_STARTER_REPO = "https://github.com/LazyVim/starter"
LAZYVIM_STARTER_COMMIT = "803bc181d7c0d6d5eeba9274d9be49b287294d99"

# Large C file for the editor workloads (13,016 lines).
NVIM_FILE = ("https://raw.githubusercontent.com/torvalds/linux/v6.6/kernel/sched/fair.c",
             "7d259d533ffb439992969e5d1d20b27dc64c9203f5c09e09f839047cbd4e40bb", "fair.c")

TTE_VERSION = "0.15.0"
TTE_WHEEL = ("https://files.pythonhosted.org/packages/ba/e8/89035cd56a3ef4fe1c2dbf790e1a2c78d4e922d3dbfc048e314e40c22b1a/"
             "terminaltexteffects-0.15.0-py3-none-any.whl",
             "5503250dacae9a3c17e22b0010b2f5fa10332124019f485d517e0c9ebc51aa47")
# The last Omarchy commit whose screensaver ran tte (later ones use ttfx).
OMARCHY_COMMIT = "7644b56d4e63730ce6c3ba77a96c92d7bb8f06ac"
OMARCHY_LOGO = (f"https://raw.githubusercontent.com/basecamp/omarchy/{OMARCHY_COMMIT}/logo.txt",
                "f98c966b1670d71ffc26620a6ff885a73ab355b370bff6082cea3215ee580a29")
# Omarchy picks --random-effect; one fixed effect keeps runs comparable.
TTE_EFFECT = "matrix"

FONT_ZIP = ("https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip",
            "6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf")
FONT_FILES = ("fonts/ttf/JetBrainsMono-Regular.ttf", "fonts/ttf/JetBrainsMono-Bold.ttf",
              "fonts/ttf/JetBrainsMono-Italic.ttf", "fonts/ttf/JetBrainsMono-BoldItalic.ttf")
# Fallback for the half-width katakana of tte's matrix effect, which
# JetBrains Mono lacks (Monstar embeds Nerd Font symbols itself).
FALLBACK_FONT_ZIP = ("https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/11_NotoSansMonoCJKjp.zip",
                     "6c8faf475ce78fa37486dd5d8920e4bb4450b1b0f3c497edf3ba2d25cf52ab78")
FALLBACK_FONT_FILES = ("NotoSansMonoCJKjp-Regular.otf",)
FONT_FAMILY = "JetBrains Mono"
FONT_SIZE = "12"

# Corpus for log tailing and the cat flood, generated locally (gen-text.py).
CORPUS_SEED = 1
CORPUS_LINES = 20000
CORPUS_COLUMNS = 180
# The flood cats the corpus this many times (about 1.8 GB, ~10 s at the
# ~180 MB/s a Ryzen 7640HS laptop reaches; 440 MB lasted only 2.4 s).
FLOOD_COPIES = 256

BTOP_UPDATE_MS = 100


def manifest():
    """Everything a result depends on, recorded in the cache and the JSON."""
    return {
        "nvim": NVIM_VERSION,
        "lazyvim_starter": LAZYVIM_STARTER_COMMIT,
        "nvim_file": NVIM_FILE[1],
        "tte": TTE_VERSION,
        "tte_effect": TTE_EFFECT,
        "omarchy": OMARCHY_COMMIT,
        "font": FONT_ZIP[1],
        "fallback_font": FALLBACK_FONT_ZIP[1],
        "corpus": [CORPUS_SEED, CORPUS_LINES, CORPUS_COLUMNS, FLOOD_COPIES],
        "btop_update_ms": BTOP_UPDATE_MS,
    }
