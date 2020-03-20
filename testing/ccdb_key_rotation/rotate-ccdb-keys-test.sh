#!/bin/bash

set -o errexit -o nounset #-o xtrace

export KUBECF_NAMESPACE="${KUBECF_NAMESPACE:-kubecf}"
export KUBECF_INSTALL_NAME="${KUBECF_INSTALL_NAME:-kubecf}"
KUBECF_CHART_TARGET="${KUBECF_CHART_TARGET:-//deploy/helm/kubecf}"
VALUES_FILE="${PWD}/ccdb-new-key-label.yaml"

# - -- --- ----- -------- ------------- ---------------------

# color codes
# - 30 black - 31 red - 32 green - 33 yellow - 34 blue - 35 magenta - 36 cyan - 37 white

function red()   { printf '\e[31m%b\e[0m' "$1" ; }
function green() { printf '\e[32m%b\e[0m' "$1" ; }
function blue()  { printf '\e[34m%b\e[0m' "$1" ; }
function cyan()  { printf '\e[36m%b\e[0m' "$1" ; }

# - -- --- ----- -------- ------------- ---------------------

echo
echo -n 'Talking to cluster referenced by ... '
# shellcheck disable=SC2005
echo "$(blue "${KUBECONFIG}")"

echo    "KubeCF operating in namespace    ... $(blue "${KUBECF_NAMESPACE}")"
echo    "KubeCF deployment                ... $(blue "${KUBECF_INSTALL_NAME}")"
echo

# - -- --- ----- -------- ------------- ---------------------

# Given a bazel target, output the file name it generates ending with
# the given extension.
get_output_file() {
    local package="${1}"
    local extension="${2}"
    awk "
    BEGIN { wanted_action = false }
    wanted_action && match(\$0, /^  Outputs: \\[(.*)\\]/, output) {
      print output[1];
    }
    /^[^ ]/ { wanted_action = 0 }
    /^action.*\\.${extension}'\$/ {
      wanted_action = 1
    }
  " <(bazel aquery "${package}:all" 2>/dev/null)
}

rotate_job_name() {
    kubectl get jobs --namespace "${KUBECF_NAMESPACE}" --output name 2> /dev/null | \
        grep "rotate-cc-database-key"
}

rotate_pod_name() {
    kubectl get pods --namespace "${KUBECF_NAMESPACE}" --output name 2> /dev/null | \
        grep "rotate-cc-database-key"
}

rotate_pod_exists() {
    kubectl get pods --namespace "${KUBECF_NAMESPACE}" --output name 2> /dev/null | \
        grep --quiet "rotate-cc-database-key"
}

# Wait for rotation errand to start.
wait_for_rotate_pod_to_start() {
  local timeout="300"
  until rotate_pod_exists || [[ "$timeout" == "0" ]]
  do
      sleep 1; timeout=$((timeout - 1))
  done
  if [[ "${timeout}" == 0 ]]; then return 1; fi

  pod_name="$(rotate_pod_name)"
  echo "$(green "Pod handling the job"): $(blue "${pod_name}")"

  until [[ "$(kubectl get "${pod_name}" \
                      --namespace "${KUBECF_NAMESPACE}" \
                      --output jsonpath='{.status.containerStatuses[?(@.name == "rotate-cc-database-key-rotate")].state.running}' \
                      2> /dev/null)" != "" ]] || [[ "$timeout" == "0" ]]
  do
      sleep 1; timeout=$((timeout - 1))
  done

  if [[ "${timeout}" == 0 ]]; then
      # shellcheck disable=SC2005
      echo "$(red "Pod handling the job failed to become ready")"
      return 1;
  fi

  # shellcheck disable=SC2005
  echo "$(blue "Pod handling the job now running")"
  return 0
}

