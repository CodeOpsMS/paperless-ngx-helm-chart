#!/usr/bin/env bash
# Sourced by paperless-e2e.sh and its monitoring helper.

start_kube_port_forward() {
  local pid_variable=$1 log=$2 pid attempt
  shift 2
  local kube_command=("$KUBECTL_BIN")
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kube_command+=(--context "$KUBE_CONTEXT")
  fi
  if [[ "${KUBE_INSECURE_SKIP_TLS_VERIFY:-false}" == true ]]; then
    kube_command+=(--insecure-skip-tls-verify=true)
  fi

  # Launch the executable directly: backgrounding kube() tracks a Bash wrapper
  # whose termination can leave kubectl alive and the local port occupied.
  "${kube_command[@]}" port-forward --address=127.0.0.1 "$@" \
    >"$log" 2>&1 &
  pid=$!
  printf -v "$pid_variable" '%s' "$pid"
  for attempt in $(seq 1 60); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      cat "$log" >&2
      return 1
    fi
    # Wait for this process to bind before probing HTTP. An unrelated listener
    # must not make a failed port-forward appear healthy.
    if grep -q '^Forwarding from 127.0.0.1:' "$log"; then
      return 0
    fi
    sleep 1
  done
  echo "kubectl port-forward did not open its listener" >&2
  cat "$log" >&2
  return 1
}

stop_kube_port_forward() {
  local pid=${1:-}
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}
