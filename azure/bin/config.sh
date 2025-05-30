#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The name of environment file
ENV_FILE=".env"

# The clients organization domain. Required.
ORG_DOMAIN=""
# Names of stages / environments.
# Used to create management groups hierarchy, managed identities and setup permissions.
ENVIRONMENTS_LIST=(
  "development/sandbox"
  "development/testing"
  "production/staging"
  "production/live"
)
# The parent of management groups hierarchy. Optional.
# If empty string, the 'Tenant Root Group' will be used.
MANAGEMENT_GROUP_PARENT=""
# Location. Values from: 'az account list-locations'. Required.
LOCATION=""
# The OIDC issuer URLs map. Required.
OIDC_ISSUER_URLS=()
# Google Cloud project
ATHENA_PROJECTS=()
# The list of lifecycle stages.
LIFECYCLE_STAGES=(
  "development"
  "production"
)

NAME_PREFIX=""
# Billing information
BILLING_ACCOUNT_NAME=""
BILLING_PROFILE_NAME=""
BILLING_INVOICE_SECTION_NAME=""


############################################
# Parameters processing and helper functions
############################################

source "${SCRIPT_DIR}/common.sh"

function print_help() {
  cat <<-EOF
		Usage: ${0} <command> [<parameters>]
		Commands:
		  init
		  apply
		  output
		  save-secrets
		  set-billing-scope

		Init usage: ${0} init --domain <domain_name>
		Parameters:
		  --domain -d     Organization domain name. Required.

		Global parameters:
		  --location -l   Location. Values from: 'az account list-locations'.
		  --help -h       Print help.
		EOF
}

function print_dot_env_help() {
  echo "Dot Env help"
}

function load_dot_env() {
  # shellcheck disable=SC2046
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then source "${SCRIPT_DIR}/.env"; fi
}

function parse_args() {
  key="${1}"

  case "${key}" in
  init)
    COMMAND="init"
    COMMAND_DISPLAY_NAME="Generate .env blank file"
    shift
    ;;
  apply)
    COMMAND="apply"
    COMMAND_DISPLAY_NAME="Apply new configuration on Azure"
    shift
    ;;
  output)
    COMMAND="output"
    COMMAND_DISPLAY_NAME="Display output"
    shift
    ;;
  save-secrets)
    COMMAND="save_secrets"
    COMMAND_DISPLAY_NAME="Save secret for environment to Google Cloud secret manager"
    shift
    ;;
  set-billing-scope)
    COMMAND="set_billing_scope"
    COMMAND_DISPLAY_NAME="Set the values of billing account, billing profile and invoice section"
    shift
    ;;
  -h | --help)
    print_help && exit 0
    ;;
  *)
    echo "Error: unknown command '${key}'" && print_help && exit 1
    ;;
  esac

  set +e
  while [[ $# -gt 0 ]]; do
    key="${1}"

    case "${key}" in
    -l | --location)
      LOCATION="${2}"
      shift # past argument
      shift # past value
      ;;
    -d | --domain)
      ORG_DOMAIN="${2}"
      shift # past argument
      shift # past value
      ;;
    -h | --help)
      print_help && exit 0
      ;;
    *)
      echo "Error: unknown option '${key}'" && print_help && exit 1
      ;;
    esac
  done
  set -e
}

############################
# Input validation functions
############################

