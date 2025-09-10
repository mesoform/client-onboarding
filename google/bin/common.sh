#!/usr/bin/env bash

DRY_RUN=false

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
  echo -e "\033[0;36m${1}\033[0m"
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

  local existing_folder_id
  existing_folder_id=$(gcloud resource-manager folders list --format="value(ID)" \
    --filter="displayName=${folder_name} AND parent=${parent_id}")

  if [[ -n "${existing_folder_id}" ]]; then
    _log_info "Folder '${folder_name}' already exists under parent '${parent_id}'."
    echo "${existing_folder_id}"
    return 0
  fi

  _log_info "Creating folder: ${folder_name} under parent ${parent_id}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    _log_cmd "gcloud resource-manager folders create --display-name=\"${folder_name}\" --parent=\"${parent_id}\" --format=\"value(ID)\""
  else
    gcloud resource-manager folders create --display-name="${folder_name}" --parent="${parent_id}" --format="value(ID)"
  fi
}

# Create hierarchy of folders
function _create_folder_hierarchy() {
  local folder_path="${1}"
  local parent_id="${2}" # e.g. organizations/12345
  local current_parent_id="${parent_id}"
  local folder_name

  if [[ -z "${folder_path}" ]]; then _log_error "Folder path is required"; return 1; fi

  for folder_name in $(echo "${folder_path}" | sed 's/\// /g'); do
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

    if gcloud projects describe "${project_id}" > /dev/null 2>&1; then
        _log_info "Project '${project_id}' already exists."
    else
        _log_info "Creating project '${project_id}'..."
        if [[ "${DRY_RUN}" == "true" ]]; then
          _log_cmd "gcloud projects create \"${project_id}\" ${parent_folder_id:+--folder=\"${parent_folder_id}\"}"
        else
          gcloud projects create "${project_id}" ${parent_folder_id:+--folder="${parent_folder_id}"}
        fi
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

    _log_info "Assigning role '${role}' to '${service_account_email}' on project '${project_id}'"
    if [[ "${DRY_RUN}" == "true" ]]; then
      _log_cmd "gcloud projects add-iam-policy-binding \"${project_id}\" --member=\"serviceAccount:${service_account_email}\" --role=\"${role}\" --condition=None"
    else
      gcloud projects add-iam-policy-binding "${project_id}" \
          --member="serviceAccount:${service_account_email}" \
          --role="${role}" \
          --condition=None > /dev/null
    fi
}

# Assign Billing User role to a service account on a billing account
function _assign_billing_iam_role() {
    local billing_account_id="${1}"
    local service_account_email="${2}"

    if [[ -z "${billing_account_id}" ]]; then _log_error "Billing account ID is required"; return 1; fi
    if [[ -z "${service_account_email}" ]]; then _log_error "Service account email is required"; return 1; fi

    _log_info "Assigning Billing User role to '${service_account_email}' on billing account '${billing_account_id}'"
    if [[ "${DRY_RUN}" == "true" ]]; then
      _log_cmd "gcloud billing accounts add-iam-policy-binding \"${billing_account_id}\" --member=\"serviceAccount:${service_account_email}\" --role=\"roles/billing.user\""
    else
      gcloud billing accounts add-iam-policy-binding "${billing_account_id}" \
          --member="serviceAccount:${service_account_email}" \
          --role="roles/billing.user" > /dev/null
    fi
}