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
# Template parameter -> the AUTHENTICATION__ key it feeds in the rendered .env.
ENV_KEYS = {
    "AuthProvider": "PROVIDER",
    "AuthClientId": "CLIENTID",
    "AuthAdminRoles": "ADMINROLES",
    "AuthAudience": "AUDIENCE",
    "AuthDomain": "DOMAIN",
    "AuthTenantId": "TENANTID",
    "AuthInstance": "INSTANCE",
    "AuthAuthority": "AUTHORITY",
}
# The deploy-time Rules that enforce each provider's required fields, and the fields each asserts.
ACTIVE_RULE = {
    "AzureAd": {"AuthAzureAdRequiresTenant": {"AuthTenantId", "AuthInstance"}},
    "Okta": {"AuthDomainProviderRequiresDomain": {"AuthDomain"}},
    "Auth0": {"AuthDomainProviderRequiresDomain": {"AuthDomain"}, "AuthAuth0RequiresAudience": {"AuthAudience"}},
    "Oidc": {"AuthOidcRequiresAuthority": {"AuthAuthority"}},
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
    if set(group_fields) != AUTH_FIELDS | {"AuthProvider", "AuthClientId", "AuthClientSecret", "AuthAdminRoles"}:
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


def check_provider_wiring(result, entry):
    """The fields broch refuses to boot without for this provider (its required-field check at boot)
    must survive the filter as parameters, reach .env under the right key without being shadowed
    by the UserData Fn::Sub map, and stay enforced by a deploy-time Rule that references them."""
    _, params, rules, resources = sections(result)
    params = params.split("Conditions:\n", 1)[0]
    auth = entry["auth"]
    for field in AUTH_BUCKETS[auth]:
        assert re.search(rf"^  {field}:", params, re.M), f"{auth}: {field} parameter dropped"
    for field in AUTH_BUCKETS[auth] | {"AuthProvider", "AuthClientId", "AuthAdminRoles"}:
        # A real .env line (not a comment), and no Fn::Sub map entry overriding the parameter —
        # a `Field: ""` there renders the line empty while the text above still reads correctly.
        assert re.search(rf"^\s+AUTHENTICATION__{ENV_KEYS[field]}=\$\{{{field}\}}$", resources, re.M), \
            f"{auth}: {field} not wired to .env"
        assert not re.search(rf"^              {field}:", resources, re.M), \
            f"{auth}: {field} shadowed in the UserData Fn::Sub map"
    assert set().union(*ACTIVE_RULE[auth].values()) == AUTH_BUCKETS[auth], \
        f"{auth}: its rules and its identity fields disagree"
    for rule, fields in ACTIVE_RULE[auth].items():
        block = re.search(rf"^  {rule}:\n(?:(?!  \S).*\n)*", rules, re.M)
        assert block, f"{auth}: rule {rule} dropped"
        # The whole condition must be a plain (Or of) AuthProvider equality that names this
        # provider: a !Not or !And around it would skip the Rule while still mentioning it.
        cond = re.search(r"^    RuleCondition: (.+)$", block.group(), re.M)
        equals = r"!Equals \[!Ref AuthProvider, \w+\]"
        assert cond and re.fullmatch(rf"{equals}|!Or \[{equals}(?:, {equals})+\]", cond.group(1)) \
            and f"!Equals [!Ref AuthProvider, {auth}]" in cond.group(1), \
            f"{auth}: rule {rule} no longer applies to {auth}"
        for field in fields:
            # The predicate itself, not just a mention: a dropped !Not would let "" through.
            assert f'!Not [!Equals [!Ref {field}, ""]]' in block.group(), \
                f"{auth}: rule {rule} no longer requires {field} to be non-empty"


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
        check_provider_wiring(result, entry)
    assert "EntraExternalId" in source
    by_auth = {e["auth"]: e for e in entries}
    anchor = '            - DataVolumeId: !If [IsLocal, !Ref DataVolume, ""]'
    for auth, bad, expected in (
        ("AzureAd", source.replace("AUTHENTICATION__TENANTID=${AuthTenantId}", "AUTHENTICATION__TENANT=${AuthTenantId}"),
         "AuthTenantId not wired to .env"),
        ("AzureAd", source.replace(anchor, anchor + '\n              AuthTenantId: ""'),
         "AuthTenantId shadowed in the UserData Fn::Sub map"),
        ("AzureAd", source.replace('!Not [!Equals [!Ref AuthTenantId, ""]]', '!Not [!Equals [!Ref AuthInstance, ""]]'),
         "no longer requires AuthTenantId"),
        ("Auth0", source.replace('!Not [!Equals [!Ref AuthDomain, ""]]', '!Equals [!Ref AuthDomain, ""]'),
         "no longer requires AuthDomain"),
        ("Oidc", source.replace("AUTHENTICATION__AUTHORITY=${AuthAuthority}", "AUTHENTICATION__AUTHORITY="),
         "AuthAuthority not wired to .env"),
        ("Oidc", source.replace("    RuleCondition: !Equals [!Ref AuthProvider, Oidc]",
                                "    RuleCondition: !Equals [!Ref AuthProvider, OIDC]"),
         "no longer applies to Oidc"),
        ("Oidc", source.replace("    RuleCondition: !Equals [!Ref AuthProvider, Oidc]",
                                "    RuleCondition: !Not [!Equals [!Ref AuthProvider, Oidc]]"),
         "no longer applies to Oidc"),
        ("Auth0", source.replace("    RuleCondition: !Or [!Equals [!Ref AuthProvider, Auth0], !Equals [!Ref AuthProvider, Okta]]",
                                 "    RuleCondition: !Not [!Or [!Equals [!Ref AuthProvider, Auth0], !Equals [!Ref AuthProvider, Okta]]]"),
         "no longer applies to Auth0"),
        ("Auth0", source.replace("  AuthDomainProviderRequiresDomain:", "  AuthDomainRuleRenamed:"),
         "rule AuthDomainProviderRequiresDomain dropped"),
        ("Auth0", source.replace('!Not [!Equals [!Ref AuthAudience, ""]]', '!Equals [!Ref AuthAudience, ""]'),
         "no longer requires AuthAudience"),
        ("Auth0", source.replace("AUTHENTICATION__AUDIENCE=${AuthAudience}", "AUTHENTICATION__AUDIENCE="),
         "AuthAudience not wired to .env"),
        ("Okta", source.replace("AUTHENTICATION__CLIENTID=${AuthClientId}", "AUTHENTICATION__CLIENT=${AuthClientId}"),
         "AuthClientId not wired to .env"),
    ):
        if auth not in by_auth:
            continue
        assert bad != source, f"fail-closed case for {auth} ({expected}) no longer matches the template"
        result = render(bad, by_auth[auth])  # the mutation must render; only the wiring check may object
        try:
            check_provider_wiring(result, by_auth[auth])
        except AssertionError as exc:
            assert expected in str(exc), f"{auth}: wiring check failed for the wrong reason: {exc}"
        else:
            raise AssertionError(f"provider wiring check accepted a broken {auth} variant ({expected})")
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
