// Broch on Azure Container Apps — Bicep deployment template.
//
// Deploys the Broch server on Azure Container Apps with PostgreSQL:
// - Embedded mode: EVALUATION ONLY — PostgreSQL sidecar on ephemeral storage
//   (single replica). The database does not survive revision restarts, image
//   upgrades, or platform maintenance: each one returns the app to first-run
//   state (re-enter IdP config, re-activate the license). Azure Files can't
//   host postgres (SMB has no chmod, initdb requires it), and that's fine for
//   this mode's purpose: click, deploy, evaluate.
// - Managed mode:  provisions a private Azure Database for PostgreSQL flexible
//   server in a dedicated VNet — a production shape.
// - Shared mode:   bring-your-own PostgreSQL connection string (e.g. Flexible
//   Server) — a production shape.
//
// See README.md for the architecture, custom-domain / wildcard-TLS steps, and
// tradeoffs.

targetScope = 'resourceGroup'

// ============================================================================
// Core Parameters
// ============================================================================

@description('Location for all resources')
param location string = resourceGroup().location

@description('Base name for resources')
param siteName string = 'broch-${uniqueString(resourceGroup().id)}'

@description('At-rest encryption root used to derive the DataProtection keyring wrap key (HKDF-SHA256). Customer-owned; rotating it invalidates anything DP-wrapped in the database. Required.')
@secure()
@minLength(32)
param masterKey string
// @minLength counts spaces; Broch also refuses a key that is only whitespace. Checked at preflight,
// and the container's master-key secret reads the key through it.
var checkedMasterKey = empty(trim(masterKey)) ? fail('masterKey must not be only spaces.') : masterKey

@description('Container image to deploy. Defaults to a concrete pinned version (NOT :latest) so a revision restart never silently rolls the app across an EF-migration boundary; new releases of this template bump this default. Override with a newer tag to upgrade deliberately, or :latest to float.')
param containerImage string = 'ghcr.io/broch-io/broch:1.35.0'

// ============================================================================
// Database Parameters
// ============================================================================

@description('Database deployment mode. Embedded: evaluation only — single-instance PostgreSQL sidecar on EPHEMERAL storage; the database is lost on revision restarts, image upgrades, and platform maintenance. Managed: provision an Azure Database for PostgreSQL flexible server in this deployment (production). Shared: connect to an external PostgreSQL via connection string (production).')
@allowed(['Embedded', 'Managed', 'Shared'])
param databaseMode string = 'Embedded'

@secure()
@description('PostgreSQL connection string. Required for Shared mode. For Embedded/Managed modes it is generated automatically.')
param databaseConnectionString string = ''

@secure()
@description('PostgreSQL password for the Embedded mode sidecar. Auto-generated when omitted — the sidecar is reachable only on localhost inside the Container App. Ignored in Shared/Managed modes.')
param databasePassword string = ''

@secure()
@description('Administrator password for the PostgreSQL flexible server provisioned in Managed mode. Required for Managed mode; ignored otherwise.')
param postgresAdminPassword string = ''

@description('Compute SKU for the PostgreSQL flexible server provisioned in Managed mode (e.g. Standard_B1ms burstable, Standard_D2ds_v5 general purpose).')
param postgresSkuName string = 'Standard_B1ms'

// ============================================================================
// API & Networking Parameters
// ============================================================================

@description('Central server URL for license validation and config delivery')
param centralServerUrl string = 'https://api.broch.io'

@description('Wildcard hostname for tunnel subdomains (e.g., broch.company.com). Required — the server fails to start without it.')
@minLength(1)
param wildcardHostname string

// Broch refuses a hostname of only spaces at startup; refuse it at preflight instead.
var checkedWildcardHostname = empty(trim(wildcardHostname)) ? fail('wildcardHostname must not be only spaces.') : wildcardHostname

// ============================================================================
// Authentication & Authorization Parameters
// ============================================================================

@description('Authentication provider type. Leave empty (with the other sign-in values) to set up sign-in in the app.')
@allowed(['', 'AzureAd', 'EntraExternalId', 'Auth0', 'Okta', 'Oidc'])
param authProvider string = ''

