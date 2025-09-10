#!/usr/bin/env bash

DRY_RUN=false
DEBUG=false

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

function _log_cmd() {
  # Always log to stderr to avoid contaminating command output
  echo -e "\033[0;36mCMD: ${1}\033[0m" >&2
}

function _run() {
  # The first argument determines the type of command (e.g., 'resource-manager', 'projects')
  if [[ "${DEBUG}" == "true" ]]; then
    # Use printf to safely quote arguments for logging
    _log_cmd "gcloud $(printf "'%s' " "$@")"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    # In dry-run mode, only execute read-only commands (list, describe).
    # For write commands (create, add-iam-policy-binding), just return.
    case "${2}" in
      list|describe)
        # It's safe to execute read-only commands.
        ;;
      *)
        # This is a write command, so we skip execution.
        return
        ;;
    esac
  fi

  # Execute the command directly, passing arguments as an array. This is safer than eval.
  gcloud "$@"
}

function _to_lowercase() {
  local in_str="${1}"
  local out_str

  out_str="$(tr '[:upper:]' '[:lower:]' <<< "${in_str}")"
  echo "${out_str}"
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

  # Check whether gcloud CLI installed
  if which gcloud > /dev/null 2>&1; then
    gcloud version
    _log_begin "gcloud CLI: "; _log_ok "OK"
  else
    _log_begin "gcloud CLI: "; _log_error "ERROR"
    _log_error "gcloud CLI required. See: https://cloud.google.com/sdk/docs/install"
    ((ec=ec+1))
  fi

  # Check gcloud login
  if account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null); then
    _log_begin "gcloud login: "; _log_ok "OK"
    _log_begin "Logged in as "; _log_ok "${account}"
  else
    _log_begin "gcloud login: "; _log_error "ERROR"
    _log_error "Please run 'gcloud auth login' and 'gcloud auth application-default login' to setup account."
    ((ec=ec+1))
  fi

  _log_begin "Prerequisites check: "
  if [ "${ec}" -gt 0 ]; then _log_error "Failed\n";  exit "${ec}"; else _log_ok "Passed\n"; fi
}

# Create folder if it doesn't exist
function _create_folder() {
  local folder_name="${1}"
  local parent_id="${2}" # e.g. organizations/12345 or folders/67890

  if [[ -z "${folder_name}" ]]; then _log_error "Folder name is required"; return 1; fi
  if [[ -z "${parent_id}" ]]; then _log_error "Parent ID is required"; return 1; fi

  # Normalize parent_id to ensure it has the correct prefix.
  if [[ ! "${parent_id}" =~ ^(organizations|folders)/ ]]; then
    # If it's just a number, assume it's a folder ID. The org ID is always passed with its prefix.
    if [[ "${DEBUG}" == "true" ]]; then
       _log_info "Normalizing parent ID '${parent_id}' to 'folders/${parent_id}'" >&2
    fi
    parent_id="folders/${parent_id}"
  fi

  local existing_folder_id
  local scope_arg

  if [[ "${parent_id}" == "organizations/"* ]]; then
    scope_arg="--organization=${parent_id##*/}"
  else
    scope_arg="--folder=${parent_id##*/}"
  fi

  # To achieve a case-insensitive exact match, we list all folders and check in bash.
  # The gcloud filter's '=' is case-sensitive, and ':' is a substring match.
  local all_folders_raw
  all_folders_raw=$(_run resource-manager folders list --format="csv[no-heading](name,displayName)" "${scope_arg}")

  local desired_name_lower
  desired_name_lower=$(_to_lowercase "${folder_name}")

  while IFS=, read -r name display_name; do
    local current_name_lower
    current_name_lower=$(_to_lowercase "${display_name}")
    if [[ "${current_name_lower}" == "${desired_name_lower}" ]]; then
      existing_folder_id="${name}"
      break
    fi
  done <<< "${all_folders_raw}"

  if [[ -n "${existing_folder_id}" ]]; then
    _log_info "Folder '${folder_name}' with id '${existing_folder_id}' already exists under parent '${parent_id}'." >&2
    echo "${existing_folder_id}"
    return 0
  fi
  
  _log_info "Creating folder: ${folder_name} under parent ${parent_id}" >&2
  if [[ "${DRY_RUN}" == "true" ]]; then
    _log_cmd "gcloud resource-manager folders create --display-name=\"${folder_name}\" ${scope_arg} --format=\"value(name)\""
    echo "folders/DRY_RUN_PLACEHOLDER_FOR_${folder_name}"
  else
    _run resource-manager folders create --display-name="${folder_name}" "${scope_arg}" --format="value(name)"
  fi
}

