# /// script
# requires-python = ">=3.10"
# dependencies = ["tiktoken==0.14.0"]
# ///
# Org-wide per-unit Claude-token limit. A unit is every Cargo package (a directory whose
# Cargo.toml has a [package] table) and every JS/TS package (a directory with a
# package.json, unless it only lists workspaces: it has "workspaces" or sits beside
# pnpm-workspace.yaml), outside build output. Each stays within 50,000 Claude tokens of
# hand-written source, measured as tiktoken o200k_base x 1.5 (rounded up). A file
# belongs to the deepest unit that contains it; files outside every unit are not counted.
#   check-crate-tokens.py                  every unit, working tree (tracked and untracked,
#                                          not ignored)
#   check-crate-tokens.py --report         every unit's count, largest first, and the
#                                          migration tokens left out of it
#   check-crate-tokens.py --help           this text
#   check-crate-tokens.py --print-baseline diagnostic rows only, not permission to add them
#   check-crate-tokens.py --ci BASE        check BASE against the committed HEAD tree
#   check-crate-tokens.py --range BASE TIP UNIT...  the same verdict, only selected units
#   check-crate-tokens.py --history-needed BASE [TIP]  config-only preflight; exit 3 if a
#                                          candidate addition needs complete history
# Rows and exemptions may never be added or raised. No label bypasses this policy.
# Except in a sync (see sync-tip.sh, beside this engine, given the CRATE_TOKENS_* event data):
# lines at that tip, at that value or lower, passed there and count as accepted.
# Above 50,000, a touched grandfathered unit must shrink below its measured base count AND
# its base row, ratcheting the row to the new count. At <=50,000, just remove its row.
# Measured files alone count as touches. Touched units warn at >=40,000 (80%) with their headroom.
# Deleted units must lose their rows.
# An all-zero or missing BASE falls back to the merge-base with the default branch
# (CRATE_TOKENS_DEFAULT_BRANCH, else origin/HEAD, origin/main or origin/master).
# Run with: uv run --script scripts/check-crate-tokens.py [mode], or through
# scripts/check-crate-tokens.sh, which also works piped from curl.
# .crate-tokens lines (# starts a comment):
#   exempt <glob>              generated or vendored paths; * is one path segment,
#                              ** any depth, ? one character, the rest literal
#   baseline <unit> <tokens>   a grandfathered unit ("." for the repository root);
#                              existing allowances only; touch it, split it
# Each projects/<p>/.crate-tokens adds lines relative to its folder ("." is the folder) and
# is never counted itself; each config file may only shrink against the same file at BASE.
# Never counted: lockfiles, *.d.ts, source maps, minified files, snapshots, SVGs,
# OpenAPI and Swagger documents (openapi*.json, swagger*.yaml and so on), the org-vendored .githooks/org/, anything under target, node_modules, dist, build, .svelte-kit, .next, coverage,
# .sqlx or openapi directories, files that say "@generated" or "DO NOT EDIT" near
# the top, binaries, symlinks and submodules.
# Database migrations are never counted either: a file whose name ends in .sql (any case)
# with a directory named exactly "migrations" or "migrate" anywhere above it (sqlx, goose,
# dbmate, Prisma's migrations/<id>/migration.sql). Migrations in a general-purpose language
# (Alembic versions/*.py, Rails db/migrate/*.rb, TypeScript migrations) still count, as does
# any .sql file outside such a directory. --report shows the tokens left out per unit; the
# file length check still applies to every migration.
import json
import os
import re
import subprocess
import sys

LIMIT = 50_000
CONFIG = ".crate-tokens"
PROJECT = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]*\Z")  # a projects/<p> folder (no dot-folders)
SKIP_NAMES = {
    "Cargo.lock", "bun.lock", "bun.lockb", "package-lock.json", "npm-shrinkwrap.json",
    "pnpm-lock.yaml", "yarn.lock", "deno.lock",
}
SKIP_SUFFIXES = (".d.ts", ".d.mts", ".d.cts", ".map", ".min.js", ".min.css", ".snap", ".svg")
SKIP_DIRS = {
    "target", "node_modules", "dist", "build", ".svelte-kit", ".next", ".nuxt", ".turbo",
    "coverage", ".sqlx", "openapi",
}
VENDORED = (".githooks/org/",)  # the org pre-push guard, vendored by org-checks
MIGRATION_DIRS = {"migrations", "migrate"}
API_SPEC = re.compile(r"(openapi|swagger)[^/]*\.(json|ya?ml)\Z", re.IGNORECASE)
GENERATED_MARK = re.compile(rb"@generated|DO NOT EDIT")
PACKAGE_TABLE = re.compile(rb"^[ \t]*\[package\][ \t]*(#.*)?\r?$", re.MULTILINE)
# Control characters in a unit path print as \xNN escapes, so a directory name cannot start
# a new output line (and with it a "::" workflow command).
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


