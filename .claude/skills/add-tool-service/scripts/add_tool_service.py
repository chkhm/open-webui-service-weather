#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
"""
Deterministic edits for adding a tool service to this Open WebUI setup.

    add_tool_service.py validate [--name N --port P --operation-id ID]
    add_tool_service.py add --name N --port P --operation-id ID \\
        --info-description TEXT [--secret VAR [--secret-comment TEXT]] \\
        [--dry-run] [--force]

`validate` checks the repository for the collisions Open WebUI would not report
(duplicate ports, container names and operationIds; connection urls with a path)
and, given a proposal, that the proposal is free as well.

`add` appends the service to docker-compose.yml, appends its connection to
TOOL_SERVER_CONNECTIONS, extends open-webui's depends_on, adds the container to
CONTAINERS in scripts/health-check.sh and, with --secret, appends the variable to
.env.example. Existing entries are never modified or reordered. The connections
JSON is re-parsed from the rewritten YAML before anything is written.

Standard library only: PyYAML is not guaranteed on the development machine, and
the compose file has a fixed, known shape.
"""

import argparse
import difflib
import json
import py_compile
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

REPO = Path(__file__).resolve().parents[4]
COMPOSE = REPO / "docker-compose.yml"
HEALTH = REPO / "scripts" / "health-check.sh"
ENV_EXAMPLE = REPO / ".env.example"
PREFIX = "TOOL_SERVER_CONNECTIONS="

NAME_RE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
OPID_RE = re.compile(r"^[a-z][a-z0-9_]*$")


class Fail(Exception):
    pass


def ok(msg):
    print(f"  [ ok ] {msg}")


def fail(msg):
    print(f"  [FAIL] {msg}")


# --------------------------------------------------------------------------
# docker-compose.yml: the TOOL_SERVER_CONNECTIONS folded scalar
# --------------------------------------------------------------------------

def find_connections_block(lines):
    """Return (dash_idx, content_start, content_end, content_indent)."""
    for i, line in enumerate(lines):
        if line.strip() != "- >-" or i + 1 >= len(lines):
            continue
        if not lines[i + 1].strip().startswith(PREFIX):
            continue
        dash_indent = len(line) - len(line.lstrip())
        j = i + 1
        while j < len(lines):
            cur = lines[j]
            if not cur.strip():
                break
            if len(cur) - len(cur.lstrip()) <= dash_indent:
                break
            j += 1
        content_indent = len(lines[i + 1]) - len(lines[i + 1].lstrip())
        return i, i + 1, j, content_indent
    raise Fail("TOOL_SERVER_CONNECTIONS folded scalar not found in docker-compose.yml "
               "(expected a '- >-' line followed by 'TOOL_SERVER_CONNECTIONS=')")


def fold(lines):
    """Join a YAML folded scalar the way YAML does: stripped lines, single spaces."""
    return " ".join(line.strip() for line in lines)


def read_connections(lines):
    _, start, end, _ = find_connections_block(lines)
    text = fold(lines[start:end])
    if not text.startswith(PREFIX):
        raise Fail("folded scalar does not start with TOOL_SERVER_CONNECTIONS=")
    try:
        return json.loads(text[len(PREFIX):])
    except json.JSONDecodeError as e:
        raise Fail(f"TOOL_SERVER_CONNECTIONS is not valid JSON as written: {e}")


def render_connections(conns, indent, width=76):
    """Render the array as folded-scalar lines, wrapping at ', ' boundaries.

    A line ending in ',' followed by a line starting with the next piece folds back
    to ', ' exactly, so the wrapped form is byte-identical to json.dumps once folded.
    """
    body = PREFIX + json.dumps(conns)
    pieces = body.split(", ")
    out, cur = [], ""
    for piece in pieces:
        candidate = piece if not cur else cur + ", " + piece
        if cur and len(candidate) > width:
            out.append(cur + ",")
            cur = piece
        else:
            cur = candidate
    out.append(cur)
    pad = " " * indent
    return [pad + line for line in out]


def render_entry(entry, indent, width=76):
    """Render one entry as folded-scalar lines; the last line closes the array."""
    body = json.dumps(entry) + "]"
    pieces = body.split(", ")
    out, cur = [], ""
    for piece in pieces:
        candidate = piece if not cur else cur + ", " + piece
        if cur and len(candidate) > width:
            out.append(cur + ",")
            cur = piece
        else:
            cur = candidate
    out.append(cur)
    pad = " " * indent
    return [pad + line for line in out]