# Wait for rotation errand to start.
wait_for_rotate_pod_to_end() {
    pod_name="$(rotate_pod_name)"
    jsonpath='{.status.containerStatuses[?(@.name == "rotate-cc-database-key-rotate")].state.terminated.exitCode}'
    while true ; do
	echo -n .
	exit_code="$(kubectl get "${pod_name}" --namespace "${KUBECF_NAMESPACE}" --output "jsonpath=${jsonpath}")"
	if [[ -n "${exit_code}" ]]; then
            echo " $(blue "Completed")"
            echo Terminating job
            kubectl delete --namespace "${KUBECF_NAMESPACE}" "$(rotate_job_name)"
	    # shellcheck disable=SC2005
	    echo "$(green "OK")"
            exit "${exit_code}"
	fi
	sleep 1
    done
}

show_jobs() {
    kubectl get jobs \
	    --namespace "${KUBECF_NAMESPACE}" \
	    2> /dev/null \
	| grep -v NAME | sed -e "s|^|$(date): |"
}

ig_job_name() {
    kubectl get jobs \
	    --namespace "${KUBECF_NAMESPACE}" \
	    --output name \
	    2> /dev/null \
	| grep "ig-"
}

ig_job_exists() {
    kubectl get jobs \
	    --namespace "${KUBECF_NAMESPACE}" \
	    --output name \
	    2> /dev/null \
	| grep --quiet "ig-"
}

wait_for_ig_job() {
    # Waiting twice. For the job to be created/appear, and for it to
    # complete/disappear again. After that we assume that the BDPL
    # has settled and reconfigured to contain our changes.

    # FUTURE: See if there is a more direct way of determining this,
    # like a deployment state ?!
    # Complaint wrong. The echo generates a traling newline the `blue` doesn't.
    # shellcheck disable=SC2005
    echo "$(blue "Waiting for the ig job to start...")"

    local timeout="360"
    until ig_job_exists || [[ "$timeout" == "0" ]]
    do show_jobs; sleep 1; timeout=$((timeout - 1))
    done
    if [[ "${timeout}" == 0 ]]; then
	# shellcheck disable=SC2005
	>&2 echo "$(red "Timed out waiting for the ig job to be created")"
	return 1
    fi

    job_name="$(ig_job_name)"
    echo "$(green "Job exists"):  $(blue "${job_name}")"

    # shellcheck disable=SC2005
    echo "$(blue "Waiting for the ig job to complete...")"

    local timeout="360"
    while ig_job_exists && [[ "$timeout" -gt 0 ]]
    do show_jobs; sleep 1; timeout=$((timeout - 1))
    done
    if [[ "${timeout}" == 0 ]]; then
	# shellcheck disable=SC2005
	>&2 echo "$(red "Timed out waiting for the ig job to complete")"
	return 1
    fi

    # shellcheck disable=SC2005
    echo "$(blue "Completed ig job, continue...")"
    return 0
}

# - -- --- ----- -------- ------------- ---------------------

# Setting up a new key label. It assumes that the deployed
# `ccdb.encryption.rotation` settings are the defaults found in file
# `deploy/helm/kubecf/values.yaml`.

cat > "${VALUES_FILE}" <<EOF
ccdb:
  encryption:
    rotation:
      key_labels:
      - encryption_key_0
      - encryption_key_1
      current_key_label: encryption_key_1
EOF

# Get the deployed chart (tarball)
bazel build "${KUBECF_CHART_TARGET}"
chart_file="${PWD}/$(get_output_file "${KUBECF_CHART_TARGET%:*}" "tgz")"

echo
echo "Chart file ... $(blue "${chart_file}")"
echo

# Upgrade deployment to the modified key labels.
helm upgrade "${KUBECF_INSTALL_NAME}" "${chart_file}" \
      --namespace "${KUBECF_NAMESPACE}" \
      --reuse-values \
      --values "${VALUES_FILE}"

echo
echo Upgraded
echo

wait_for_ig_job

echo
echo Trigger rotation ...
echo

# Trigger the actual rotation of the keys
kubectl patch qjob "${KUBECF_INSTALL_NAME}-rotate-cc-database-key" \
  --namespace "${KUBECF_NAMESPACE}" \
  --type merge \
  --patch '{"spec":{"trigger":{"strategy":"now"}}}'

wait_for_rotate_pod_to_start

echo
echo Rotation in progress ...
echo

wait_for_rotate_pod_to_end
exit
