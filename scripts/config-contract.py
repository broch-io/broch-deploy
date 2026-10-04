#!/usr/bin/env python3
"""Configuration contract check: every template refuses exactly the settings Broch refuses at startup.

Broch publishes its startup rules (`--describe-config`) and judges a configuration without starting
(`--check-config --json`). This script derives cases from the rules alone, has each template render
what it would send Broch for each case, and asks Broch whether it would start with it. It fails when
  - a template accepts what Broch refuses (the deploy "succeeds", then crash-loops);
  - a template refuses what Broch accepts, beyond the strictness it declares (with its reason) in
    scripts/config-contract-targets.json;
  - a template changes a value on the way to Broch (quoting, interpolation, trimming);
  - a template accepts a deploy whose instance then never starts Broch (a boot gate, a missing secret).
Nothing here lists what Broch requires.

It fails closed too: on a rule field, check, condition or type it doesn't know; on a key a rule checks
that a template sends but the targets file doesn't account for; on a rule over a template input that
produced no case; on a case that doesn't violate the rule it was built to violate; on a Terraform,
compose or Azure error that isn't a refusal of the inputs; and on any template construct (an ARM
function, a CloudFormation intrinsic, a shell form in a boot script) it doesn't model.

Stdlib only, except cfn-lint's template reader for CloudFormation targets. Usage:
  python3 scripts/config-contract.py --oracle docker:ghcr.io/broch-io/broch:<version> [--target terraform/aws-ecs]
  python3 scripts/config-contract.py --oracle dotnet:/path/to/Broch.Api.dll

Requirements (each only for the targets that need it; a missing one stops the run with a message):
  - docker, with the compose plugin (the docker: oracle, compose targets, the instances' .env files);
  - terraform >= 1.7, with each module initialized (`terraform -chdir=terraform/<module> init -backend=false`);
  - cfn-lint for CloudFormation targets, at the version CFN_LINT_VERSION below names (`pip install
    cfn-lint==<that version>`);
  - az, logged in, with Bicep, for Bicep targets, and CONTRACT_AZURE_RESOURCE_GROUP naming a resource group
    to validate in (nothing is deployed). Without that variable the Bicep targets are skipped with a
    notice, unless named with --target.
"""
from __future__ import annotations

import argparse
import atexit
import base64
import concurrent.futures
import importlib.util
import itertools
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Iterator

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS_FILE = os.path.join(ROOT, "scripts", "config-contract-targets.json")
# The cfn-lint whose template reader verdicts are checked with (the one CI installs).
CFN_LINT_VERSION = "1.51.5"

Config = dict[str, str]


# ── Broch, the judge ────────────────────────────────────────────────────────────────────────────

class Oracle:
    """Runs the Broch image (or a local build) with --describe-config / --check-config."""

    def __init__(self, spec: str) -> None:
        kind, _, where = spec.partition(":")
        if kind not in ("docker", "dotnet") or not where:
            raise SystemExit(f"--oracle must be docker:<image> or dotnet:<Broch.Api.dll>, got {spec!r}")
        self.kind, self.where = kind, where

    def _run(self, args: list[str], env: Config) -> subprocess.CompletedProcess:
        for key, value in env.items():
            if not isinstance(value, str):
                raise TypeError(f"{key}: {value!r} is not a string")
        if self.kind == "docker":
            for key, value in env.items():
                if "\n" in value:
                    raise ValueError(f"{key}: an env file can't carry a multi-line value")
            fd, path = tempfile.mkstemp(suffix=".env", dir=os.environ.get("RUNNER_TEMP"))
            try:
                # docker's --env-file passes each value literally (no quoting, no trimming), as the
                # container platforms deliver plain settings. No network: the commands make no calls.
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.writelines(f"{key}={value}\n" for key, value in env.items())
                return subprocess.run(["docker", "run", "--rm", "--network", "none", "--env-file", path,
                                       self.where, *args], capture_output=True, text=True, timeout=180)
            finally:
                os.unlink(path)
        # A local build: only the case's settings plus what the runtime needs, so the developer's
        # shell can't leak configuration into the verdict.
        base = {k: v for k, v in os.environ.items()
                if k in ("PATH", "HOME", "DOTNET_ROOT", "DOTNET_CLI_HOME", "TMPDIR", "LANG")}
        return subprocess.run(["dotnet", self.where, *args], capture_output=True, text=True, timeout=180,
                              env={**base, **env}, cwd=os.path.dirname(os.path.abspath(self.where)))

    def rules(self) -> dict:
        r = self._run(["--describe-config"], {})
        if r.returncode != 0:
            raise SystemExit(f"--describe-config failed (an image without the command is too old):\n{r.stderr[-2000:]}")
        return json.loads(r.stdout)

    def check(self, env: Config) -> list[str]:
        """Broch's verdict on an environment: the ids of the rules it violates ([] = it would start)."""
        r = self._run(["--check-config", "--json"], env)
        try:
            result = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise RuntimeError(f"--check-config gave no verdict (exit {r.returncode}):\n{r.stdout[-1000:]}{r.stderr[-1000:]}")
        violations = [v["id"] for v in result["violations"]]
        if result["ok"] != (not violations) or (r.returncode == 0) != result["ok"]:
            raise RuntimeError(f"--check-config verdict is inconsistent (exit {r.returncode}): {r.stdout[-500:]}")
        return violations


# ── Cases, derived from the rules ───────────────────────────────────────────────────────────────

class Case:
    """A configuration to try. `rules` are the rules it was generated for; `expect` / `expect_not` are
    rules the published semantics say it must / must not violate (checked, so a case can't be vacuous)."""

    def __init__(self, name: str, config: Config, rule: str, mutated: str | None = None) -> None:
        self.name, self.config, self.mutated = name, config, mutated
        self.rules = {rule}
        self.expect: set[str] = set()
        self.expect_not: set[str] = set()


