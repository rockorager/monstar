import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from monstar_bench import input as keys  # noqa: E402
from monstar_bench import metrics, report  # noqa: E402

R = 16_666_667
MS = 1_000_000


def frame(i, start, commit, present, refresh=R, missed=None, **extra):
    ev = {"ev": "frame", "id": i, "start": start, "render_done": start + 2 * MS if start else 0, "commit": commit,
          "w": 800, "h": 600, "present": present, "refresh": refresh, "msc": 0, "flags": 0}
    if missed is not None:
        ev["missed"] = missed
    ev.update(extra)
    return ev


class MissedRefreshTest(unittest.TestCase):
    # Same vectors as the Zig test in src/FrameTelemetry.zig.
    def test_mirrors_monstar_rule(self):
        p0 = 1_000_000_000
        f = metrics.missed_refreshes
        self.assertEqual(f(p0 - 5 * MS, p0, p0 + R, R), 0)
        self.assertEqual(f(p0 - 5 * MS, p0, p0 + 2 * R, R), 1)
        self.assertEqual(f(p0, p0, p0 + 4 * R + 2 * MS, R), 3)
        self.assertEqual(f(p0 + 1, p0, p0 + 30 * R, R), 0)
        self.assertEqual(f(p0 - 1, p0, p0 + 3 * R, 0), 0)
        self.assertEqual(f(p0 - 1, 0, p0 + 3 * R, R), 0)
        self.assertEqual(f(0, p0, p0 + 3 * R, R), 0)

    def test_frame_stats_uses_output_mode_when_refresh_is_unreported(self):
        base = 10_000 * MS
        # A continuous stream: frame 3 started before frame 2 was shown but
        # landed three refreshes later (two missed); frame 4 went dirty after
        # frame 3 was shown, so its gap is not a miss.
        presents = [base, base + R, base + 4 * R, base + 10 * R]
        starts = [base - 10 * MS, base - 5 * MS, base + R - 3 * MS, base + 4 * R + 5 * MS]
        events = [frame(i, s, s + 3 * MS, p, refresh=0) for i, (s, p) in enumerate(zip(starts, presents))]
        events.append({"ev": "frame", "id": 9, "start": 0, "render_done": 0, "commit": base + 11 * R, "w": 1, "h": 1,
                       "discarded": True})
        stats = metrics.frame_stats(events, 0, base + 20 * R, mode_refresh_ns=R)
        self.assertEqual(stats["missed_refreshes"], 2)
        self.assertEqual(stats["late_frames"], 1)
        self.assertEqual(stats["refresh_source"], "output-mode")
        self.assertEqual(stats["presented"], 4)
        self.assertEqual(stats["discarded"], 1)
        self.assertEqual(stats["interval_ms"], [round(R / MS, 3), round(3 * R / MS, 3), round(6 * R / MS, 3)])

    def test_frame_stats_trusts_monstar_missed_and_window(self):
        events = [frame(1, 1, 5 * MS, 20 * MS, missed=0), frame(2, 2, 30 * MS, 40 * MS, missed=3),
                  frame(3, 3, 99 * MS, 120 * MS, missed=5)]
        stats = metrics.frame_stats(events, 0, 50 * MS)
        self.assertEqual(stats["committed"], 2)
        self.assertEqual(stats["missed_refreshes"], 3)
        self.assertEqual(stats["refresh_source"], "presentation")

    def test_frame_stats_collects_gpu_time_when_reported(self):
        events = [frame(1, 1, 5 * MS, 20 * MS, gpu_ns=450_000), frame(2, 2, 30 * MS, 40 * MS),
                  frame(3, 3, 35 * MS, 60 * MS, gpu_ns=1_250_000)]
        self.assertEqual(metrics.frame_stats(events, 0, 50 * MS)["gpu_ms"], [0.45, 1.25])


def path(t, renderer, presentation):
    return {"ev": "path", "t": t, "renderer": renderer, "presentation": presentation}


