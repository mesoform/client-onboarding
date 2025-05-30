#!/usr/bin/env bash

function _log_error() {
  echo -e "\033[1;31m${1}\033[0m"
}

function _log_ok() {
  echo -e "\033[1;92m${1}\033[0m"
}

function _log_begin() {
  echo -n "${1}"
}

function _log_info() {
  echo "${1}"
}

function _to_lowercase() {
  local in_str="${1}"
  local out_str

  out_str="$(tr '[:upper:]' '[:lower:]' <<< "${in_str}")"
  echo "${out_str}"
}

function _write_env_var() {
  local filename="${1}"
  local var_name="${2}"
  local var_value="${3}"

  if [[ -z "${filename}" ]]; then _log_error "The filename is required"; return 1; fi
  if [[ -z "${var_name}" ]]; then _log_error "The variable name is required"; return 1; fi
  if [[ -z "${var_value}" ]]; then _log_error "The variable value is required"; return 1; fi

  if ! grep -R "^[#]*\s*${var_name}=.*" "${filename}" > /dev/null; then
    echo "$var_name=$var_value" >> "${filename}"
  else
    sed -i '' -E "s/^[#]*[ \t]*${var_name}=.*$/${var_name}=${var_value}/" "${filename}"
  fi
}

function _get_parameter_by_key() {
  local env="${1}"

  if [[ -z "${env}" ]]; then _log_error "The environment name is required"; return 1; fi

  shift
  local map=("$@")
  local parameter_value

  for ln in "${map[@]}"
  do
    key="${ln%%=*}"
    val="${ln#*=}"
    if [[ "${env}" == "${key}" ]]; then parameter_value="${val}"; break; fi
  done

  echo "${parameter_value}"
}

function _get_lifecycle_stage() {
  local env="${1}"

  if [[ -z "${env}" ]]; then _log_error "The environment name is required"; return 1; fi
  echo "${env//\/*/}"
}

function _get_name_prefix() {
  local org_domain="${1}"

  if [[ -z "${org_domain}" ]]; then _log_error "The domain is required"; return 1; fi

  echo "${org_domain//./-}"
}

