#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The name of environment file
ENV_FILE=".env"

# The clients organization domain. Required.
ORG_DOMAIN=""
# The Google Cloud Organization ID. e.g. 123456789012. Required.
GCP_ORG_ID=""
# The Google Cloud Billing Account ID. e.g. 01A2B3-C4D5E6-F7G8H9. Required.
GCP_BILLING_ACCOUNT_ID=""

# Names of stages / environments.
# Used to create folder hierarchy.
ENVIRONMENTS_LIST=(
  "development/sandbox"
  "development/testing"
  "production/staging"
  "production/live"
)

# The list of lifecycle stages derived from ENVIRONMENTS_LIST.
LIFECYCLE_STAGES=()

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

		Init usage: ${0} init --domain <domain_name> --org-id <gcp_org_id> --billing-id <gcp_billing_id>
		Parameters:
		  --domain -d      Organization domain name. Required.
		  --org-id         Google Cloud Organization ID. Required.
		  --billing-id     Google Cloud Billing Account ID. Required.

		Apply parameters:
		  --dry-run        Output the commands that would be run without actually running them.
		Global parameters:
		  --help -h        Print help.
		EOF
}

function load_dot_env() {
  if [[ -f "${SCRIPT_DIR}/${ENV_FILE}" ]]; then source "${SCRIPT_DIR}/${ENV_FILE}"; fi
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
    COMMAND_DISPLAY_NAME="Apply new configuration on Google Cloud"
    shift
    ;;
  -h | --help)
    print_help && exit 0
    ;;
  *)
    echo "Error: unknown command '${key}'" && print_help && exit 1
    ;;
  esac

  while [[ $# -gt 0 ]]; do
    key="${1}"

    case "${key}" in
    -d | --domain)
      ORG_DOMAIN="${2}"
      shift 2
      ;;
    --org-id)
      GCP_ORG_ID="${2}"
      shift 2
      ;;
    --billing-id)
      GCP_BILLING_ACCOUNT_ID="${2}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      export DRY_RUN
      shift
      ;;
    -h | --help)
      print_help && exit 0
      ;;
    *)
      echo "Error: unknown option '${key}'" && print_help && exit 1
      ;;
    esac
  done
}

function validate_input() {
  _log_ok "Validating input..."
  local ec=0

  if [[ -z "${ORG_DOMAIN}" ]]; then
    _log_error "Organization domain name is required." && ec=1
  fi
  if [[ -z "${GCP_ORG_ID}" ]]; then
    _log_error "Google Cloud Organization ID is required." && ec=1
  fi
  if [[ -z "${GCP_BILLING_ACCOUNT_ID}" ]]; then
    _log_error "Google Cloud Billing Account ID is required." && ec=1
  fi

  if [[ ${ec} -gt 0 ]]; then print_help && exit 1; fi
  _log_ok "Done\n"
}

function build_lifecycle_list() {
  local tmp_list=()
  for env_path in "${ENVIRONMENTS_LIST[@]}"; do
    tmp_list+=("${env_path//\/*/}")
  done
  # shellcheck disable=SC2207
  LIFECYCLE_STAGES=($(tr ' ' '\n' <<<"${tmp_list[@]}" | awk '!u[$0]++' | tr '\n' ' '))
}

function apply_stage_config() {
    local stage_name="${1}"
    local parent_folder_id="${2}"
    local athena_project_id
    local service_account_email
    local athena_gsa_project_id
    local athena_sha

    athena_project_id=$(_get_athena_project_name "${ORG_DOMAIN}" "${stage_name}")
    service_account_email="cloudspace-creator@${athena_project_id}.iam.gserviceaccount.com"

    _log_ok "Assigning IAM roles for stage '${stage_name}' to folder '${parent_folder_id}'"
    _assign_folder_iam_role "${parent_folder_id}" "${service_account_email}" "roles/resourcemanager.projectCreator"
    _assign_folder_iam_role "${parent_folder_id}" "${service_account_email}" "roles/resourcemanager.projectDeleter"
    _assign_folder_iam_role "${parent_folder_id}" "${service_account_email}" "roles/resourcemanager.projectIamAdmin"
    _assign_billing_iam_role "${GCP_BILLING_ACCOUNT_ID}" "${service_account_email}"

    # Create the athena-gsa project inside the stage folder
    athena_sha=$(echo -n "${athena_project_id}" | cut -c 3-)
    athena_gsa_project_id="athena-gsa-${stage_name}-$(echo -n "${athena_sha}" | head -c 8)"
    _log_ok "Creating athena-gsa project for stage '${stage_name}'"
    _create_project "${athena_gsa_project_id}" "${parent_folder_id}"
}

function apply() {
  _log_ok "Processing lifecycle stages..."
  for stage in "${LIFECYCLE_STAGES[@]}"; do
    _log_ok "--- Stage: ${stage} ---"
    # Create the top-level stage folder (e.g., 'development', 'production')
    local stage_folder_id
    stage_folder_id=$(_create_folder "${stage}" "organizations/${GCP_ORG_ID}")

    # Create subfolders and apply permissions
    for env_path in "${ENVIRONMENTS_LIST[@]}"; do
      if [[ "${env_path}" == "${stage}"* ]]; then
        _log_info "Processing folder path: ${env_path}"
        _create_folder_hierarchy "${env_path}" "organizations/${GCP_ORG_ID}"
      fi
    done
    apply_stage_config "${stage}" "${stage_folder_id}"
  done
  _log_ok "Setup complete."
}

function init() {
    if [[ -f "${SCRIPT_DIR}/${ENV_FILE}" ]]; then
        _log_info "${ENV_FILE} already exists."
    else
        _log_info "Creating ${ENV_FILE}..."
        cat > "${SCRIPT_DIR}/${ENV_FILE}" <<-EOF
			# Google Cloud configuration for Athena
			# The clients organization domain.
			ORG_DOMAIN="${ORG_DOMAIN}"
			# The Google Cloud Organization ID (e.g., 123456789012).
			GCP_ORG_ID="${GCP_ORG_ID}"
			# The Google Cloud Billing Account ID (e.g., 01A2B3-C4D5E6-F7G8H9).
			GCP_BILLING_ACCOUNT_ID="${GCP_BILLING_ACCOUNT_ID}"
			EOF
    fi
    _log_ok "Initialization done. Please review and edit ${SCRIPT_DIR}/${ENV_FILE}."
}

######
# Main
######
function main() {
  load_dot_env
  parse_args "$@"
  validate_input
  _check_prerequisites
  build_lifecycle_list
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    _log_ok "Dry run mode enabled. No changes will be made."
  fi

  _log_ok "Run: ${COMMAND_DISPLAY_NAME}"
  ${COMMAND}
}

main "$@"