class PathTest(unittest.TestCase):
    VULKAN = {"renderer": "vulkan"}
    CPU = {"renderer": "cpu"}

    def test_cpu_first_handoff_is_not_a_mismatch(self):
        cpu = {"renderer": "cpu", "presentation": "dmabuf"}
        shm = {"renderer": "cpu", "presentation": "shm"}
        vk = {"renderer": "vulkan", "presentation": "swapchain"}
        f = metrics.path_mismatches
        self.assertEqual(f([cpu, shm, vk], self.VULKAN, self.CPU), [])
        self.assertEqual(f([vk], self.VULKAN, self.CPU), [])
        # Never reaching Vulkan, or falling back after it, is a mismatch.
        self.assertEqual(f([cpu], self.VULKAN, self.CPU), [cpu])
        self.assertEqual(f([vk, cpu], self.VULKAN, self.CPU), [cpu])
        # Configs without a handoff accept only their own path.
        self.assertEqual(f([shm, cpu], {"presentation": "dmabuf"}), [shm])

    def test_first_frame_on_expected_path(self):
        base = 1000 * MS
        # Feedback for the last CPU frame arrives after the path switch, so
        # file order alone would misattribute it; commit times decide.
        events = [path(base, "cpu", "dmabuf"), frame(1, base, base + 1 * MS, base + 10 * MS),
                  path(base + 12 * MS, "vulkan", "swapchain"), frame(2, base + 5, base + 11 * MS, base + 27 * MS),
                  frame(3, base + 6, base + 13 * MS, base + 44 * MS), frame(4, base + 7, base + 30 * MS, base + 60 * MS)]
        self.assertEqual(metrics.first_presented_on(events, self.VULKAN)["id"], 3)
        self.assertEqual(metrics.first_presented_on(events, self.CPU)["id"], 1)
        self.assertIsNone(metrics.first_presented_on(events[:2], self.VULKAN))


class LatencyTest(unittest.TestCase):
    def test_matches_first_frame_after_receipt_and_skips_unmeasured(self):
        sent = [(100 * MS, "a", True), (300 * MS, "C-u", False), (500 * MS, "b", True), (700 * MS, "c", True)]
        events = [
            {"ev": "key", "t": 101 * MS}, {"ev": "key", "t": 301 * MS}, {"ev": "key", "t": 502 * MS},
            # Committed before key b was received: not its echo.
            frame(1, 0, 501 * MS, 510 * MS),
            frame(2, 0, 104 * MS, 117 * MS),
            frame(3, 0, 303 * MS, 320 * MS),
            frame(4, 0, 506 * MS, 525 * MS),
            # Key c never produced a frame before the run ended.
        ]
        flips = [117 * MS, 300 * MS, 525 * MS]
        lat = metrics.match_latency(sent, events, flips)
        self.assertEqual(lat["key_to_present_ms"], [17.0, 25.0])
        self.assertEqual(lat["key_to_commit_ms"], [4.0, 6.0])
        self.assertEqual(lat["key_to_receive_ms"], [1.0, 2.0])
        self.assertEqual(lat["key_to_flip_ms"], [17.0, 25.0])
        self.assertEqual(lat["keys"], 3)
        self.assertEqual(lat["unmatched"], 1)