class ConfigError(Exception):
    pass


def git(*args, data=None, check=True):
    r = subprocess.run(["git", *args], input=data, capture_output=True, check=check)
    return r.stdout if r.returncode == 0 else None


def glob_re(g):
    out, i = [], 0
    while i < len(g):
        if g.startswith("**/", i):
            out.append("(.*/)?"); i += 3
        elif g.startswith("**", i):
            out.append(".*"); i += 2
        elif g[i] == "*":
            out.append("[^/]*"); i += 1
        elif g[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(g[i])); i += 1
    return re.compile("".join(out) + r"\Z")


def parse_config(text, name, prefix=""):
    """Returns (exempt globs, {unit: tokens}), with globs and units relative to folder PREFIX
    made relative to the repository root; raises ConfigError on bad lines."""
    exempt, rows, errors = [], {}, []
    for n, line in enumerate(text.splitlines(), 1):
        w = line.split("#", 1)[0].split()
        if not w:
            continue
        if w[0] == "exempt" and len(w) == 2:
            exempt.append(prefix + w[1])
        elif w[0] == "baseline" and len(w) == 3 and w[2].isdigit():
            unit = normalise_unit(w[1])
            if prefix:
                unit = prefix.rstrip("/") if unit == "." else prefix + unit
            if unit in rows:
                errors.append(f"{name}:{n}: duplicate baseline row for {unit}")
            rows[unit] = int(w[2])
        else:
            errors.append(f"{name}:{n}: unknown or malformed line: {line.strip()}")
    if errors:
        raise ConfigError("\n".join(errors))
    return exempt, rows


def normalise_unit(unit):
    value = unit.rstrip("/")
    if value != "." and (not value or any(p in ("", ".", "..") for p in value.split("/"))):
        raise ConfigError(f"invalid unit path {unit!r}; use a repository-relative canonical path")
    return value


def prefix_of(name):
    return name[: -len(CONFIG)]


def tree_config_names(paths):
    """Immutable config enumeration, independent of working-tree adapter overrides."""
    return [CONFIG] + sorted(p for p in paths if p.count("/") == 2
                            and p.startswith("projects/") and p.endswith("/" + CONFIG)
                            and PROJECT.fullmatch(p.split("/")[1]))


def config_names(paths=None):
    """Root and project configs; adapters may replace this with a zero-argument callable."""
    if paths is not None:
        return tree_config_names(paths)
    names = [CONFIG]
    if os.path.isdir("projects"):
        names += sorted(f"projects/{d}/{CONFIG}" for d in os.listdir("projects")
                        if PROJECT.match(d) and os.path.isfile(f"projects/{d}/{CONFIG}"))
    return names


def load_configs(names, reader=None):
    """Returns (exempt globs, {unit: tokens}, {config name: (exempt, rows)}) for every config;
    raises ConfigError on bad lines or a unit with rows in two files."""
    exempt, rows, per, errors = [], {}, {}, []
    for name in names:
        try:
            text = (reader(name) or b"").decode("utf-8") if reader else read_text(name)
            e, r = parse_config(text, name, prefix_of(name))
        except ConfigError as err:
            errors.append(str(err))
            continue
        errors += [f"{name}: duplicate baseline row for {u}" for u in sorted(set(r) & set(rows))]
        exempt += e
        rows.update(r)
        per[name] = (e, r)
    if errors:
        raise ConfigError("\n".join(errors))
    return exempt, rows, per


def skipped(path, exempt_res):
    parts = path.split("/")
    name = parts[-1]
    if name in SKIP_NAMES or name.endswith(SKIP_SUFFIXES) or API_SPEC.match(name):
        return True
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return True
    if path == CONFIG or path.startswith(VENDORED) or (len(parts) == 3 and parts[0] == "projects" and name == CONFIG):
        return True
    return any(r.match(path) for r in exempt_res)


def migration(path):
    """A database migration: a .sql file under a directory named migrations or migrate."""
    parts = path.split("/")
    return parts[-1].lower().endswith(".sql") and any(p in MIGRATION_DIRS for p in parts[:-1])


