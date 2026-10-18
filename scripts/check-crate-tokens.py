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
#   check-crate-tokens.py --report         every unit's count, largest first
#   check-crate-tokens.py --print-baseline "baseline <unit> <tokens>" for every unit over
#                                          the limit
#   check-crate-tokens.py --ci BASE        the working tree, and .crate-tokens may not add
#                                          or raise baseline rows or add exempt lines
#                                          compared with BASE unless
#                                          CRATE_TOKENS_EXCEPTION=true (the PR label)
# An all-zero or missing BASE falls back to the merge-base with the default branch
# (CRATE_TOKENS_DEFAULT_BRANCH, else origin/HEAD, origin/main or origin/master).
# Run with: uv run --script scripts/check-crate-tokens.py [mode], or through
# scripts/check-crate-tokens.sh, which also works piped from curl (see GRANDFATHER).
# .crate-tokens lines (# starts a comment):
#   exempt <glob>              generated or vendored paths; * is one path segment,
#                              ** any depth, ? one character, the rest literal
#   baseline <unit> <tokens>   a grandfathered unit ("." for the repository root);
#                              the unit fails once it grows past its row
# Each projects/<p>/.crate-tokens adds lines relative to its folder ("." is the folder) and
# is never counted itself; each config file may only shrink against the same file at BASE.
# Never counted: lockfiles, *.d.ts, source maps, minified files, snapshots, SVGs,
# OpenAPI and Swagger documents (openapi*.json, swagger*.yaml and so on), the org-vendored .githooks/org/, anything under target, node_modules, dist, build, .svelte-kit, .next, coverage,
# .sqlx or openapi directories, files that say "@generated" or "DO NOT EDIT" near
# the top, binaries, symlinks and submodules.
import json
import os
import re
import subprocess
import sys

LIMIT = 50_000
CONFIG = ".crate-tokens"
PROJECT = re.compile(r"[A-Za-z0-9._-]+\Z")  # a projects/<p> folder that may hold a config
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
API_SPEC = re.compile(r"(openapi|swagger)[^/]*\.(json|ya?ml)\Z", re.IGNORECASE)
GENERATED_MARK = re.compile(rb"@generated|DO NOT EDIT")
PACKAGE_TABLE = re.compile(rb"^[ \t]*\[package\][ \t]*(#.*)?\r?$", re.MULTILINE)
# Control characters in a unit path print as \xNN escapes, so a directory name cannot start
# a new output line (and with it a "::" workflow command).
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


GRANDFATHER = """\
crate-tokens: to grandfather units that were already over the limit, run this at the
repository root (it needs uv), then commit .crate-tokens:
    curl -fsSL https://raw.githubusercontent.com/malcomsonbrothers/org-checks/master/scripts/check-crate-tokens.sh |
      bash -s -- --print-baseline >> .crate-tokens
The pull request that adds baseline rows needs the crate-tokens-exception label; after adding
it, close and reopen the pull request so the check re-runs."""


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
            unit = w[1].rstrip("/") or "."
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


def prefix_of(name):
    return name[: -len(CONFIG)]


def config_names():
    """.crate-tokens and each projects/<p>/.crate-tokens in the working tree."""
    names = [CONFIG]
    if os.path.isdir("projects"):
        names += sorted(f"projects/{d}/{CONFIG}" for d in os.listdir("projects")
                        if PROJECT.match(d) and os.path.isfile(f"projects/{d}/{CONFIG}"))
    return names


def load_configs(names):
    """Returns (exempt globs, {unit: tokens}, {config name: (exempt, rows)}) for every config;
    raises ConfigError on bad lines or a unit with rows in two files."""
    exempt, rows, per, errors = [], {}, {}, []
    for name in names:
        try:
            e, r = parse_config(read_text(name), name, prefix_of(name))
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
    if path.startswith(VENDORED) or (len(parts) == 3 and parts[0] == "projects" and name == CONFIG):
        return True
    return any(r.match(path) for r in exempt_res)


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


def workspace_root(path, paths):
    """A package.json with "workspaces", or beside pnpm-workspace.yaml, is like a Cargo virtual
    manifest: it only lists packages, so it is not a unit itself."""
    if path.rsplit("/", 1)[0] + "/pnpm-workspace.yaml" in paths or (
        path == "package.json" and "pnpm-workspace.yaml" in paths
    ):
        return True
    try:
        manifest = json.loads(read(path) or b"")
    except ValueError:
        return False
    return isinstance(manifest, dict) and "workspaces" in manifest


def discover(paths):
    """Unit directories: a Cargo.toml with [package], or a package.json that is not only a
    workspace root, outside build output and node_modules."""
    units, present = set(), set(paths)
    for p in paths:
        parts = p.split("/")
        if any(q in SKIP_DIRS for q in parts[:-1]):
            continue
        d = "/".join(parts[:-1]) or "."
        if parts[-1] == "package.json":
            if not workspace_root(p, present):
                units.add(d)
        elif parts[-1] == "Cargo.toml":
            data = read(p)
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