def replace_connections(lines, conns):
    """Rewrite the folded scalar so it holds `conns`.

    Prefer appending: keep every existing line untouched except the final ']',
    which becomes ',' so the new entry's lines can follow. Fall back to a full
    re-render only if the block does not end the way it is expected to.
    """
    _, start, end, indent = find_connections_block(lines)
    existing = read_connections(lines)
    last = lines[end - 1]
    if conns[:len(existing)] == existing and len(conns) == len(existing) + 1 and last.rstrip().endswith("]"):
        head = lines[start:end - 1] + [last.rstrip()[:-1] + ","]
        new_block = head + render_entry(conns[-1], indent)
    else:
        new_block = render_connections(conns, indent)
    # Round-trip: what YAML will fold must parse back to exactly what we meant.
    check = fold(new_block)
    if json.loads(check[len(PREFIX):]) != conns:
        raise Fail("internal error: rendered TOOL_SERVER_CONNECTIONS does not round-trip")
    return lines[:start] + new_block + lines[end:]


def connection_entry(name, port, operation_id, info_description):
    return {
        "url": f"http://{name}-proxy:{port}",
        "path": "openapi.json",
        "type": "openapi",
        "auth_type": "bearer",
        "headers": None,
        "key": "",
        "spec_type": "url",
        "spec": "",
        "config": {"enable": True, "function_name_filter_list": "", "access_grants": []},
        "info": {"id": "", "name": operation_id, "description": info_description},
    }


# --------------------------------------------------------------------------
# docker-compose.yml: service block and depends_on
# --------------------------------------------------------------------------

def service_block(name, port, secret, secret_comment):
    svc = f"{name}-proxy"
    block = [
        f"  {svc}:",
        f"    build: ./{svc}",
        f"    container_name: {svc}",
        "    restart: unless-stopped",
    ]
    if secret:
        comment = f"   # from .env{': ' + secret_comment if secret_comment else ''}"
        block += [
            "    environment:",
            f"      - {secret}=${{{secret}}}{comment}",
        ]
    block += [
        "    expose:",
        f'      - "{port}"',
        "    # Stable DNS name for the other services",
        "    networks:",
        "      default:",
        "        aliases:",
        f"          - {svc}",
    ]
    return block


def insert_service(lines, block):
    for k, line in enumerate(lines):
        if line.rstrip() == "networks:":
            lead = [] if (k > 0 and not lines[k - 1].strip()) else [""]
            return lines[:k] + lead + block + [""] + lines[k:]
    raise Fail("top-level 'networks:' not found in docker-compose.yml")


def service_bounds(lines, service):
    start = next((i for i, l in enumerate(lines) if l.rstrip() == f"  {service}:"), None)
    if start is None:
        raise Fail(f"service '{service}' not found in docker-compose.yml")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        cur = lines[i]
        if cur.strip() and len(cur) - len(cur.lstrip()) <= 2:
            end = i
            break
    return start, end


def add_depends_on(lines, svc):
    """Append the service to open-webui's depends_on, in whichever form it uses.

    Short form:  `      - name`
    Long form:   `      name:` followed by `        condition: ...` (and possibly
                 `required: false` for optional services like ollama).
    """
    start, end = service_bounds(lines, "open-webui")
    dep = next((i for i in range(start, end) if lines[i].rstrip() == "    depends_on:"), None)
    if dep is None:
        raise Fail("open-webui has no 'depends_on:' list")
    # The block runs until a blank line or the next key at the service level.
    j = dep + 1
    while j < end and lines[j].strip() and (len(lines[j]) - len(lines[j].lstrip())) > 4:
        j += 1
    block = [l.strip() for l in lines[dep + 1:j]]
    if any(l.startswith("- ") for l in block):
        if f"- {svc}" in block:
            return lines
        return lines[:j] + [f"      - {svc}"] + lines[j:]
    if f"{svc}:" in block:
        return lines
    return lines[:j] + [f"      {svc}:", "        condition: service_started"] + lines[j:]


# --------------------------------------------------------------------------
# scripts/health-check.sh and .env.example
# --------------------------------------------------------------------------

def add_container(text, svc):
    m = re.search(r"^CONTAINERS=\((.*)\)$", text, re.M)
    if not m:
        raise Fail("CONTAINERS=(...) line not found in scripts/health-check.sh")
    items = m.group(1).split()
    if svc in items:
        return text
    items.append(svc)
    return text[:m.start()] + "CONTAINERS=(" + " ".join(items) + ")" + text[m.end():]


def add_env_example(text, var, comment):
    if re.search(rf"^{re.escape(var)}=", text, re.M):
        return text
    block = "\n" + (f"# {comment}\n" if comment else "") + f"{var}=\n"
    return text.rstrip("\n") + "\n" + block


