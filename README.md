# Client Onboarding Scripts

This repository contains a collection of scripts designed to bootstrap a foundational organizational structure on
different Cloud Service Providers (CSPs). The primary goal is to prepare a new cloud environment for management by
Mesoform's Athena platform.

By running these scripts, you will create the necessary management hierarchies and delegate permissions, enabling Athena
to provision and manage cloud resources like CloudSpaces, which in turn create projects (GCP) and subscriptions (Azure).

## Overview

The setup process is tailored to the specific CSP. You will find dedicated directories for each provider, containing
scripts to perform the initial setup.

### `google/`

The scripts in this directory configure a Google Cloud Platform (GCP) organization by:

1. **Creating a Folder Hierarchy**: Establishes a standard folder structure (e.g., `development/sandbox`,
   `production/live`) to organize resources by environment.
2. **Delegating Permissions**: Grants a pre-existing Athena `cloudspace-creator` service account the necessary IAM
   roles (`roles/resourcemanager.projectCreator`, `roles/billing.user`, etc.) at the folder level. This allows Athena to
   create and manage GCP projects within the designated folders.

For detailed instructions, see the Google README.

### `azure/`

The scripts in this directory configure an Azure tenant by:

1. **Creating a Management Group Hierarchy**: Establishes a standard management group structure to mirror the
   organization's environments.
2. **Creating Service Principals**: Sets up service principals for each lifecycle stage and assigns them the appropriate
   roles (`Contributor`, billing roles) on the corresponding management groups and subscriptions.
3. **Configuring Federated Credentials**: Establishes a trust relationship between Azure and Athena using OIDC, allowing
   for secure, passwordless authentication.

For detailed instructions, see the Azure documentation within its directory.