@description('Identity provider tenant ID (e.g., contoso.onmicrosoft.com or a GUID). Required for AzureAd and EntraExternalId providers. Auth0 uses authDomain instead.')
param authTenantId string = ''

@description('OAuth2 client/application ID registered in the identity provider')
param authClientId string = ''

@description('Identity provider instance URL. Leave empty for AzureAd to use the login authority of the cloud this deploys into (public, Government, or China — resolved automatically). Required for EntraExternalId (https://<tenant>.ciamlogin.com/) unless authAuthority is set. Auth0/Okta derive their authority from authDomain.')
param authInstance string = ''

@description('Auth0/Okta domain (e.g., contoso.auth0.com or contoso.okta.com). Only used when authProvider is Auth0 or Okta.')
param authDomain string = ''

@description('Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers.')
param authAuthority string = ''

@description('Required for Auth0: the Identifier of the Auth0 API your Broch application has user access to. Ignored by other providers.')
@maxLength(500)
param authAudience string = ''

// Broch refuses to start as Auth0 without an audience, and only after the app is built and the
// database migrated. This variable depends only on parameters, so ARM evaluates it at preflight
// validation and the fail() stops the deployment before any resource exists. The container reads
// the audience through it (not authAudience directly), which keeps the check wired in. With no
// sign-in value set (authConfigured below) the IdP is configured in the app instead (no
// AUTHENTICATION__* env is sent), and the app's own settings check applies, so the guard stands down.
var checkedAuthAudience = authConfigured && toLower(trim(authProvider)) == 'auth0' && empty(trim(authAudience))
  ? fail('authAudience is required when authProvider is Auth0: set it to the Identifier of the Auth0 API your Broch application has user access to.')
  : authAudience

// The rest of Broch's sign-in startup checks, the same way: each fail()s at preflight, and the
// container reads the provider through this variable. An authAuthority waives the domain,
// tenant and instance checks, as it does in the server. AzureAd's instance defaults below, so
// only EntraExternalId (whose instance is tenant-specific) must supply one. Sign-in counts as
// configured when any sign-in parameter is set (provider, client id, client secret, tenant, domain,
// instance, authority, audience, scopes): then all of it is sent and checked; otherwise none of it is
// sent and the admin sets up sign-in in the app. (Gating on authClientId alone silently dropped a provider,
// secret or tenant entered without a client id.)
var authProviderKey = toLower(trim(authProvider))
var authAuthoritySet = !empty(trim(authAuthority))
var authConfigured = !empty(authProvider) || !empty(authClientId) || !empty(authClientSecret) || !empty(authTenantId) || !empty(authDomain) || !empty(authInstance) || !empty(authAuthority) || !empty(authAudience) || !empty(authScopes)
var checkedAuthProvider = authConfigured && empty(authProviderKey)
  ? fail('authProvider is required when another sign-in value (authClientId, authClientSecret, authTenantId, authDomain, authInstance, authAuthority, authAudience or authScopes) is set: Broch refuses to start without it.')
  : authConfigured && empty(authClientId)
  ? fail('authClientId is required when authProvider is set: Broch refuses to start without it.')
  : authConfigured && empty(authClientSecret)
  ? fail('authClientSecret is required when authProvider is set: Broch refuses to start without it.')
  : authConfigured && authProviderKey == 'oidc' && !authAuthoritySet
      ? fail('authAuthority is required when authProvider is Oidc: set it to your IdP\'s issuer URL.')
      : authConfigured && contains(['auth0', 'okta'], authProviderKey) && !authAuthoritySet && empty(trim(authDomain))
          ? fail('authDomain is required when authProvider is Auth0 or Okta (e.g. your-tenant.auth0.com).')
          : authConfigured && contains(['azuread', 'entraexternalid'], authProviderKey) && !authAuthoritySet && empty(trim(authTenantId))
              ? fail('authTenantId is required when authProvider is AzureAd or EntraExternalId.')
              : authConfigured && authProviderKey == 'entraexternalid' && !authAuthoritySet && empty(trim(authInstance))
                  ? fail('authInstance is required when authProvider is EntraExternalId: set it to https://<tenant>.ciamlogin.com/.')
                  : authProvider