def read(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return None  # symlink, submodule, or tracked but deleted
    with open(path, "rb") as f:
        return f.read()


def read_text(path):
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as f:
        return f.read()


def workspace_root(path, paths, reader=None):
    """A package.json with "workspaces", or beside pnpm-workspace.yaml, is like a Cargo virtual
    manifest: it only lists packages, so it is not a unit itself."""
    if path.rsplit("/", 1)[0] + "/pnpm-workspace.yaml" in paths or (
        path == "package.json" and "pnpm-workspace.yaml" in paths
    ):
        return True
    try:
        manifest = json.loads((reader or read)(path) or b"")
    except ValueError:
        return False
    return isinstance(manifest, dict) and "workspaces" in manifest


def discover(paths, reader=None):
    """Unit directories: a Cargo.toml with [package], or a package.json that is not only a
    workspace root, outside build output and node_modules."""
    units, present = set(), set(paths)
    for p in paths:
        parts = p.split("/")
        if any(q in SKIP_DIRS for q in parts[:-1]):
            continue
        d = "/".join(parts[:-1]) or "."
        if parts[-1] == "package.json":
            if not workspace_root(p, present, reader):
                units.add(d)
        elif parts[-1] == "Cargo.toml":
            data = (reader or read)(p)
            if data is not None and PACKAGE_TABLE.search(data):
                units.add(d)
    return units


def escape(path):
    return CONTROL.sub(lambda m: f"\\x{ord(m.group()):02x}", path)


def owner(path, units):
    d = path
    while "/" in d:
        d = d.rsplit("/", 1)[0]
        if d in units:
            return d
    return "." if "." in units else None


def source_text(path, exempt_res, reader):
    if skipped(path, exempt_res):
        return None
    data = reader(path)
    if data is None or b"\0" in data or GENERATED_MARK.search(data[:1024]):
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def measure(exempt, paths=None, reader=None, units=None, selected=None, *, raw_keys=False):
    """Legacy escaped unit keys by default; immutable policy callers request raw identities."""
    reader = reader or read
    if paths is None:
        out = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
        paths = sorted(set(filter(None, out.decode("utf-8", "surrogateescape").split("\0"))))
    units = discover(paths, reader) if units is None else units
    exempt_res = [glob_re(g) for g in exempt]
    owners, texts, kinds = [], [], []
    counted = units if selected is None else units & set(selected)
    for p in paths:
        u = owner(p, units)
        if u not in counted:
            continue
        text = source_text(p, exempt_res, reader)
        if text is not None:
            texts.append(text)
            owners.append(u)
            kinds.append(2 if migration(p) else 0)
    counts = {u: [0, 0, 0] for u in counted}
    if texts:
        import tiktoken

        enc = tiktoken.get_encoding("o200k_base")
        for u, k, toks in zip(owners, kinds, enc.encode_ordinary_batch(texts, num_threads=1)):
            counts[u][k] += len(toks)
            counts[u][1] += not k
    return {(u if raw_keys else escape(u)): ((raw * 3 + 1) // 2, files, (mig * 3 + 1) // 2)
            for u, (raw, files, mig) in counts.items()}


def batch_blobs(oids):
    """Read unique blobs in one batch, checking every response, including missing objects."""
    want = sorted(set(oids))
    out = git("cat-file", "--batch", data="".join(o + "\n" for o in want).encode()) if want else b""
    blobs, pos = {}, 0
    for oid in want:
        end = out.index(b"\n", pos)
        header = out[pos:end].split()
        if len(header) != 3 or header[0].decode() != oid or header[1] != b"blob":
            raise ConfigError("missing config/source blob; fetch complete objects before checking")
        size = int(header[2])
        blobs[oid] = out[end + 1:end + 1 + size]
        pos = end + size + 2
    return blobs


class Tree:
    """Immutable two-tree input. A supplied unit list restricts source and manifest reads."""
    def __init__(self, ref, selected=None):
        scopes = set(selected or [])
        for u in list(scopes):
            parts = [] if u == "." else u.split("/")
            for i in range(len(parts)):
                pre = "/".join(parts[:i])
                scopes.update((pre + "/" if pre else "") + n
                              for n in ("Cargo.toml", "package.json", "pnpm-workspace.yaml"))
        self.entries, self.data, self.modes = {}, {}, {}
        for rec in git("ls-tree", "-r", "-z", ref, "--", *sorted(scopes)).split(b"\0"):
            if not rec:
                continue
            meta, path = rec.split(b"\t", 1)
            mode, kind, oid = meta.split()
            path = path.decode("utf-8", "surrogateescape")
            self.entries[path] = oid.decode() if kind == b"blob" and mode != b"120000" else None
            self.modes[path] = mode
        self.load(p for p in self.entries if p.rsplit("/", 1)[-1] in ("Cargo.toml", "package.json")
                  and not any(d in SKIP_DIRS for d in p.split("/")[:-1]))
        self.units = discover(self.entries, self.read)

    def load(self, paths):
        want = {p: self.entries[p] for p in paths if self.entries.get(p) and p not in self.data}
        blobs = batch_blobs(want.values())
        self.data.update((p, blobs[o]) for p, o in want.items())

    def read(self, path):
        return self.data.get(path)

    def measure(self, exempt, selected=None):
        res = [glob_re(g) for g in exempt]
        self.load(p for p in self.entries if (selected is None or owner(p, self.units) in selected)
                  and not skipped(p, res))
        return measure(exempt, self.entries, self.read, self.units, selected, raw_keys=True)

    def touched(self, other, exempt, other_exempt):
        res, other_res = ([glob_re(g) for g in e] for e in (exempt, other_exempt))
        candidates = []
        for p in self.entries.keys() | other.entries.keys():
            if migration(p) or (skipped(p, res) and skipped(p, other_res)):
                continue
            if (self.entries.get(p), self.modes.get(p), owner(p, self.units), skipped(p, res)) != (
                    other.entries.get(p), other.modes.get(p), owner(p, other.units), skipped(p, other_res)):
                candidates.append(p)
        self.load(candidates)
        other.load(candidates)
        touched = set()
        for p in candidates:
            a, b = source_text(p, res, self.read), source_text(p, other_res, other.read)
            u, v = owner(p, self.units), owner(p, other.units)
            if (u, a, self.modes.get(p)) != (v, b, other.modes.get(p)):
                touched.update(w for w, text in ((u, a), (v, b)) if w is not None and text is not None)
        return touched | (self.units - other.units)


def unit_verdict(count, row=None, *, old_count=None, old_row=None, touched=False, exists=True):
    """Shared pure policy: return (failure messages, warnings), without unit-name prefixes.
    old_count is the measured base count, not row slack. None means no range comparison.
    Callers also compare configs to reject additions/raises even on untouched units."""
    failures, warnings = [], []
    if touched and old_row is not None:
        if not exists or count <= LIMIT:
            if row is not None:
                failures.append("under the limit: delete its row" if exists else
                                "within the limit or deleted; remove its baseline row")
        else:
            if old_count is None or count >= old_count or count >= old_row:
                failures.append(f"{count} tokens must be strictly below measured base {old_count} and baseline {old_row}; split it")
            if row != count:
                failures.append(f"ratchet its row to baseline <unit> {count}")
    if row is not None and count > row:
        failures.append(f"{count} tokens, baseline {row} (grew; split it)")
    elif row is None and count > LIMIT:
        failures.append(f"{count} tokens, limit {LIMIT} (split it)")
    if touched and count >= 40_000:
        warnings.append(f"{count:,}/{LIMIT:,} tokens " + (f"({LIMIT - count:,} left); split it along a seam" if count <= LIMIT else "(over the limit)"))
    return failures, warnings


def default_branch():
    d = os.environ.get("CRATE_TOKENS_DEFAULT_BRANCH", "")
    head = git("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", check=False)
    cands = ([f"origin/{d}", d] if d else []) + [head.decode().strip() if head else ""]
    for b in cands + ["origin/main", "origin/master"]:
        if b and git("rev-parse", "-q", "--verify", f"{b}^{{commit}}", check=False):
            return b
    return None


def resolve_base(base):
    if base.strip("0"):
        if git("cat-file", "-e", f"{base}^{{commit}}", check=False) is not None:
            return base
    else:
        d = default_branch()
        mb = git("merge-base", "HEAD", d, check=False) if d else None
        if mb:
            return mb.decode().strip()
    raise ConfigError("base unavailable; fetch the base/default branch before checking")


def configs_at(ref):
    entries = {}
    for rec in git("ls-tree", "-r", "-z", ref, "--", CONFIG, "projects/").split(b"\0"):
        if rec:
            meta, path = rec.split(b"\t", 1)
            entries[path.decode("utf-8", "surrogateescape")] = meta.split()
    names = tree_config_names(entries)
    wanted = {p: entries[p][2].decode() for p in names if p in entries}
    if any(entries[p][0] not in (b"100644", b"100755") for p in wanted):
        raise ConfigError("config files must be regular files")
    blobs = batch_blobs(wanted.values())
    return load_configs(names, lambda p: blobs.get(wanted.get(p)))


def config_delta(old, new):
    added, candidates = [], set()
    for name, (exempt, rows) in new.items():
        old_exempt, old_rows = old.get(name, ([], {}))
        pre = prefix_of(name)
        added += [(name, f"new exempt line {g[len(pre):]}") for g in exempt if g not in old_exempt]
        for u, n in sorted(rows.items()):
            if u not in old_rows:
                candidates.add(u)
                added.append((name, f"new baseline row {u} {n}"))
            elif n > old_rows[u]:
                added.append((name, f"baseline row {u} raised from {old_rows[u]} to {n}"))
    return added, candidates


def compare_base(base, per):
    base = resolve_base(base)
    return base, config_delta(configs_at(base)[2], per)[0]


def sync_tip(base, *tip):  # sync-tip.sh: without TIP, whether the refs allow a sync; with it, the tip or ""
    env = [os.environ.get(f"CRATE_TOKENS_{n}", "") for n in ("DEFAULT_BRANCH", "REPO", "HEAD_REPO", "BASE_REF", "HEAD_REF")]
    r = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync-tip.sh"), *env, base, *tip], capture_output=True, check=False)
    if r.returncode not in (0, 1) or tip and r.returncode:
        raise ConfigError(f"sync-tip.sh beside the engine failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout.decode().strip() if tip else r.returncode == 0


def accepted_per(base, tip, per):
    """BASE's config lines, plus in a sync (see the top) the tip's, a row at the higher value."""
    sha = sync_tip(base, tip)
    if not sha:
        return per
    merged = {name: (list(exempt), dict(rows)) for name, (exempt, rows) in per.items()}
    for name, (exempt, rows) in configs_at(sha)[2].items():
        old_exempt, old_rows = merged.setdefault(name, ([], {}))
        old_exempt += [g for g in exempt if g not in old_exempt]
        old_rows.update({u: max(n, old_rows.get(u, 0)) for u, n in rows.items()})
    return merged


def historical_units(base):
    """One accepted-history walk, one blob batch. Never include the PR's new ancestry."""
    if git("rev-parse", "--is-shallow-repository").strip() != b"false" or git(
            "config", "--get-regexp", r"^(remote\..*\.(promisor|partialclonefilter)|extensions\.partialclone)$", check=False):
        raise ConfigError("allowance history incomplete; fetch full base/default history without filters")
    default = default_branch()
    if not default:
        raise ConfigError("default branch unavailable; fetch full base/default history")
    raw = git("log", "--format=", "--full-history", "-m", "--root", "--raw", "-z",
              "--no-renames", "--no-abbrev", base, default, "--", CONFIG,
              ":(glob)projects/*/" + CONFIG).split(b"\0")
    pairs, i = set(), 0
    while i < len(raw):
        meta = raw[i].strip()
        i += 1
        if not meta:
            continue
        if not meta.startswith(b":") or i == len(raw):
            raise ConfigError("could not parse accepted config history")
        path = raw[i].decode("utf-8", "surrogateescape")
        i += 1
        if path not in tree_config_names([path]):
            continue
        fields = meta[1:].split()
        for oid in fields[2:4]:
            if oid.strip(b"0"):
                pairs.add((oid.decode(), path))
    blobs, units = batch_blobs(o for o, _ in pairs), set()
    for oid, path in sorted(pairs):
        units.update(parse_config(blobs[oid].decode("utf-8"), path, prefix_of(path))[1])
    return units


def check_range(base, tip="HEAD", units=None):
    """Shared release/hook entry point: (counts, failures, warnings). Units are raw paths.
    The hook supplies its union of old/new owning units; no unrelated source is measured."""
    base = resolve_base(base)
    old_exempt, old_rows, old_per = configs_at(base)
    exempt, rows, per = configs_at(tip)
    added, candidates = config_delta(accepted_per(base, tip, old_per), per)
    failures = [f"{name}: {message}" for name, message in added]
    if candidates:
        try:
            reused = candidates & historical_units(base)
            failures += [f"{u}: baseline path appeared in accepted history; allowances cannot be re-added" for u in sorted(reused)]
        except (ConfigError, UnicodeError, subprocess.CalledProcessError) as err:
            failures.append(f"allowance history could not be proven: {err}")
    old, new = Tree(base, units), Tree(tip, units)
    touched = old.touched(new, old_exempt, exempt)
    selected = None if units is None else set(units)
    counts = new.measure(exempt, selected)
    before = old.measure(old_exempt, touched & set(old_rows))
    warnings = []
    for u in sorted(set(counts) | (set(old_rows) & touched)):
        if selected is not None and u not in selected:
            continue
        errors, notes = unit_verdict(counts.get(u, (0,))[0], rows.get(u),
                                    old_count=before.get(u, (0,))[0], old_row=old_rows.get(u),
                                    touched=u in touched, exists=u in new.units)
        failures += [f"{u}: {m}" for m in errors]
        warnings += [f"{u}: {m}" for m in notes]
    return counts, failures, warnings


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")
    mode = argv[0] if argv else "all"
    if mode in ("-h", "--help") and len(argv) == 1:
        with open(__file__, encoding="utf-8") as f:
            lines = f.read().split("# ///\n", 2)[-1].splitlines()
        for line in lines[: next(i for i, x in enumerate(lines) if not x.startswith("#"))]:
            print(line[2:])
        return 0
    valid = (mode in ("all", "--report", "--print-baseline") and len(argv) <= 1
             or mode == "--ci" and len(argv) == 2
             or mode == "--range" and len(argv) >= 4
             or mode == "--history-needed" and len(argv) in (2, 3))
    if not valid:
        print("usage: check-crate-tokens.py [--report | --print-baseline | --ci BASE |"
              " --range BASE TIP UNIT... | --history-needed BASE [TIP]]", file=sys.stderr)
        return 2
    os.chdir(git("rev-parse", "--show-toplevel").decode().strip())
    if mode == "--history-needed":
        base = resolve_base(argv[1])
        added, candidates = config_delta(configs_at(base)[2], configs_at(argv[2] if len(argv) == 3 else "HEAD")[2])
        candidates = bool(candidates or added and sync_tip(base))  # telling a sync apart needs full history
        print("crate-tokens: complete accepted history " + ("required" if candidates else "not needed"))
        return 3 if candidates else 0
    if mode in ("--ci", "--range"):
        counts, failures, warnings = check_range(argv[1], argv[2] if mode == "--range" else "HEAD",
                                                {normalise_unit(u) for u in argv[3:]} if mode == "--range" else None)
    else:
        exempt, rows, per = load_configs(config_names())
        counts = measure(exempt)
        failures, warnings = [], []
        if mode == "--report":
            print(f"{'tokens':>8} {'files':>6} {'migrations':>10}  unit")
            for u, (n, f, m) in sorted(counts.items(), key=lambda kv: (-kv[1][0], kv[0])):
                print(f"{n:>8} {f:>6} {m:>10}  {escape(u)}")
            return 0
        if mode == "--print-baseline":
            for u in sorted(counts):
                if counts[u][0] > LIMIT:
                    print(f"baseline {escape(u)} {counts[u][0]}")
            return 0
        src = {u: name for name, (_, r) in per.items() for u in r}
        for u in sorted(counts):
            n = counts[u][0]
            failures += [f"{u}: {m}" for m in unit_verdict(n, rows.get(u))[0]]
            if u in rows and n < rows[u]:
                action = f"delete its {src[u]} row" if n <= LIMIT else f'lower its row to "baseline {u} {n}"'
                print("note: " + escape(f"{u}: {n} tokens; {action}"))
        for u in sorted(set(rows) - set(counts)):
            print("note: " + escape(f"{src[u]} row for {u} matches no unit; delete it"))
    for tag, messages in (("WARN", warnings), ("FAIL", failures)):
        for message in messages:
            print(f"[{tag}] {escape(message)}")
    if failures:
        print(f"crate-tokens: {len(failures)} failure(s); limit {LIMIT} Claude tokens per unit; split it, see --report")
        return 1
    print(f"crate-tokens: {len(counts)} unit(s) checked, each within its budget")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ConfigError, UnicodeError, subprocess.CalledProcessError) as err:
        print(f"[FAIL] crate-tokens: {escape(str(err))}", file=sys.stderr)
        sys.exit(1 if isinstance(err, ConfigError) else 2)
