"""Identity parameters retained by each published AWS VM template."""

AUTH_FIELDS = frozenset({"AuthDomain", "AuthTenantId", "AuthInstance", "AuthAuthority"})
AUTH_BUCKETS = {
    "AzureAd": frozenset({"AuthTenantId", "AuthInstance"}),
    "Okta": frozenset({"AuthDomain"}),
    "Auth0": frozenset({"AuthDomain"}),
    "Oidc": frozenset({"AuthAuthority"}),
}

def inactive_auth_rules(auth):
    rules = {
        "AuthAzureAdRequiresTenant",
        "AuthDomainProviderRequiresDomain",
        "AuthOidcRequiresAuthority",
    }
    if auth == "AzureAd":
        rules.remove("AuthAzureAdRequiresTenant")
    if auth in ("Okta", "Auth0"):
        rules.remove("AuthDomainProviderRequiresDomain")
    if auth == "Oidc":
        rules.remove("AuthOidcRequiresAuthority")
    return rules
