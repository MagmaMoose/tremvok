"""Repo-shape checks for the MagmaMoose documentation standard.

These are the rules nothing else enforces. MegaLinter already runs markdownlint and
link checking on every pull request in every repo (via Chargate's provisioned
``security.yml``), and ``mkdocs build --strict`` already fails on a broken internal link
or a nav entry pointing at a missing file. Duplicating any of that here would be a second
place to keep in step.

What is left is the shape of the repository itself: whether the README is still a
listing rather than a manual, whether its licence claim matches the LICENSE beside it,
whether its links survive being rendered somewhere other than github.com, and whether
the shared MkDocs base is actually reaching this repo.

Deliberately five checks, each a hard error. A linter with forty rules on a
one-maintainer org gets bypassed in week two.

PyYAML is imported rather than hand-rolled: this runs after the docs toolchain is
installed, and MkDocs depends on PyYAML, so it is always present by then.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# README H2s that must appear, in this relative order. Other sections may sit between
# them — the contract fixes the spine, not every vertebra.
REQUIRED_ORDER: dict[str, list[str]] = {
    "action": ["Quickstart", "What it does", "Most-used inputs", "Where it sits"],
    "service": ["What it is", "Run it", "Documentation"],
}

# Headings that name an anti-pattern rather than a topic. Matched case-insensitively on
# the heading text, so "## Contents" and "## contents" are the same defect.
BANNED_HEADINGS: dict[str, str] = {
    "contents": "GitHub renders an outline automatically and MkDocs Material has "
    "toc.follow; a hand-maintained TOC only drifts",
    "table of contents": "as above",
    "examples": "a heading that means 'unsorted how-to guides'; give each one a "
    "task-shaped page in docs/how-to/",
    "inputs": "the full input table is reference; keep 'Most-used inputs' here and "
    "generate the rest into docs/",
    "outputs": "reference, belongs in the generated action reference",
    "permissions": "reference, belongs in docs/",
    "conventions": "contributor material, belongs in CONTRIBUTING.md",
    "not yet implemented": "status prose, belongs in docs/explanation/roadmap.md",
    "open decisions": "an ADR with Status: Proposed makes staleness visible; a README "
    "list hides it",
    "open questions": "as above",
    "phased migration": "belongs in docs/explanation/roadmap.md",
    "risk register": "belongs in docs/explanation/roadmap.md",
}

LINE_BUDGET: dict[str, int] = {"action": 120, "service": 80, "spec": 40}

SPDX_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("Apache-2.0", re.compile(r"Apache License|Apache-2\.0", re.I)),
    ("MIT", re.compile(r"\bMIT License\b", re.I)),
    ("Proprietary", re.compile(r"\bProprietary\b", re.I)),
]


@dataclass
class Report:
    errors: list[tuple[str, str]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def error(self, where: str, message: str) -> None:
        self.errors.append((where, message))

    def note(self, message: str) -> None:
        self.notes.append(message)


def detect_profile(root: Path) -> str:
    """A root action.yml means the action profile; a src/ tree means service.

    Detected rather than declared, so a new repo gets the right shape without anyone
    updating a list.
    """
    if (root / "action.yml").is_file() or (root / "action.yaml").is_file():
        return "action"
    # Any shipped surface at all makes this a service. A manifest, a source tree, a
    # container build or a chart each count: dunmir ships agent/ + control-plane/ +
    # charts/ and noctyr ships backend/ + ios/, and neither has a src/ or a pyproject,
    # so keying on those alone filed both as spec-stage and held them to a 40-line
    # budget they were never going to meet.
    manifests = (
        "pyproject.toml",
        "package.json",
        "go.mod",
        "Cargo.toml",
        "Gemfile",
        "Dockerfile",
        "docker-bake.hcl",
    )
    if any((root / m).is_file() for m in manifests):
        return "service"
    dirs = (
        "src",
        "lib",
        "cmd",
        "app",
        "charts",
        "backend",
        "worker",
        "agent",
        "control-plane",
        "broker",
        "automation",
    )
    if any((root / d).is_dir() for d in dirs):
        return "service"
    return "spec"


def load_yaml(path: Path) -> dict[str, Any]:
    """Parse a YAML file, tolerating MkDocs' python/name tags."""
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    # mkdocs.yml legitimately carries `!!python/name:...` for superfences custom_fences;
    # safe_load refuses it, and we only ever read plain keys, so neutralise the tag.
    text = re.sub(r"!!python/name:\S+", "'<python-name>'", text)
    try:
        return yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:  # pragma: no cover - malformed YAML fails elsewhere too
        raise SystemExit(f"lint-docs: cannot parse {path}: {exc}") from exc


