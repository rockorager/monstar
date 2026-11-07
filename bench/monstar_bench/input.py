"""Scripted keyboard input: deterministic key schedules and their playback."""

import random
import time

KEY_ESC, KEY_BACKSPACE, KEY_TAB, KEY_ENTER, KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_SPACE = 1, 14, 15, 28, 29, 42, 57

_ROWS = {
    "1234567890-=": 2,
    "qwertyuiop[]": 16,
    "asdfghjkl;'`": 30,
    "\\zxcvbnm,./": 43,
}
_SHIFTED = dict(zip("!@#$%^&*()_+{}:\"~|<>?", "1234567890-=[];'`\\,./"))


def _base_codes():
    codes = {" ": KEY_SPACE, "\n": KEY_ENTER, "\t": KEY_TAB}
    for row, first in _ROWS.items():
        for i, ch in enumerate(row):
            codes[ch] = first + i
    return codes


BASE = _base_codes()


def char_key(ch):
    """(evdev code, shift) for an ASCII character on a US layout."""
    if ch in BASE:
        return BASE[ch], False
    if ch.isupper() and ch.lower() in BASE:
        return BASE[ch.lower()], True
    if ch in _SHIFTED:
        return BASE[_SHIFTED[ch]], True
    raise ValueError(f"no US key for {ch!r}")


class Tap:
    """One key tap. `label` names it in results; `measure` marks keys whose
    echo latency counts."""

    __slots__ = ("code", "shift", "ctrl", "label", "measure")

    def __init__(self, code, shift=False, ctrl=False, label="", measure=True):
        self.code, self.shift, self.ctrl, self.label, self.measure = code, shift, ctrl, label, measure

    @classmethod
    def char(cls, ch, measure=True):
        code, shift = char_key(ch)
        return cls(code, shift=shift, label=ch, measure=measure)


def typing_schedule(text, rate_hz, seconds, seed, typo_every=7, prefix=(), reset=()):
    """Taps at ~rate_hz with +-30% jitter, typing `text` with a wrong key and
    a backspace every `typo_every` characters. When the text is done, the
    `reset` taps run (unmeasured) and typing starts over. Returns
    [(offset_s, Tap)]."""
    rng = random.Random(seed)
    out, t = [], 0.0
    for tap in prefix:
        out.append((t, tap))
        t += 1.0 / rate_hz
    while t < seconds:
        for i, ch in enumerate(text):
            if t >= seconds:
                break
            if typo_every and i % typo_every == typo_every - 1 and ch.isalpha():
                out.append((t, Tap.char(rng.choice("asdfjkl"))))
                t += rng.uniform(0.7, 1.3) / rate_hz
                out.append((t, Tap(KEY_BACKSPACE, label="BackSpace")))
                t += rng.uniform(0.7, 1.3) / rate_hz
            out.append((t, Tap.char(ch)))
            t += rng.uniform(0.7, 1.3) / rate_hz
        for tap in reset:
            out.append((t, tap))
            t += 2.0 / rate_hz
    return [(offset, tap) for offset, tap in out if offset < seconds]


def repeat_schedule(phases, rate_hz):
    """Key-repeat style input: [(seconds, Tap)] phases, one tap per period."""
    out, t = [], 0.0
    for seconds, tap in phases:
        end = t + seconds
        while t < end - 1e-9:
            out.append((t, tap))
            t += 1.0 / rate_hz
    return out


HOLD_S = 0.02


def play(keyboard, schedule, start_ns=None):
    """Play a schedule on `keyboard`; returns [(send_ns, label, measure)] for
    each tap's key press. Sleeps between taps; never busy-waits."""
    start = start_ns or time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    sent = []
    for offset, tap in schedule:
        target = start + int(offset * 1e9)
        delay = (target - time.clock_gettime_ns(time.CLOCK_MONOTONIC)) / 1e9
        if delay > 0:
            time.sleep(delay)
        mods = (1 if tap.shift else 0) | (4 if tap.ctrl else 0)
        if tap.ctrl:
            keyboard.key(KEY_LEFTCTRL, True, mods=4 | (mods & 1))
        if tap.shift:
            keyboard.key(KEY_LEFTSHIFT, True, mods=mods)
        when = keyboard.key(tap.code, True, mods=mods)
        time.sleep(HOLD_S)
        keyboard.key(tap.code, False, mods=mods)
        if tap.shift:
            keyboard.key(KEY_LEFTSHIFT, False, mods=mods & ~1)
        if tap.ctrl:
            keyboard.key(KEY_LEFTCTRL, False, mods=0)
        sent.append((when, tap.label, tap.measure))
    return sent