class Rules:
    COMMON = {"id", "check", "keys", "layer", "stage", "blank", "when", "summary"}
    CHECKS = {
        "required": set(), "minUtf8Bytes": {"minBytes"}, "base64MinBytes": {"minBytes"},
        "enum": {"type", "clrType", "allowedValues", "unsetValues"}, "positiveTimeSpan": set(),
        "binds": {"type", "clrType", "allowedValues", "unsetValues", "min", "max"}, "distinct": set(),
    }
    OPS = {"anySet": {"op", "keys", "layer"}, "blank": {"op", "keys", "layer"}, "in": {"op", "keys", "layer", "values"}}
    VALUES = {"blank": {"absent", "empty", "whitespace"}, "layer": {"environment", "effective"},
              "stage": {"startup", "afterDatabase"},
              "type": {"integer", "number", "boolean", "enum", "timeSpan", "uri", "guid", "dateTime", "other"}}

    def __init__(self, doc: dict) -> None:
        if doc.get("version") != 1:
            raise SystemExit(f"Unsupported --describe-config schema version {doc.get('version')}")
        self.all = doc["rules"]
        for rule in self.all:
            self._known(rule, rule["id"], self.COMMON | self.CHECKS.get(rule.get("check"), set()))
            if rule["check"] not in self.CHECKS:
                raise SystemExit(f"Rule {rule['id']}: unknown check {rule['check']!r}; teach scripts/config-contract.py")
            for c in rule["when"]:
                if c.get("op") not in self.OPS:
                    raise SystemExit(f"Rule {rule['id']}: unknown condition {c.get('op')!r}; teach scripts/config-contract.py")
                self._known(c, f"{rule['id']} ({c['op']})", self.OPS[c["op"]])
        # Keys whose value selects which rules apply (the provider): each combination gets a valid base.
        self.forking = sorted({c["keys"][0] for r in self.all for c in r["when"] if c["op"] == "in"})
        # Keys of the first-run gate: with none of them set, the conditional rules don't apply.
        self.gate = sorted({k for r in self.all for c in r["when"] if c["op"] == "anySet" for k in c["keys"]})

    def _known(self, item: dict, where: str, fields: set) -> None:
        """Fail closed on a field or value this script doesn't model (the schema adds them without a version bump)."""
        unknown = set(item) - fields
        if unknown:
            raise SystemExit(f"Rule {where}: unknown fields {sorted(unknown)}; teach scripts/config-contract.py")
        for field, allowed in self.VALUES.items():
            if field in item and item[field] not in allowed:
                raise SystemExit(f"Rule {where}: unknown {field} {item[field]!r}; teach scripts/config-contract.py")

    def typed_rule(self, key: str) -> dict | None:
        return next((r for r in self.all if r.get("type") and key in r["keys"]), None)

    def enum_rule(self, key: str) -> dict | None:
        rule = self.typed_rule(key)
        return rule if rule and rule["type"] == "enum" else None

    @staticmethod
    def unset_by(blank: str, value: str | None) -> bool:
        return value is None or (blank in ("empty", "whitespace") and value == "") \
            or (blank == "whitespace" and not value.strip())

    def is_set(self, config: Config, key: str, blank: str = "empty") -> bool:
        """Set, as the rules define it: `blank` (conditions use empty), and an enum key normalised by
        its own rule (its blank and its unset values)."""
        value = config.get(key)
        if self.unset_by(blank, value):
            return False
        rule = self.enum_rule(key)
        if rule is None:
            return True
        if self.unset_by(rule["blank"], value):
            return False
        return value.strip().lower() not in [v.lower() for v in rule.get("unsetValues") or []]

    def holds(self, rule: dict, config: Config) -> bool:
        for c in rule["when"]:
            if c["op"] == "in":
                if not self.is_set(config, c["keys"][0]) or \
                        config[c["keys"][0]].strip().lower() not in [v.lower() for v in c["values"]]:
                    return False
            elif c["op"] == "blank":
                if self.is_set(config, c["keys"][0]):
                    return False
            elif not any(self.is_set(config, k) for k in c["keys"]):  # anySet
                return False
        return True

    def valid_value(self, key: str) -> str:
        """A value every rule on the key accepts."""
        typed = self.typed_rule(key)
        if typed is not None:
            return {"enum": (typed.get("allowedValues") or [""])[0], "integer": "7", "number": "7.5",
                    "boolean": "true", "timeSpan": "00:15:00", "uri": "https://example.test/",
                    "guid": "00000000-0000-0000-0000-00000000000b", "dateTime": "2026-01-01T00:00:00Z",
                    }.get(typed["type"]) or self._raise(f"{key}: no valid sample for type {typed['type']!r}")
        checks = {r["check"]: r for r in self.all if key in r["keys"]}
        if "base64MinBytes" in checks:
            return _b64(checks["base64MinBytes"]["minBytes"])
        if "positiveTimeSpan" in checks:
            return "00:15:00"
        min_bytes = checks["minUtf8Bytes"]["minBytes"] if "minUtf8Bytes" in checks else 0
        return ("valid." + key.replace(":", "-").lower() + ".example.test").ljust(min_bytes, "k")

    @staticmethod
    def _raise(message: str):
        raise SystemExit(message + "; teach scripts/config-contract.py")

    def satisfy_required(self, config: Config, leave_unset: tuple = ()) -> Config:
        """Sets every required key whose conditions hold, until nothing more is required."""
        config = dict(config)
        changed = True
        while changed:
            changed = False
            for rule in self.all:
                key = rule["keys"][0]
                if rule["check"] == "required" and self.holds(rule, config) \
                        and not self.is_set(config, key, rule["blank"]) and key not in leave_unset:
                    config[key] = self.valid_value(key)
                    changed = True
        return config

    def forks(self) -> list[tuple[str, Config]]:
        """Assignments of the forking keys: none (first run), and every combination of their values."""
        values = []
        for key in self.forking:
            rule = self.enum_rule(key)
            if rule is None:
                raise SystemExit(f"{key} selects rules but no enum rule lists its values")
            values.append([(key, v) for v in rule["allowedValues"]])
        combos = [("first-run", {})]
        for combo in itertools.product(*values):
            combos.append((", ".join(f"{k}={v}" for k, v in combo), dict(combo)))
        return combos

    def values(self, rule: dict, key: str) -> list[tuple[str, str, bool | None]]:
        """Values to try for a rule's key, from its published check, type and limits, each with whether
        the published semantics say the rule passes it (None: they don't say; Broch decides)."""
        check, kind = rule["check"], rule.get("type")
        if check == "required":
            out = [("empty", "", None), ("spaces", "   ", None)]  # expectations() derives these from blank
            if self.typed_rule(key) is None:
                # Free text: what a template's quoting or interpolation could change on the way.
                out += [(label, value, None) for label, value in (
                    ("a dollar sign", "pa$NOPE"), ("only a variable", "$NOPE"), ("a quote", "it's"),
                    ("a double quote", 'say "hi"'), ("a hash", "a #b"), ("a trailing backslash", "ends\\"),
                    ("padded", " padded "))]
            return out
        # Every other check passes an unset value; an empty one is unset unless blank is absent.
        out = [("empty", "", rule["blank"] != "absent" or None),
               ("spaces", "   ", True if rule["blank"] == "whitespace" else None)]
        if check == "minUtf8Bytes":
            n = rule["minBytes"]
            out += [("one byte short", "k" * (n - 1), False), ("at the minimum", "k" * n, True),
                    ("multi-byte", "é" * math.ceil(n / 2), True)]
        elif check == "base64MinBytes":
            n = rule["minBytes"]
            out += [("not base64", "not base64!", False), ("one byte short", _b64(n - 1), False),
                    ("at the minimum", _b64(n), True)]
        elif check == "positiveTimeSpan":
            out += [("zero", "00:00:00", False), ("negative", "-00:00:01", False), ("positive", "00:00:01", True),
                    ("whole days", "2", True), ("not a duration", "fifteen minutes", False)]
        if kind == "enum":
            allowed = rule["allowedValues"]
            out += [("unknown value", "NotARealValue", False), ("undefined number", "999", False),
                    (f"{allowed[0]} padded", f" {allowed[0]} ", True)]
            out += [(f"{a} lowercase", a.lower(), True) for a in allowed]
            out += [(f"unset value {u}", u, True) for u in rule.get("unsetValues") or []]
            if len(allowed) >= 2:
                out.append(("comma list", f"{allowed[0]},{allowed[1]}", False))
        elif kind == "boolean":
            out += [("not a boolean", "maybe", False), ("true", "TRUE", True), ("false", "false", True)]
        elif kind == "integer":
            out += [("not a number", "seven", False), ("a number", "7", True), ("a fraction", "7.5", False)]
            if rule.get("max") is not None:
                out += [("the max", str(int(rule["max"])), True), ("above max", str(int(rule["max"]) + 1), False)]
            if rule.get("min") is not None:
                out += [("the min", str(int(rule["min"])), True), ("below min", str(int(rule["min"]) - 1), False)]
        elif kind == "number":
            out += [("not a number", "seven", False), ("a number", "7.5", True)]
        elif kind == "timeSpan":
            out += [("not a duration", "fifteen minutes", False), ("a duration", "00:15:00", True)]
        elif kind == "guid":
            out += [("not a GUID", "not-a-guid", False), ("a GUID", "00000000-0000-0000-0000-00000000000a", True)]
        elif kind == "uri":
            out += [("not a URI", "http://[::1", None), ("a URI", "https://example.test/", True)]
        elif kind == "dateTime":
            out += [("not a date", "someday", False), ("a date", "2026-01-01T00:00:00Z", True)]
        elif kind not in (None, "other"):
            self._raise(f"Rule {rule['id']}: no sample values for type {kind!r}")
        return out

    def first_present(self, rule: dict, config: Config) -> str | None:
        """The value a rule checks: its first key present at all (aliases), even empty."""
        return next((config[k] for k in rule["keys"] if k in config), None)

    def expectations(self, case: Case, rule: dict) -> Case:
        """What a required rule's published semantics say about the case."""
        if rule["check"] == "required" and self.holds(rule, case.config):
            value = self.first_present(rule, case.config)
            key = next((k for k in rule["keys"] if k in case.config), rule["keys"][0])
            unset = self.unset_by(rule["blank"], value) or not self.is_set(case.config, key, rule["blank"])
            (case.expect if unset else case.expect_not).add(rule["id"])
        return case

    def cases(self) -> Iterator[Case]:
        forks = self.forks()
        bases = [(name, self.satisfy_required(fork)) for name, fork in forks]
        for name, config in bases:
            yield Case(f"{name}: valid", config, "(valid)")
        for rule in self.all:
            rid, keys = rule["id"], tuple(rule["keys"])
            applicable = [b for b in bases if self.holds(rule, b[1])] if rule["when"] else bases[:1]
            for base_name, base in applicable:
                if rule["check"] == "distinct":
                    first = base.get(keys[0]) or self.valid_value(keys[0])
                    equal = Case(f"{rid} [{base_name}] equal", {**base, keys[0]: first, keys[1]: first.upper()}, rid, keys[1])
                    equal.expect.add(rid)
                    differ = Case(f"{rid} [{base_name}] different", {**base, keys[0]: first, keys[1]: "other." + first}, rid, keys[1])
                    differ.expect_not.add(rid)
                    yield equal
                    yield differ
                    continue
                for key in keys:
                    for label, value, valid in self.values(rule, key):
                        config = self.satisfy_required({**base, key: value}, leave_unset=keys)
                        case = self.expectations(Case(f"{rid} [{base_name}] {key}={label}", config, rid, key), rule)
                        if valid is not None and self.holds(rule, config) and \
                                next((k for k in keys if k in config), None) == key:
                            (case.expect_not if valid else case.expect).add(rid)
                        yield case
                if len(keys) > 1:  # aliases: the first present key is checked, even when empty
                    bad = next((v for label, v, _ in self.values(rule, keys[1]) if label not in ("empty", "spaces")), "x")
                    config = self.satisfy_required({**base, keys[0]: "", keys[1]: bad}, leave_unset=keys)
                    yield Case(f"{rid} [{base_name}] {keys[0]} empty before {keys[1]}", config, rid, keys[0])
                for c in rule["when"]:
                    if c["op"] == "blank":  # the waiver: setting the key lifts the requirement
                        waived = self.satisfy_required({**base, c["keys"][0]: self.valid_value(c["keys"][0])}, leave_unset=keys)
                        waived[keys[0]] = ""
                        case = Case(f"{rid} [{base_name}] waived by {c['keys'][0]}", waived, rid, keys[0])
                        case.expect_not.add(rid)
                        yield case
            # The gate, opened by each of its keys (on every fork, so the rule's other conditions hold).
            for c in rule["when"]:
                for key in c["keys"] if c["op"] == "anySet" else []:
                    for fork_name, fork in forks:
                        config = self.satisfy_required({key: self.valid_value(key), **fork}, leave_unset=keys)
                        if self.holds(rule, config):
                            yield self.expectations(Case(f"{rid} [{fork_name}] gate opened by {key}", config, rid, key), rule)


def _b64(n: int) -> str:
    return base64.b64encode(b"\0" * n).decode()


# ── Templates ───────────────────────────────────────────────────────────────────────────────────

def env_name(key: str) -> str:
    return key.replace(":", "__")


def lookup(env: Config, key: str) -> str | None:
    """A setting by its configuration key or env-var name, case-insensitively (as Broch reads them)."""
    name = env_name(key).lower()
    return next((v for k, v in env.items() if k.lower() == name), None)


def hcl_string(value: str) -> str:
    return json.dumps(value).replace("${", "$${").replace("%{", "%%{")


def _code(line: str) -> str:
    """An HCL line without its string contents and comments (so braces in them don't count)."""
    out, quote, i = [], False, 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == '"':
                quote = False
        elif ch == '"':
            quote = True
        elif ch == "#" or line.startswith("//", i):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def top_level_blocks(hcl: str) -> list[str]:
    """The top-level blocks of an HCL file, by brace depth outside strings and comments."""
    blocks, current, depth = [], [], 0
    for line in hcl.splitlines():
        if depth == 0 and not current and not _code(line).strip():
            continue
        current.append(line)
        code = _code(line)
        depth += code.count("{") - code.count("}")
        if depth == 0:
            blocks.append("\n".join(current))
            current = []
    if current:
        raise RuntimeError("unbalanced braces in an HCL file")
    return blocks