def measure(exempt):
    out = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    paths = sorted(set(filter(None, out.decode("utf-8", "surrogateescape").split("\0"))))
    units = discover(paths)
    exempt_res = [glob_re(g) for g in exempt]
    owners, texts = [], []
    for p in paths:
        u = owner(p, units)
        if u is None or skipped(p, exempt_res):
            continue
        data = read(p)
        if data is None or b"\0" in data or GENERATED_MARK.search(data[:1024]):
            continue
        try:
            texts.append(data.decode("utf-8"))
        except UnicodeDecodeError:
            continue
        owners.append(u)
    counts = {u: [0, 0] for u in units}
    if texts:
        import tiktoken

        enc = tiktoken.get_encoding("o200k_base")
        for u, toks in zip(owners, enc.encode_ordinary_batch(texts)):
            counts[u][0] += len(toks)
            counts[u][1] += 1
    return {escape(u): ((raw * 3 + 1) // 2, files) for u, (raw, files) in counts.items()}


def default_branch():
    d = os.environ.get("CRATE_TOKENS_DEFAULT_BRANCH", "")
    head = git("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", check=False)
    cands = ([f"origin/{d}", d] if d else []) + [head.decode().strip() if head else ""]
    for b in cands + ["origin/main", "origin/master"]:
        if b and git("rev-parse", "-q", "--verify", f"{b}^{{commit}}", check=False):
            return b
    return None


def resolve_base(base):
    if base.strip("0") and git("cat-file", "-e", f"{base}^{{commit}}", check=False) is not None:
        return base
    d = default_branch()
    mb = git("merge-base", "HEAD", d, check=False) if d else None
    return mb.decode().strip() if mb else None


def compare_base(base, per):
    """(config name, line) for each line a config file added or raised compared with the same
    file at BASE."""
    base = resolve_base(base)
    added = []
    for name, (exempt, rows) in per.items():
        pre = prefix_of(name)
        old_text = git("show", f"{base}:{name}", check=False) if base else None
        try:
            old_exempt, old_rows = parse_config((old_text or b"").decode(), f"{base}:{name}", pre)
        except ConfigError:
            old_exempt, old_rows = [], {}  # a broken base config grandfathers nothing
        added += [(name, f"new exempt line {g[len(pre):]}") for g in exempt if g not in old_exempt]
        for u, n in sorted(rows.items()):
            if u not in old_rows:
                added.append((name, f"new baseline row {u} {n}"))
            elif n > old_rows[u]:
                added.append((name, f"baseline row {u} raised from {old_rows[u]} to {n}"))
    return base, added


def main(argv):
    for stream in (sys.stdout, sys.stderr):  # non-UTF-8 paths print as escapes, not a crash
        stream.reconfigure(errors="backslashreplace")
    mode = argv[0] if argv else "all"
    if mode not in ("all", "--report", "--print-baseline", "--ci") or (mode == "--ci") != (len(argv) == 2) \
            or (mode != "--ci" and len(argv) > 1):
        print("usage: check-crate-tokens.py [--report | --print-baseline | --ci BASE]", file=sys.stderr)
        return 2
    os.chdir(git("rev-parse", "--show-toplevel").decode().strip())
    try:
        exempt, rows, per = load_configs(config_names())
    except ConfigError as e:
        stream = sys.stderr if mode == "--print-baseline" else sys.stdout
        print("\n".join(f"[FAIL] {m}" for m in str(e).splitlines()), file=stream)
        return 1
    counts = measure(exempt)
    if mode == "--report":
        print(f"{'tokens':>8} {'files':>6}  unit")
        for u, (n, f) in sorted(counts.items(), key=lambda kv: (-kv[1][0], kv[0])):
            print(f"{n:>8} {f:>6}  {u}")
        return 0
    if mode == "--print-baseline":
        for u in sorted(counts):
            if counts[u][0] > LIMIT:
                print(f"baseline {u} {counts[u][0]}")
        return 0
    src = {u: name for name, (_, r) in per.items() for u in r}
    bad = 0
    for u in sorted(counts):
        n = counts[u][0]
        if u in rows:
            if n > rows[u]:
                print(f"[FAIL] {u}: {n} tokens, baseline {rows[u]} (grew; shrink it to {rows[u]} or fewer, or split it)")
                bad += 1
            elif n <= LIMIT:
                print(f"note: {u}: {n} tokens is within the limit {LIMIT}; delete its {src[u]} row")
            elif n < rows[u]:
                print(f"note: {u}: shrank to {n} tokens; lower its row to \"baseline {u} {n}\"")
        elif n > LIMIT:
            print(f"[FAIL] {u}: {n} tokens, limit {LIMIT} (split it)")
            bad += 1
    for u in sorted(set(rows) - set(counts)):
        print(f"note: {src[u]} row for {u} matches no unit; delete it")
    if mode == "--ci":
        base, added = compare_base(argv[1], per)
        allowed = os.environ.get("CRATE_TOKENS_EXCEPTION") == "true"
        for name, a in added:
            if allowed:
                print(f"crate-tokens: allowed by the crate-tokens-exception label: {a}")
            else:
                print(f"[FAIL] {name}: {a}")
                bad += 1
        if added and not allowed:
            print(f"crate-tokens: {CONFIG} may only shrink (compared with {base or 'nothing'}). A reviewer"
                  " allows a new or raised line by adding the crate-tokens-exception label to the pull"
                  " request, then closing and reopening it.")
    if bad:
        print(f"crate-tokens: {bad} failure(s); limit {LIMIT} Claude tokens (o200k_base x 1.5) per"
              " unit; see --report")
        print(GRANDFATHER)
        return 1
    print(f"crate-tokens: {len(counts)} unit(s) checked, each within its budget")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
