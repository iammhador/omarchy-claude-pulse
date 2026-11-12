#!/usr/bin/env python3
"""Write ~/.cache/claude-pulse/demo.json: made-up data for screenshots.

    python3 tools/make-demo.py          # turn demo mode on
    rm ~/.cache/claude-pulse/demo.json  # back to your real data

Every project, prompt and number here is invented. With the file present the
helper answers every command from it, so README screenshots never show real
work. Times are relative to when you run this.
"""

import json
import os
import random
import time

random.seed(7)
now = time.time()
H = "/home/demo"
DAY = 86400


def spark(level):
    return [max(0, int(random.gauss(level, level * 0.6))) if random.random() > 0.25 else 0 for _ in range(30)]


def session(pid, project, title, prompt, model, status, since, tokens, cost, ctx, branch, **extra):
    row = {
        "pid": pid, "sessionId": "%08x-0000-4000-8000-%012x" % (pid, pid), "cwd": f"{H}/work/{project}", "project": project,
        "name": project, "kind": "interactive", "status": status, "rawStatus": "busy" if status == "busy" else "idle",
        "since": now - since, "startedAt": now - since - 3600, "version": "2.1.322", "chain": [pid],
        "title": title, "prompt": prompt, "model": model, "modelName": extra.pop("modelName"), "branch": branch,
        "context": ctx, "tokens": tokens, "cost": cost, "turns": random.randint(40, 180), "agentCalls": 0,
        "models": [], "sub": {"running": 0, "done": 0, "tokens": 0, "cost": 0, "active": []},
        "spark": spark(1500 if status == "busy" else 300), "rate": 0, "doing": None, "approval": None,
        "waitKind": "", "mode": "auto", "outdated": False,
    }
    row.update(extra)
    row["rate"] = round(sum(row["spark"][-5:]) / 5)
    return row


sessions = [
    session(4101, "atlas-api", "Migrate orders table to new schema", "add the orders migration and run it against staging",
            "claude-fable-5-2", "waiting", 95, 14_200_000, 9.84, 412_000, "feat/orders-v2", modelName="Fable 5.2",
            approval={"id": "demo1", "tool": "Bash", "detail": "pnpm prisma migrate deploy"}, waitKind="approval",
            rawStatus="waiting", mode="default"),
    session(4102, "acme-storefront", "Responsive product grid", "make the product grid work on mobile and add skeleton loading",
            "claude-opus-5-5", "busy", 260, 31_500_000, 14.02, 368_000, "ui/product-grid", modelName="Opus 5.5",
            doing={"id": "demo2", "tool": "Edit", "detail": "ProductGrid.tsx"},
            sub={"running": 2, "done": 3, "tokens": 6_400_000, "cost": 2.31,
                 "active": [{"type": "Explore", "desc": "Find every place the grid breakpoints are set"},
                            {"type": "general-purpose", "desc": "Write skeleton loading states"}]}),
    session(4103, "portfolio-site", "Blog post on edge caching", "draft the caching post and fix the code samples",
            "claude-sonnet-5-5", "busy", 40, 5_900_000, 1.73, 141_000, "main", modelName="Sonnet 5.5",
            doing={"id": "demo3", "tool": "Bash", "detail": "npm run build"}, mode="plan"),
]

windows = [
    {"id": "session", "label": "Session", "group": "session", "pct": 42.0, "resetsAt": now + 3 * 3600 + 1200, "windowSec": 18000, "severity": "normal", "active": True},
    {"id": "weekly", "label": "Weekly", "group": "weekly", "pct": 58.0, "resetsAt": now + 3 * DAY + 7200, "windowSec": 604800, "severity": "normal", "active": False},
    {"id": "model:Fable", "label": "Weekly · Fable", "group": "weekly", "pct": 23.0, "resetsAt": now + 3 * DAY + 7200, "windowSec": 604800, "severity": "normal", "active": False},
]

days = []
costs = [11.4, 18.9, 3.2, 22.6, 16.1, 0.0, 25.6]
for i, c in enumerate(costs):
    t = time.localtime(now - (6 - i) * DAY)
    days.append({"day": time.strftime("%Y-%m-%d", t), "label": time.strftime("%a", t), "tokens": int(c * 2_400_000), "cost": c})

projects = [
    {"cwd": f"{H}/work/acme-storefront", "project": "acme-storefront", "tokens": 98_000_000, "cost": 41.2, "sessions": 6, "models": ["Opus 5.5"], "subTokens": 21_000_000},
    {"cwd": f"{H}/work/atlas-api", "project": "atlas-api", "tokens": 52_000_000, "cost": 28.7, "sessions": 4, "models": ["Fable 5.2", "Opus 5.5"], "subTokens": 0},
    {"cwd": f"{H}/work/portfolio-site", "project": "portfolio-site", "tokens": 18_000_000, "cost": 6.4, "sessions": 3, "models": ["Sonnet 5.5"], "subTokens": 0},
    {"cwd": f"{H}/work/infra", "project": "infra", "tokens": 9_000_000, "cost": 3.9, "sessions": 2, "models": ["Haiku 5.5", "Sonnet 5.5"], "subTokens": 0},
]

