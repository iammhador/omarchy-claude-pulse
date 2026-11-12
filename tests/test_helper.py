"""Run: python3 -m unittest discover -s tests"""

import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("helper", os.path.join(HERE, "..", "bin", "claude-pulse-helper"))
spec = importlib.util.spec_from_loader("helper", loader)
H = importlib.util.module_from_spec(spec)
loader.exec_module(H)


def line(**o):
    return json.dumps(o) + "\n"


def assistant(mid, model, ts, inp=10, out=100, cw=1000, cr=5000, tools=()):
    content = [{"type": "tool_use", "name": n, "input": {}} for n in tools]
    return line(type="assistant", timestamp=ts, cwd="/work/demo", sessionId="s1",
                message={"id": mid, "model": model, "content": content,
                         "usage": {"input_tokens": inp, "output_tokens": out, "cache_creation_input_tokens": cw,
                                   "cache_read_input_tokens": cr,
                                   "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": cw}}})


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "s1.jsonl")
        with open(self.path, "w") as f:
            f.write(line(type="user", timestamp="2026-11-12T10:00:00Z", cwd="/work/demo", sessionId="s1",
                         gitBranch="main", message={"role": "user", "content": "fix the navbar"}))
            f.write(line(type="ai-title", aiTitle="Fix navbar"))
            f.write(assistant("m1", "claude-opus-5-5", "2026-11-12T10:00:05Z", tools=("Agent",)))
            # The same message repeated per content block must count once.
            f.write(assistant("m1", "claude-opus-5-5", "2026-11-12T10:00:05Z"))
            f.write(assistant("m2", "claude-opus-5-5", "2026-11-12T10:01:00Z", cr=9000))

    def test_scan_totals(self):
        st = H.scan_file(self.path, H.new_state())
        self.assertEqual(st["title"], "Fix navbar")
        self.assertEqual(st["prompt"], "fix the navbar")
        self.assertEqual(st["branch"], "main")
        self.assertEqual(st["model"], "claude-opus-5-5")
        self.assertEqual(st["agents"], 1)
        self.assertEqual(st["ctx"], 10 + 1000 + 9000)
        per, cost = H.sum_days(st)
        t = per["claude-opus-5-5"]
        self.assertEqual(t[5], 2, "duplicate message id counted once")
        self.assertEqual(t[4], 14000)
        # 20 in*4 + 200 out*20 + 2000 1h-writes*8 + 14000 reads*0.2, per million
        self.assertAlmostEqual(cost, (20 * 4 + 200 * 20 + 2000 * 8 + 14000 * 0.2) / 1e6)

    def test_incremental(self):
        st = H.scan_file(self.path, H.new_state())
        off = st["off"]
        with open(self.path, "a") as f:
            f.write(assistant("m3", "claude-sonnet-5-5", "2026-11-12T11:00:00Z"))
            f.write('{"type":"assistant", "partial')  # incomplete line waits
        st = H.scan_file(self.path, st)
        self.assertGreater(st["off"], off)
        per, _ = H.sum_days(st)
        self.assertIn("claude-sonnet-5-5", per)
        self.assertEqual(st["model"], "claude-sonnet-5-5")

    def test_prices_and_names(self):
        self.assertEqual(H.price_for("claude-opus-5-5")[0], 4.0)
        self.assertEqual(H.price_for("claude-opus-5")[0], 5.0)
        self.assertEqual(H.price_for("claude-fable-5-2")[0], 8.0)
        self.assertIsNone(H.price_for("gpt-4"))
        self.assertEqual(H.pretty_model("claude-opus-5-5"), "Opus 5.5")
        self.assertEqual(H.pretty_model("claude-fable-5"), "Fable 5")
        self.assertEqual(H.project_name(os.path.expanduser("~")), "~")
        self.assertEqual(H.project_name("/a/b/My Site/"), "My Site")