# --------------------------------------------------------------------------
# Repository inspection for validation
# --------------------------------------------------------------------------

def compose_ports(lines):
    """Container-side ports declared under expose: and ports:, with the service."""
    found, mode, service = [], None, None
    for line in lines:
        s = line.strip()
        indent = len(line) - len(line.lstrip())
        if indent == 2 and s.endswith(":") and not s.startswith("-"):
            service = s[:-1]
        if indent == 4 and s in ("expose:", "ports:"):
            mode = s[:-1]
            continue
        if mode and s.startswith("- "):
            val = s[2:].strip().strip('"').strip("'")
            container_side = val.split(":")[-1].split("/")[0]
            if container_side.isdigit():
                found.append((int(container_side), mode, service))
            continue
        if mode and (not s or indent <= 4):
            mode = None
    return found


def container_names(lines):
    names = []
    for line in lines:
        s = line.strip()
        if s.startswith("container_name:"):
            names.append(s.split(":", 1)[1].strip().strip('"').strip("'"))
    return names


def operation_ids():
    found = []
    for py in sorted(REPO.glob("*-proxy/*_service.py")):
        for m in re.finditer(r'"operationId":\s*"([^"]+)"', py.read_text()):
            found.append((m.group(1), str(py.relative_to(REPO))))
    return found


def tracked_changes():
    out = subprocess.run(["git", "status", "--porcelain"], cwd=REPO,
                         capture_output=True, text=True, check=True).stdout
    return [l for l in out.splitlines() if not l.startswith("??")]


def validate(name=None, port=None, operation_id=None, own_files_expected=False):
    """Check the repository, and a proposal if given.

    own_files_expected: the proposal's directory and service file may already
    exist (the skill writes the service before wiring it), so do not count them
    as collisions.
    """
    problems = 0

    def check(cond, good, bad):
        nonlocal problems
        if cond:
            ok(good)
        else:
            fail(bad)
            problems += 1

    lines = COMPOSE.read_text().splitlines()

    ports = compose_ports(lines)
    nums = [p for p, _, _ in ports]
    dupes = sorted({p for p in nums if nums.count(p) > 1})
    check(not dupes, f"ports unique: {', '.join(f'{p} ({s})' for p, _, s in ports)}",
          f"duplicate container ports: {dupes}")

    names = container_names(lines)
    dupes = sorted({n for n in names if names.count(n) > 1})
    check(not dupes, f"container names unique: {', '.join(names)}",
          f"duplicate container names: {dupes}")

    ops = operation_ids()
    ids = [o for o, _ in ops]
    dupes = sorted({o for o in ids if ids.count(o) > 1})
    check(not dupes, f"operationIds unique: {', '.join(f'{o} ({f})' for o, f in ops)}",
          f"duplicate operationIds (Open WebUI would silently rename): {dupes}")

    try:
        conns = read_connections(lines)
        urls = [c.get("url", "") for c in conns]
        with_path = [u for u in urls if urlparse(u).path not in ("",) or u.endswith("/")]
        check(not with_path, f"connection urls are service roots: {', '.join(urls)}",
              f"connection urls must be the service root, no path: {with_path}")
        dupes = sorted({u for u in urls if urls.count(u) > 1})
        check(not dupes, "connection urls unique", f"duplicate connection urls: {dupes}")
    except Fail as e:
        fail(str(e))
        problems += 1
        conns, urls = [], []

    r = subprocess.run(["bash", "-n", str(HEALTH)], capture_output=True, text=True)
    check(r.returncode == 0, "scripts/health-check.sh parses", f"bash -n failed: {r.stderr.strip()}")

    for py in sorted(REPO.glob("*-proxy/*_service.py")):
        try:
            py_compile.compile(str(py), doraise=True)
            ok(f"{py.relative_to(REPO)} compiles")
        except py_compile.PyCompileError as e:
            fail(f"{py.relative_to(REPO)} does not compile: {e.msg}")
            problems += 1

    own_dir = f"{name}-proxy/" if name else None
    if name is not None:
        svc = f"{name}-proxy"
        check(bool(NAME_RE.match(name)), f"name '{name}' is well-formed",
              f"name '{name}' must be lower-case letters, digits and single hyphens")
        check(svc not in names, f"container name '{svc}' is free", f"container '{svc}' already exists")
        if own_files_expected:
            ok(f"directory '{svc}/' may already exist (service written first)")
        else:
            check(not (REPO / svc).exists(), f"directory '{svc}/' does not exist yet",
                  f"directory '{svc}/' already exists")
        check(f"http://{svc}:{port}" not in urls, f"connection url for {svc} not yet stored",
              f"a connection for http://{svc}:{port} already exists")
    if port is not None:
        check(port not in nums, f"port {port} is free", f"port {port} is already used")
    if operation_id is not None:
        check(bool(OPID_RE.match(operation_id)), f"operationId '{operation_id}' is snake_case",
              f"operationId '{operation_id}' must be snake_case")
        # The proposal's own service file legitimately declares the id.
        others = [o for o, f in ops if not (own_files_expected and own_dir and f.startswith(own_dir))]
        check(operation_id not in others, f"operationId '{operation_id}' is free",
              f"operationId '{operation_id}' already exists")

    return problems


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_validate(args):
    print("validating repository" + (f" and proposal {args.name}" if args.name else ""))
    problems = validate(args.name, args.port, args.operation_id)
    print()
    if problems:
        print(f"{problems} problem(s)")
        return 1
    print("all clear")
    return 0