@description('Comma-separated OAuth2 scopes (e.g., openid,profile,email). When empty, provider-specific defaults are used.')
param authScopes string = ''

@description('OAuth2 client secret used by the server to exchange authorization codes. Required for server-brokered auth.')
@secure()
param authClientSecret string = ''

@description('Comma-separated role/group names that grant admin access. Your first admin signs in holding one of these.')
param adminRoles string = 'broch_admin'

// ============================================================================
// Monitoring Parameters
// ============================================================================

@description('Telemetry/APM provider for tracing, metrics, and live diagnostics')
@allowed(['', 'ApplicationInsights', 'DataDog'])
param telemetryProvider string = ''

@description('Application Insights connection string. If empty and telemetryProvider is ApplicationInsights, a new Application Insights resource is created.')
@secure()
param applicationInsightsConnectionString string = ''

@description('Serilog logging provider for structured log routing (independent of telemetry provider). Seq is supported application-side only and is not yet wired in Bicep.')
@allowed(['', 'DataDog'])
param loggingProvider string = ''

@description('DataDog API key (only used if loggingProvider is DataDog)')
@secure()
param datadogApiKey string = ''

@description('DataDog Application key (only used if loggingProvider is DataDog)')
@secure()
param datadogApplicationKey string = ''

@description('DataDog service name (only used if loggingProvider is DataDog)')
param datadogServiceName string = 'broch-server'

@description('DataDog environment tag (only used if loggingProvider is DataDog)')
param datadogEnvironment string = 'production'

@description('DataDog site domain (e.g., datadoghq.com for US, datadoghq.eu for EU). Only used if loggingProvider is DataDog.')
param datadogSite string = 'datadoghq.com'

// Computed: is DataDog logging fully configured (provider selected AND key provided)?
var datadogLoggingEnabled = loggingProvider == 'DataDog' && !empty(datadogApiKey)

// ============================================================================
// Custom Domain & SSL Parameters
// ============================================================================

@description('Custom domain hostname to bind (e.g., app.example.com). Leave empty to use default Azure domain.')
param customDomainHostname string = ''

@description('Wildcard custom domain hostname (e.g., *.app.example.com). Uses the same SSL certificate. Leave empty to skip.')
param customDomainWildcardHostname string = ''

@secure()
@description('Base64-encoded PFX certificate for custom domain. Required if customDomainHostname is set.')
param sslCertificatePfxBase64 string = ''

@secure()
@description('Password for the PFX certificate. Required if sslCertificatePfxBase64 is set.')
param sslCertificatePassword string = ''

// ============================================================================
// Access Terminate-Mode Parameters
// ============================================================================

@description('Access domain (e.g. access.broch.io) whose wildcard resolves to the client loopback. Leave empty to disable Access terminate mode.')
param accessDomainName string = ''

@secure()
@description('Combined PEM bundle (CERTIFICATE + PRIVATE KEY) for *.{accessDomainName}, presented by the Access loopback terminator. Leave empty to run Access in passthrough-only mode.')
param accessCert string = ''

// ============================================================================
// Container Registry Parameters
// ============================================================================

@description('Container registry username (if private)')
param registryUsername string = ''

@secure()
@description('Container registry password (if private)')
param registryPassword string = ''

// ============================================================================
// Resource Naming Parameters (override for existing deployments)
// ============================================================================

@description('Container App name. Defaults to siteName.')
param containerAppName string = ''

@description('Container App Environment name. Defaults to {siteName}-env.')
param environmentName string = ''

// ============================================================================
// Scaling Parameters
// ============================================================================

@description('Minimum number of replicas')
param minReplicas int = 0

@description('Maximum number of replicas. Leave at 1: Broch runs as one instance and doesn\'t cluster, and WebSocket tunnels pin to a replica, so scaling past 1 breaks tunnel routing. Embedded mode always runs one replica.')
param maxReplicas int = 1

@description('Revision suffix for tracking deployments (e.g., commit SHA). Leave empty for auto-generated.')
param revisionSuffix string = ''

@description('ASP.NET Core environment name (Production, Development, etc.)')
param aspnetCoreEnvironment string = 'Production'