function _get_athena_project_name() {
  local org_domain="${1}"
  local lfc_stage="${2}"

  if [[ -z "${org_domain}" ]]; then _log_error "The domain is required"; return 1; fi
  if [[ -z "${lfc_stage}" ]]; then _log_error "The lifecycle stage is required"; return 1; fi

  echo "mf$(echo -n "${org_domain//./-}""${lfc_stage}" | sha256sum | head -c 20)"
}

function _check_prerequisites() {
  local ec=0

  _log_ok "Checking prerequisites..."

  # Check whether Azure CLI installed
  if which az > /dev/null 2>&1; then
    az version
    _log_begin "Azure CLI: "; _log_ok "OK"
  else
    _log_begin "Azure CLI: "; _log_error "ERROR"
    _log_error "Azure CLI required. See: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest"
    ((ec=ec+1))
  fi

  # Check Azure login
  if dn=$(az ad signed-in-user show --query "displayName" --out tsv 2>/dev/null); then
    _log_begin "Azure login: "; _log_ok "OK"
    _log_begin "Logged in as "; _log_ok "${dn}"
  else
    _log_begin "Azure login: "; _log_error "ERROR"
    _log_error "Please run 'az login' to setup account."
    ((ec=ec+1))
  fi

  _log_begin "Prerequisites check: "
  if [ "${ec}" -gt 0 ]; then _log_error "Failed\n";  exit "${ec}"; else _log_ok "Passed\n"; fi
}

# Get the ID of resource group
function _get_resource_group_id() {
  local rg_name="${1}" # Name of the new resource group.
  local rg_id=""

  if [[ -z "${rg_name}" ]]; then _log_error "Resource group name is required"; return 1; fi

  rg_id=$(az group list --query "[?name=='${rg_name}'].id" --out tsv)
  echo "${rg_id}"
}

function _get_managed_identity_principal_id() {
  local mi_name="${1}" # Name of the managed identity.
  local rg_name="${2}" # Name of the new resource group.
  local mi_id=""

  if [[ -z "${mi_name}" ]]; then _log_error "Managed identity name is required"; return 1; fi
  if [[ -z "${rg_name}" ]]; then _log_error "Resource group name is required"; return 1; fi

  mi_id=$(az identity list -g "${rg_name}" --query "[?name=='${mi_name}'].principalId" --out tsv)
  echo "${mi_id}"
}

function _get_managed_identity_client_id() {
  local mi_name="${1}" # Name of the managed identity.
  local rg_name="${2}" # Name of the new resource group.
  local mi_id=""

  if [[ -z "${mi_name}" ]]; then _log_error "Managed identity name is required"; return 1; fi
  if [[ -z "${rg_name}" ]]; then _log_error "Resource group name is required"; return 1; fi

  mi_id=$(az identity list -g "${rg_name}" --query "[?name=='${mi_name}'].clientId" --out tsv)
  # az identity list --query "[?name=='${MI_REGULAR_NAME}'].clientId" --out tsv

  echo "${mi_id}"
}

# Get the ID of management group
function _get_management_group_id() {
  local mg_name="${1}" # Name of the new management group.
  local mg_id
  local is_mg_available

  if [[ -z "${mg_name}" ]]; then _log_error "Management group name is required"; return 1; fi

  set +e
  is_mg_available=$(az account management-group check-name-availability --name "${mg_name}" --output tsv --query "nameAvailable")
  if [[ "${is_mg_available}" == "false" ]]; then
    mg_id=$(az account management-group show --name "${mg_name}" -o tsv --query "id" 2>/dev/null)
  fi
  set -e

  echo "${mg_id}"
}

# Get the ID of Azure subscription (e.g. 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
function _get_subscription_id() {
  local id=""

  id="$(az account list --query "[?isDefault].id" --output tsv 2>/dev/null)"

  echo "${id}"
}

# Get the subscriptionId of Azure subscription (e.g. '/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
function _get_subscription_scope_id() {
  local id=""
  local subscription_scope_id=""

  id="$(az account list --query "[?isDefault].id" --output tsv 2>/dev/null)"
  subscription_scope_id=$(az account subscription list --query "[?subscriptionId=='${id}'].id" --out tsv 2>/dev/null)

  echo "${subscription_scope_id}"
}

# Get the tenantId
function _get_tenant_id() {
  local tenant_id=""

  tenant_id="$(az account list --query "[?isDefault].tenantId" --output tsv 2>/dev/null)"

  echo "${tenant_id}"
}

function _wait_management_group_ready {
  local mg_name="${1}" # Name of the new management group.
  local mg_ready="false"
  local max_count=20
  local ccount=1
  local mg_id=""

  set +e
  sleep 30
  while [[ ${mg_ready} == "false" && "${ccount}" -le "${max_count}" ]]
  do
    mg_id="$(_get_management_group_id "${mg_name}")"
    if [[ -n "${mg_id}" ]]; then
      mg_ready="true"
    else
      _log_begin "waiting management group '${mg_name}' ready... "
      _log_ok "${ccount}"
      sleep 3
    fi
    ((ccount=ccount+1))
  done
  set -e

  if [[ -n "${mg_id}" ]]; then
    _log_info "${mg_id}"
  else
    _log_error "Can't get management group id for '${mg_name}'"
  fi
}

# Create management group
function _create_management_group() {
  local mg_name="${1}" # Name of the new management group.
  local mg_parent="${2}" # Parent of the management group. Can be the fully qualified id or the name of the mg.
  local is_mg_available

  if [[ -z "${mg_name}" ]]; then _log_error "Management group name is required"; return 1; fi

  # Check name availability
  is_mg_available=$(az account management-group check-name-availability --name "${mg_name}" --output tsv --query "nameAvailable")
  if [[ "${is_mg_available}" == "true" ]]; then
    if [[ -n "${mg_parent}" ]]; then
      _log_info "Creating management group: ${mg_name}, Parent: ${mg_parent}"
      az account management-group create --name "${mg_name}" --parent "${mg_parent}" --query id --output tsv
    else
      _log_info "Creating management group: ${mg_name}"
      az account management-group create --name "${mg_name}" --query id --output tsv
    fi
    _wait_management_group_ready "${mg_name}"
  else
    _log_info "Management group '${mg_name}' exist"
  fi
}

# Create hierarchy of management groups
function _create_management_group_hierarchy() {
  local mg_path="${1}"
  local mg_name="" # Name of the new management group.
  local mg_parent="${2}" # Parent of the management group. Can be the fully qualified id or the name of the mg.

  if [[ -z "${mg_path}" ]]; then _log_error "Management groups path is required"; return 1; fi
  # Skip 'seed' environment
  if [[ "${mg_path}" == "seed" ]]; then return 0; fi

  for mg_name in $(echo "${mg_path}" | sed 's/\// /g'); do
    _create_management_group "${mg_name}" "${mg_parent}"

    mg_parent="${mg_name}"
  done;
}

# Create resource group
function _create_resource_group() {
  local rg_name="${1}" # Name of the new resource group.
  local rg_location="${2}" # Location. Values from: az account list-locations.
  local rg_id=""
  # local rg_tags="${3}" # Space-separated tags: key[=value] [key[=value] ...]. Use "" to clear existing tags.

  if [[ -z "${rg_name}" ]]; then _log_error "Resource group name is required"; return 1; fi
  if [[ -z "${rg_location}" ]]; then _log_error "Location of the resource group is required"; return 1; fi

  if az group create --location "${rg_location}" --name "${rg_name}" > /dev/null 2>&1; then
    rg_id=$(_get_resource_group_id "${rg_name}")
  fi

  echo "${rg_id}"
}

# Create a new role assignment for a user, group, or service principal
function _assign_role() {
  local obj_id="${1}" # Object id.
  local role_name="${2}" # Name of the role to be assigned.
  local scope="${3}" # Scope at which the role assignment or definition applies to, e.g.

  if [[ -z "${obj_id}" ]]; then _log_error "Object id is required"; return 1; fi
  if [[ -z "${role_name}" ]]; then _log_error "Name of the role is required"; return 1; fi
  if [[ -z "${scope}" ]]; then _log_error "Scope is required"; return 1; fi

  az role assignment create --assignee "${obj_id}" --role "${role_name}" --scope "${scope}"
}

#################
# Billing section
#################
# Create role assignment by invoice section
# https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/understand-mca-roles
# https://learn.microsoft.com/en-us/rest/api/billing/billing-role-assignments/create-by-invoice-section?view=rest-billing-2024-04-01&tabs=HTTP
# https://learn.microsoft.com/en-us/cli/azure/billing/account/invoice-section?view=azure-cli-latest
function _assign_billing_role() {
  local obj_id="${1}" # Object id.
  local billing_role_id="${2}" # ID of the role to be assigned. E.g. 30000000-aaaa-bbbb-cccc-100000000000
  local tenant_id="${3}" # The Azure tenant id
  local billing_id_path="${4}" # Billing ids in form 'billingAccounts/xxx/billingProfiles/xxx/invoiceSections/xxx'

  if [[ -z "${obj_id}" ]]; then _log_error "Object id is required"; return 1; fi
  if [[ -z "${billing_role_id}" ]]; then _log_error "ID of the billing role is required"; return 1; fi
  if [[ -z "${tenant_id}" ]]; then _log_error "The Azure tenant id is required"; return 1; fi
  if [[ -z "${billing_id_path}" ]]; then _log_error "The billing id path is required"; return 1; fi

  local api_url_base="https://management.azure.com/providers/Microsoft.Billing"
  local api_url_sfx="createBillingRoleAssignment?api-version=2024-04-01"
  local api_url
  local json_body

#  billing_id_path="$(_get_billing_id_path)"
  billing_role_definition_id="/providers/Microsoft.Billing/${billing_id_path}/billingRoleDefinitions/${billing_role_id}"
  api_url="${api_url_base}/${billing_id_path}/${api_url_sfx}"

  json_body=$(jq -n --arg object_id "${obj_id}" --arg tenant_id "${tenant_id}" --arg role_definition "${billing_role_definition_id}" '{
                          principalId: $object_id,
                          principalTenantId: $tenant_id,
                          roleDefinitionId: $role_definition
                        }'
                      )
  echo "${json_body}"
  az rest --method post --url "${api_url}" --body "${json_body}"
}