class TerraformTarget:
    """A Terraform module: verdicts from a mock-provider plan, rendering from terraform console."""

    # Terraform's refusals of a module's inputs. Any other error is a broken case or harness: raised.
    REFUSALS = {"Invalid value for variable", "No value for required variable", "Resource precondition failed",
                "Check block assertion failed"}

    # What Terraform would read from a module directory besides the module itself: an operator's
    # variable files, override files and state. Left out of the copy the check runs in.
    OPERATOR_FILES = re.compile(r"(terraform\.tfvars(\.json)?|.*\.auto\.tfvars(\.json)?|(.*_)?override\.tf(\.json)?"
                                r"|terraform\.tfstate.*|\.terraform\.tfstate\.lock\.info|\.config-contract-.*)")

    def __init__(self, path: str, spec: dict, values: Config, rules: Rules) -> None:
        self.path, self.spec, self.values, self.rules = path, spec, values, rules
        self.source_dir = os.path.join(ROOT, path)
        self.dir = self._clean_copy()
        self.inputs, self.fixed_keys = spec["inputs"], spec.get("fixed", [])
        with open(os.path.join(self.dir, spec["mocks"]), encoding="utf-8") as f:
            # The mock providers (and overrides) of the module's own tests, without its variables or runs.
            self.mocks = "\n".join(b for b in top_level_blocks(f.read()) if b.startswith(("mock_provider", "override_")))
        self.blocks = []
        for name in sorted(os.listdir(self.dir)):
            if name.endswith(".tf"):
                with open(os.path.join(self.dir, name), encoding="utf-8") as f:
                    self.blocks += top_level_blocks(f.read())
        # Variables without a default: a case that leaves one out is refused at plan.
        self.required = set()
        for block in self.blocks:
            m = re.match(r'variable\s+"([^"]+)"', block)
            if m and not re.search(r"^  default\s*=", block, re.M):
                self.required.add(m.group(1))

    def _clean_copy(self) -> str:
        """A copy of the module without the operator's files (see OPERATOR_FILES), so a terraform.tfvars
        or *.auto.tfvars in a checkout can't change a verdict. A sibling of the module, so a
        `${path.module}/../` read resolves as it does in place; it shares the module's initialized
        .terraform. Removed at exit."""
        copy = tempfile.mkdtemp(prefix=".config-contract-", dir=os.path.dirname(self.source_dir))
        atexit.register(shutil.rmtree, copy, True)
        for name in os.listdir(self.source_dir):
            source = os.path.join(self.source_dir, name)
            if self.OPERATOR_FILES.fullmatch(name):
                continue
            if name == ".terraform":
                os.symlink(source, os.path.join(copy, name))
            elif os.path.isdir(source):
                shutil.copytree(source, os.path.join(copy, name), symlinks=True)
            else:
                shutil.copy2(source, copy)
        return copy

    @staticmethod
    def env() -> dict[str, str]:
        """The caller's environment without TF_VAR_* / TF_CLI_ARGS*, which would also change verdicts."""
        return {k: v for k, v in os.environ.items() if not k.startswith(("TF_VAR_", "TF_CLI_ARGS"))}

    def variables(self, config: Config) -> Config:
        """The module's variables for a case: base values, then each mapped input the case sets. An input
        the case leaves out is left out, so the module's own default applies."""
        variables = dict(self.spec["base_vars"])
        for key, var in self.spec["inputs"].items():
            if key in config:
                variables[var] = config[key]
        return variables

    def verdicts(self, cases: list[Case]) -> dict[str, tuple[bool, str]]:
        """{case name: (accepted, the module's error)} from one `terraform test`, a file per case."""
        test_dir = tempfile.mkdtemp(prefix=".config-contract-", dir=self.dir)
        names = {}
        try:
            for i, case in enumerate(cases):
                names[f"c{i:04d}"] = case.name
                body = "\n".join(f"    {var} = {hcl_string(value)}" for var, value in self.variables(case.config).items())
                with open(os.path.join(test_dir, f"c{i:04d}.tftest.hcl"), "w", encoding="utf-8") as f:
                    f.write(f'{self.mocks}\n\nrun "case" {{\n  command = plan\n  plan_options {{\n'
                            f'    target = [{self.spec["plan_target"]}]\n  }}\n  variables {{\n{body}\n  }}\n}}\n')
            r = subprocess.run(["terraform", "test", f"-test-directory={os.path.basename(test_dir)}", "-json"],
                               cwd=self.dir, env=self.env(), capture_output=True, text=True, timeout=3600)
            status: dict[str, str] = {}
            errors: dict[str, list[tuple[str, str]]] = {}
            for line in r.stdout.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                case = os.path.basename(event.get("@testfile", "")).split(".")[0]
                if event.get("type") == "test_run" and event["test_run"].get("progress") == "complete":
                    status[case] = event["test_run"]["status"]
                elif event.get("type") == "diagnostic" and event["diagnostic"]["severity"] == "error":
                    d = event["diagnostic"]
                    errors.setdefault(case, []).append((d["summary"], d.get("detail") or d["summary"]))
            missing = [c for c in names if c not in status]
            if missing:
                raise RuntimeError(f"{self.path}: terraform test reported no result for {missing[:5]}:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
            out = {}
            for c, name in names.items():
                if status[c] == "pass":
                    out[name] = (True, "")
                    continue
                found = errors.get(c) or [("(no diagnostic)", "")]
                other = [s for s, _ in found if s not in self.REFUSALS]
                if other:
                    raise RuntimeError(f"{self.path}: case {name!r} failed with {other}, not a refusal of its inputs:\n{found}")
                out[name] = (False, " | ".join(detail for _, detail in found))
            return out
        finally:
            shutil.rmtree(test_dir, ignore_errors=True)

    def render(self, config: Config) -> str | None:
        """The rendered expression for a case, or None if Terraform refuses the inputs."""
        variables = self.variables(config)
        if self.required - set(variables):
            return None  # Terraform refuses a plan without a required variable (console just shows it unknown)
        args = []
        for var, value in variables.items():
            args += ["-var", f"{var}={value}"]

        def console(expression: str) -> subprocess.CompletedProcess:
            # A state path of its own per call: console takes the state lock, and calls run in parallel.
            with tempfile.TemporaryDirectory(prefix="config-contract-state-") as state:
                return subprocess.run(["terraform", "console", f"-state={state}/terraform.tfstate", *args],
                                      input=expression + "\n", cwd=self.dir, env=self.env(),
                                      capture_output=True, text=True, timeout=300)

        r = console(f"jsonencode({self.spec['render_expression']})")
        if r.returncode == 0 and r.stdout.strip() == "(sensitive value)":
            # A value carrying a secret input (the cloud-init holds the client secret). nonsensitive()
            # only on demand: some Terraform versions refuse it on a value that isn't sensitive.
            r = console(f"nonsensitive(jsonencode({self.spec['render_expression']}))")
        if r.returncode != 0:
            if "Invalid value for variable" in r.stderr:
                return None  # an input the module refuses before rendering (a variable validation)
            raise RuntimeError(f"{self.path}: terraform console failed:\n{r.stderr[-2000:]}")
        try:
            return json.loads(json.loads(r.stdout.strip()))
        except ValueError:
            raise RuntimeError(f"{self.path}: terraform console gave no value for {config}:\n"
                               f"stdout: {r.stdout[-1000:]}\nstderr: {r.stderr[-2000:]}")

    def environment(self, config: Config) -> Config | None:
        """What the module sends Broch for a case (env-var names), or None if Terraform refuses the inputs."""
        rendered = self.render(config)
        if rendered is None:
            return None
        if self.spec["render"] == "map":
            env = dict(rendered)
        else:
            env = cloud_init_environment(rendered, self.spec["dotenv_path"], self.spec["compose_service"])
        for name, value in env.items():
            if not isinstance(value, str):
                raise RuntimeError(f"{self.path}: renders {name} as {value!r}, not a string")
        variables = self.variables(config)
        for name, var in self.spec["secret_inputs"].items():
            if var in variables:
                env[name] = variables[var]
        for name, how in self.spec["generated"].items():
            env[name] = self.generated(name, how, env, rendered)
        return env

    def generated(self, name: str, how: dict, env: Config, rendered) -> str:
        """A value the template generates, judged at the size its generator produces."""
        current = lookup(env, name)
        if "placeholder" in how:
            if current != how["placeholder"]:
                raise RuntimeError(f"{self.path}: expected {name}={how['placeholder']} in the render, got {current!r}")
        elif current is not None:
            raise RuntimeError(f"{self.path}: renders {name} itself; drop it from generated in the targets file")
        if "random_password" in how or "command" in how:
            # The stand-ins below model only the value's UTF-8 length: refuse a rule they can't speak for.
            other = sorted(r["id"] for r in self.rules.all
                           if any(env_name(k).lower() == name.lower() for k in r["keys"])
                           and r["check"] not in ("required", "minUtf8Bytes"))
            if other:
                raise RuntimeError(f"{self.path}: {name} has rules {other} a length-only stand-in can't satisfy; teach scripts/config-contract.py")
        if "random_password" in how:
            block = next((b for b in self.blocks if re.match(rf'resource\s+"random_password"\s+"{how["random_password"]}"', b)), None)
            m = re.search(r"^\s+length\s*=\s*(\d+)\s*$", block or "", re.M)
            if m is None:
                raise RuntimeError(f"{self.path}: random_password.{how['random_password']} has no literal length")
            return "k" * int(m.group(1))
        if "command" in how:
            # Anchored to the whole line, so a trailing `| head -c N` can't make the size wrong.
            found = re.findall(how["command"], rendered, re.M)
            if len(found) != 1:
                raise RuntimeError(f"{self.path}: expected one line matching {how['command']!r} generating {name}, found {len(found)}")
            m = re.search(how["command"], rendered, re.M)
            return "k" * (4 * math.ceil(int(m.group(1)) / 3))  # base64 of N bytes
        if "stand_in" in how:
            return self.values[how["stand_in"]]
        raise RuntimeError(f"{self.path}: generated {name}: unknown generator {how}")


def compose_config(where: str, compose_file: str, env_text: str, service: str) -> tuple[bool, str, Config | None]:
    """`docker compose config` over a compose file and an .env: (False, compose's error, None) when a
    `${VAR:?}` refuses it, else (True, "", the service's environment). Any other error is raised."""
    fd, env_file = tempfile.mkstemp(suffix=".env", dir=os.environ.get("RUNNER_TEMP"))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(env_text)
        # Only what the CLI needs from the process environment, which compose would otherwise read
        # ahead of the .env.
        base = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST")}
        r = subprocess.run(["docker", "compose", "--project-directory", os.path.dirname(compose_file), "-f",
                            compose_file, "--env-file", env_file, "config", "--format", "json", "--no-path-resolution"],
                           capture_output=True, text=True, timeout=120, env=base)
    finally:
        os.unlink(env_file)
    if r.returncode != 0:
        if not re.search(r"required variable \w+ is missing a value", r.stderr):
            raise RuntimeError(f"{where}: docker compose config failed, not a refusal of its inputs:\n{r.stderr[-2000:]}")
        return False, r.stderr.strip(), None
    environment = json.loads(r.stdout)["services"][service].get("environment") or {}
    # `config` prints a literal `$` as `$$` so its output can be fed back through interpolation; the
    # container itself gets the single `$`.
    return True, "", {k: v.replace("$$", "$") for k, v in environment.items() if v is not None}


class ComposeTarget:
    """A docker compose file the operator fills through its .env: verdicts and the environment both from
    `docker compose config` (a `${VAR:?}` refuses the inputs; otherwise the broch service's environment
    is what Broch gets). Each value is written into the .env single-quoted, as .env.example says to."""

    def __init__(self, path: str, spec: dict, values: Config, rules: Rules) -> None:
        self.path, self.spec = path, spec
        self.dir = os.path.join(ROOT, path)
        self.inputs, self.fixed_keys = spec["inputs"], spec.get("fixed", [])
        self.results: dict[str, tuple[bool, str, Config | None]] = {}

    def dotenv_text(self, config: Config) -> tuple[str | None, str]:
        """The .env for a case, or None and why when the documented form can't carry a value."""
        entries = dict(self.spec["base_vars"])
        for key, var in self.spec["inputs"].items():
            if key in config:
                entries[var] = config[key]
        for var, value in entries.items():
            if "'" in value or "\n" in value or "\r" in value or value.endswith("\\"):
                return None, f"{var}: a single-quoted .env value can't carry {value!r}"
        return "".join(f"{var}='{value}'\n" for var, value in entries.items()), ""

    def run(self, config: Config) -> tuple[bool, str, Config | None]:
        key = json.dumps(config, sort_keys=True)
        if key in self.results:
            return self.results[key]
        text, why = self.dotenv_text(config)
        if text is None:
            result = (False, why, None)
        else:
            result = compose_config(self.path, os.path.join(self.dir, self.spec["compose_file"]), text,
                                    self.spec["compose_service"])
        self.results[key] = result
        return result

    def verdicts(self, cases: list[Case]) -> dict[str, tuple[bool, str]]:
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            return {case.name: result[:2] for case, result in zip(cases, pool.map(lambda c: self.run(c.config), cases))}

    def environment(self, config: Config) -> Config | None:
        return self.run(config)[2]


DEPLOY_TIME = "{{deploy-time:"


class Unresolved(str):
    """A value only known at deploy time (a resource's id or attribute, a pseudo parameter). Its text
    carries DEPLOY_TIME, which survives any string built from it: such a value reaching a key one of
    Broch's rules checks is an error, not a pass."""

    def __new__(cls, what: str) -> "Unresolved":
        return super().__new__(cls, what if what.startswith(DEPLOY_TIME) else f"{DEPLOY_TIME}{what}}}}}")


def is_deploy_time(v) -> bool:
    """True for a value that is, or was built from, a deploy-time value. The marker survives string
    composition (Fn::Sub, concat, format, replace) which turns an Unresolved into a plain str, so this
    checks the text, and a list holding such a value counts too."""
    if isinstance(v, str):
        return DEPLOY_TIME in v
    if isinstance(v, list):
        return any(is_deploy_time(x) for x in v)
    return False


def import_variant_generator():
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import generate_aws_variant
    return generate_aws_variant


class CfnTarget:
    """A CloudFormation template, judged as CloudFormation judges a stack's inputs before building
    anything: each parameter's constraints, then the Rules. What Broch gets is the /opt/broch/.env the
    UserData writes, plus the lines render-secrets.sh appends at boot (each a secret whose SecretString
    is a parameter), read through the compose file the template embeds for the case, with real
    `docker compose config`. Any intrinsic, constraint or shell form this doesn't model is an error.

    `variant` names a published variant (cloudformation/aws-vm/published_variants.yaml): the template is
    then scripts/generate_aws_variant.py's render of the canonical one. An input whose parameter the
    template doesn't have is one the template hard-codes (fixed)."""

    PARAMETER_FIELDS = {"Type", "Default", "Description", "NoEcho", "MinLength", "MaxLength", "AllowedPattern",
                        "AllowedValues", "ConstraintDescription", "MinValue", "MaxValue"}
    PSEUDO = {"AWS::Region", "AWS::StackName", "AWS::StackId", "AWS::AccountId", "AWS::Partition", "AWS::URLSuffix",
              "AWS::NoValue"}
    ENV_WRITE = re.compile(r"^put ([A-Za-z_][A-Za-z0-9_]*) ([A-Za-z0-9-]+)$")
    # The lines naming .env that write nothing to it.
    ENV_FILE_OK = {"env_file=/opt/broch/.env", 'chmod 0600 "$env_file"'}
    # render-secrets.sh's put(), whose body the model below stands for: changing it needs this updated.
    PUT_BODY = [
        'raw="$(get "$2" && printf x)" || fatal "could not read secret $2"',
        '[ "$(printf \'%s\' "$raw" | wc -l)" -eq 1 ] || fatal "secret $2 contains a line break, which /opt/broch/.env can\'t carry"',
        'v="$(printf \'%s\' "$raw" | head -n 1)"',
        'case "$v" in *"\'"*|*\\\\|*"$(printf \'\\r\')"*) fatal "secret $2 contains a single quote or a carriage return, '
        'or ends with a backslash, which /opt/broch/.env can\'t carry" ;; esac',
        'printf "%s=\'%s\'\\n" "$1" "$v" >> "$env_file"',
    ]

    def __init__(self, path: str, spec: dict, values: Config, rules: Rules) -> None:
        import cfnlint.decode  # the CloudFormation-aware YAML reader (pinned cfn-lint; see Requirements above)
        self.path, self.spec = path, spec
        self.dir = os.path.join(ROOT, spec["dir"])
        with open(os.path.join(self.dir, spec["template"]), encoding="utf-8") as f:
            text = f.read()
        if "variant" in spec:
            generate_aws_variant = import_variant_generator()
            entry = next((e for e in generate_aws_variant.variants() if e["auth"] == spec["variant"]), None)
            if entry is None:
                raise RuntimeError(f"{path}: {spec['variant']} is not a published variant")
            text = generate_aws_variant.render(text, entry)
        self.template, matches = cfnlint.decode.decode_str(text)
        if matches or not isinstance(self.template, dict):
            raise RuntimeError(f"{path}: the template doesn't parse: {matches}")
        self.parameters = self.template["Parameters"]
        for name, p in self.parameters.items():
            if set(p) - self.PARAMETER_FIELDS:
                raise RuntimeError(f"{path}: parameter {name} has fields this check doesn't model: {sorted(set(p) - self.PARAMETER_FIELDS)}")
        self.inputs = {k: v for k, v in spec["inputs"].items() if v in self.parameters}
        missing = [v for k, v in spec["inputs"].items() if k not in self.inputs]
        if missing and "variant" not in spec:
            raise RuntimeError(f"{path}: the targets file maps inputs to parameters the template doesn't have: {missing}")
        self.fixed_keys = spec.get("fixed", []) + [k for k in spec["inputs"] if k not in self.inputs]
        unknown = [k for k in spec["base_parameters"] if not k.startswith("_") and k not in self.parameters]
        if unknown:
            raise RuntimeError(f"{path}: base_parameters names parameters the template doesn't have: {unknown}")
        with open(os.path.join(ROOT, spec["build_script"]), encoding="utf-8") as f:
            self.build_script = f.read()

    # ── CloudFormation's own evaluation ──

    def resolved(self, config: Config) -> dict[str, str]:
        params = {k: v for k, v in self.spec["base_parameters"].items() if not k.startswith("_")}
        for key, name in self.inputs.items():
            if key in config:
                params[name] = config[key]
        return params

    def refusal(self, params: dict[str, str]) -> str | None:
        """Why CloudFormation refuses these parameters (naming the parameter), or None."""
        for name, p in self.parameters.items():
            value = params.get(name, p.get("Default"))
            if value is None:
                return f"Parameters: [{name}] must have values"
            value = str(value)
            if p["Type"] == "Number":
                if not re.fullmatch(r"-?\d+(\.\d+)?", value) or ("MinValue" in p and float(value) < float(p["MinValue"])) \
                        or ("MaxValue" in p and float(value) > float(p["MaxValue"])) \
                        or ("AllowedValues" in p and float(value) not in [float(v) for v in p["AllowedValues"]]):
                    return f"Parameter {name} failed its Number constraints"
                continue
            if p["Type"] != "String":
                if name not in self.spec["base_parameters"] and name in params:
                    raise RuntimeError(f"{self.path}: a case sets {name}, of type {p['Type']}, which this check doesn't model")
                continue
            if "AllowedValues" in p and value not in [str(v) for v in p["AllowedValues"]]:
                return f"Parameter {name} failed to satisfy constraint AllowedValues: {value!r}"
            units = len(value.encode("utf-16-le")) // 2  # Java string length, as CloudFormation counts
            if "MinLength" in p and units < int(p["MinLength"]):
                return f"Parameter {name} failed to satisfy constraint MinLength"
            if "MaxLength" in p and units > int(p["MaxLength"]):
                return f"Parameter {name} failed to satisfy constraint MaxLength"
            if "AllowedPattern" in p and re.fullmatch(self.java_pattern(name, p["AllowedPattern"]), value, re.ASCII) is None:
                return f"Parameter {name} failed to satisfy constraint AllowedPattern: {p.get('ConstraintDescription', '')}"
        for rule_name, rule in (self.template.get("Rules") or {}).items():
            if set(rule) - {"RuleCondition", "Assertions"}:
                raise RuntimeError(f"{self.path}: rule {rule_name} has fields this check doesn't model")
            if "RuleCondition" in rule and not self.evaluate(rule["RuleCondition"], params):
                continue
            for assertion in rule["Assertions"]:
                if not self.evaluate(assertion["Assert"], params):
                    return f"Rule {rule_name}: {assertion.get('AssertDescription', '')}"
        return None

    def java_pattern(self, name: str, pattern: str) -> str:
        """An AllowedPattern (Java regex, which CloudFormation uses) for Python's re, matched with
        re.ASCII as Java's \\s \\d \\w are. Java-only syntax is refused rather than misread."""
        if re.search(r"&&|[*+?}]\+|\\[pPQEZGz]|\(\?[<]?[a-zA-Z]", pattern):
            raise RuntimeError(f"{self.path}: parameter {name}'s AllowedPattern uses regex syntax this check doesn't model: {pattern}")
        return pattern

    def condition(self, name: str, params: dict[str, str]) -> bool:
        return bool(self.evaluate(self.template["Conditions"][name], params))

    def evaluate(self, node, params: dict[str, str], sub_vars: dict | None = None):
        if isinstance(node, (str, int, float)) and not isinstance(node, bool):
            return str(node)
        if isinstance(node, list):
            return [self.evaluate(n, params, sub_vars) for n in node]
        if not isinstance(node, dict) or len(node) != 1:
            raise RuntimeError(f"{self.path}: can't evaluate {node!r}")
        (fn, arg), = node.items()
        if fn == "Ref":
            if arg in self.parameters:
                value = params.get(arg, self.parameters[arg].get("Default"))
                kind = self.parameters[arg]["Type"]
                if kind.startswith("List<") or kind == "CommaDelimitedList":
                    return [v.strip() for v in str(value).split(",")]
                return str(value)
            if arg in self.PSEUDO or arg in self.template["Resources"]:
                return Unresolved(arg)
            raise RuntimeError(f"{self.path}: Ref to unknown {arg}")
        if fn == "Condition":
            return self.condition(arg, params)
        if fn == "Fn::If":
            return self.evaluate(arg[1] if self.condition(arg[0], params) else arg[2], params, sub_vars)
        if fn == "Fn::Equals":
            a, b = (self.evaluate(x, params, sub_vars) for x in arg)
            if is_deploy_time(a) or is_deploy_time(b):
                raise RuntimeError(f"{self.path}: Fn::Equals over a deploy-time value: {node!r}")
            return a == b
        if fn == "Fn::Not":
            return not self.evaluate(arg[0], params, sub_vars)
        if fn == "Fn::And":
            return all(self.evaluate(x, params, sub_vars) for x in arg)
        if fn == "Fn::Or":
            return any(self.evaluate(x, params, sub_vars) for x in arg)
        if fn == "Fn::Contains":
            container = self.evaluate(arg[0], params, sub_vars)
            if not isinstance(container, list):
                raise RuntimeError(f"{self.path}: Fn::Contains over a non-list: {node!r}")
            item = self.evaluate(arg[1], params, sub_vars)
            if is_deploy_time(item) or is_deploy_time(container):
                raise RuntimeError(f"{self.path}: Fn::Contains over a deploy-time value: {node!r}")
            return item in container
        if fn == "Fn::Sub":
            text, variables = (arg, {}) if isinstance(arg, str) else arg
            return self.substitute(text, variables, params)
        if fn in ("Fn::Select", "Fn::Split", "Fn::Join"):
            a, b = (self.evaluate(x, params, sub_vars) for x in arg)
            if fn == "Fn::Join":
                return Unresolved(fn) if is_deploy_time(a) or is_deploy_time(b) else a.join(b)
            if fn == "Fn::Split":
                return Unresolved(fn) if is_deploy_time(a) or is_deploy_time(b) else b.split(a)
            return Unresolved(fn) if is_deploy_time(a) or is_deploy_time(b) else b[int(a)]
        if fn in ("Fn::GetAtt", "Fn::Base64", "Fn::GetAZs", "Fn::ImportValue"):
            return Unresolved(fn)
        raise RuntimeError(f"{self.path}: can't evaluate {fn}")

    def substitute(self, text: str, variables: dict, params: dict[str, str]) -> str:
        """Fn::Sub: ${Name} from the variable map, a parameter, a pseudo parameter or a resource (the
        last two only known at deploy time); ${!Literal} is a literal ${Literal}."""
        def sub(m: re.Match) -> str:
            name = m.group(1)
            if name.startswith("!"):
                return "${" + name[1:] + "}"
            if name in variables:
                return str(self.evaluate(variables[name], params))
            if name in self.parameters:
                return str(self.evaluate({"Ref": name}, params))
            if name in self.PSEUDO or name.split(".")[0] in self.template["Resources"]:
                return Unresolved(name)
            raise RuntimeError(f"{self.path}: Fn::Sub names unknown ${{{name}}}")
        return re.sub(r"\$\{([^}]*)\}", sub, text)

    # ── What reaches Broch ──

    def verdicts(self, cases: list[Case]) -> dict[str, tuple[bool, str]]:
        out = {}
        for case in cases:
            why = self.refusal(self.resolved(case.config))
            out[case.name] = (why is None, why or "")
        return out

    def env_file(self, params: dict[str, str]) -> str:
        """The /opt/broch/.env the instance ends up with: UserData's, then render-secrets.sh's appends."""
        instance = self.template["Resources"][self.spec["instance"]]
        user_data = instance["Properties"]["UserData"]["Fn::Base64"]["Fn::Sub"]
        text = self.substitute(user_data[0], user_data[1], params)
        body = cloud_init_file(text, "/opt/broch/.env")
        files = instance["Metadata"]["AWS::CloudFormation::Init"]["config"]["files"]
        script = files["/opt/broch/render-secrets.sh"]["content"]["Fn::Sub"]
        appended = self.secret_lines(self.substitute(script[0], script[1], params), params)
        return body + "".join(appended)

    def secret_lines(self, script: str, params: dict[str, str]) -> list[str]:
        """The .env lines render-secrets.sh appends for these parameters. Its `if [ "<true|false>" = "true" ]`
        and `case "<value>" in` blocks are followed (their conditions are rendered by Fn::Sub); every
        active write to $env_file must be `put KEY <secret>`, put() having exactly the body PUT_BODY
        models (append KEY='value'; stop the boot on a value single quotes can't carry)."""
        secrets = {}
        for name, resource in self.template["Resources"].items():
            if resource["Type"] != "AWS::SecretsManager::Secret":
                continue
            secret_name = resource["Properties"]["Name"]["Fn::Sub"][0].rsplit("/", 1)[-1]
            secrets[secret_name] = resource
        lines, stack, heredoc, function, put_defined, expecting_pattern = [], [], None, None, False, False
        for raw in script.splitlines():
            line = raw.strip()
            if function is not None:  # inside a function's body
                if line == "}":
                    if function_name == "put":
                        if function != self.PUT_BODY:
                            raise RuntimeError(f"{self.path}: render-secrets.sh's put() isn't the one this check models: {function}")
                        put_defined = True
                    elif any("env_file" in f or re.match(r"put\b", f) for f in function):
                        raise RuntimeError(f"{self.path}: render-secrets.sh's {function_name}() writes .env; this check doesn't model that")
                    function = None
                    continue
                function.append(line)
                continue
            if m := re.fullmatch(r"(\w+)\(\) \{", line):
                function, function_name = [], m.group(1)
                continue
            if heredoc:
                if line == heredoc:
                    heredoc = None
                continue
            m = re.search(r"(?<!<)<<-?\s*['\"]?(\w+)['\"]?(?!<)", line)
            if m:
                heredoc = m.group(1)
            # Control words compared without a trailing comment, so `else # ...` is still an else.
            code = re.sub(r"(^|\s)#.*$", "", line).strip()
            if expecting_pattern and code and code != "esac" and not re.match(r"[^\s()]+\)", code):
                raise RuntimeError(f"{self.path}: render-secrets.sh case item this check can't read: {line}")
            if code:
                expecting_pattern = False
            # Stack entries: [kind, active (None: a condition this doesn't follow), a branch already taken,
            # the case subject (None: not a literal)].
            inactive = any(entry[1] is False for entry in stack)
            unknown = any(entry[1] is None for entry in stack)
            if m := re.fullmatch(r'if \[ "(true|false)" = "true" \]; then', code):
                stack.append(["if", m.group(1) == "true", True, None])
            elif re.match(r"if\b", code) and not re.search(r"\bfi\b", code):
                stack.append(["if", None, True, None])
            elif code == "else":
                stack[-1][1] = None if stack[-1][1] is None else not stack[-1][1]
            elif re.match(r"elif\b", code):
                stack[-1][1] = None
            elif code in ("fi", "fi;"):
                stack.pop()
            elif m := re.fullmatch(r"case (.*) in", code):
                literal = re.fullmatch(r'"([^"$`]*)"', m.group(1))
                stack.append(["case", False, False, literal.group(1) if literal else None])
                expecting_pattern = True
            elif stack and stack[-1][0] == "case" and (m := re.match(r"([^\s()]+)\)(.*)$", code)):
                alternatives = m.group(1).split("|")
                if any(a != "*" and not re.fullmatch(r"[A-Za-z0-9_.-]+", a) for a in alternatives):
                    raise RuntimeError(f"{self.path}: render-secrets.sh case pattern this check can't match: {line}")
                subject = stack[-1][3]
                hit = None if subject is None else ("*" in alternatives or subject in alternatives)
                stack[-1][1] = None if hit is None else hit and not stack[-1][2]
                stack[-1][2] = stack[-1][2] or bool(hit)
                if m.group(2).rstrip().endswith(";;"):
                    if "env_file" in m.group(2) or "/opt/broch/.env" in m.group(2) or re.match(r"\s*put\b", m.group(2)):
                        raise RuntimeError(f"{self.path}: render-secrets.sh writes .env in a one-line case item: {line}")
                    stack[-1][1] = False
                    expecting_pattern = True
            elif code == ";;":
                stack[-1][1] = False
                expecting_pattern = True
            elif code == "esac":
                stack.pop()
            elif code in self.ENV_FILE_OK:
                continue
            elif "env_file" in code or "/opt/broch/.env" in code or re.match(r"put\b", code):
                # Any other line naming .env is a write, and must be a put this check reads.
                if inactive:
                    continue
                if unknown:
                    raise RuntimeError(f"{self.path}: render-secrets.sh writes .env under a condition this check can't follow: {line}")
                w = self.ENV_WRITE.fullmatch(code)
                if w is not None and not put_defined:
                    raise RuntimeError(f"{self.path}: render-secrets.sh calls put before defining it: {line}")
                if w is None:
                    raise RuntimeError(f"{self.path}: render-secrets.sh writes .env in a form this check can't read: {line}")
                key, secret_name = w.groups()
                resource = secrets.get(secret_name)
                if resource is None:
                    raise RuntimeError(f"{self.path}: render-secrets.sh reads a secret no resource creates: {secret_name}")
                if "Condition" in resource and not self.condition(resource["Condition"], params):
                    raise RuntimeError(f"{self.path}: render-secrets.sh reads {secret_name}, whose resource this case doesn't create")
                value = resource["Properties"].get("SecretString")
                if not (isinstance(value, dict) and set(value) == {"Ref"} and value["Ref"] in self.parameters):
                    raise RuntimeError(f"{self.path}: secret {secret_name} isn't a parameter's value; teach scripts/config-contract.py")
                secret = self.evaluate(value, params)
                if re.search(r"['\r\n]|\\$", secret):
                    raise BootRefused(f"render-secrets.sh stops: secret {secret_name} can't be written to .env single-quoted")
                lines.append(f"{key}='{secret}'\n")
        if stack or heredoc:
            raise RuntimeError(f"{self.path}: render-secrets.sh's if/case blocks don't balance as read")
        return lines

    def environment(self, config: Config) -> Config | None:
        params = self.resolved(config)
        if self.refusal(params) is not None:
            return None
        compose = self.evaluate(self.template["Resources"][self.spec["instance"]]["Metadata"]
                                ["AWS::CloudFormation::Init"]["config"]["files"]["/opt/broch/docker-compose.yml"]["content"], params)
        if compose not in self.spec["embeds"] or compose not in self.build_script:
            raise RuntimeError(f"{self.path}: the compose placeholder {compose!r} isn't one the targets file maps and build.sh fills")
        accepted, why, env = compose_config(self.path, os.path.join(ROOT, self.spec["embeds"][compose]),
                                            self.env_file(params), self.spec["compose_service"])
        if not accepted:
            raise BootRefused(f"compose refuses the instance's .env: {why}")
        return env


class BootRefused(Exception):
    """The template accepts the inputs at deploy, then the instance refuses to start Broch with them."""


class TemplateFail(Exception):
    """An ARM template's fail() was reached."""


class Lambda:
    def __init__(self, names: list[str], body) -> None:
        self.names, self.body = names, body


# environment() of Azure's public cloud: the values a template reads from it, nothing more.
AZURE_ENVIRONMENT = {
    "name": "AzureCloud",
    "authentication": {"loginEndpoint": "https://login.microsoftonline.com/"},
    "suffixes": {"keyvaultDns": ".vault.azure.net", "storage": "core.windows.net",
                 "sqlServerHostname": ".database.windows.net", "acrLoginServer": ".azurecr.io"},
}


class Arm:
    """ARM template expressions over known parameters, for the functions a template here uses. A value
    only known at deploy time (a reference(), a resource id, uniqueString()) is Unresolved; branching on
    one, or any function or property this doesn't model, is an error rather than a guess."""

    def __init__(self, template: dict, params: dict) -> None:
        self.template, self.params, self.memo = template, params, {}
        self.scopes: list[dict] = []

    # ── parsing ──
    def parse(self, text: str):
        pos = 0

        def skip():
            nonlocal pos
            while pos < len(text) and text[pos] == " ":
                pos += 1

        def primary():
            nonlocal pos
            skip()
            ch = text[pos]
            if ch == "'":
                out, pos = [], pos + 1
                while True:
                    end = text.index("'", pos)
                    out.append(text[pos:end])
                    pos = end + 1
                    if pos < len(text) and text[pos] == "'":
                        out.append("'")
                        pos += 1
                        continue
                    return ("lit", "".join(out))
            m = re.compile(r"-?\d+").match(text, pos)
            if m:
                pos = m.end()
                return ("lit", int(m.group(0)))
            m = re.compile(r"[A-Za-z_][A-Za-z0-9_]*").match(text, pos)
            if not m:
                raise RuntimeError(f"can't parse ARM expression at {pos}: {text[pos:pos + 60]!r}")
            pos = m.end()
            skip()
            if text[pos] != "(":
                raise RuntimeError(f"ARM expression: {m.group(0)} isn't a call")
            pos += 1
            args = []
            skip()
            if text[pos] == ")":
                pos += 1
            else:
                while True:
                    args.append(expression())
                    skip()
                    if text[pos] == ",":
                        pos += 1
                        continue
                    if text[pos] == ")":
                        pos += 1
                        break
                    raise RuntimeError(f"ARM expression: expected , or ) at {pos}")
            return ("call", m.group(0), args)

        def expression():
            nonlocal pos
            node = primary()
            while True:
                skip()
                if pos < len(text) and text[pos] == ".":
                    m = re.compile(r"\.([A-Za-z_][A-Za-z0-9_]*)").match(text, pos)
                    pos = m.end()
                    node = ("get", node, ("lit", m.group(1)))
                elif pos < len(text) and text[pos] == "[":
                    pos += 1
                    index = expression()
                    skip()
                    pos += 1  # ]
                    node = ("get", node, index)
                else:
                    return node

        node = expression()
        skip()
        if pos != len(text):
            raise RuntimeError(f"ARM expression: trailing text {text[pos:pos + 60]!r}")
        return node

    # ── evaluation ──
    def value(self, node):
        """A template value: a string expression "[...]" is evaluated; objects and arrays recursively."""
        if isinstance(node, str):
            if node.startswith("[[") or not (node.startswith("[") and node.endswith("]")):
                return node[1:] if node.startswith("[[") else node
            return self.eval(self.parse(node[1:-1]))
        if isinstance(node, list):
            return [self.value(v) for v in node]
        if isinstance(node, dict):
            return {k: self.value(v) for k, v in node.items()}
        return node

    def eval(self, node):
        kind = node[0]
        if kind == "lit":
            return node[1]
        if kind == "get":
            base, key = self.eval(node[1]), self.eval(node[2])
            if is_deploy_time(base):
                return Unresolved(f"{base}.{key}")
            if isinstance(base, dict):
                if key not in base:
                    raise RuntimeError(f"ARM expression: no property {key!r} (have {sorted(base)})")
                return base[key]
            if isinstance(base, list):
                return base[key]
            raise RuntimeError(f"ARM expression: can't index {base!r}")
        _, name, args = node
        lazy = getattr(self, f"lazy_{name}", None)
        if lazy:
            return lazy(args)
        fn = getattr(self, f"fn_{name}", None)
        if fn is None:
            raise RuntimeError(f"ARM function {name}() isn't modelled; teach scripts/config-contract.py")
        return fn(*[self.eval(a) for a in args])

    def truth(self, v) -> bool:
        if isinstance(v, Unresolved) or not isinstance(v, bool):
            raise RuntimeError(f"ARM expression: a condition is {v!r}, not a known boolean")
        return v

    def lazy_if(self, args):
        return self.eval(args[1] if self.truth(self.eval(args[0])) else args[2])

    def lazy_lambda(self, args):
        return Lambda([self.eval(a) for a in args[:-1]], args[-1])

    def call(self, fn: Lambda, *values):
        self.scopes.append(dict(zip(fn.names, values)))
        try:
            return self.eval(fn.body)
        finally:
            self.scopes.pop()

    def fn_lambdaVariables(self, name):
        return self.scopes[-1][name]

    def fn_parameters(self, name):
        if name in self.params:
            return self.params[name]
        p = self.template["parameters"][name]
        if "defaultValue" not in p:
            raise RuntimeError(f"parameter {name} has no value")
        return self.value(p["defaultValue"])

    def fn_variables(self, name):
        if name not in self.memo:
            self.memo[name] = self.value(self.template["variables"][name])
        return self.memo[name]

    def fn_fail(self, message):
        raise TemplateFail(message)

    @staticmethod
    def _unresolved(*values):
        return any(is_deploy_time(v) for v in values)

    def fn_concat(self, *values):
        if values and isinstance(values[0], list):
            return [x for v in values for x in v]
        return "".join(self.fn_string(v) for v in values)

    def fn_createArray(self, *values):
        return list(values)

    def fn_createObject(self, *values):
        return dict(zip(values[0::2], values[1::2]))

    def fn_empty(self, v):
        if is_deploy_time(v):
            raise RuntimeError("ARM expression: empty() of a deploy-time value")
        return v is None or v == "" or v == [] or v == {}

    def fn_trim(self, s):
        return Unresolved(s) if is_deploy_time(s) else s.strip()

    def fn_not(self, v):
        return not self.truth(v)

    def fn_and(self, *values):
        return all([self.truth(v) for v in values])

    def fn_or(self, *values):
        return any([self.truth(v) for v in values])

    def fn_true(self):
        return True

    def fn_false(self):
        return False

    def fn_null(self):
        return None

    def fn_equals(self, a, b):
        if self._unresolved(a, b):
            raise RuntimeError("ARM expression: equals() over a deploy-time value")
        return a == b

    def fn_contains(self, container, item):
        if self._unresolved(container, item):
            raise RuntimeError("ARM expression: contains() over a deploy-time value")
        if isinstance(container, dict):  # ARM property names are case-insensitive
            return str(item).lower() in (k.lower() for k in container)
        return item in container

    def fn_toLower(self, s):
        return Unresolved(s) if is_deploy_time(s) else s.lower()

    def fn_startsWith(self, s, prefix):  # ARM compares case-insensitively
        if self._unresolved(s, prefix):
            raise RuntimeError("ARM expression: startsWith() over a deploy-time value")
        return s.lower().startswith(prefix.lower())

    def fn_endsWith(self, s, suffix):
        if self._unresolved(s, suffix):
            raise RuntimeError("ARM expression: endsWith() over a deploy-time value")
        return s.lower().endswith(suffix.lower())

    def fn_replace(self, s, old, new):
        return str(s).replace(old, str(new))

    def fn_format(self, fmt, *values):
        def sub(m: re.Match) -> str:
            return {"{{": "{", "}}": "}"}.get(m.group(0)) or self.fn_string(values[int(m.group(1))])
        if re.search(r"\{\d+:", fmt):
            raise RuntimeError(f"ARM format(): a format specifier isn't modelled: {fmt!r}")
        return re.sub(r"\{\{|\}\}|\{(\d+)\}", sub, fmt)

    def fn_string(self, v):
        if isinstance(v, bool):
            return "True" if v else "False"
        if isinstance(v, (dict, list)):
            return json.dumps(v, separators=(",", ":"))
        return str(v)

    def fn_base64(self, s):
        return base64.b64encode(str(s).encode()).decode()

    def fn_join(self, values, sep):
        return sep.join(self.fn_string(v) for v in values)

    def fn_split(self, s, sep):
        return str(s).split(sep)

    def fn_take(self, v, n):
        return v[:n]

    def fn_coalesce(self, *values):
        return next((v for v in values if v is not None), None)

    def fn_tryGet(self, obj, *keys):
        for key in keys:
            if not isinstance(obj, (dict, list)) or (isinstance(obj, dict) and key not in obj):
                return None
            obj = obj[key]
        return obj

    def fn_json(self, s):
        return json.loads(s)

    def fn_items(self, obj):
        return [{"key": k, "value": obj[k]} for k in sorted(obj, key=str.lower)]  # ARM sorts by key

    def fn_map(self, values, fn):
        return [self.call(fn, v) for v in values]

    def fn_filter(self, values, fn):
        return [v for v in values if self.truth(self.call(fn, v))]

    def fn_reduce(self, values, initial, fn):
        acc = initial
        for v in values:
            acc = self.call(fn, acc, v)
        return acc

    def fn_environment(self):
        return AZURE_ENVIRONMENT

    def fn_resourceGroup(self):
        return Unresolved("resourceGroup()")

    def fn_subscription(self):
        return Unresolved("subscription()")

    def _runtime(name):
        return lambda self, *args: Unresolved(f"{name}()")

    fn_reference = _runtime("reference")
    fn_resourceId = _runtime("resourceId")
    fn_subscriptionResourceId = _runtime("subscriptionResourceId")
    fn_uniqueString = _runtime("uniqueString")
    fn_guid = _runtime("guid")
    fn_newGuid = _runtime("newGuid")
    fn_listKeys = _runtime("listKeys")
    del _runtime


class BicepTarget:
    """A Bicep template. Verdicts from Azure's preflight (`az deployment group validate` in a resource
    group kept for it: parameter constraints and every fail() over the parameters). What Broch gets is
    the compiled template's own expressions evaluated here (Arm) over the case's parameters:

      render "container-app": the container's env, each secretRef resolved through the app's secrets;
      render "vm": the /opt/broch/.env its customData writes, plus what the boot fetch appends from Key
        Vault (kvSecretMap's KEY=secret pairs: each secret must be a deployed resource with a non-empty
        value, or the boot stops), read through the compose file the customData embeds, with real
        `docker compose config`.

    A case Azure accepts but this evaluation fail()s on is an error (the evaluation is wrong), so the
    evaluation can't silently drift from what Azure does."""

    # Azure's refusals of a template's inputs (code InvalidTemplate): a parameter that is missing or
    # breaks its constraints, or a template variable whose fail() fired.
    REFUSALS = (r"Deployment template validation failed: '(The provided value (?:'.*?' )?for the template parameter '\w+' is not valid"
                r"|The value for the template parameter '\w+' at line '\d+' and column '\d+' is not provided"
                r"|The template variable '\w+' is not valid)")

    def __init__(self, path: str, spec: dict, values: Config, rules: Rules) -> None:
        self.path, self.spec = path, spec
        self.inputs, self.fixed_keys = spec["inputs"], spec.get("fixed", [])
        source = os.path.join(ROOT, path, spec["template"])
        r = subprocess.run(["az", "bicep", "build", "--file", source, "--stdout", "--only-show-errors"],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"{path}: bicep build failed:\n{r.stderr[-2000:]}")
        self.compiled = r.stdout
        self.template = json.loads(r.stdout)
        if isinstance(self.template["resources"], dict):
            raise RuntimeError(f"{path}: a symbolic-name (languageVersion 2.0) template isn't modelled")
        unknown = [p for p in list(spec["base_parameters"]) + list(spec["inputs"].values())
                   if not p.startswith("_") and p not in self.template["parameters"]]
        if unknown:
            raise RuntimeError(f"{path}: the targets file names parameters the template doesn't have: {unknown}")

    def parameters(self, config: Config) -> dict:
        params = {k: v for k, v in self.spec["base_parameters"].items() if not k.startswith("_")}
        for key, name in self.inputs.items():
            if key in config:
                params[name] = config[key]
        return params

    def resource_group(self) -> str:
        var = self.spec["resource_group_env"]
        group = os.environ.get(var, "")
        if not group:
            raise RuntimeError(f"{self.path}: set {var} to the resource group Azure validates in")
        return group

    def validate(self, config: Config) -> tuple[bool, str]:
        params = {k: {"value": v} for k, v in self.parameters(config).items()}
        with tempfile.TemporaryDirectory(prefix="config-contract-bicep-", dir=os.environ.get("RUNNER_TEMP")) as d:
            with open(os.path.join(d, "template.json"), "w", encoding="utf-8") as f:
                f.write(self.compiled)
            with open(os.path.join(d, "parameters.json"), "w", encoding="utf-8") as f:
                json.dump(params, f)
            for attempt in range(6):
                r = subprocess.run(["az", "deployment", "group", "validate", "--resource-group", self.resource_group(),
                                    "--template-file", os.path.join(d, "template.json"), "--parameters",
                                    "@" + os.path.join(d, "parameters.json"), "--no-prompt", "--only-show-errors", "-o", "json"],
                                   capture_output=True, text=True, timeout=300)
                if r.returncode == 0:
                    return True, ""
                m = re.search(r'"code":\s*"([A-Za-z]+)"', r.stderr)
                code = m.group(1) if m else ""
                if code == "InvalidTemplate" and re.search(self.REFUSALS, r.stderr):
                    return False, r.stderr.strip()
                if code in ("TooManyRequests", "InternalServerError", "ServiceUnavailable", "GatewayTimeout") or "RetryableError" in r.stderr:
                    time.sleep(5 * (attempt + 1))
                    continue
                raise RuntimeError(f"{self.path}: az deployment group validate failed, not a refusal of its inputs:\n{r.stderr[-2000:]}")
        raise RuntimeError(f"{self.path}: az deployment group validate kept failing transiently:\n{r.stderr[-2000:]}")

    def verdicts(self, cases: list[Case]) -> dict[str, tuple[bool, str]]:
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            return {case.name: verdict for case, verdict in zip(cases, pool.map(lambda c: self.validate(c.config), cases))}

    def resource(self, arm: Arm, type_: str) -> dict:
        found = [r for r in self.template["resources"] if r["type"] == type_]
        if len(found) != 1:
            raise RuntimeError(f"{self.path}: expected one {type_}, found {len(found)}")
        if "condition" in found[0] and not arm.truth(arm.value(found[0]["condition"])):
            raise RuntimeError(f"{self.path}: the {type_} isn't deployed for this case")
        return found[0]

    def environment(self, config: Config) -> Config | None:
        arm = Arm(self.template, self.parameters(config))
        try:
            if self.spec["render"] == "container-app":
                return self.container_app_env(arm)
            return self.vm_env(arm)
        except TemplateFail:
            return None

    def container_app_env(self, arm: Arm) -> Config:
        app = self.resource(arm, "Microsoft.App/containerApps")
        secrets = {s["name"]: s.get("value") for s in arm.value(app["properties"]["configuration"]["secrets"])}
        containers = [c for c in arm.value(app["properties"]["template"]["containers"]) if c["name"] == self.spec["container"]]
        if len(containers) != 1:
            raise RuntimeError(f"{self.path}: expected one container {self.spec['container']!r}")
        env = {}
        for entry in containers[0]["env"]:
            if "secretRef" in entry:
                if entry["secretRef"] not in secrets:
                    raise BootRefused(f"{entry['name']} references secret {entry['secretRef']!r}, which the app doesn't define")
                value = secrets[entry["secretRef"]]
            else:
                value = entry.get("value")
            if not isinstance(value, str):
                raise RuntimeError(f"{self.path}: env {entry['name']} renders as {value!r}, not a string")
            env[entry["name"]] = value
        return env

    def vm_env(self, arm: Arm) -> Config:
        vm = self.resource(arm, "Microsoft.Compute/virtualMachines")
        cloud_init = base64.b64decode(arm.value(vm["properties"]["osProfile"]["customData"])).decode()
        env_text = cloud_init_file(cloud_init, "/opt/broch/.env")
        secret_map = arm.fn_variables(self.spec["secret_map"])
        if not secret_map:
            raise BootRefused("the boot fetch stops: an empty Key Vault secret map")
        secrets = {}
        vault = f"variables('{self.spec['secret_vault']}')"
        for r in self.template["resources"]:
            if r["type"] == "Microsoft.KeyVault/vaults/secrets" and vault in r["name"]:
                name = str(arm.value(r["name"])).rsplit("/", 1)[-1]
                deployed = "condition" not in r or arm.truth(arm.value(r["condition"]))
                if deployed:
                    secrets[name] = arm.value(r["properties"]["value"])
        appended = {}
        for entry in filter(None, secret_map.split(";")):
            key, _, secret = entry.partition("=")
            value = secrets.get(secret)
            if not value:
                raise BootRefused(f"the boot fetch stops: Key Vault secret {secret} ({key}) is {'empty' if secret in secrets else 'never created'}")
            if "\n" in value or "\r" in value or "'" in value or value.endswith("\\"):
                raise BootRefused(f"the boot fetch stops: {secret} can't be written to .env single-quoted")
            appended[key] = value
        kept = [line for line in env_text.splitlines(keepends=True)
                if line.lstrip().startswith("#") or line.split("=", 1)[0] not in appended]
        env_text = "".join(kept) + "".join(f"{k}='{v}'\n" for k, v in appended.items())
        # The start gate, as rendered: `if [ "<true|false>" != "true" ]; then` / `grep -q "^KEY='[^']" .env ...`.
        gates = re.findall(r'^\s*if \[ "([^"]*)" != "true" \]; then\n\s*grep -q "\^([A-Z_]+)=\'\[\^\'\]" /opt/broch/\.env \|\|',
                           cloud_init, re.M)
        if len(gates) != cloud_init.count("/opt/broch/.env ||"):
            raise RuntimeError(f"{self.path}: a start gate on .env this check can't read")
        for flag, key in gates:
            if flag not in ("true", "false"):
                raise RuntimeError(f"{self.path}: start gate condition {flag!r} isn't a rendered boolean")
            if flag == "false" and not re.search(rf"^{key}='[^']", env_text, re.M):
                raise BootRefused(f"the start gate stops: no {key} in .env")
        compose = cloud_init_file(cloud_init, "/opt/broch/docker-compose.yml")
        with tempfile.TemporaryDirectory(prefix="config-contract-compose-", dir=os.environ.get("RUNNER_TEMP")) as d:
            compose_file = os.path.join(d, "docker-compose.yml")
            with open(compose_file, "w", encoding="utf-8") as f:
                f.write(compose)
            accepted, why, env = compose_config(self.path, compose_file, env_text, self.spec["compose_service"])
        if not accepted:
            raise BootRefused(f"compose refuses the instance's .env: {why}")
        return env


def cloud_init_file(text: str, path: str) -> str:
    """The content of a cloud-init write_files entry: a `content: |` block scalar, or a one-line
    `content:` with `encoding: b64`."""
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == f"- path: {path}"]
    if len(starts) != 1:
        raise RuntimeError(f"the cloud-init writes {path} {len(starts)} times, not once")
    start = starts[0]
    entry_indent = len(lines[start]) - len(lines[start].lstrip()) + 2
    fields = {}
    for line in lines[start + 1:]:
        if not line.strip() or len(line) - len(line.lstrip()) != entry_indent or line.lstrip().startswith("- "):
            break
        k, _, v = line.strip().partition(":")
        fields[k] = v.strip()
    if fields.get("content") != "|":
        if fields.get("encoding") != "b64" or not fields.get("content"):
            raise RuntimeError(f"cloud-init entry {path}: a content form this check can't read: {fields}")
        return base64.b64decode(fields["content"]).decode()
    content = next(i for i in range(start, len(lines)) if lines[i].strip() == "content: |")
    indent = len(lines[content + 1]) - len(lines[content + 1].lstrip())
    body = []
    for line in lines[content + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:] + "\n")
    return "".join(body)


