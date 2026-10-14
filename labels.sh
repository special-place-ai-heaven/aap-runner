# Shared runner-label checks. Source this file; it does not run on source.
# GitHub compares labels case-insensitively, so a label must already be
# lowercase. The charset check runs before the reserved-label check and
# before the duplicate check.
# shellcheck shell=bash

# Bump this when the label contract changes. The manager, bootstrap, and
# evidence each call require_labels_version with the value they were
# written against and exit if this stamp differs.
AAP_RUNNER_LABELS_VERSION=1

require_labels_version() {
  local expected="$1"
  if [[ "${AAP_RUNNER_LABELS_VERSION}" == "${expected}" ]]; then
    return 0
  fi
  echo "refusing: AAP_RUNNER_LABELS_VERSION=${AAP_RUNNER_LABELS_VERSION} does not match ${expected}" >&2
  return 1
}

label_charset_ok() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

label_is_reserved() {
  case "$1" in
    crrr | fresh | self-hosted | linux) return 0 ;;
  esac
  return 1
}

# Charset, then crrr or fresh. Empty is refused. Uppercase never reaches
# the allowed-value check.
validate_base_label() {
  local base="$1"
  if [[ -z "${base}" ]]; then
    echo "refusing: AAP_RUNNER_BASE_LABEL is required" >&2
    return 1
  fi
  if ! label_charset_ok "${base}"; then
    echo "refusing: AAP_RUNNER_BASE_LABEL=${base} does not match ^[a-z0-9][a-z0-9._-]*$" >&2
    return 1
  fi
  case "${base}" in
    crrr | fresh) return 0 ;;
  esac
  echo "refusing: AAP_RUNNER_BASE_LABEL=${base} is not crrr or fresh" >&2
  return 1
}

# Charset, then reserved, then duplicate against seen (comma-separated).
extra_label_ok() {
  local part="$1" seen="$2"
  if ! label_charset_ok "${part}"; then
    echo "refusing: extra label '${part}' does not match ^[a-z0-9][a-z0-9._-]*$" >&2
    return 1
  fi
  if label_is_reserved "${part}"; then
    echo "refusing: extra label '${part}' is reserved" >&2
    return 1
  fi
  case ",${seen}," in
    *",${part},"*)
      echo "refusing: extra label '${part}' duplicates a label already set" >&2
      return 1
      ;;
  esac
  return 0
}

compose_runner_labels() {
  local base="$1" extra="$2" part seen="" expect
  local -a parts=()
  validate_base_label "${base}" || return 1
  expect="self-hosted,linux,${base}"
  if [[ -z "${extra}" ]]; then
    printf '%s\n' "${expect}"
    return 0
  fi
  IFS=',' read -ra parts <<< "${extra}"
  if [[ "${#parts[@]}" -eq 0 ]]; then
    echo "refusing: AAP_RUNNER_EXTRA_LABELS has no label" >&2
    return 1
  fi
  for part in "${parts[@]}"; do
    extra_label_ok "${part}" "${seen}" || return 1
    seen="${seen:+${seen},}${part}"
  done
  printf '%s\n' "${expect},${seen}"
}

labels_line_ok() {
  local line="$1" base="$2"
  [[ "${line}" == "self-hosted,linux,${base}" || "${line}" == "self-hosted,linux,${base},"* ]] || return 1
  [[ "${line}" =~ ^self-hosted,linux,(crrr|fresh)(,[a-z0-9][a-z0-9._-]*)*$ ]]
}

# The right-hand side of [[ == ]] is a pattern. Quote the charset so
# ^, brackets, and * stay literal and this check cannot pass on a
# different refusal.
charset_refusal() {
  [[ "$1" == *'does not match ^[a-z0-9][a-z0-9._-]*$'* ]]
}

labels_self_check() {
  local name err rc
  for name in CRRR Crrr FRESH; do
    rc=0
    err=$(validate_base_label "${name}" 2>&1) || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      echo "base label ${name} was accepted" >&2
      return 1
    fi
    if ! charset_refusal "${err}"; then
      echo "base label ${name} was not refused by the charset check" >&2
      printf '%s\n' "${err}" >&2
      return 1
    fi
  done
  for name in LINUX Self-Hosted; do
    rc=0
    err=$(extra_label_ok "${name}" "" 2>&1) || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      echo "extra label ${name} was accepted" >&2
      return 1
    fi
    if ! charset_refusal "${err}"; then
      echo "extra label ${name} was not refused by the charset check" >&2
      printf '%s\n' "${err}" >&2
      return 1
    fi
  done
  rc=0
  err=$(compose_runner_labels fresh "heavy,Heavy" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "heavy,Heavy was accepted" >&2
    return 1
  fi
  if [[ "${err}" != *"Heavy"* ]] || ! charset_refusal "${err}"; then
    echo "heavy,Heavy was not refused by the charset check" >&2
    printf '%s\n' "${err}" >&2
    return 1
  fi
  validate_base_label crrr
  validate_base_label fresh
  extra_label_ok heavy ""
  rc=0
  err=$(extra_label_ok linux "" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 || "${err}" != *"is reserved"* ]]; then
    echo "lowercase linux was not refused as reserved" >&2
    return 1
  fi
  [[ "$(compose_runner_labels crrr "")" == "self-hosted,linux,crrr" ]]
  [[ "$(compose_runner_labels fresh heavy)" == "self-hosted,linux,fresh,heavy" ]]
  require_labels_version "${AAP_RUNNER_LABELS_VERSION}"
  rc=0
  err=$(require_labels_version "not-${AAP_RUNNER_LABELS_VERSION}" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 || "${err}" != *"does not match not-${AAP_RUNNER_LABELS_VERSION}"* ]]; then
    echo "a labels version mismatch was accepted" >&2
    printf '%s\n' "${err}" >&2
    return 1
  fi
  echo "labels self-check ok"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    --self-check) labels_self_check ;;
    *)
      echo "usage: labels.sh --self-check" >&2
      exit 1
      ;;
  esac
fi