recent = []
titles = [
    ("acme-storefront", "Checkout flow refactor", "split the checkout into steps and keep the cart in sync", "Opus 5.5", "feat/checkout"),
    ("atlas-api", "Rate limiting middleware", "add per-key rate limits with redis", "Fable 5.2", "main"),
    ("portfolio-site", "Dark mode polish", "the code blocks look washed out in dark mode", "Sonnet 5.5", "main"),
    ("infra", "Terraform state cleanup", "remove the old staging buckets from state", "Haiku 5.5", "chore/state"),
    ("acme-storefront", "Image optimisation", "convert product images to avif with fallbacks", "Opus 5.5", "perf/images"),
    ("atlas-api", "OpenAPI docs", "generate docs from the zod schemas", "Opus 5.5", "docs/openapi"),
]
for i, (proj, title, prompt, model, branch) in enumerate(titles):
    recent.append({"sessionId": "%08x-1111-4000-8000-000000000000" % i, "cwd": f"{H}/work/{proj}", "project": proj, "title": title,
                   "prompt": prompt, "model": model, "branch": branch, "last": now - (i + 1) * 9000, "first": now - (i + 1) * 9000 - 3600,
                   "tokens": random.randint(2, 40) * 1_000_000, "cost": round(random.uniform(1, 18), 2)})

folders = [{"cwd": f"{H}/work/{p}", "project": p, "last": now - i * 3600} for i, p in enumerate(["acme-storefront", "atlas-api", "portfolio-site", "infra"])]

plugins = [
    {"name": "frontend-design", "market": "claude-plugins-official", "version": "1.1.1", "enabled": True, "skills": ["frontend-design"], "commands": [], "agents": [], "mcp": []},
    {"name": "context7", "market": "claude-plugins-official", "version": "e0ab6e51", "enabled": True, "skills": [], "commands": [], "agents": [], "mcp": ["context7"]},
    {"name": "code-review-kit", "market": "example-market", "version": "0.4.0", "enabled": True, "skills": ["review"], "commands": ["review"], "agents": ["reviewer"], "mcp": []},
]

demo = {
    "sessions": {"ok": True, "now": now, "sessions": sessions},
    "usage": {"ok": True, "windows": windows,
              "breakdown": [{"key": "claude_code", "label": "Claude Code", "pct": 81}, {"key": "chat", "label": "Chats", "pct": 14}, {"key": "cowork", "label": "Cowork", "pct": 5}],
              "extra": None, "plan": "Max", "updatedAt": now - 40, "stale": False, "error": "", "retryAt": 0, "now": now},
    "scan": {"ok": True, "now": now, "today": {"tokens": 61_000_000, "cost": 25.6}, "week": {"tokens": 236_000_000, "cost": 97.8},
             "month": {"tokens": 1_020_000_000, "cost": 412.0, "days": 30}, "chart": days, "projects": projects,
             "models": [{"model": "Opus 5.5", "tokens": 150_000_000, "cost": 61.0, "messages": 920},
                        {"model": "Fable 5.2", "tokens": 41_000_000, "cost": 24.6, "messages": 210},
                        {"model": "Sonnet 5.5", "tokens": 30_000_000, "cost": 9.1, "messages": 340},
                        {"model": "Haiku 5.5", "tokens": 15_000_000, "cost": 0.9, "messages": 120}],
             "recent": recent, "folders": folders},
    "status": {"ok": True, "indicator": "none", "description": "All Systems Operational", "incidents": [], "degraded": [], "at": now},
    "inventory": {"ok": True, "plugins": plugins,
                  "skills": [{"name": "release-notes", "description": "Write release notes from the merged pull requests since the last tag."},
                             {"name": "db-migrations", "description": "Plan and review database migrations safely."}],
                  "mcp": [{"name": "context7", "scope": "plugin:context7", "type": ""}, {"name": "github", "scope": "user", "type": "http"}]},
    "jobs": {"ok": True, "now": now, "jobs": [
        {"id": "demojob1", "name": "nightly-dependency-audit", "state": "done", "detail": "No vulnerable packages found", "needs": "",
         "intent": "", "cwd": f"{H}/work/acme-storefront", "project": "acme-storefront", "tokens": 1_200_000, "updatedAt": now - 5400,
         "createdAt": now - 9000, "sessionId": ""}]},
    "version": {"ok": True, "local": "2.1.322", "latest": "2.1.322", "update": False, "at": now},
    "health": {"ok": True, "now": now, "signedIn": True, "tokenExpiresAt": now + 6 * 3600, "refreshExpiresAt": now + 24 * DAY,
               "plan": "max", "mcpNeedsAuth": []},
}

path = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "claude-pulse", "demo.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(demo, f)
print("demo mode on:", path)