@description('OpenTelemetry service name for distributed tracing')
param otelServiceName string = 'broch-api'

// ============================================================================
// Optional: Log Analytics & Application Insights
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) {
  name: '${siteName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) {
  name: '${siteName}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) ? logAnalytics.id : null
  }
}

// Resolve the Application Insights connection string: provided or auto-created
var resolvedAppInsightsConnectionString = !empty(applicationInsightsConnectionString)
  ? applicationInsightsConnectionString
  : ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString) ? appInsights.properties.ConnectionString : '')

// Embedded-mode sidecar password: operator-provided, or derived deterministically
// from the resource group + master key when omitted. The sidecar listens on
// localhost inside the Container App only — the password never crosses a network
// boundary. Only consumed on the Embedded paths below; Shared mode uses
// databaseConnectionString as-is.
var effectiveDatabasePassword = empty(databasePassword) ? uniqueString(resourceGroup().id, masterKey) : databasePassword

// Managed PostgreSQL flexible server: name and FQDN are derived from the known
// naming pattern (<name>.postgres.database.azure.com) rather than read off the
// resource, so resolvedConnectionString never references a conditionally-deployed
// resource (which would fail to resolve in the other modes).
// Deterministically salted: flexible-server names are GLOBAL (the server owns
// <name>.postgres.database.azure.com), and while the siteName DEFAULT already embeds a
// uniqueString, an explicit siteName override would otherwise derive a bare global name that
// the first deployment anywhere claims — every later one dies with ServerNameAlreadyExists.
var managedPgServerName = '${siteName}-pg-${take(uniqueString(resourceGroup().id, siteName, location), 7)}'
var managedPgFqdn = '${managedPgServerName}.postgres.database.azure.com'

// Managed-mode VNet integration (databaseMode=Managed ONLY — Embedded/Shared deploy none of
// the resources below and their behaviour is unchanged). The Flexible Server is VNet-injected
// into a delegated subnet with a private DNS zone and NO public endpoint, and the Container App
// environment is integrated into the SAME VNet so it reaches the DB privately. This replaces the
// previous 'publicNetworkAccess: Enabled' + all-Azure (0.0.0.0) firewall rule, which exposed the
// DB to any Azure-hosted source in ANY tenant, gated only by the admin password. Mirrors the
// bicep/azure-vm sibling's private-Postgres pattern (delegated subnet + private DNS zone).
// Subnet IDs are built by resourceId() (not read off the conditional VNet) so they resolve in all
// modes; ordering is enforced with explicit dependsOn on the VNet / DNS link.
var managedVnetName = '${siteName}-vnet'
var managedAcaSubnetName = 'aca-infra'
var managedPgSubnetName = 'postgres'
var managedAcaSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', managedVnetName, managedAcaSubnetName)
var managedPgSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', managedVnetName, managedPgSubnetName)
var managedPgDnsZoneName = '${siteName}-db.private.postgres.database.azure.com'

// Resolve connection string by mode: external (Shared), provisioned flexible
// server (Managed), or the localhost sidecar (Embedded).
// Passwords are SINGLE-QUOTED with embedded quotes doubled — Npgsql's value-quoting rule.
// Interpolating them raw would silently corrupt the Key=Value;... pair syntax on any password
// containing ';' or a quote: everything deploys, ARM reports success, broch crash-loops at boot.
var managedPgPasswordQuoted = '\'${replace(postgresAdminPassword, '\'', '\'\'')}\''
var embeddedPgPasswordQuoted = '\'${replace(effectiveDatabasePassword, '\'', '\'\'')}\''
var resolvedConnectionString = databaseMode == 'Shared'
  ? databaseConnectionString
  : databaseMode == 'Managed'
      // SSL Mode=VerifyFull: Npgsql validates the server certificate's chain against the OS trust
      // store AND checks it names managedPgFqdn. (SSL Mode=Require does NOT validate the
      // certificate at all in current Npgsql — it only encrypts — so an on-path attacker could pose
      // as the server and read the DB session, which carries every DataProtection-wrapped secret
      // and all tunnel/user data.) Azure Database for PostgreSQL Flexible Server certificates chain
      // to DigiCert / Microsoft public roots, so no Root Certificate is needed. Matches the
      // azure-vm sibling (pg.bicep) and the Terraform ACA module.
      ? 'Host=${managedPgFqdn};Port=5432;Database=brochdb;Username=brochadmin;Password=${managedPgPasswordQuoted};SSL Mode=VerifyFull'
      : 'Host=localhost;Database=brochdb;Username=broch;Password=${embeddedPgPasswordQuoted}'