function validate_dot_env() {
  _log_ok "Validating dot env file..."

  if [[ "${COMMAND}" == "init" ]]; then
    return 0
  fi

  if [[ -z "${ORG_DOMAIN}" ]]; then
    _log_error "Organization domain name is required by init command" && print_help && exit 1
  fi
  NAME_PREFIX="$(_get_name_prefix "${ORG_DOMAIN}")"

  if [[ ${#OIDC_ISSUER_URLS[@]} -le 0 ]]; then
    _log_error "The OIDC issuer URLs map shouldn't be empty" && print_help && exit 1
  fi

  if [[ ${#ATHENA_PROJECTS[@]} -le 0 && "${COMMAND}" == "save_secrets" ]]; then
    _log_error "Google Cloud project should be specified" && print_help && exit 1
  fi

}

function validate_input() {
  _log_ok "Validating input..."

  if [[ "${COMMAND}" == "init" ]]; then
    if [[ -z "${ORG_DOMAIN}" ]]; then
      _log_error "Organization domain name is required by init command" && print_help && exit 1
    fi
    return 0
  fi

  if [[ -z "${LOCATION}" ]]; then
    _log_error "Location should be specified" && print_help && exit 1
  fi

  _log_ok "Done\n"
}

###################
# Billing functions
###################
# Get names of billing account, billing profile, and invoice section. Build combination of names used in API calls
function get_billing_id_path() {
  local billing_account_name="${1}"
  local billing_profile_name="${2}"
  local billing_invoice_section_name="${3}"

  if [[ -z "${billing_account_name}" ]]; then _log_error "Billing account name is required"; return 1; fi
  if [[ -z "${billing_profile_name}" ]]; then _log_error "Billing profile name is required"; return 1; fi
  if [[ -z "${billing_invoice_section_name}" ]]; then _log_error "Invoice section name is required"; return 1; fi

  echo "billingAccounts/${billing_account_name}/billingProfiles/${billing_profile_name}/invoiceSections/${billing_invoice_section_name}"
}

function get_billing_scope_id() {
  local billing_account_name="${1}"
  local billing_profile_name="${2}"
  local billing_invoice_section_name="${3}"

  if [[ -z "${billing_account_name}" ]]; then _log_error "Billing account name is required"; return 1; fi
  if [[ -z "${billing_profile_name}" ]]; then _log_error "Billing profile name is required"; return 1; fi
  if [[ -z "${billing_invoice_section_name}" ]]; then _log_error "Invoice section name is required"; return 1; fi

  echo "/providers/Microsoft.Billing/billingAccounts/${billing_account_name}/billingProfiles/${billing_profile_name}/invoiceSections/${billing_invoice_section_name}"
}

# Prints option list and gets user input
# Example how to select subscription from list of enabled:
# sli=( $(az account subscription list --only-show-errors --query "[?state=='Enabled'].subscriptionId" --output tsv) )
# _select_option "${sli[@]}"
SELECT_OPTION_VALUE=""
function select_option() {
  local options=("$@")
  local op_num=1
  local op_choice
  SELECT_OPTION_VALUE=""

  # shellcheck disable=SC2128
  if [[ ${#options[@]} -le 0 || (${#options[@]} -eq 1 && -z "${options}") ]]; then
    return
  fi

  _log_info "Pick option to use:"
  for itm in "${options[@]}"
  do
    echo " [${op_num}] ${itm}"
    ((op_num=op_num+1))
  done

  _log_begin "Please enter your numeric choice: "
  read -r op_choice
  op_choice="${op_choice:-1}"

  if [[ "${op_choice}" -ge 1 && "${op_choice}" -le ${#options[@]} ]]; then
    ((op_choice=op_choice-1))
    SELECT_OPTION_VALUE="${options[$op_choice]}"
  fi
}

# Get the billing account, billing profile and invoice section ids
function get_billing_ids() {
  local billing_account_list
  local billing_profile_list
  local billing_invoice_section_list

  _log_ok "Select billing account"
   billing_account_list=$(az billing account list --only-show-errors --output tsv --query "[].[name]")
  select_option "${billing_account_list[@]}"
  BILLING_ACCOUNT_NAME="${SELECT_OPTION_VALUE}"

  _log_ok "Select billing profile"
  billing_profile_list=$(az billing profile list --account-name "${BILLING_ACCOUNT_NAME}" --only-show-errors \
    --output tsv --query "[].[name]")
  select_option "${billing_profile_list[@]}"
  BILLING_PROFILE_NAME="${SELECT_OPTION_VALUE}"

  _log_ok "Select invoice section"
  billing_invoice_section_list=$(az billing invoice section list --account-name "${BILLING_ACCOUNT_NAME}" \
    --profile-name "${BILLING_PROFILE_NAME}" --only-show-errors --output tsv --query "[].[name]")
  select_option "${billing_invoice_section_list[@]}"
  BILLING_INVOICE_SECTION_NAME="${SELECT_OPTION_VALUE}"

  return 0
}

###################################################
# Lifecycle and environment configuration functions
###################################################

function build_lifecycle_list() {
  local tmp_list=()

  for env_path in "${ENVIRONMENTS_LIST[@]}"
  do
    tmp_list+=( "$(_get_lifecycle_stage "${env_path}")" )
  done
  # shellcheck disable=SC2207
  LIFECYCLE_STAGES=( $(tr ' ' '\n' <<<"${tmp_list[@]}" | awk '!u[$0]++' | tr '\n' ' ') )
}

function configure_environments() {
  local fnc="${1}"
  shift

  [[ -z "${fnc}" ]] && _log_error "Function name is missing" && return 1

  for mg_path in "${ENVIRONMENTS_LIST[@]}"
  do
    _log_ok "${mg_path//\//-}"

    ${fnc} "${mg_path}" "$@"
  done
}

function configure_lifecycle_stages() {
  local fnc="${1}"
  shift

  [[ -z "${fnc}" ]] && _log_error "Function name is missing" && return 1

  for stage_name in "${LIFECYCLE_STAGES[@]}"
  do
    _log_ok "${stage_name}"

    ${fnc} "${stage_name}" "$@"
  done
}

########################
# Seed related functions
########################

function configure_seed() {
  local resource_group_name
  local service_principal_name
  local federated_credential_name
  local sp_id

  resource_group_name=$(_to_lowercase "${NAME_PREFIX}-seed-rg")
  service_principal_name=$(_to_lowercase "${NAME_PREFIX}-seed-sp")
  federated_credential_name=$(_to_lowercase "${NAME_PREFIX}-seed-fc")

  # Resource group
  _log_ok "Creating resource group: ${resource_group_name} ..."
  _create_resource_group "${resource_group_name}" "${LOCATION}"

  # Service principal
  _log_ok "Creating service principal: ${service_principal_name} ..."
  sp_id=$(_create_service_principal "${service_principal_name}" "$(_get_subscription_scope_id)" "Contributor")

  _log_ok "Assigning roles to service principal: ${service_principal_name} ..."
  _assign_role "${sp_id}" "Contributor" "$(_get_resource_group_id "${resource_group_name}")"

  # Owner role on invoice section
  local app_obj_id
  app_obj_id="$(az ad app show --id "${sp_id}" --query id -otsv)"
  _log_ok "Assign billing roles to service principal on invoice section"
  _assign_billing_role "${app_obj_id}" "30000000-aaaa-bbbb-cccc-100000000000" "$(_get_tenant_id)" \
    "$(get_billing_id_path "${BILLING_ACCOUNT_NAME}" "${BILLING_PROFILE_NAME}" "${BILLING_INVOICE_SECTION_NAME}")"

  _log_ok "Creating federated credentials for service principal: ${service_principal_name} ..."
  _create_sp_federated_credentials "${federated_credential_name}" \
    "${sp_id}" "$(_get_parameter_by_key "production" "${OIDC_ISSUER_URLS[@]}")"
}

function seed_output() {
  local subscription_id="${1}"
  local tenant_id="${2}"

  if [[ -z "${subscription_id}" ]]; then _log_error "The Azure subscription id is required"; return 1; fi
  if [[ -z "${tenant_id}" ]]; then _log_error "The Azure tenant id is required"; return 1; fi

  _log_ok "seed"

  _get_sp_output "seed" "${NAME_PREFIX}" "${subscription_id}" "${tenant_id}"
}

function save_seed_secrets() {
  local subscription_id="${1}"
  local tenant_id="${2}"

  if [[ -z "${subscription_id}" ]]; then _log_error "The Azure subscription id is required"; return 1; fi
  if [[ -z "${tenant_id}" ]]; then _log_error "The Azure tenant id is required"; return 1; fi

  _log_ok "seed"

  _save_google_secrets "seed" "${NAME_PREFIX}" \
    "${subscription_id}" "${tenant_id}" "${ATHENA_PROJECTS[@]}"
}

##########
# Commands
##########

function init() {
  local ENV_FILE=".env"

  if [[ ! -f "${SCRIPT_DIR}/${ENV_FILE}" ]]; then

    touch "${SCRIPT_DIR}/${ENV_FILE}"

    cat <<-EOF > "${SCRIPT_DIR}/${ENV_FILE}"
		# Athena .env file
		# The clients organization domain. Required.
		ORG_DOMAIN="${ORG_DOMAIN}"
		# Location. Values from: 'az account list-locations'. Required.
		LOCATION="uksouth"
		# The parent of management groups hierarchy. Optional.
		# If empty string, the 'Tenant Root Group' will be used.
		MANAGEMENT_GROUP_PARENT=""
		EOF

    # The OIDC issuer URL.
    echo "# The map of the OIDC issuer URLs. Required. Each environment should have OIDC URL as a value." \
      >> "${SCRIPT_DIR}/${ENV_FILE}"
    echo "OIDC_ISSUER_URLS=(" >> "${SCRIPT_DIR}/${ENV_FILE}"
    for stage_name in "${LIFECYCLE_STAGES[@]}"
    do
      echo "  \"${stage_name}=\"" >> "${SCRIPT_DIR}/${ENV_FILE}"
    done
    echo ")" >> "${SCRIPT_DIR}/${ENV_FILE}"

    # Google cloud projects to save secrets
    echo "# The map of GCP projects to save secrets. Required. Each environment should have GCP project as a value." \
      >> "${SCRIPT_DIR}/${ENV_FILE}"
    echo "ATHENA_PROJECTS=(" >> "${SCRIPT_DIR}/${ENV_FILE}"
    echo "  \"seed=$(_get_athena_project_name "${ORG_DOMAIN}" "seed")\"" >> "${SCRIPT_DIR}/${ENV_FILE}"
    for stage_name in "${LIFECYCLE_STAGES[@]}"
    do
      echo "  \"${stage_name}=$(_get_athena_project_name "${ORG_DOMAIN}" "${stage_name}")\"" >> "${SCRIPT_DIR}/${ENV_FILE}"
    done
    echo ")" >> "${SCRIPT_DIR}/${ENV_FILE}"

    # Billing information
    get_billing_ids
    echo "# Billing information" >> "${SCRIPT_DIR}/${ENV_FILE}"

    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_ACCOUNT_NAME" "${BILLING_ACCOUNT_NAME}"
    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_PROFILE_NAME" "${BILLING_PROFILE_NAME}"
    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_INVOICE_SECTION_NAME" "${BILLING_INVOICE_SECTION_NAME}"
  fi

  _log_ok "Initialization done"
}

function apply() {
  configure_seed
  
  _log_ok "Creating management groups..."
  configure_environments _create_management_group_hierarchy "${MANAGEMENT_GROUP_PARENT}"
  
  sleep 60

  _log_ok "Configuring permissions..."
  configure_lifecycle_stages _configure_sp_permissions "${NAME_PREFIX}" \
    "$(get_billing_id_path "${BILLING_ACCOUNT_NAME}" "${BILLING_PROFILE_NAME}" "${BILLING_INVOICE_SECTION_NAME}")" \
    "${OIDC_ISSUER_URLS[@]}"
}

# TODO: return empty secret value for env in case of error
function output() {
  local azure_subscription_id
  local azure_tenant_id

  azure_subscription_id=$(_get_subscription_id)
  azure_tenant_id=$(_get_tenant_id)

  _log_ok "Getting output..."
  seed_output "${azure_subscription_id}" "${azure_tenant_id}"
  configure_lifecycle_stages _get_sp_output "${NAME_PREFIX}" "${azure_subscription_id}" "${azure_tenant_id}"

  _log_ok "Billing scope:"
  _log_info "$(get_billing_scope_id "${BILLING_ACCOUNT_NAME}" "${BILLING_PROFILE_NAME}" "${BILLING_INVOICE_SECTION_NAME}")"
}

function save_secrets() {
  local azure_subscription_id
  local azure_tenant_id

  azure_subscription_id=$(_get_subscription_id)
  azure_tenant_id=$(_get_tenant_id)

  _log_ok "Saving secrets..."
  save_seed_secrets "${azure_subscription_id}" "${azure_tenant_id}"
  configure_lifecycle_stages _save_google_secrets "${NAME_PREFIX}" \
    "${azure_subscription_id}" "${azure_tenant_id}" "${ATHENA_PROJECTS[@]}"
}

function set_billing_scope() {
    get_billing_ids

    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_ACCOUNT_NAME" "${BILLING_ACCOUNT_NAME}"
    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_PROFILE_NAME" "${BILLING_PROFILE_NAME}"
    _write_env_var "${SCRIPT_DIR}/${ENV_FILE}" "BILLING_INVOICE_SECTION_NAME" "${BILLING_INVOICE_SECTION_NAME}"
}

######
# Main
######
function main() {
  load_dot_env
  parse_args "$@"
  validate_dot_env
  validate_input
  _check_prerequisites

  _log_ok "Run: ${COMMAND_DISPLAY_NAME}"
  ${COMMAND}
}

main "$@"
