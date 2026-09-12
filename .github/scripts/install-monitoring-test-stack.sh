#!/usr/bin/env bash
# Cluster-scoped bootstrap ONLY for the disposable Kind monitoring CI job.
# Never run this against an existing cluster; real acceptance requires an
# independently provisioned operator and policy-enforcing CNI.
set -euo pipefail
[[ "${CI:-}" == true && "${GITHUB_JOB:-}" == monitoring-integration ]]
test "$(kubectl config current-context)" = kind-chart-testing
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl -fsSL --retry 3 https://helm.cilium.io/cilium-1.20.1.tgz -o "$work/cilium.tgz"
test "$(sha256sum "$work/cilium.tgz" | awk '{print $1}')" = 06210eef7c23d15f7699c79e2fe3a1ec9c389024c5c5c006ea04022d322449a2
helm --kube-context kind-chart-testing install cilium "$work/cilium.tgz" \
  --namespace kube-system --set operator.replicas=1 --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false --wait --timeout 5m
kubectl --context kind-chart-testing wait nodes --all --for=condition=Ready --timeout=5m
curl -fsSL --retry 3 https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.94.0/bundle.yaml \
  -o "$work/operator-source.yaml"
test "$(sha256sum "$work/operator-source.yaml" | awk '{print $1}')" = 14948e73145f1543a675acfd32f2bfbce2a261588da949bd9f4baef214d73161
sed \
  -e 's|quay.io/prometheus-operator/prometheus-operator:v0.94.0|quay.io/prometheus-operator/prometheus-operator@sha256:cf153f64d6c38113fceb2cda7642365ea887f71edd7888f054e43e54cf177e55|g' \
  -e 's|quay.io/prometheus-operator/prometheus-config-reloader:v0.94.0|quay.io/prometheus-operator/prometheus-config-reloader@sha256:142a1f11df8dd165f00375b0b1826aecb9c9adeb05c39855893138d7c7575ff7|g' \
  "$work/operator-source.yaml" >"$work/operator.yaml"
kubectl --context kind-chart-testing apply --server-side -f "$work/operator.yaml"
kubectl --context kind-chart-testing wait --for=condition=Established --timeout=2m \
  crd/prometheuses.monitoring.coreos.com crd/servicemonitors.monitoring.coreos.com crd/prometheusrules.monitoring.coreos.com
kubectl --context kind-chart-testing rollout status deployment/prometheus-operator -n default --timeout=5m