// Broch refuses to start without a connection string, or with an access domain equal to the
// wildcard hostname (their routes would collide). Like checkedAuthProvider, these fail() at
// preflight and the container reads the values through them.
var checkedConnectionString = databaseMode == 'Shared' && empty(trim(databaseConnectionString))
  ? fail('databaseConnectionString is required when databaseMode is Shared.')
  : resolvedConnectionString
var checkedAccessDomainName = !empty(trim(accessDomainName)) && toLower(trim(accessDomainName)) == toLower(trim(wildcardHostname))
  ? fail('accessDomainName must differ from wildcardHostname: Broch refuses to start when they match.')
  : accessDomainName

// Resolve resource names
var resolvedContainerAppName = !empty(containerAppName) ? containerAppName : siteName
var resolvedEnvironmentName = !empty(environmentName) ? environmentName : '${siteName}-env'

// ============================================================================
// Container App Environment
// ============================================================================

resource containerAppEnv 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: resolvedEnvironmentName
  location: location
  // Managed mode: the environment must exist inside the VNet before it can inject the
  // infrastructure subnet. Ignored in Embedded/Shared (no VNet is deployed).
  dependsOn: databaseMode == 'Managed' ? [managedVnet] : []
  properties: {
    // Managed mode: integrate the environment into the dedicated VNet's infrastructure subnet so
    // the app can reach the VNet-private Flexible Server. internal:false keeps EXTERNAL (public)
    // ingress — the app's public *.azurecontainerapps.io FQDN and any custom domain still work;
    // only the DB is private. Null in Embedded/Shared, so those modes stay non-VNet as before.
    // NOTE: vnetConfiguration is immutable once the environment exists — switching an already-
    // deployed environment into/out of Managed mode requires recreating the environment.
    vnetConfiguration: databaseMode == 'Managed' ? {
      infrastructureSubnetId: managedAcaSubnetId
      internal: false
    } : null
    appLogsConfiguration: ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) ? {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    } : null
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ============================================================================
// SSL Certificate (custom domain only)
// ============================================================================

resource sslCertificate 'Microsoft.App/managedEnvironments/certificates@2025-01-01' = if (!empty(customDomainHostname) && !empty(sslCertificatePfxBase64)) {
  parent: containerAppEnv
  name: '${siteName}-cert'
  location: location
  properties: {
    value: sslCertificatePfxBase64
    password: sslCertificatePassword
  }
}

// ============================================================================
// Managed PostgreSQL (Managed mode) — Azure Database for PostgreSQL flexible server
// ============================================================================

var managedPgTier = startsWith(postgresSkuName, 'Standard_B')
  ? 'Burstable'
  : (startsWith(postgresSkuName, 'Standard_D') ? 'GeneralPurpose' : 'MemoryOptimized')

