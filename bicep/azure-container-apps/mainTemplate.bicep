// Broch on Azure Container Apps — Bicep deployment template.
//
// Deploys the Broch server on Azure Container Apps with PostgreSQL:
// - Embedded mode: PostgreSQL sidecar container persisted to Azure Files (single replica)
// - Shared mode:   bring-your-own PostgreSQL connection string (e.g. Flexible Server)
//
// This is the same template Broch, LLC runs for its own dev and production
// deployments — what you deploy here is what we run. See README.md for the
// architecture, custom-domain / wildcard-TLS steps, and tradeoffs.

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
param masterKey string

@description('Container image to deploy. Pin to a specific version in production (e.g. ghcr.io/broch-io/broch:1.5.0).')
param containerImage string = 'ghcr.io/broch-io/broch:latest'

// ============================================================================
// Database Parameters
// ============================================================================

@description('Database deployment mode: Embedded (PostgreSQL sidecar, single instance) or Shared (external PostgreSQL connection string, multi-instance HA)')
@allowed(['Embedded', 'Shared'])
param databaseMode string = 'Embedded'

@secure()
@description('PostgreSQL connection string. Required for Shared mode. For Embedded mode, auto-generated to connect to the sidecar.')
param databaseConnectionString string = ''

@secure()
@description('PostgreSQL password for the Embedded mode sidecar. Auto-generated when omitted — the sidecar is reachable only on localhost inside the Container App. Ignored in Shared mode.')
param databasePassword string = ''

// ============================================================================
// API & Networking Parameters
// ============================================================================

@description('Central server URL for license validation and config delivery')
param centralServerUrl string = 'https://api.broch.io'

@description('Wildcard hostname for tunnel subdomains (e.g., tunnels.company.com). Required — the server fails to start without it.')
@minLength(1)
param wildcardHostname string

// ============================================================================
// Authentication & Authorization Parameters
// ============================================================================

@description('Authentication provider type')
@allowed(['AzureAd', 'EntraExternalId', 'Auth0', 'Okta', 'Oidc'])
param authProvider string = 'AzureAd'

@description('Identity provider tenant ID (e.g., contoso.onmicrosoft.com or a GUID). Required for AzureAd and EntraExternalId providers. Auth0 uses authDomain instead.')
param authTenantId string = ''

@description('OAuth2 client/application ID registered in the identity provider')
param authClientId string = ''

@description('Identity provider instance URL. Defaults per provider: AzureAd/EntraExternalId use https://login.microsoftonline.com/, Auth0 is derived from authDomain.')
param authInstance string = ''

@description('Auth0/Okta domain (e.g., contoso.auth0.com or contoso.okta.com). Only used when authProvider is Auth0 or Okta.')
param authDomain string = ''

@description('Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers.')
param authAuthority string = ''

@description('OAuth2 API audience identifier. When empty, falls back to authClientId.')
param authAudience string = ''

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
// Custom Domain & SSL Parameters (ELF-300)
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
// Access Terminate-Mode Parameters (ELF-800)
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

@description('Maximum number of replicas')
param maxReplicas int = 3

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

// Resolve connection string: external (Shared) or auto-generated for sidecar (Embedded)
var resolvedConnectionString = databaseMode == 'Shared'
  ? databaseConnectionString
  : 'Host=localhost;Database=brochdb;Username=broch;Password=${effectiveDatabasePassword}'

// Resolve resource names
var resolvedContainerAppName = !empty(containerAppName) ? containerAppName : siteName
var resolvedEnvironmentName = !empty(environmentName) ? environmentName : '${siteName}-env'
var storageAccountName = take(toLower(replace('${siteName}st${uniqueString(resourceGroup().id)}', '-', '')), 24)

// ============================================================================
// Persistent Storage (Embedded mode — PostgreSQL data)
// ============================================================================

@description('Storage Account for PostgreSQL data persistence (Embedded mode only)')
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = if (databaseMode == 'Embedded') {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

@description('File Share for PostgreSQL data persistence')
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (databaseMode == 'Embedded') {
  name: '${storageAccount.name}/default/postgres-data'
  properties: {
    shareQuota: 5 // 5 GB for PostgreSQL data files
  }
}

// ============================================================================
// Container App Environment
// ============================================================================

resource containerAppEnv 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: resolvedEnvironmentName
  location: location
  properties: {
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

@description('Storage binding for PostgreSQL data volume (Embedded mode only)')
resource envStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = if (databaseMode == 'Embedded') {
  name: 'postgres-data'
  parent: containerAppEnv
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: 'postgres-data'
      accessMode: 'ReadWrite'
    }
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
// Container App
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: resolvedContainerAppName
  location: location
  dependsOn: databaseMode == 'Embedded' ? [envStorage] : []
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
            value: masterKey
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
            value: resolvedConnectionString
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
            // Auth provider env vars (all gated on authClientId — local IdP config)
            !empty(authClientId) ? concat(
              [
                {
                  name: 'AUTHENTICATION__PROVIDER'
                  value: authProvider
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
              !empty(authInstance) ? [
                {
                  name: 'AUTHENTICATION__INSTANCE'
                  value: authInstance
                }
              ] : [],
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
              !empty(authAudience) ? [
                {
                  name: 'AUTHENTICATION__AUDIENCE'
                  value: authAudience
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
                value: wildcardHostname
              }
            ],
            // [ACCESS] Access domain (always set; empty disables terminate) + terminator cert
            // (secret, only wired when provided — otherwise terminate falls back to passthrough).
            [
              {
                name: 'API__ACCESSDOMAINNAME'
                value: accessDomainName
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
                name: 'ConnectionStrings__DefaultConnection'
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
      volumes: databaseMode == 'Embedded' ? [
        {
          name: 'postgres-data-volume'
          storageName: 'postgres-data'
          storageType: 'AzureFile'
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

@description('Estimated monthly cost (USD)')
output estimatedMonthlyCost string = databaseMode == 'Embedded' ? '~$50 (always-on, 0.75 vCPU / 1.5 GiB)' : '$16-20 (typical usage)'

@description('Database server info')
output databaseServer string = databaseMode == 'Shared' ? 'External PostgreSQL (connection string provided)' : 'Embedded PostgreSQL sidecar'

@description('Application Insights name (if enabled)')
output applicationInsightsName string = ((telemetryProvider == 'ApplicationInsights') && empty(applicationInsightsConnectionString)) ? appInsights.name : ((telemetryProvider == 'ApplicationInsights') ? 'Using provided connection string' : 'Application Insights not enabled')
