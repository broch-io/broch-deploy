"""Identity parameters retained by each published AWS VM template."""

AUTH_FIELDS = frozenset({"AuthDomain", "AuthTenantId", "AuthInstance", "AuthAuthority", "AuthAudience"})
AUTH_BUCKETS = {
    "AzureAd": frozenset({"AuthTenantId", "AuthInstance"}),
    "Okta": frozenset({"AuthDomain"}),
    # Only Auth0 is sent an audience: it names the Auth0 API whose access token carries roles.
    "Auth0": frozenset({"AuthDomain", "AuthAudience"}),
    "Oidc": frozenset({"AuthAuthority"}),
}

def inactive_auth_rules(auth):
    rules = {
        "AuthAzureAdRequiresTenant",
        "AuthDomainProviderRequiresDomain",
        "AuthAuth0RequiresAudience",
        "AuthOidcRequiresAuthority",
    }
    if auth == "AzureAd":
        rules.remove("AuthAzureAdRequiresTenant")
    if auth in ("Okta", "Auth0"):
        rules.remove("AuthDomainProviderRequiresDomain")
    if auth == "Auth0":
        rules.remove("AuthAuth0RequiresAudience")
    if auth == "Oidc":
        rules.remove("AuthOidcRequiresAuthority")
    return rules