def headings(readme: str) -> list[str]:
    return [m.group(1).strip() for m in re.finditer(r"^## +(.+?)\s*$", readme, re.M)]


# --------------------------------------------------------------------------- checks


def check_readme_shape(root: Path, profile: str, budget: int, rep: Report) -> None:
    """The README is the listing, not the manual."""
    path = root / "README.md"
    if not path.is_file():
        rep.error("README.md", "missing")
        return
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    if len(lines) > budget:
        rep.error(
            "README.md",
            f"{len(lines)} lines exceeds the {profile}-profile budget of {budget}. "
            + (
                "The README is rendered verbatim on the Marketplace with no nav and no "
                "search; move the manual into docs/."
                if profile == "action"
                else "A repo root is where someone lands to find out what this is; "
                "the manual belongs in docs/."
            ),
        )

    if not re.match(r"^# +\S", text):
        rep.error("README.md", "must open with a single `# Title` heading")

    found = headings(text)
    for heading in found:
        key = heading.lower().rstrip(":")
        # "Most-used inputs" is allowed; a bare "Inputs" is not.
        if key in BANNED_HEADINGS:
            rep.error("README.md", f"banned heading `## {heading}` — {BANNED_HEADINGS[key]}")

    required = REQUIRED_ORDER.get(profile, [])
    lowered = [h.lower() for h in found]
    positions = []
    for want in required:
        try:
            positions.append(lowered.index(want.lower()))
        except ValueError:
            rep.error(
                "README.md", f"missing required section `## {want}` for the {profile} profile"
            )
            positions.append(-1)
    ordered = [p for p in positions if p >= 0]
    if ordered != sorted(ordered):
        rep.error(
            "README.md",
            "required sections are out of order; expected " + " → ".join(required),
        )


def check_licence_agreement(root: Path, rep: Report) -> None:
    """The README's licence claim, the LICENSE file and pyproject must agree.

    This is a legal claim, not a formatting nit, and it is trivially machine-checkable —
    which is exactly why three repos in this org shipped a README saying MIT over an
    Apache-2.0 LICENSE for months.
    """
    licence_file = root / "LICENSE"
    if not licence_file.is_file():
        rep.error("LICENSE", "missing")
        return

    head = licence_file.read_text(encoding="utf-8", errors="replace")[:400]
    actual = next((name for name, pat in SPDX_PATTERNS if pat.search(head)), None)
    if actual is None:
        rep.note("LICENSE: could not identify the licence; skipping the agreement check")
        return

    readme = root / "README.md"
    if readme.is_file():
        text = readme.read_text(encoding="utf-8")
        # Only look at a licence section, not every incidental "MIT" in prose.
        section = re.search(r"^##.*Licen[cs]e.*$([\s\S]*?)(?=^## |\Z)", text, re.M | re.I)
        if section:
            claimed = next((n for n, p in SPDX_PATTERNS if p.search(section.group(1))), None)
            if claimed and claimed != actual:
                rep.error(
                    "README.md",
                    f"claims {claimed} but LICENSE is {actual}",
                )

    pyproject = root / "pyproject.toml"
    if pyproject.is_file():
        text = pyproject.read_text(encoding="utf-8")
        m = re.search(r'^\s*license\s*=\s*[\{"]?\s*(?:text\s*=\s*)?"([^"]+)"', text, re.M)
        if m:
            declared = m.group(1).strip()
            if not any(p.search(declared) for n, p in SPDX_PATTERNS if n == actual):
                rep.error(
                    "pyproject.toml",
                    f'license = "{declared}" but LICENSE is {actual}',
                )


