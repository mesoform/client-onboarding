# Azure Onboarding Scripts

This directory contains a set of Bash scripts designed to bootstrap a standardized Microsoft Azure environment for a new client. It mirrors the organizational principles found in the Google Cloud onboarding scripts.

The primary goal is to create a consistent management group hierarchy and to delegate permissions to service principals managed by Athena. This enables Athena to securely provision and manage Azure resources, such as subscriptions, within a well-defined structure.

## Infrastructure Created

When the `apply` command is executed, the following resources are provisioned in your Azure tenant:

### 1. Management Group Hierarchy

The scripts create a multi-level management group structure based on the `ENVIRONMENTS_LIST` array in `bin/config.sh`. This hierarchy is essential for organizing subscriptions and applying governance policies at scale.

Given the default configuration:

```bash
ENVIRONMENTS_LIST=(
  "development/sandbox"
  "development/testing"
  "production/staging"
  "production/live"
)
```

The following management group structure will be created under the specified parent management group (or the Tenant Root Group if none is specified):

```
<Parent Management Group>
├── development/
│   ├── sandbox/
│   └── testing/
└── production/
    ├── staging/
    └── live/
```

### 2. Service Principals and Permissions

For each top-level lifecycle stage (`development` and `production`), as well as a special `seed` environment, the scripts create an Azure Active Directory Service Principal. These service principals are granted specific roles to allow Athena to manage resources.

*   **Service Principals Created**:
    *   `...-seed-sp`
    *   `...-development-sp`
    *   `...-production-sp`
*   **Permissions Granted**:
    *   **Contributor Role**: Each service principal is granted the `Contributor` role on its corresponding top-level management group (e.g., the `development-sp` gets `Contributor` on the `development` management group). This allows it to manage resources within that scope.
    *   **Billing Role**: Each service principal is also assigned a billing role on the specified invoice section, enabling Athena to manage subscription billing.

### 3. Federated Credentials (OIDC)

For each service principal, a federated credential is created. This establishes an OIDC trust relationship between your Azure tenant and the Athena platform. This modern, secure approach allows Athena to authenticate and obtain Azure access tokens without needing to store any client secrets or long-lived credentials.

## How to Use

### 1. Prerequisites

Before running the scripts, please ensure the following requirements are met:

*   **Azure CLI**: The `az` command-line tool must be installed. You can find instructions at the Azure CLI documentation.
*   **jq**: The `jq` command-line JSON processor is required.
*   **Authentication**: You must be authenticated with an account that has sufficient permissions on the target Azure tenant.
    *   **Required Roles**:
        *   `Owner` or `User Access Administrator` and `Management Group Contributor` at the tenant root or target parent management group scope.
        *   Permissions to create Service Principals and grant them roles (e.g., `Application Administrator`).
        *   Permissions to assign billing roles (e.g., `Billing account owner`).
    *   **Authentication Command**: Run the following command to authenticate:
        ```sh
        az login
        ```

*   **Athena Project**: You must have already been onboarded by Mesoform. This provides the OIDC issuer URLs required for setting up federated credentials.

### 2. Initialize

Run the `init` command. This will interactively guide you through selecting a billing scope and will generate a `.env` file containing your configuration.

```sh
./azure/bin/config.sh init --domain "your-company.com"
```

After initialization, review and complete the `OIDC_ISSUER_URLS` map in the newly created `.env` file.

### 3. Apply

Execute the `apply` command to create the management groups, service principals, and federated credentials.

```sh
./azure/bin/config.sh apply --location <your-azure-location>
```

### 4. Save Secrets to Google Secret Manager

After applying the configuration, run the `save-secrets` command. This will generate the necessary Azure credentials and securely store them in the appropriate Google Secret Manager instance for Athena to use.

```sh
./azure/bin/config.sh save-secrets
```

### 5. View Output

You can run the `output` command at any time to display the generated client IDs and other relevant information for the configured service principals.

```sh
./azure/bin/config.sh output
```