class ProcTest(unittest.TestCase):
    def test_fdinfo_dedupes_clients_and_scales_memory(self):
        with tempfile.TemporaryDirectory() as proc:
            fdinfo = Path(proc, "42", "fdinfo")
            fdinfo.mkdir(parents=True)
            text = ("pos:\t0\ndrm-driver:\tamdgpu\ndrm-client-id:\t7\ndrm-engine-gfx:\t1500000 ns\n"
                    "drm-engine-capacity-gfx:\t1\ndrm-memory-vram:\t2 MiB\ndrm-memory-gtt:\t512 KiB\n")
            (fdinfo / "5").write_text(text)
            (fdinfo / "6").write_text(text)  # dup of the same client
            (fdinfo / "7").write_text(text.replace("client-id:\t7", "client-id:\t8"))
            (fdinfo / "1").write_text("pos:\t0\nflags:\t02\n")
            out = metrics.drm_fdinfo(42, proc)
        self.assertEqual(out["engine_ns"], {"gfx": 3_000_000})
        self.assertEqual(out["memory_kb"], {"memory-vram": 4096, "memory-gtt": 1024})

    def test_version_commit(self):
        self.assertEqual(metrics.parse_version_commit("monstar 1.1.0-dev.145+g9b8aaa9.dirty"), ("9b8aaa9", True))
        self.assertEqual(metrics.parse_version_commit("monstar 1.1.0"), (None, None))


class InputTest(unittest.TestCase):
    def test_us_layout_keys(self):
        self.assertEqual(keys.char_key("a"), (30, False))
        self.assertEqual(keys.char_key("A"), (30, True))
        self.assertEqual(keys.char_key("|"), (43, True))
        self.assertEqual(keys.char_key("/"), (53, False))
        self.assertEqual(keys.char_key("\n"), (28, False))

    def test_typing_schedule_is_deterministic_and_bounded(self):
        a = keys.typing_schedule("echo hi there", 9, 5.0, seed=3)
        b = keys.typing_schedule("echo hi there", 9, 5.0, seed=3)
        self.assertEqual([(t, k.code, k.label) for t, k in a], [(t, k.code, k.label) for t, k in b])
        self.assertTrue(all(t < 5.0 for t, _ in a))
        self.assertAlmostEqual(len(a) / 5.0, 9, delta=2.5)
        self.assertIn("BackSpace", [k.label for _, k in a])

    def test_repeat_schedule_rate(self):
        j = keys.Tap.char("j")
        sched = keys.repeat_schedule([(1.0, j), (1.0, j)], 25)
        self.assertEqual(len(sched), 50)


def run_doc(label, id_, w):
    def run(power, presented, missed, intervals):
        return {"seconds": 10.0, "power": {"package_w": power, "package_j": power * 10},
                "cpu": {"client_pct": 5.0, "compositor_pct": 3.0, "workload_pct": 1.0},
                "frames": {"presented": presented, "missed_refreshes": missed, "late_frames": missed,
                           "interval_ms": intervals, "render_ms": [1.0, 2.0], "gpu_ms": [0.4, 0.6],
                           "commit_to_present_ms": [9.0]},
                "memory": {"client": {"rss_kb": 51200}, "compositor": {"rss_kb": 102400}}}
    return {
        "schema": report.SCHEMA, "id": id_,
        "machine": {"label": label, "hostname": label, "cpu": {"model": "cpu"}, "gpus": [], "kernel": "k"},
        "session": {"compositor": "sway", "version": "1.12", "mode": "own",
                    "display": {"output": "eDP-1", "width": 1920, "height": 1200, "refresh_hz": 60, "scale": 1}},
        "monstar": {"version": "monstar x"}, "settings": {"repetitions": 3, "input": "uinput"},
        "measurements": {"rapl_package": {"status": "ok", "privileged": True}},
        "configs": {"cpu": {"status": "ok"}, "vulkan": {"status": "skipped", "reason": "no vulkan"}},
        "baseline": {"runs": [{"package_w": 3.0}, {"package_w": 3.4}, {"package_w": 3.2}]},
        "cells": [{"key": "sway/cpu/tiled/log-60", "compositor": "sway", "config": "cpu", "state": "tiled",
                   "workload": "log-60", "errors": [],
                   "runs": [run(w, 600, 0, [16.7] * 99 + [33.4]), run(w + 1, 590, 10, [16.7] * 100),
                            run(w - 1, 600, 0, [16.7])]}],
        "startup": [{"key": "s", "compositor": "sway", "config": "cpu", "cache": "warm",
                     "first_present_ms": [40.0, 50.0, 45.0], "first_commit_ms": [30.0, 40.0, 35.0], "failures": 0},
                    {"key": "v", "compositor": "sway", "config": "vulkan", "cache": "warm",
                     "first_present_ms": [40.0, 41.0, 42.0], "first_commit_ms": [30.0, 31.0, 32.0],
                     "handoff_ms": [62.0, None, 60.0], "failures": 0}],
    }