def make_target(path: str, spec: dict, values: Config, rules: Rules):
    kinds = {"terraform": TerraformTarget, "compose": ComposeTarget, "cloudformation": CfnTarget, "bicep": BicepTarget}
    if spec["kind"] not in kinds:
        raise SystemExit(f"{path}: unknown target kind {spec['kind']!r}")
    return kinds[spec["kind"]](path, spec, values, rules)


_VAR = re.compile(r"\$\$|\\\$|\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-+?])([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)|\$\{")


def interpolate(value: str, env: Config) -> str:
    """Compose's variable expansion: ${VAR}, $VAR (unknown -> empty), ${VAR:-d} / ${VAR-d},
    ${VAR:+a} / ${VAR+a}, and $$ / \\$ for a literal $. ${VAR:?e} / ${VAR?e} fail compose when unset;
    so does any other ${ form."""
    def sub(m: re.Match) -> str:
        if m.group(0) in ("$$", "\\$"):
            return "$"
        if m.group(0) == "${":
            raise RuntimeError(f"a ${{...}} form this check doesn't model: {value!r}")
        name, op, arg = m.group(1) or m.group(4), m.group(2), m.group(3)
        found = env.get(name)
        present, nonempty = found is not None, bool(found)
        if op in (":?", "?") and not (nonempty if op == ":?" else present):
            raise RuntimeError(f"compose would refuse {m.group(0)!r}: {name} is unset")
        if op in (":-", "-") and not (nonempty if op == ":-" else present):
            return arg
        if op in (":+", "+"):
            return arg if (nonempty if op == ":+" else present) else ""
        return found or ""
    return _VAR.sub(sub, value)