# Create hierarchy of folders
function _create_folder_hierarchy() {
  local folder_path="${1}"
  local parent_id="${2}" # e.g. organizations/12345
  local current_parent_id="${parent_id}"
  local folder_name
  local path_to_create="${folder_path}"

  # If the parent is a folder, we only need to create the sub-path.
  if [[ "${parent_id}" == "folders/"* ]]; then
    path_to_create=$(echo "${folder_path}" | sed 's/^[^\/]*\///')
  fi

  # Only proceed if there are sub-folders to create.
  for folder_name in $(echo "${path_to_create}" | sed 's/\// /g'); do
    current_parent_id=$(_create_folder "${folder_name}" "${current_parent_id}")
    if [[ -z "${current_parent_id}" ]]; then
      _log_error "Failed to create or find folder '${folder_name}'. Aborting hierarchy creation."
      return 1
    fi
  done
  echo "${current_parent_id}"
}

# Create project if it doesn't exist
function _create_project() {
    local project_id="${1}"
    local parent_folder_id="${2}"

    if [[ -z "${project_id}" ]]; then _log_error "Project ID is required"; return 1; fi

    # Read-only command, safe to run in all modes.
    if _run projects describe "${project_id}" > /dev/null 2>&1; then
        _log_info "Project '${project_id}' already exists." >&2
    else
        _log_info "Creating project '${project_id}'..."
        # This is a write command, so we use the _run_gcloud wrapper
        # which respects DRY_RUN.
        _run projects create "${project_id}" ${parent_folder_id:+--folder="${parent_folder_id}"}
    fi
}

# Assign IAM role to a service account on a folder
function _assign_folder_iam_role() {
    local folder_id="${1}"
    local service_account_email="${2}"
    local role="${3}"

    if [[ -z "${folder_id}" ]]; then _log_error "Folder ID is required"; return 1; fi
    if [[ -z "${service_account_email}" ]]; then _log_error "Service account email is required"; return 1; fi
    if [[ -z "${role}" ]]; then _log_error "Role is required"; return 1; fi

    _log_info "Assigning role '${role}' to '${service_account_email}' on folder '${folder_id}'" >&2
    if [[ "${DRY_RUN}" == "true" ]]; then
        _log_cmd "gcloud resource-manager folders create --display-name=\"${folder_name}\" ${scope_arg} --format=\"value(name)\""
    else
        _run resource-manager folders add-iam-policy-binding "${folder_id}" --member="serviceAccount:${service_account_email}" --role="${role}" --condition=None > /dev/null
    fi
}

# Assign IAM role to a service account on a project
function _assign_project_iam_role() {
    local project_id="${1}"
    local service_account_email="${2}"
    local role="${3}"

    if [[ -z "${project_id}" ]]; then _log_error "Project ID is required"; return 1; fi
    if [[ -z "${service_account_email}" ]]; then _log_error "Service account email is required"; return 1; fi
    if [[ -z "${role}" ]]; then _log_error "Role is required"; return 1; fi

    _log_info "Assigning role '${role}' to '${service_account_email}' on project '${project_id}'" >&2
    _run projects add-iam-policy-binding "${project_id}" --member="serviceAccount:${service_account_email}" --role="${role}" --condition=None > /dev/null
}

# Assign Billing User role to a service account on a billing account
function _assign_billing_iam_role() {
    local billing_account_id="${1}"
    local service_account_email="${2}"

    if [[ -z "${billing_account_id}" ]]; then _log_error "Billing account ID is required"; return 1; fi
    if [[ -z "${service_account_email}" ]]; then _log_error "Service account email is required"; return 1; fi

    _log_info "Assigning Billing User role to '${service_account_email}' on billing account '${billing_account_id}'" >&2
    _run billing accounts add-iam-policy-binding "${billing_account_id}" --member="serviceAccount:${service_account_email}" --role="roles/billing.user" > /dev/null
}