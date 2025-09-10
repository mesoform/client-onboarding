# Google Cloud Onboarding Scripts

This directory contains a set of Bash scripts designed to bootstrap a standardized Google Cloud Platform (GCP) environment structure for a new client. It mirrors the organizational principles found in the Azure onboarding scripts.

The primary goal is to create a consistent folder hierarchy for different lifecycle stages (e.g., `development`, `production`) and to delegate project creation permissions to an Athena-managed service account within those folders.

## Infrastructure Created

When the `apply` command is executed, the following resources are provisioned in your Google Cloud organization:

### 1. Folder Hierarchy

The scripts create a two-level folder structure based on the `ENVIRONMENTS_LIST` array in `bin/config.sh`.

Given the default configuration:

```bash
ENVIRONMENTS_LIST=(
  "development/sandbox"
  "development/testing"
  "production/staging"
  "production/live"
)
```

The following folder structure will be created directly under your specified GCP Organization:

```
<Your GCP Organization>
├── development/
│   ├── sandbox/
│   └── testing/
└── production/
    ├── staging/
    └── live/
```

### 2. IAM Permissions (Folder-Level)

For each top-level lifecycle folder (`development` and `production`), the scripts grant specific IAM roles to a pre-existing Athena service account. This delegation allows the service account to manage projects within that folder and its subfolders.

*   **Service Account**: `cloudspace-creator@<athena-project-id>.iam.gserviceaccount.com`
    *   The `<athena-project-id>` is dynamically generated based on the organization's domain and the lifecycle stage (e.g., `mf-your-company-com-development-....`).
*   **Permissions Granted on `development` folder**:
    *   `roles/resourcemanager.projectCreator`: Allows creation of new GCP projects within the `development` folder.
    *   `roles/resourcemanager.projectDeleter`: Allows deletion of GCP projects within the `development` folder.
    *   `roles/resourcemanager.projectIamAdmin`: Allows management of IAM policies on projects within the `development` folder.
*   **Permissions Granted on `production` folder**:
    *   The same set of roles (`projectCreator`, `projectDeleter`, `projectIamAdmin`) are granted to the corresponding `production` service account on the `production` folder.

### 3. Billing Permissions

The same Athena service accounts (`cloudspace-creator@...`) for both `development` and `production` are granted the `roles/billing.user` role on the specified `GCP_BILLING_ACCOUNT_ID`. This allows the service account to associate newly created projects with the organization's billing account.

### 4. Athena GSA Project

Inside each top-level lifecycle folder (`development` and `production`), a dedicated project is created to house resources related to the Google Service Account (GSA).

*   **Project Name**: `athena-gsa-<stage_name>-<short_sha>`
    *   `<stage_name>` is either `development` or `production`.
    *   `<short_sha>` is the first 8 characters of the SHA hash used in the Athena project ID.
*   **Example Project Created**:
    *   `athena-gsa-development-abcdef12` (inside the `development` folder)
    *   `athena-gsa-production-ghijkl34` (inside the `production` folder)

## How to Use

1.  **Prerequisites**: Ensure you have the `gcloud` CLI installed and have authenticated with an account that has `resourcemanager.organizationAdmin` and `billing.admin` permissions on your GCP organization.

2.  **Initialize**:
    Run the `init` command to generate a `.env` file with your organization's details.
    ```sh
    ./google/bin/config.sh init \
      --domain "your-company.com" \
      --org-id "123456789012" \
      --billing-id "01A2B3-C4D5E6-F7G8H9"
    ```

3.  **Dry Run (Recommended)**:
    Review the changes that will be made without applying them.
    ```sh
    ./google/bin/config.sh apply --dry-run
    ```

4.  **Apply**:
    Execute the script to create the infrastructure.
    ```sh
    ./google/bin/config.sh apply
    ```