#!/usr/bin/env python3
"""Filter the canonical aws-vm template into one manifest-published variant.

The manifest is JSON syntax in a YAML file, so build.sh needs only Python's stdlib.
Each output hides irrelevant identity fields; database and DNS stay configurable.
"""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
AWS_VM = ROOT / "cloudformation/aws-vm"
sys.path.insert(0, str(AWS_VM))
from variant_axes import AUTH_BUCKETS, AUTH_FIELDS, inactive_auth_rules  # noqa: E402

MANIFEST = AWS_VM / "published_variants.yaml"
PARAMETER = re.compile(r"^  ([A-Za-z][A-Za-z0-9]*):(?:\s|$)", re.M)
AUTH_LABELS = {
    "AzureAd": "Microsoft Entra ID",
    "Okta": "Okta",
    "Auth0": "Auth0",
    "Oidc": "OpenID Connect",
}


def variants(path=MANIFEST):
    entries = json.loads(Path(path).read_text())
    if not isinstance(entries, list) or not entries:
        raise ValueError("published variants must be a nonempty list")
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"auth", "db", "dns"}:
            raise ValueError(f"invalid variant entry: {entry!r}")
        key = (entry["auth"], entry["db"], entry["dns"])
        if key in seen or key[0] not in AUTH_BUCKETS or key[1:] != ("Shared", "Shared"):
            raise ValueError(f"duplicate or unsupported variant: {key}")
        seen.add(key)
    return entries


def filename(entry):
    return "template-" + "-".join(entry[k].lower() for k in ("auth", "db", "dns")) + ".yaml"


def sections(text):
    for name in ("Metadata", "Parameters", "Rules", "Resources"):
        if len(re.findall(rf"^{name}:$", text, re.M)) != 1:
            raise ValueError(f"expected exactly one {name} section")
    before, rest = text.split("Parameters:\n", 1)
    params, rest = rest.split("Rules:\n", 1)
    rules, after = rest.split("Resources:\n", 1)
    return before, params, rules, after


def filter_blocks(body, omit):
    matches = list(PARAMETER.finditer(body))
    names = [m.group(1) for m in matches]
    if not omit <= set(names):
        raise ValueError(f"missing expected blocks: {sorted(omit - set(names))}")
    chunks = [body[:matches[0].start()]]
    for i, match in enumerate(matches):
        if match.group(1) not in omit:
            chunks.append(body[match.start():matches[i + 1].start() if i + 1 < len(matches) else len(body)])
    return "".join(chunks)