def cmd_add(args):
    if not args.force:
        changes = tracked_changes()
        if changes:
            print("tracked files are modified; commit or stash first (or --force):")
            for c in changes:
                print("  " + c)
            return 1

    print("preflight")
    if validate(args.name, args.port, args.operation_id, own_files_expected=True):
        print("\nnot adding: fix the problems above first")
        return 1

    svc = f"{args.name}-proxy"

    compose_old = COMPOSE.read_text()
    lines = compose_old.splitlines()
    conns = read_connections(lines)
    conns.append(connection_entry(args.name, args.port, args.operation_id, args.info_description))
    lines = replace_connections(lines, conns)
    lines = add_depends_on(lines, svc)
    lines = insert_service(lines, service_block(args.name, args.port, args.secret, args.secret_comment))
    compose_new = "\n".join(lines) + "\n"

    health_old = HEALTH.read_text()
    health_new = add_container(health_old, svc)

    env_old = ENV_EXAMPLE.read_text() if ENV_EXAMPLE.exists() else ""
    env_new = add_env_example(env_old, args.secret, args.secret_comment) if args.secret else env_old

    edits = [(COMPOSE, compose_old, compose_new), (HEALTH, health_old, health_new)]
    if args.secret:
        edits.append((ENV_EXAMPLE, env_old, env_new))

    print()
    for path, old, new in edits:
        rel = path.relative_to(REPO)
        if old == new:
            print(f"{rel}: no change")
            continue
        diff = difflib.unified_diff(old.splitlines(), new.splitlines(),
                                    fromfile=f"a/{rel}", tofile=f"b/{rel}", lineterm="")
        print("\n".join(diff))
        print()

    if args.dry_run:
        print("(dry run, nothing written)")
        return 0

    for path, old, new in edits:
        if old != new:
            path.write_text(new)
            print(f"wrote {path.relative_to(REPO)}")

    print("\npost-check")
    problems = validate()
    written = read_connections(COMPOSE.read_text().splitlines())
    if written[-1].get("url") == f"http://{svc}:{args.port}" and len(written) == len(conns):
        ok(f"TOOL_SERVER_CONNECTIONS now has {len(written)} entries, last is {svc}")
    else:
        fail("TOOL_SERVER_CONNECTIONS did not come back as expected")
        problems += 1

    print()
    if problems:
        print(f"{problems} problem(s) after writing; inspect the diff above")
        return 1
    todo = []
    if not (REPO / svc / f"{args.name}_service.py").exists():
        todo.append(f"write {svc}/{args.name}_service.py and {svc}/Dockerfile")
    if f"check_{args.name}_proxy" not in HEALTH.read_text():
        todo.append(f"add check_{args.name}_proxy to scripts/health-check.sh and call it")
    todo.append("update README.md")
    print("done. next: " + "; ".join(todo))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate", help="check the repository (and optionally a proposal) for collisions")
    v.add_argument("--name")
    v.add_argument("--port", type=int)
    v.add_argument("--operation-id")
    v.set_defaults(func=cmd_validate)

    a = sub.add_parser("add", help="wire a new service into compose, the health check and .env.example")
    a.add_argument("--name", required=True, help="service name; directory and container become <name>-proxy")
    a.add_argument("--port", type=int, required=True)
    a.add_argument("--operation-id", required=True)
    a.add_argument("--info-description", required=True, help="short phrase shown in the admin UI")
    a.add_argument("--secret", help="environment variable name for an upstream key, if any")
    a.add_argument("--secret-comment", help="where to obtain the key; written to .env.example")
    a.add_argument("--dry-run", action="store_true")
    a.add_argument("--force", action="store_true", help="proceed even if tracked files are modified")
    a.set_defaults(func=cmd_add)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