##################################################
# Service principal section
##################################################
# Create service principal
function _create_service_principal() {
  local sp_name="${1}" # Name of the service principal.
  local scopes="${2}" # Space-separated list of scopes the service principal's role assignment applies to.
  local role_name="${3}" # Role of the service principal.
  local sp_id=""

  if [[ -z "${sp_name}" ]]; then _log_error "Service principal name is required"; return 1; fi
  if [[ -z "${scopes}" ]]; then _log_error "Scopes parameter is required"; return 1; fi
  if [[ -z "${role_name}" ]]; then role_name="Reader"; fi

  if result=$(az ad sp create-for-rbac --only-show-errors --display-name "${sp_name}" --role="${role_name}" \
    --scopes="${scopes}" --query "appId" --out tsv 2>&1); then
    sp_id="${result}"
  fi

  echo "${sp_id}"
}

# Establish trust between your OIDC issuer URL and the service principal.
function _create_sp_federated_credentials() {
  local federated_credential_name="${1}" # Name of the federated credential.
  local sp_id="${2}" # Name of the service principal.
  local issuer_url="${3}" # The OIDC issuer URL

  [[ -z "${federated_credential_name}" ]] && _log_error "Name of the federated credential is required" && return 1
  [[ -z "${sp_id}" ]] && _log_error "Name of the service principal is required" && return 1
  [[ -z "${issuer_url}" ]] && _log_error "The OIDC issuer URL is required" && return 1

  if az ad app federated-credential show --only-show-errors --federated-credential-id "${federated_credential_name}" \
    --id "${sp_id}" > /dev/null 2>&1;
  then
    _log_ok "Federated Credential with name ${federated_credential_name} already exists."; return
  fi

  local app_obj_id
  app_obj_id="$(az ad app show --id "${sp_id}" --query id -otsv)"

  cat <<EOF > params.json
{
  "name": "${federated_credential_name}",
  "issuer": "${issuer_url}",
  "subject": "system:serviceaccount:azureserviceoperator-athena-system:azureserviceoperator-default",
  "description": "",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF

  az ad app federated-credential create --id "${app_obj_id}" --parameters @params.json
}

# Create service principal, assign roles, create federated credentials
function _configure_sp_permissions() {
  local stage_name="${1}"
  local name_prefix="${2}" # Prefix to the names.
  local billing_id_path="${3}" # Billing ids in form 'billingAccounts/xxx/billingProfiles/xxx/invoiceSections/xxx'

  local sp_name # Name of the service principal.
  local sp_id # Client id of the service principal.
  local fc_name # Name of the federated credential.
  local scope # The role assignment scope.

  if [[ -z "${stage_name}" ]]; then _log_error "Lifecycle stage name is required"; return 1; fi
  # Skip 'seed' environment
  if [[ "${stage_name}" == "seed" ]]; then return 0; fi
  if [[ -z "${name_prefix}" ]]; then _log_error "The name prefix is required"; return 1; fi
  if [[ -z "${billing_id_path}" ]]; then _log_error "The billing id path is required"; return 1; fi

  shift 2
  local issuer_url_map=("$@")
  if [[ ${#issuer_url_map[@]} -le 0 ]]; then _log_error "The OIDC issuer URL map is required"; return 1; fi

  sp_name=$(_to_lowercase "${name_prefix}-${stage_name}-sp")
  fc_name=$(_to_lowercase "${name_prefix}-${stage_name}-fc")

  # Create service principal
  _log_ok "Creating service principal: ${sp_name} ..."
  # The stage name match the top level management group name
  scope="$(_get_management_group_id "${stage_name}")"
#  echo "DEBUG: sp_name: ${sp_name}, scope: ${scope}"
  sp_id=$(_create_service_principal "${sp_name}" "${scope}" "Contributor")
#  echo "DEBUG: sp_id: ${sp_id}"
  # Assign roles
  # Contributor role on default subscription
  scope=$(_get_subscription_scope_id)
  _log_ok "Assigning roles to service principal: ${sp_name} on scope ${scope}... for ${sp_id}"
  _assign_role "${sp_id}" "Contributor" "${scope}"

  # Owner role on invoice section
  local app_obj_id
  app_obj_id="$(az ad app show --id "${sp_id}" --query id -otsv)"
  _log_ok "Assign billing roles to service principal on invoice section"
  _assign_billing_role "${app_obj_id}" "30000000-aaaa-bbbb-cccc-100000000000" "$(_get_tenant_id)" "${billing_id_path}"

  # Create federated credentials
  _log_ok "Creating federated credentials for service principal: ${sp_name} ..."
  _create_sp_federated_credentials "${fc_name}" \
    "${sp_id}" "$(_get_parameter_by_key "$(_get_lifecycle_stage "${stage_name}")" "${issuer_url_map[@]}")"
}

# Get the values to create secrets for ASO
function _get_sp_output() {
  local stage_name="${1}"
  local name_prefix="${2}" # Prefix to the names.
  local subscription_id="${3}" # The Azure subscription id
  local tenant_id="${4}" # The Azure tenant id
  local output

  if [[ -z "${stage_name}" ]]; then _log_error "Lifecycle stage name is required"; return 1; fi
  if [[ -z "${name_prefix}" ]]; then _log_error "The name prefix is required"; return 1; fi
  if [[ -z "${subscription_id}" ]]; then _log_error "The Azure subscription id is required"; return 1; fi
  if [[ -z "${tenant_id}" ]]; then _log_error "The Azure tenant id is required"; return 1; fi

  local sp_name # Name of the service principal.
  local sp_id # The service principal id.

  sp_name=$(_to_lowercase "${name_prefix}-${stage_name}-sp")
  sp_id=$(az ad sp list --display-name "${sp_name}" --query "[].{spID:appId}" --output tsv)
  output=$(printf '%s\n%s\n%s\n%s' \
    "AZURE_SUBSCRIPTION_ID=${subscription_id}" \
    "AZURE_TENANT_ID=${tenant_id}" \
    "AZURE_CLIENT_ID=${sp_id}" \
    "USE_WORKLOAD_IDENTITY_AUTH=true"
  )
  echo "${output}"
}

##################################################
# Google secrets section
##################################################

_create_google_secret_version() {
  local secret_name="${1}"
  local secret_value="${2}"
  local athena_project="${3}"
  local retain_versions_count="${4}"

  if [[ -z "${secret_name}" ]]; then _log_error "Secret name is required"; return 1; fi
  # If there is no athena project provided, skip execution without error
  if [[ -z "${athena_project}" ]]; then _log_error "The google cloud project not specified. Skipping saving secret."; return 0; fi

  # remove version from secret name
  secret_name=$(echo "${secret_name}" | sed 's/\.v[0-9]*$//' | tr '.' '_' | tr '[:upper:]' '[:lower:]')
  _log_ok "Checking ${secret_name} google secret exists"

  if ! gcloud secrets describe "${secret_name}" \
    --project "${athena_project}" --verbosity=none; then
    echo "Secret ${secret_name} doesn't exist, creating secret..."
    gcloud secrets create "${secret_name}" --replication-policy="automatic" \
      --project="${athena_project}"
    echo "${secret_value}" | gcloud secrets versions add "${secret_name}" --data-file=- \
      --project "${athena_project}"
  else
    _add_secret_version "${secret_name}" "${secret_value}" "${athena_project}"
    _cleanup_secret_versions "${secret_name}" "${athena_project}" "${retain_versions_count}"
  fi
}

# Add new version to existing secret
_add_secret_version() {
  local secret_name="${1}"
  local secret_value="${2}"
  local athena_project="${3}"

  if [[ -z "${secret_name}" ]]; then _log_error "Secret name is required"; return 1; fi
  if [[ -z "${athena_project}" ]]; then _log_error "The google cloud project is required"; return 1; fi

  _log_ok "Adding new version to ${secret_name} google secret"

  if echo "${secret_value}" | gcloud secrets versions add "${secret_name}" --data-file=- \
    --project "${athena_project}"; then
      _log_ok "Done"
  else
      _log_error "Failed"; return 1
  fi
}

_cleanup_secret_versions() {
  local secret_name="${1}"
  local athena_project="${2}"
  local retain_versions_count="${3}"

  local enabled_versions
  local delete_count

  if [[ -z "${secret_name}" ]]; then _log_error "Secret name is required"; return 1; fi
  if [[ -z "${athena_project}" ]]; then _log_error "The google cloud project is required"; return 1; fi

  _log_ok "Starting secret versions cleanup: ${secret_name} google secret"
  # Do nothing if we need retain all versions
  if [[ -z "${retain_versions_count}" ]]; then _log_ok "Done"; return 0; fi
  if [[ ${retain_versions_count} -le 0 ]]; then _log_error "The retain versions count must be greater then 0"; return 1; fi

  # shellcheck disable=SC2207
  enabled_versions=( $(gcloud secrets versions list "${secret_name}" \
    --project "${athena_project}" \
    --filter "state=enabled OR state=disabled" --format="value(name)" --sort-by=createTime) ) || return 1

  # If retain count is greater or equal then number of versions available - do nothing
  if [[ ${retain_versions_count} -ge ${#enabled_versions[@]} ]]; then _log_ok "Done"; return 0; fi

  delete_count=$(( ${#enabled_versions[@]}-retain_versions_count ))
  for v in "${enabled_versions[@]}"
  do
    echo "Delete count: ${delete_count}"
    if [[ ${delete_count} -le 0 ]]; then break; fi
    echo "Version: ${v}"
    gcloud secrets versions destroy "${v}" --secret="${secret_name}" --quiet

    (( delete_count=delete_count-1 ))
  done
  _log_ok "Done"
}

function _save_google_secrets() {
  local stage_name="${1}"
  local name_prefix="${2}" # Prefix to the names.
  local subscription_id="${3}" # The Azure subscription id
  local tenant_id="${4}" # The Azure tenant id

  local secret_name
  local secret_value

  if [[ -z "${stage_name}" ]]; then _log_error "Lifecycle stage name is required"; return 1; fi
  if [[ -z "${name_prefix}" ]]; then _log_error "The name prefix is required"; return 1; fi
  if [[ -z "${subscription_id}" ]]; then _log_error "The Azure subscription id is required"; return 1; fi
  if [[ -z "${tenant_id}" ]]; then _log_error "The Azure tenant id is required"; return 1; fi

  shift 4
  local athena_projects_map=("$@")
  if [[ ${#athena_projects_map[@]} -le 0 ]]; then _log_error "The Google projects map is required"; return 1; fi

  secret_name="azure_credentials_root"

  secret_value=$(_get_sp_output "${stage_name}" "${name_prefix}" "${subscription_id}" "${tenant_id}")
  _create_google_secret_version "${secret_name}" "${secret_value}" \
    "$(_get_parameter_by_key "$(_get_lifecycle_stage "${stage_name}")" "${athena_projects_map[@]}")"
}