// Dedicated VNet for Managed mode: one subnet delegated to the Container App environment and
// one delegated to the Flexible Server. The DB is injected into its subnet and reachable ONLY
// from inside this VNet (no public endpoint), replacing the former all-Azure firewall opening.
resource managedVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = if (databaseMode == 'Managed') {
  name: managedVnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.2.0.0/16'] }
    subnets: [
      {
        // Container App environment infrastructure subnet (workload-profiles environments
        // require a subnet delegated to Microsoft.App/environments, /27 or larger).
        name: managedAcaSubnetName
        properties: {
          addressPrefix: '10.2.0.0/23'
          delegations: [
            {
              name: 'aca-env'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        // Flexible Server VNet-injection subnet.
        name: managedPgSubnetName
        properties: {
          addressPrefix: '10.2.2.0/28'
          delegations: [
            {
              name: 'pgflex'
              properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
            }
          ]
        }
      }
    ]
  }
}

// Private DNS zone for the Flexible Server, linked to the VNet so both the DB subnet and the
// Container App environment resolve the server's FQDN to its private address. Mirrors azure-vm.
resource managedPgDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (databaseMode == 'Managed') {
  name: managedPgDnsZoneName
  location: 'global'
}

resource managedPgDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (databaseMode == 'Managed') {
  parent: managedPgDnsZone
  name: '${siteName}-pg-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: managedVnet.id }
  }
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (databaseMode == 'Managed') {
  name: managedPgServerName
  location: location
  // The delegated subnet and the linked private DNS zone must both exist before the server is
  // VNet-injected; the DNS link transitively depends on the VNet (and thus its subnets).
  dependsOn: [managedPgDnsLink]
  sku: {
    name: postgresSkuName
    tier: managedPgTier
  }
  properties: {
    version: '16'
    administratorLogin: 'brochadmin'
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    // VNet-injected + private DNS: NO public endpoint (publicNetworkAccess cannot be Enabled
    // alongside a delegated subnet), so the DB is unreachable from other tenants / the public
    // internet. Only workloads in managedVnet (the Container App) can connect, over validating
    // TLS as the admin. This is the azure-vm sibling's posture, adapted to ACA's VNet model.
    network: {
      delegatedSubnetResourceId: managedPgSubnetId
      privateDnsZoneArmResourceId: managedPgDnsZone.id
    }
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = if (databaseMode == 'Managed') {
  parent: postgresServer
  name: 'brochdb'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ============================================================================
// Container App
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: resolvedContainerAppName
  location: location
  // In Managed mode, wait for the flexible server + database before starting the app:
  // Broch runs migrations on boot, and the server takes several minutes to provision.
  // The dependency is ignored in modes where these resources are not deployed.
  dependsOn: databaseMode == 'Managed' ? [postgresDatabase] : []
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        customDomains: concat(
          (!empty(customDomainHostname) && !empty(sslCertificatePfxBase64)) ? [
            {
              name: customDomainHostname
              certificateId: sslCertificate.id
              bindingType: 'SniEnabled'
            }
          ] : [],
          (!empty(customDomainHostname) && !empty(customDomainWildcardHostname) && !empty(sslCertificatePfxBase64)) ? [
            {
              name: customDomainWildcardHostname
              certificateId: sslCertificate.id
              bindingType: 'SniEnabled'
            }
          ] : []
        )
      }
      registries: (!empty(registryUsername) && !empty(registryPassword)) ? [
        {
          server: split(containerImage, '/')[0]
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ] : []
      secrets: concat(
        (!empty(registryUsername) && !empty(registryPassword)) ? [
          {
            name: 'registry-password'
            value: registryPassword
          }
        ] : [],
        [
          {
            name: 'master-key'
            value: checkedMasterKey
          }
        ],
        // [ACCESS] Terminator cert — only present when provided, so terminate degrades to
        // passthrough when no AccessCert is configured.
        (!empty(accessCert)) ? [
          {
            name: 'access-cert'
            value: accessCert
          }
        ] : [],
        (telemetryProvider == 'ApplicationInsights') ? [
          {
            name: 'appinsights-connstr'
            value: resolvedAppInsightsConnectionString
          }
        ] : [],
        datadogLoggingEnabled ? [
          {
            name: 'datadog-api-key'
            value: datadogApiKey
          }
        ] : [],
        (datadogLoggingEnabled && !empty(datadogApplicationKey)) ? [
          {
            name: 'datadog-application-key'
            value: datadogApplicationKey
          }
        ] : [],
        [
          {
            name: 'db-connection'
            value: checkedConnectionString
          }
        ],
        databaseMode == 'Embedded' ? [
          {
            name: 'postgres-password'
            value: effectiveDatabasePassword
          }
        ] : [],
        !empty(authClientSecret) ? [
          {
            name: 'auth-client-secret'
            value: authClientSecret
          }
        ] : []
      )
    }
    template: {
      revisionSuffix: !empty(revisionSuffix) ? revisionSuffix : null
      containers: concat([
        {
          name: 'broch'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: concat(
            // Core env vars (always set)
            [
              {
                name: 'ASPNETCORE_ENVIRONMENT'
                value: aspnetCoreEnvironment
              }
              {
                name: 'ASPNETCORE_URLS'
                value: 'http://+:8080'
              }
              {
                name: 'CentralServer__ApiUrl'
                value: centralServerUrl
              }
              {
                name: 'BROCH_MASTER_KEY'
                secretRef: 'master-key'
              }
              {
                name: 'AUTHENTICATION__ADMINROLES'
                value: adminRoles
              }
            ],
            // Auth provider env vars (all gated on authConfigured — local IdP config)
            authConfigured ? concat(
              [
                {
                  name: 'AUTHENTICATION__PROVIDER'
                  value: checkedAuthProvider
                }
                {
                  name: 'AUTHENTICATION__CLIENTID'
                  value: authClientId
                }
              ],
              !empty(authTenantId) ? [
                {
                  name: 'AUTHENTICATION__TENANTID'
                  value: authTenantId
                }
              ] : [],
              // AUTHENTICATION__INSTANCE is required by the server for AzureAd/EntraExternalId.
              // AzureAd defaults to the login authority of the cloud this deployment runs in
              // (environment() resolves public, Government, and China correctly); an explicit
              // authInstance still wins. EntraExternalId's instance is tenant-specific
              // (ciamlogin.com), so it has no default: checkedAuthProvider requires it. For other
              // providers it is only emitted when supplied.
              authProviderKey == 'azuread' ? [
                {
                  name: 'AUTHENTICATION__INSTANCE'
                  value: empty(authInstance) ? environment().authentication.loginEndpoint : authInstance
                }
              ] : (!empty(authInstance) ? [
                {
                  name: 'AUTHENTICATION__INSTANCE'
                  value: authInstance
                }
              ] : []),
              !empty(authDomain) ? [
                {
                  name: 'AUTHENTICATION__DOMAIN'
                  value: authDomain
                }
              ] : [],
              // Set unconditionally (the server ignores an empty value), matching the
              // Terraform templates' AUTHENTICATION__AUTHORITY wiring.
              [
                {
                  name: 'AUTHENTICATION__AUTHORITY'
                  value: authAuthority
                }
              ],
              !empty(checkedAuthAudience) ? [
                {
                  name: 'AUTHENTICATION__AUDIENCE'
                  value: checkedAuthAudience
                }
              ] : [],
              !empty(authScopes) ? [
                {
                  name: 'AUTHENTICATION__SCOPES'
                  value: authScopes
                }
              ] : [],
              !empty(authClientSecret) ? [
                {
                  name: 'AUTHENTICATION__CLIENTSECRET'
                  secretRef: 'auth-client-secret'
                }
              ] : []
            ) : [],
            [
              {
                name: 'OTEL_SERVICE_NAME'
                value: otelServiceName
              }
            ],
            [
              {
                name: 'API__WILDCARDHOSTNAME'
                value: checkedWildcardHostname
              }
            ],
            // [ACCESS] Access domain (always set; empty disables terminate) + terminator cert
            // (secret, only wired when provided — otherwise terminate falls back to passthrough).
            [
              {
                name: 'API__ACCESSDOMAINNAME'
                value: checkedAccessDomainName
              }
            ],
            (!empty(accessCert)) ? [
              {
                name: 'API__ACCESSCERT'
                secretRef: 'access-cert'
              }
            ] : [],
            // Telemetry provider configuration
            !empty(telemetryProvider) ? [
              {
                name: 'BROCHTELEMETRY__PROVIDER'
                value: telemetryProvider
              }
            ] : [],
            (telemetryProvider == 'ApplicationInsights') ? [
              {
                name: 'BROCHTELEMETRY__APPLICATIONINSIGHTSCONNECTIONSTRING'
                secretRef: 'appinsights-connstr'
              }
            ] : [],
            // Set logging provider so the app knows DataDog was intended
            // (even without API key, the app logs a warning at startup)
            loggingProvider == 'DataDog' ? [
              {
                name: 'BROCHLOGGING__PROVIDER'
                value: 'DataDog'
              }
              {
                name: 'BROCHLOGGING__DATADOG__SERVICENAME'
                value: datadogServiceName
              }
              {
                name: 'BROCHLOGGING__DATADOG__ENVIRONMENT'
                value: datadogEnvironment
              }
              {
                name: 'BROCHLOGGING__DATADOG__SITE'
                value: datadogSite
              }
            ] : [],
            // DataDog API key secret (only when key is provided)
            datadogLoggingEnabled ? [
              {
                name: 'BROCHLOGGING__DATADOG__APIKEY'
                secretRef: 'datadog-api-key'
              }
            ] : [],
            // DataDog Application key secret (only when provided)
            (datadogLoggingEnabled && !empty(datadogApplicationKey)) ? [
              {
                name: 'BROCHLOGGING__DATADOG__APPLICATIONKEY'
                secretRef: 'datadog-application-key'
              }
            ] : [],
            // Database connection (both modes — Embedded connects to sidecar, Shared to external)
            [
              {
                name: 'DATABASE__PROVIDER'
                value: 'PostgreSQL'
              }
              {
                name: 'ConnectionStrings__BrochConnection'
                secretRef: 'db-connection'
              }
            ]
          )
          volumeMounts: []
          // Liveness only. /healthz is the always-200, license-independent endpoint, so ACA can
          // restart a container that's TCP-alive but hung at the HTTP layer (the default TCP probe
          // can't). Matches the terraform variant's liveness settings. Deliberately NO readiness
          // probe on /healthz/ready: it's license-gated, and gating ingress on it deadlocks
          // first-run activation (no traffic → can't reach setup UI → never activates).
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 60
              periodSeconds: 30
              timeoutSeconds: 10
              failureThreshold: 3
            }
          ]
        }
      ], databaseMode == 'Embedded' ? [
        {
          name: 'postgres'
          image: 'postgres:16-alpine'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'POSTGRES_DB'
              value: 'brochdb'
            }
            {
              name: 'POSTGRES_USER'
              value: 'broch'
            }
            {
              name: 'POSTGRES_PASSWORD'
              secretRef: 'postgres-password'
            }
            {
              name: 'PGDATA'
              value: '/var/lib/postgresql/data/pgdata'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'postgres-data-volume'
              mountPath: '/var/lib/postgresql/data'
            }
          ]
        }
      ] : [])
      // EmptyDir is replica-scoped ephemeral storage: it survives individual
      // container restarts within the replica (a broch liveness restart doesn't
      // wipe postgres) but is lost with the replica itself — revision restarts,
      // image upgrades, platform maintenance. That is Embedded mode's contract.
      // Azure Files is not an option here: SMB has no chmod and postgres initdb
      // hard-requires it.
      volumes: databaseMode == 'Embedded' ? [
        {
          name: 'postgres-data-volume'
          storageType: 'EmptyDir'
        }
      ] : []
      scale: {
        // Embedded mode: exactly 1 replica — PostgreSQL sidecar is single-instance, no scale-to-zero
        minReplicas: databaseMode == 'Embedded' ? 1 : minReplicas
        maxReplicas: databaseMode == 'Embedded' ? 1 : maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('URL to access the Broch web interface')
output brochUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'

@description('Custom domain URL (if configured)')
output customDomainUrl string = !empty(customDomainHostname) ? 'https://${customDomainHostname}' : 'N/A (using default Azure domain)'

@description('SSH tunnel WebSocket endpoint')
output sshEndpoint string = 'wss://${wildcardHostname}/ws/share'

@description('Deployment mode used')
output deploymentMode string = databaseMode

@description('Database server info')
output databaseServer string = databaseMode == 'Shared' ? 'External PostgreSQL (connection string provided)' : databaseMode == 'Managed' ? 'Azure Database for PostgreSQL flexible server (${managedPgFqdn})' : 'Embedded PostgreSQL sidecar — EVALUATION ONLY: ephemeral storage, the database does not survive revision restarts or image upgrades. For production, set databaseMode=Managed (provisioned) or Shared (external).'

@description('Application Insights name (if enabled)')
output applicationInsightsName string = ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) ? appInsights.name : ((telemetryProvider == 'ApplicationInsights') ? 'Using provided connection string' : 'Application Insights not enabled')