class ReportTest(unittest.TestCase):
    def test_summary_and_table(self):
        doc = report.finalize(run_doc("timbot", "a", 5.0))
        s = doc["cells"][0]["summary"]
        self.assertEqual(s["package_w"]["median"], 5.0)
        self.assertAlmostEqual(s["package_delta_w"]["median"], 1.8)
        self.assertEqual(s["missed_refreshes"], 10)
        self.assertAlmostEqual(s["missed_pct"], 100 * 10 / 1800, places=3)
        self.assertTrue(s["keeps_up"])
        self.assertEqual(s["frame_interval_ms"]["max"], 33.4)
        self.assertEqual(s["client_rss_mb"]["median"], 50.0)
        md = report.render_markdown(doc)
        self.assertIn("| timbot | sway | cpu | tiled | log-60 | yes (10/1790) |", md)
        self.assertIn("vulkan (no vulkan)", md)
        self.assertIn("| timbot | sway | cpu | warm | 3 | 45.0 |", md)
        self.assertEqual(s["gpu_ms"]["p50"], 0.4)
        # Render p50/p99, then GPU p50/p99 per frame.
        self.assertIn("| 1.00 / 2.00 | 0.40 / 0.60 |", md)
        # Handoff pools launches that switched; CPU configs have none.
        self.assertIn("| timbot | sway | vulkan | warm | 3 | 41.0 | 42.0 | 40.0 | 42.0 | 60.0 | 0 |", md)
        self.assertIn("| timbot | sway | cpu | warm | 3 | 45.0 | 50.0 | 40.0 | 50.0 | — | 0 |", md)

    def test_keeps_up_fails_over_threshold(self):
        doc = run_doc("m", "a", 5.0)
        for r in doc["cells"][0]["runs"]:
            r["frames"]["missed_refreshes"] = 20
        s = report.finalize(doc)["cells"][0]["summary"]
        self.assertFalse(s["keeps_up"])

    def test_merge_dedupes_runs_and_round_trips(self):
        a, b = run_doc("timbot", "a", 5.0), run_doc("laptop", "b", 7.0)
        merged = report.merge([a, b, json.loads(json.dumps(a))])
        self.assertEqual([r["id"] for r in merged["runs"]], ["a", "b"])
        again = report.merge([merged, b])
        self.assertEqual(len(again["runs"]), 2)
        md = report.render_markdown(again)
        self.assertIn("| laptop | sway | cpu | tiled | log-60 |", md)
        self.assertIn("## timbot", md)

    def test_kms_scanout_heuristic(self):
        doc = run_doc("m", "a", 5.0)
        tiled = doc["cells"][0]
        tiled["runs"][0]["kms_fbs"] = [[101, "1920x1200", "0x0"], [102, "1920x1200", "0x0"], [7, "64x64", "0x0"]]
        fs = json.loads(json.dumps(tiled))
        fs["state"] = "fullscreen"
        fs["runs"][0]["kms_fbs"] = [[201, "1920x1200", "0x0"], [7, "64x64", "0x0"]]
        comp = json.loads(json.dumps(fs))
        comp["workload"] = "idle"
        comp["runs"][0]["kms_fbs"] = [[101, "1920x1200", "0x0"]]
        doc["cells"] += [fs, comp]
        report.finalize(doc)
        self.assertTrue(doc["cells"][1]["summary"]["scanout_kms"])
        self.assertFalse(doc["cells"][2]["summary"]["scanout_kms"])
        self.assertNotIn("scanout_kms", doc["cells"][0]["summary"])


if __name__ == "__main__":
    unittest.main()