class ActivityTests(unittest.TestCase):
    def test_spark_buckets(self):
        now = 10_000
        acts = [[now - 30 * 60 - 5, 999], [now - 29 * 60 - 30, 10], [now - 90, 20], [now - 10, 5], [now - 1, 7]]
        b = H.spark(acts, now)
        self.assertEqual(len(b), 30)
        self.assertEqual(b[0], 10, "the oldest minute; older ones are dropped")
        self.assertEqual(b[28], 20)
        self.assertEqual(b[29], 12)

    def test_act_is_bounded(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "a.jsonl")
        with open(p, "w") as f:
            for i in range(H.ACT_KEEP + 30):
                f.write(assistant("m%d" % i, "claude-opus-5-5", "2026-11-12T10:%02d:%02dZ" % (i // 60, i % 60)))
        st = H.scan_file(p, H.new_state())
        self.assertEqual(len(st["act"]), H.ACT_KEEP)
        self.assertEqual(st["act"][-1][1], 100)


class ToolTrackingTests(unittest.TestCase):
    def test_pending_set_and_cleared(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "t.jsonl")
        use = line(type="assistant", timestamp="2026-11-12T10:00:00Z",
                   message={"id": "m1", "model": "claude-opus-5-5", "usage": {"input_tokens": 1, "output_tokens": 1},
                            "content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "npm test"}}]})
        with open(p, "w") as f:
            f.write(line(type="permission-mode", permissionMode="plan"))
            f.write(use)
        st = H.scan_file(p, H.new_state())
        self.assertEqual(st["pending"]["tool"], "Bash")
        self.assertEqual(st["pending"]["detail"], "npm test")
        self.assertEqual(st["mode"], "plan")
        with open(p, "a") as f:
            f.write(line(type="user", timestamp="2026-11-12T10:00:03Z", permissionMode="auto",
                         message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"}]}))
        st = H.scan_file(p, st)
        self.assertIsNone(st["pending"])
        self.assertEqual(st["tool"]["detail"], "npm test", "the last action is kept")
        self.assertEqual(st["mode"], "auto")

    def test_tool_detail(self):
        self.assertEqual(H.tool_detail("Edit", {"file_path": "/a/b/Navbar.tsx"}), "Navbar.tsx")
        self.assertEqual(H.tool_detail("WebFetch", {"url": "https://example.com/x"}), "example.com")
        self.assertEqual(H.tool_detail("mcp__github__create_pr", {}), "github: create_pr")
        self.assertEqual(H.tool_detail("AskUserQuestion", {"questions": [{"question": "Which?"}]}), "Which?")
        self.assertEqual(H.tool_detail("Bash", None), "")
        self.assertEqual(H.tool_detail("Bash", {"command": 'cd "/a b" && npm run build'}), "npm run build")
        self.assertEqual(H.tool_detail("Bash", {"command": "cd ~/x && ls -la"}), "ls -la")

    def test_version_newer(self):
        self.assertTrue(H.version_newer("2.1.330", "2.1.322"))
        self.assertFalse(H.version_newer("2.1.322", "2.1.322"))
        self.assertTrue(H.version_newer("2.10.0", "2.9.9"))


class JobsAndHealthTests(unittest.TestCase):
    def run_cmd(self, fn, *args):
        buf = io.StringIO()
        with redirect_stdout(buf):
            fn(*args)
        return json.loads(buf.getvalue())

    def test_jobs_and_health(self):
        root = tempfile.mkdtemp()
        old = H.CLAUDE
        H.CLAUDE = root
        try:
            os.makedirs(os.path.join(root, "jobs", "abc"))
            with open(os.path.join(root, "jobs", "abc", "state.json"), "w") as f:
                json.dump({"state": "blocked", "name": "demo-job", "cwd": "/work/demo", "tokens": 42,
                           "updatedAt": "2099-01-01T00:00:00Z", "resumeSessionId": "s-1", "needs": "rate limited"}, f)
            with open(os.path.join(root, ".credentials.json"), "w") as f:
                json.dump({"claudeAiOauth": {"accessToken": "SECRET-TOKEN", "refreshToken": "SECRET-REFRESH",
                                             "expiresAt": 2_000_000_000_000, "refreshTokenExpiresAt": 2_100_000_000_000}}, f)
            with open(os.path.join(root, "mcp-needs-auth-cache.json"), "w") as f:
                json.dump({"plugin:context7:context7": {"timestamp": 1}}, f)
            jobs = self.run_cmd(H.cmd_jobs)["jobs"]
            self.assertEqual(jobs[0]["name"], "demo-job")
            self.assertEqual(jobs[0]["project"], "demo")
            self.assertEqual(jobs[0]["sessionId"], "s-1")
            buf = io.StringIO()
            with redirect_stdout(buf):
                H.cmd_health()
            raw = buf.getvalue()
            self.assertNotIn("SECRET", raw, "tokens never leave the helper")
            health = json.loads(raw)
            self.assertEqual(health["refreshExpiresAt"], 2_100_000_000)
            self.assertEqual(health["mcpNeedsAuth"][0]["name"], "context7")
        finally:
            H.CLAUDE = old


class UsageTests(unittest.TestCase):
    def test_normalise_limits(self):
        raw = {"limits": [
            {"kind": "session", "group": "session", "percent": 5, "resets_at": "2026-11-12T21:00:00+00:00"},
            {"kind": "weekly_all", "group": "weekly", "percent": 60, "resets_at": "2026-11-17T12:00:00+00:00"},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": "2026-11-17T12:00:00+00:00",
             "scope": {"model": {"display_name": "Fable"}}}],
            "seven_day_breakdown": {"rows": [{"key": "claude_code", "display_name": "Claude Code", "percent": 93}]},
            "spend": {"enabled": False}}
        u = H.normalise_usage(raw)
        self.assertEqual([w["id"] for w in u["windows"]], ["session", "weekly", "model:Fable"])
        self.assertEqual(u["windows"][0]["windowSec"], 18000)
        self.assertEqual(u["windows"][2]["label"], "Weekly · Fable")
        self.assertEqual(u["breakdown"][0]["pct"], 93)
        self.assertIsNone(u["extra"])

    def test_legacy_shape(self):
        u = H.normalise_usage({"five_hour": {"utilization": 42.0, "resets_at": "2026-11-12T21:00:00Z"},
                               "seven_day": {"utilization": 7.0, "resets_at": None}})
        self.assertEqual([w["pct"] for w in u["windows"]], [42.0, 7.0])


class InventoryTests(unittest.TestCase):
    def test_frontmatter_block_scalar(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "SKILL.md")
        with open(p, "w") as f:
            f.write("---\nname: demo\ndescription: >\n  First line\n  second line.\n---\nbody\n")
        self.assertEqual(H.frontmatter(p), {"name": "demo", "description": "First line second line."})


class SafetyTests(unittest.TestCase):
    def test_unknown_command_is_json(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            H.main(["x", "nope"])
        self.assertFalse(json.loads(buf.getvalue())["ok"])


if __name__ == "__main__":
    unittest.main()