def render(text, entry):
    if entry["auth"] not in AUTH_BUCKETS or (entry["db"], entry["dns"]) != ("Shared", "Shared"):
        raise ValueError(f"unsupported axis values: {entry}")
    auth = entry["auth"]
    dropped = AUTH_FIELDS - AUTH_BUCKETS[auth]
    before, params, rules, after = sections(text)
    phrase = "identity provider sign-in"
    if before.count(phrase) != 1:
        raise ValueError("template description shape changed")
    before = before.replace(phrase, f"{AUTH_LABELS[auth]} sign-in")
    group_label = "Identity provider - use the selected template"
    if before.count(group_label) != 1:
        raise ValueError("identity group label shape changed")
    before = before.replace(group_label, f"{AUTH_LABELS[auth]} sign-in")

    group = re.search(r"^(\s+Parameters: \[)(AuthProvider, AuthClientId[^\n]+)(\])$", before, re.M)
    if not group:
        raise ValueError("identity ParameterGroup shape changed")
    group_fields = [v.strip() for v in group.group(2).split(",")]
    if set(group_fields) != AUTH_FIELDS | {"AuthProvider", "AuthClientId", "AuthClientSecret", "AuthAdminRoles", "AuthAudience"}:
        raise ValueError("identity ParameterGroup and axis config disagree")
    before = before[:group.start(2)] + ", ".join(v for v in group_fields if v not in dropped) + before[group.end(2):]
    for field in dropped:
        label = re.compile(rf"^      {field}: \{{ default: [^\n]+\}}\n", re.M)
        before, count = label.subn("", before)
        if count != 1:
            raise ValueError(f"expected one label for hidden parameter {field}")

    params = filter_blocks(params, dropped)
    provider = re.search(r"  AuthProvider:\n(?:(?!^  \w).)*", params, re.M | re.S)
    if (not provider or provider.group().count('    Default: ""') != 1 or
            "    AllowedValues:" in provider.group()):
        raise ValueError("AuthProvider default or allowed values missing or ambiguous")
    replacement = provider.group().replace('    Default: ""',
        f"    Default: {auth}\n    AllowedValues: [{auth}]")
    params = params[:provider.start()] + replacement + params[provider.end():]

    inactive = inactive_auth_rules(auth)
    rules = filter_blocks(rules, inactive)
    for field in dropped:
        if re.search(rf"!Ref {field}\b", before + params + rules + after):
            raise ValueError(f"unhandled reference to dropped {field}")
        if after.count("${" + field + "}") != 1:
            raise ValueError(f"expected one UserData substitution for {field}")

    anchor = "            - DataVolumeId: !If [IsLocal, !Ref DataVolume, \"\"]"
    if after.count(anchor) != 1:
        raise ValueError("UserData Fn::Sub map anchor missing or ambiguous")
    # Fn::Sub's explicit map supplies empty values for hidden fields, preserving
    # the exact boot script and avoiding unresolved references to removed parameters.
    additions = "\n".join(f'              {field}: ""' for field in sorted(dropped))
    after = after.replace(anchor, anchor + "\n" + additions)
    return before + "Parameters:\n" + params + "Rules:\n" + rules + "Resources:\n" + after


def self_test():
    entries = variants()
    source = (AWS_VM / "template.yaml").read_text()
    for entry in entries:
        result = render(source, entry)
        before, params, rules, _ = sections(result)
        parameter_names = PARAMETER.findall(params.split("Conditions:\n", 1)[0])
        grouped = [name.strip() for group in re.findall(r"^\s+Parameters: \[([^\n]+)\]$", before, re.M)
                   for name in group.split(",")]
        labels = re.findall(r"^      ([A-Za-z][A-Za-z0-9]*): \{ default:", before, re.M)
        assert len(grouped) == len(set(grouped)) == len(parameter_names)
        assert set(grouped) == set(labels) == set(parameter_names)
        route53 = re.search(r"Label: \{ default: \"Route 53[^\n]+\n\s+Parameters: \[([^\n]+)\]", before)
        assert route53 and route53.group(1) == "HostedZoneId"
        for field in AUTH_FIELDS - AUTH_BUCKETS[entry["auth"]]:
            assert not re.search(rf"^  {field}:", result, re.M)
            assert not re.search(rf"^      {field}: \{{ default:", result, re.M)
            assert f'              {field}: ""' in result
        assert f"    AllowedValues: [{entry['auth']}]" in result
        assert 'Assert: !Not [!Equals [!Ref AuthClientSecret, ""]]' in rules
        assert f"Deploy Broch on an EC2 instance with {AUTH_LABELS[entry['auth']]} sign-in" in result
    assert "EntraExternalId" in source
    for bad in (source.replace("  AuthDomain:", "  MissingDomain:"),
                source.replace("${AuthDomain}", "${OtherDomain}"),
                source.replace("            - DataVolumeId:", "            - UnknownId:")):
        try:
            render(bad, entries[0])
        except ValueError:
            pass
        else:
            raise AssertionError("generator accepted changed canonical wiring")
    print(f"generator self-test: {len(entries)} variants and fail-closed cases passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print generated filenames")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    entries = variants()
    if args.list:
        for entry in entries:
            print(filename(entry))
        return
    if not args.source or not args.output_dir:
        parser.error("--source and --output-dir are required for generation")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for entry in entries:
        path = args.output_dir / filename(entry)
        path.write_text(render(args.source.read_text(), entry))
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