def _unescape(value: str) -> str:
    """Double-quoted env-file escapes, left to right (\\$ is left for interpolate())."""
    return re.sub(r"\\([nrt\\\"])", lambda m: {"n": "\n", "r": "\r", "t": "\t"}.get(m.group(1), m.group(1)), value)


def dotenv(text: str, env: Config | None = None) -> Config:
    """An env file as docker compose reads it (compose-go's dotenv): single-quoted values literal;
    double-quoted values with escapes and interpolation; unquoted values cut at ' #', trimmed and
    interpolated. Interpolation sees the file's earlier entries (the droplet's process env adds nothing)."""
    out: Config = dict(env or {})
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$", line)
        if m is None:
            raise RuntimeError(f"not an env-file line: {line!r}")
        key, raw = m.groups()
        if raw[:1] in ("'", '"'):
            quote = raw[0]
            end = next((i for i in range(1, len(raw)) if raw[i] == quote and raw[i - 1] != "\\"), None)
            if end is None:
                raise RuntimeError(f"{key}: unterminated {quote}-quoted value")
            value = raw[1:end]
            if quote == '"':
                value = interpolate(_unescape(value), out)
        else:
            value = interpolate(re.split(r"\s#", raw, maxsplit=1)[0].strip(), out)
        out[key] = value
    return out


