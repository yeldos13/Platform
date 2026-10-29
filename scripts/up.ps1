# Brings the whole environment up from scratch. Idempotent: safe to re-run.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$ErrorActionPreference = 'Continue'  # native stderr must not abort the existence check
k3d cluster get platform *> $null
$exists = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $exists) {
    k3d cluster create --config "$root/k3d.yaml" --wait
}
kubectl config use-context k3d-platform | Out-Null
kubectl wait --for=condition=Ready node --all --timeout=120s