def check_readme_links(root: Path, profile: str, rep: Report) -> None:
    """Relative doc links 404 on the Marketplace; absolute ones must hit a real page."""
    path = root / "README.md"
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")

    if profile == "action":
        for m in re.finditer(r"\]\((docs/[^)\s#]+)", text):
            rep.error(
                "README.md",
                f"relative link `{m.group(1)}` 404s on the Marketplace listing, which "
                "renders this file outside the repository — use the published URL",
            )

    for m in re.finditer(r"\]\((?!https?://|#|mailto:)([^)\s#]+)", text):
        target = m.group(1)
        if not (root / target).exists():
            rep.error("README.md", f"link target `{target}` does not exist")

    # Absolute links into this repo's own docs site must name a page the nav will build.
    config = load_yaml(root / "mkdocs.yml")
    site_url = (config.get("site_url") or "").rstrip("/")
    if not site_url:
        return
    pages = {
        str(v).removesuffix(".md")
        for v in re.findall(r"([\w./-]+\.md)", yaml.safe_dump(config.get("nav") or []))
    }
    pages.add("index")
    for m in re.finditer(re.escape(site_url) + r"/([\w./-]*)", text):
        slug = m.group(1).strip("/").split("#")[0]
        if slug and slug not in pages and f"{slug}/index" not in pages:
            rep.error(
                "README.md",
                f"links to {site_url}/{slug}/ but no such page is in the mkdocs nav",
            )


def check_marketplace_preflight(root: Path, profile: str, rep: Report) -> None:
    """Marketplace refuses a listing without branding; the failure comes at publish time."""
    if profile != "action":
        return
    path = root / "action.yml"
    if not path.is_file():
        path = root / "action.yaml"
    action = load_yaml(path)
    for key in ("name", "description", "author"):
        if not action.get(key):
            rep.error(path.name, f"`{key}:` is required for a Marketplace listing")
    branding = action.get("branding") or {}
    for key in ("icon", "color"):
        if not branding.get(key):
            rep.error(
                path.name,
                f"`branding.{key}:` is required — Marketplace rejects a listing without it, "
                "and the rejection arrives at publish time, not in CI",
            )


def check_inherit_not_clobbered(root: Path, rep: Report) -> None:
    """A local list silently replaces the inherited one — no merge, no warning.

    MkDocs merges INHERIT dicts recursively but REPLACES lists wholesale. A repo that
    declares its own `markdown_extensions` therefore loses every extension the shared
    base provides, with nothing reported. The visible symptom is a page that renders as
    a wall of code instead of a diagram.
    """
    path = root / "mkdocs.yml"
    config = load_yaml(path)
    if not config.get("INHERIT"):
        return
    raw = path.read_text(encoding="utf-8")
    for key in ("markdown_extensions", "plugins"):
        if re.search(rf"^{key}\s*:", raw, re.M):
            rep.error(
                "mkdocs.yml",
                f"declares `{key}:` while inheriting from {config['INHERIT']}. MkDocs "
                f"REPLACES lists rather than merging them, so this silently discards every "
                f"{key} entry the shared base provides. Move repo-specific entries into the "
                f"base, or drop INHERIT.",
            )


# --------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    # Windows consoles default to cp1252 and die on anything outside it.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Repo-shape checks for the MagmaMoose docs standard.")
    ap.add_argument("--root", default=".", type=Path)
    ap.add_argument("--profile", default="auto", choices=["auto", "action", "service", "spec"])
    ap.add_argument("--readme-budget", type=int, default=0, help="0 = the profile default")
    ap.add_argument("--github-annotations", action="store_true")
    args = ap.parse_args(argv)

    root: Path = args.root.resolve()
    profile = detect_profile(root) if args.profile == "auto" else args.profile
    budget = args.readme_budget or LINE_BUDGET.get(profile, 120)

    rep = Report()
    check_readme_shape(root, profile, budget, rep)
    check_licence_agreement(root, rep)
    check_readme_links(root, profile, rep)
    check_marketplace_preflight(root, profile, rep)
    check_inherit_not_clobbered(root, rep)

    print(f"lint-docs: profile={profile} budget={budget} root={root}")
    for note in rep.notes:
        print(f"  note: {note}")
    for where, message in rep.errors:
        if args.github_annotations:
            print(f"::error file={where}::{message}")
        print(f"  ERROR {where}: {message}")

    if rep.errors:
        print(f"lint-docs: {len(rep.errors)} error(s)")
        return 1
    print("lint-docs: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