def cloud_init_environment(text: str, dotenv_path: str, service: str) -> Config:
    """The environment cloud-init gives Broch: its .env file (read as compose reads an env_file), then
    the compose service's environment list (interpolated from that .env, as compose interpolates the file)."""
    lines = text.splitlines()
    file_env = dotenv(cloud_init_file(text, dotenv_path))
    env = dict(file_env)
    service_at = next((i for i, line in enumerate(lines) if re.fullmatch(rf"\s+{re.escape(service)}:\s*", line)), None)
    if service_at is None:
        raise RuntimeError(f"the cloud-init's compose file has no {service} service")
    service_indent = len(lines[service_at]) - len(lines[service_at].lstrip())
    in_environment, env_indent = False, 0
    for line in lines[service_at + 1:]:
        if not line.strip():
            continue
        current = len(line) - len(line.lstrip())
        if current <= service_indent:
            break
        if line.strip() == "environment:":
            in_environment, env_indent = True, current
            continue
        if in_environment:
            if current <= env_indent:
                in_environment = False
                continue
            if line.strip().startswith("#"):
                continue
            m = re.fullmatch(r"\s*-\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
            if m is None:
                raise RuntimeError(f"{service} environment entry this check can't read: {line.strip()!r}")
            env[m.group(1)] = interpolate(m.group(2), file_env)
    return env


# ── The comparison ──────────────────────────────────────────────────────────────────────────────

def declared(strictness: dict, case: Case, why: str, inputs: dict, rules: Rules) -> bool:
    """Whether a template's refusal of a case Broch accepts is one it declares (targets file). An
    `error` pattern may name the case's mutated input as {input}."""
    value = case.config.get(case.mutated or "")
    var = inputs.get(case.mutated or "")
    if "error" in strictness:
        if "{input}" in strictness["error"] and var is None:
            return False
        if not re.search(strictness["error"].replace("{input}", re.escape(var or "")), why):
            return False
    names_input = var is not None and re.search(rf"\b{re.escape(var)}\b", why) is not None
    if strictness["kind"] == "refuses_first_run":
        return not any(rules.is_set(case.config, k) for k in rules.gate)
    if strictness["kind"] == "refuses_whitespace_only":
        return bool(value) and not value.strip() and names_input
    if strictness["kind"] == "refuses_pattern":
        return value is not None and re.search(strictness["pattern"], value) is not None and names_input
    if strictness["kind"] == "refuses_rule_when_set":
        # One named CloudFormation Rule, only on a case that sets the key that waives Broch's own check.
        return why.startswith(f"Rule {strictness['rule']}:") and rules.is_set(case.config, strictness["key"])
    if strictness["kind"] == "refuses_constraint":
        # One named constraint of a parameter the case sets: CloudFormation's own wording for
        # `constraint`; otherwise the declaration's `error` (already matched above) says which.
        sets = any(v == strictness["parameter"] and k in case.config for k, v in inputs.items())
        if "constraint" not in strictness:
            if "error" not in strictness:
                raise SystemExit("refuses_constraint needs a constraint or an error")
            return sets
        return sets and re.search(rf"^Parameter {re.escape(strictness['parameter'])} failed to satisfy constraint "
                                  rf"{re.escape(strictness['constraint'])}\b", why) is not None
    raise SystemExit(f"Unknown strictness kind {strictness['kind']!r}")


def vacuous(all_cases: list[Case], oracle: Oracle, workers: int) -> list[str]:
    """Each case, as generated (no template), must violate the rules its construction says it violates
    and no rule it says it can't: otherwise it tests nothing, whatever a template does with it."""
    def judge(case: Case) -> tuple[Case, list[str]]:
        return case, oracle.check({env_name(k): v for k, v in case.config.items()})

    failures = []
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for case, violations in pool.map(judge, [c for c in all_cases if c.expect or c.expect_not]):
            missed, wrong = case.expect - set(violations), case.expect_not & set(violations)
            if missed or wrong:
                failures.append(f"VACUOUS case {case.name}: built to violate {sorted(missed)} and not "
                                f"{sorted(wrong)}, but Broch says {violations}")
    return failures


def check_target(path: str, spec: dict, values: Config, rules: Rules, oracle: Oracle, workers: int) -> tuple[int, int, list[str]]:
    target = make_target(path, spec, values, rules)
    inputs = set(target.inputs)
    generated = {n.lower() for n in spec["generated"]} | {n.lower() for n in spec["secret_inputs"]}
    all_cases = list(rules.cases())

    # The template's fixed values (keys it hard-codes), from one rendered valid case.
    fixed_env = next((env for env in (target.environment({k: v for k, v in c.config.items() if k in inputs})
                                      for c in all_cases if c.name.endswith(": valid")) if env is not None), None)
    if fixed_env is None:
        raise RuntimeError(f"{path}: no valid base case renders")
    fixed = {k: lookup(fixed_env, k) for k in target.fixed_keys}

    def expressible(key: str, value: str) -> bool:
        """Whether the template can send this value: an input; or, for a key it supplies itself (fixed or
        generated), the generator's own valid value (stands for "whatever valid value the template sends")
        or, when fixed, the template's value."""
        if key in inputs:
            return True
        if key in fixed or env_name(key).lower() in generated:
            # Such a case collapses into one the template expresses with its own value, so a rule over
            # a fixed key counts as covered without that value ever being sent. That's sound only
            # because the template's own value is judged in every render; don't read more into it.
            if value == rules.valid_value(key):
                return True
            return fixed.get(key) is not None and value.strip().lower() == fixed[key].strip().lower()
        return False

    cases: dict[str, Case] = {}
    for case in all_cases:
        if not all(expressible(k, v) for k, v in case.config.items()):
            continue
        expressed = {k: v for k, v in case.config.items() if k in inputs}
        key = json.dumps(expressed, sort_keys=True)
        if key not in cases:
            cases[key] = Case(case.name, expressed, "", case.mutated)
            cases[key].rules = set()
        cases[key].rules |= case.rules
    case_list = list(cases.values())
    verdicts = target.verdicts(case_list)

    def judge(case: Case) -> tuple[Case, Config | None, list[str], str]:
        boot = ""
        try:
            rendered = target.environment(case.config)
        except BootRefused as e:
            rendered, boot = None, str(e)
        if rendered is not None:
            # A value only known at deploy time can't be judged: never let one pass as a non-empty string.
            for rule in rules.all:
                for key in rule["keys"]:
                    value = lookup(rendered, key)
                    if value is not None and DEPLOY_TIME in value:
                        raise RuntimeError(f"{path}: {env_name(key)} (rule {rule['id']}) is only known at deploy time: {value!r}")
        sent = rendered
        if sent is None:
            # Refused before rendering: judge the inputs as the template would send them, over everything
            # else it sends (a rendered valid case, without its input keys).
            input_names = {env_name(k).lower() for k in inputs}
            sent = {k: v for k, v in fixed_env.items() if k.lower() not in input_names}
            sent.update({env_name(k): v for k, v in case.config.items()})
        return case, rendered, oracle.check(sent), boot

    # A template that validates none of Broch's settings (it can't: a compose .env) declares so, with
    # its reason; Broch is then the first to judge, and only the other directions are checked.
    unvalidated = "unvalidated" in spec
    if unvalidated and not (isinstance(spec["unvalidated"], dict) and str(spec["unvalidated"].get("why", "")).strip()):
        raise SystemExit(f"{path}: unvalidated needs its reason (a non-empty why)")
    failures, stricter, renders = [], 0, []
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for case, rendered, violations, boot in pool.map(judge, case_list):
            accepted, why = verdicts[case.name]
            if boot and accepted:
                # Accepted at deploy, then the instance won't start Broch: the outcome this check exists
                # to prevent, whatever Broch would have said, unless the target declares that stop
                # (a deliberate fail-closed boot, with its reason) for an input the case leaves blank.
                if any(re.search(d["boot"], boot) and not (case.config.get(d["key"]) or "").strip()
                       for d in spec.get("boot_refusals", [])):
                    stricter += 1
                    continue
                failures.append(f"ACCEPTS at deploy, then never starts Broch: {case.name}\n      {boot}\n      inputs {case.config}")
                continue
            if accepted and rendered is None:
                raise RuntimeError(f"{path}: plan accepts {case.name!r} but console refuses to render it")
            if rendered is not None:
                renders.append(rendered)
                if accepted:
                    for key, value in case.config.items():
                        sent = lookup(rendered, key)
                        if value.strip() and sent != value:
                            failures.append(f"CHANGES {env_name(key)}: {case.name}\n      entered {value!r}, Broch gets {sent!r}")
            if accepted and violations and not unvalidated:
                failures.append(f"ACCEPTS what Broch refuses ({', '.join(violations)}): {case.name}\n      inputs {case.config}")
            elif not accepted and not violations:
                if any(declared(s, case, why, target.inputs, rules)
                       for s in spec["stricter"] + spec.get("stricter_extra", [])):
                    stricter += 1
                else:
                    failures.append(f"REFUSES what Broch accepts: {case.name}\n      inputs {case.config}\n      template: {why}")

    # Coverage, fail closed. A key a rule checks that the template sends must be mapped to an input,
    # generated, a secret input, or declared fixed (then the same in every case). An unmapped input is
    # constant too, at its default, so constancy alone proves nothing.
    for rule in rules.all:
        for key in rule["keys"]:
            sent = [lookup(r, key) for r in renders]
            if key in inputs or env_name(key).lower() in generated or all(v is None for v in sent):
                continue
            if key not in fixed:
                failures.append(f"UNMAPPED: the template sends {env_name(key)} (rule {rule['id']}), but "
                                "scripts/config-contract-targets.json neither maps an input to it nor declares it fixed")
            elif len(set(sent)) > 1:
                failures.append(f"NOT FIXED: {key} is declared fixed but the template sends {sorted(set(map(str, sent)))}")
    # Every rule over a template input, whose conditions the template's fixed values allow, has a case.
    covered = set().union(*(c.rules for c in case_list)) if case_list else set()
    for rule in rules.all:
        if not any(k in inputs for k in rule["keys"]):
            continue
        # A distinct rule compares two keys: the template must be able to send both.
        if rule["check"] == "distinct" and not all(k in inputs or fixed.get(k) for k in rule["keys"]):
            continue
        possible = all(
            any(k in inputs or fixed.get(k) for k in c["keys"]) if c["op"] == "anySet"
            else c["keys"][0] in inputs or (fixed.get(c["keys"][0]) or "").strip().lower() in [v.lower() for v in c["values"]]
            if c["op"] == "in" else c["keys"][0] in inputs or not fixed.get(c["keys"][0])
            for c in rule["when"])
        if possible and rule["id"] not in covered:
            failures.append(f"NO CASE: rule {rule['id']} checks an input of this template but no case tests it")
    return len(case_list), stricter, failures


def load_targets() -> dict:
    with open(TARGETS_FILE, encoding="utf-8") as f:
        spec = json.load(f)
    for target in spec["targets"].values():
        base = spec["defaults"][target.pop("extends")] if "extends" in target else {}
        target.update({k: v for k, v in base.items() if k not in target})
    # Every published CloudFormation variant is a target, and every variant target is published.
    variants = {t["variant"] for t in spec["targets"].values() if "variant" in t}
    if variants:
        generate_aws_variant = import_variant_generator()
        published = {e["auth"] for e in generate_aws_variant.variants()}
        if variants != published:
            raise SystemExit(f"{TARGETS_FILE}: variant targets {sorted(variants)} != published variants {sorted(published)}")
    return spec


# Files every target's verdict depends on: a change to any of them re-checks every target.
GLOBAL_INPUTS = ("scripts/config-contract.py", "scripts/config-contract-targets.json", "scripts/BROCH_VERSION")


EVERYTHING = ""  # a read this check can't resolve: the target depends on every file


def reads_outside(path: str, target: dict) -> list[str]:
    """What a target reads from outside its own directory, derived from its source so a new read
    can't be missed. Terraform: `${path.module}/../<dir>/...` up to the first interpolation, and the
    mocks' directory. Any other way out of the module (a bare "../", path.root, path.cwd, abspath(),
    a `..` module source) is not resolved: the target then depends on every file. A kind without a
    deriver here is refused. Compose: only its compose file matters to the verdict, so nothing outside
    the directory, unless that file names a path up out of it (outside a comment): then every file."""
    if target["kind"] == "bicep":
        # Every file a template pulls in at compile time is named by a literal: load*() functions,
        # `module`, `import ... from`, `using` and `extends`. Follow them through every .bicep file in
        # the target's directory and through any .bicep file they lead to (a module in turn names its
        # own), resolving each against the file that names it. Registry modules (br:, br/, ts:) aren't
        # repository files.
        reference = re.compile(r"\bload\w+\(\s*'([^']+)'|^\s*module\s+\w+\s+'([^']+)'|\bfrom\s+'([^']+)'"
                               r"|^\s*(?:using|extends)\s+'([^']+)'", re.M)
        found: set[str] = set()
        pending = [os.path.join(path, os.path.relpath(os.path.join(d, n), os.path.join(ROOT, path)))
                   for d, _, names in os.walk(os.path.join(ROOT, path)) for n in names if n.endswith(".bicep")]
        seen = set(pending)
        while pending:
            current = pending.pop()
            with open(os.path.join(ROOT, current), encoding="utf-8") as f:
                text = f.read()
            for match in reference.finditer(text):
                rel = next(g for g in match.groups() if g)
                if re.match(r"(br|ts)[:/]", rel):
                    continue
                target_path = os.path.normpath(os.path.join(os.path.dirname(current), rel))
                if target_path.startswith(".."):
                    raise SystemExit(f"{path} reads outside the repository: {target_path}")
                found.add(target_path)
                if target_path.endswith(".bicep") and target_path not in seen and os.path.isfile(os.path.join(ROOT, target_path)):
                    seen.add(target_path)
                    pending.append(target_path)
        return sorted(p for p in found if not (p + "/").startswith(path.rstrip("/") + "/"))
    if target["kind"] == "cloudformation":
        # The template's directory (template, variant manifest and axes), the compose files it embeds,
        # its build script and the variant generator.
        return sorted({target["dir"], target["build_script"], *target["embeds"].values(),
                       *(["scripts/generate_aws_variant.py"] if "variant" in target else [])})
    if target["kind"] == "compose":
        with open(os.path.join(ROOT, path, target["compose_file"]), encoding="utf-8") as f:
            code = "\n".join(re.sub(r"(^|\s)#.*", "", line) for line in f.read().splitlines())
        return [EVERYTHING] if ".." in code else []
    if target["kind"] != "terraform":
        raise SystemExit(f"{path}: no dependency deriver for kind {target['kind']!r}; teach scripts/config-contract.py")
    module = os.path.join(ROOT, path)
    found = {os.path.normpath(os.path.join(path, os.path.dirname(target["mocks"]) or "."))}
    for name in sorted(os.listdir(module)):
        if not name.endswith(".tf"):
            continue
        with open(os.path.join(module, name), encoding="utf-8") as f:
            text = f.read()
        for rel in re.findall(r"\$\{path\.module\}/(\.\./[^\"$]*)", text):
            found.add(os.path.normpath(os.path.join(path, os.path.dirname(rel) or ".")))
        unresolved = re.sub(r"\$\{path\.module\}/\.\./[^\"$]*", "", text)
        if re.search(r"\.\.[/\\\"]|\bpath\.(root|cwd)\b|\babspath\(", unresolved):
            return [EVERYTHING]
    if any(p.startswith("..") for p in found):
        raise SystemExit(f"{path} reads outside the repository: {sorted(found)}")
    return sorted(found)


def affected(spec: dict, changed: list[str]) -> list[str]:
    """The targets a change can affect: each target's own directory plus what it reads from elsewhere;
    every target when a global input changed."""
    def under(path: str, prefix: str) -> bool:
        # "." is a read of the repository root (`${path.module}/../../file`): every path is under it.
        return prefix in (EVERYTHING, ".") or path == prefix.rstrip("/") or path.startswith(prefix.rstrip("/") + "/")

    if any(under(f, g) for f in changed for g in GLOBAL_INPUTS):
        return list(spec["targets"])
    return [path for path, target in spec["targets"].items()
            if any(under(f, p) for f in changed for p in [target.get("dir", path), *reads_outside(path, target)])]


def missing_requirements(oracle_kind: str, targets: dict[str, dict]) -> list[str]:
    """What the run needs and doesn't have (see Requirements in the docstring), one line each.
    Checks each tool is present (and docker's compose plugin), not its version."""
    problems = []
    need = {oracle_kind: "the oracle"}
    for path, target in targets.items():
        kind = target["kind"]
        if kind != "terraform" or target.get("render") == "cloud-init":
            need.setdefault("docker", f"{path} (docker compose)")
        if kind == "terraform":
            need.setdefault("terraform", path)
            if not os.path.isdir(os.path.join(ROOT, path, ".terraform")):
                problems.append(f"{path}: not initialized; run `terraform -chdir={path} init -backend=false`")
        elif kind == "bicep":
            need.setdefault("az", path)
        elif kind == "cloudformation":
            need.setdefault("cfn-lint", path)
    for tool, user in need.items():
        found = importlib.util.find_spec("cfnlint") is not None if tool == "cfn-lint" else shutil.which(tool)
        if not found:
            hint = f"; `pip install cfn-lint=={CFN_LINT_VERSION}`" if tool == "cfn-lint" else ""
            problems.append(f"{tool}: not found (needed by {user}){hint}")
        elif tool == "docker" and any(t["kind"] != "terraform" or t.get("render") == "cloud-init"
                                      for t in targets.values()):
            r = subprocess.run(["docker", "compose", "version"], capture_output=True, text=True, timeout=60)
            if r.returncode != 0:
                problems.append(f"docker compose: the compose plugin is not installed (needed by {user})")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--oracle", help="docker:<image> or dotnet:<path to Broch.Api.dll>")
    parser.add_argument("--target", action="append", help="only these templates (default: all)")
    parser.add_argument("--workers", type=int, default=4)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--affected", metavar="CHANGED_FILES",
                      help="print (JSON) the targets a change affects, from a file of changed paths (NUL- or "
                           "newline-separated, as `git diff --name-only [-z]` writes); '-' for all targets. "
                           "Needs no oracle.")
    mode.add_argument("--cases-only", action="store_true", help="only check that the derived cases are sound")
    mode.add_argument("--skip-case-check", action="store_true",
                      help="don't check the derived cases (for a run split into one target per job, with "
                           "--cases-only run once beside them)")
    args = parser.parse_args()

    spec = load_targets()
    if args.affected:
        if args.oracle or args.target:
            parser.error("--affected takes no --oracle or --target")
        if args.affected == "-":
            print(json.dumps(list(spec["targets"])))
        else:
            with open(args.affected, encoding="utf-8", newline="") as f:
                changed = [p for p in re.split(r"[\0\n]", f.read()) if p]
            print(json.dumps(affected(spec, changed)))
        return
    if not args.oracle:
        parser.error("--oracle is required")
    for path in args.target or []:
        if path not in spec["targets"]:
            parser.error(f"unknown target {path!r}")
    oracle = Oracle(args.oracle)  # refuses an unknown oracle kind
    selected = {} if args.cases_only else {
        path: target for path, target in spec["targets"].items() if not args.target or path in args.target}
    if not args.target:
        # The Bicep targets ask Azure; without a resource group to ask in, skip them unless named.
        for path, target in list(selected.items()):
            if target["kind"] == "bicep" and not os.environ.get(target["resource_group_env"]):
                print(f"{path}: skipped (set {target['resource_group_env']} to a resource group to validate in, "
                      f"or name it with --target)", flush=True)
                del selected[path]
    problems = missing_requirements(oracle.kind, selected)
    if problems:
        raise SystemExit("missing requirements:\n" + "\n".join(f"  - {p}" for p in problems))
    rules = Rules(oracle.rules())
    failed = False
    if not args.skip_case_check:
        print("cases: checking each is what it was built to be ...", flush=True)
        problems = vacuous(list(rules.cases()), oracle, args.workers)
        for problem in problems:
            print(f"  - {problem}", flush=True)
        failed = bool(problems)
    if args.cases_only:
        sys.exit(1 if failed else 0)
    for path, target in selected.items():
        print(f"{path}: checking ...", flush=True)
        total, stricter, failures = check_target(path, target, spec["values"], rules, oracle, args.workers)
        print(f"{path}: {total} cases, {len(failures)} problems, {stricter} refused by declared strictness", flush=True)
        for failure in failures:
            print(f"  - {failure}", flush=True)
        failed |= bool(failures)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
