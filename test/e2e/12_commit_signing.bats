#!/usr/bin/env bats

load lib/defer
load lib/env
load lib/gpg
load lib/install
load lib/poll

function setup() {
  setup_env
  kubectl create namespace "${FLUX_NAMESPACE}"

  generate_ssh_secret
  install_git_srv

  gnupghome=$(tmp_gnupghome)
  defer rm -rfv "$gnupghome"

  gpg_key=$(create_gpg_key)
  create_secret_from_gpg_key "$gpg_key"
  install_flux_gpg "$gpg_key"
}

@test "Git sync tag is signed" {
  # Test that a resource from https://github.com/fluxcd/flux-get-started is deployed
  # This means the Flux instance _should_ have pushed a signed high-watermark tag
  poll_until_true 'namespace demo' 'kubectl describe ns/demo'

  # Test that the tag has been signed, this errors if this isn't the case
  pod=$(kubectl --namespace "${FLUX_NAMESPACE}" get pods --no-headers -l app=flux -o custom-columns=":metadata.name" | tail -n 1)
  kubectl --namespace "${FLUX_NAMESPACE}" exec -it "$pod" \
    -- sh -c "cd /tmp/flux-gitclone* && git verify-tag flux-sync" >&3
}

@test "Git commits are signed" {
  # Assure the resource we are going to lock is deployed
  poll_until_true 'workload podinfo' 'kubectl -n demo describe deployment/podinfo'

  # Let Flux push a commit
  fluxctl --k8s-fwd-ns "${FLUX_NAMESPACE}" lock --workload demo:deployment/podinfo >&3

  # Sync right away, this will assure the clone we will look at next is up-to-date
  fluxctl --k8s-fwd-ns "${FLUX_NAMESPACE}" sync >&3

  # Test that the commit has been signed
  pod=$(kubectl --namespace "${FLUX_NAMESPACE}" get pods --no-headers -l app=flux -o custom-columns=":metadata.name" | tail -n 1)
  kubectl --namespace "${FLUX_NAMESPACE}" exec -it "$pod" \
    -- sh -c "working=\$(mktemp -d) && \
        git clone --branch master /tmp/flux-gitclone* \$working && \
        cd \$working && \
        git verify-commit HEAD" >&3
}

function teardown() {
  # For debugging purposes (in case the test fails)
  echo '>>> Flux logs'
  kubectl -n "${FLUX_NAMESPACE}" describe deployment/flux-gpg
  kubectl -n "${FLUX_NAMESPACE}" logs deployment/flux-gpg

  kubectl delete namespace "${DEMO_NAMESPACE}"
  # This also takes care of removing the generated secret,
  # and the deployed Flux instance
  kubectl delete namespace "${FLUX_NAMESPACE}"
}
