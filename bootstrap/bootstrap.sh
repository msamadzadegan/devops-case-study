#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="devops-cs"
REGISTRY="ghcr.io/voize-gmbh/devops-case-study"
LOCAL_IMAGES=false
NAMESPACE_LIST=("postgres" "ml-api" "backend-api")

echo "=== DevOps Case Study - Cluster Bootstrap ==="

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      LOCAL_IMAGES=true
      shift
      ;;
    -*)
      echo "Unknown flag: $1"
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# --- Parse positional arguments ---
GITHUB_REPO="${1:-}"
GITHUB_BRANCH="${2:-main}"

if [ -z "$GITHUB_REPO" ]; then
  echo ""
  echo "Usage: ./bootstrap.sh [--local] <github-repo-url> [branch]"
  echo "  Example: ./bootstrap.sh https://github.com/youruser/devops-case-study main"
  echo ""
  echo "  --local  Import images from local Docker instead of pulling from registry"
  echo ""
  echo "The repo URL should be your fork of this repository."
  echo "Requires GITHUB_TOKEN env var with repo scope."
  exit 1
fi

# --- Extract owner and repo from URL ---
# Supports https://github.com/owner/repo and https://github.com/owner/repo.git
GITHUB_OWNER=$(echo "$GITHUB_REPO" | sed -E 's|https?://github.com/([^/]+)/.*|\1|')
GITHUB_REPO_NAME=$(echo "$GITHUB_REPO" | sed -E 's|https?://github.com/[^/]+/([^/.]+).*|\1|')

if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO_NAME" ]; then
  echo "ERROR: Could not parse GitHub owner/repo from URL: $GITHUB_REPO"
  exit 1
fi

# --- Prerequisites check ---
for cmd in k3d kubectl flux; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed."
    exit 1
  fi
done

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN env var is required for flux bootstrap."
  echo "  Create a token at https://github.com/settings/tokens with 'repo' scope."
  echo "  Then: export GITHUB_TOKEN=<your-token>"
  exit 1
fi

# --- Create k3d cluster ---
echo ""
echo "--- Creating k3d cluster '$CLUSTER_NAME' ---"
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists. Deleting..."
  k3d cluster delete "$CLUSTER_NAME"
fi

k3d cluster create --config "$SCRIPT_DIR/k3d.config.yaml"

echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# --- Import local images if --local flag is set ---
if [ "$LOCAL_IMAGES" = true ]; then
  echo ""
  echo "--- Importing images from local Docker into k3d ---"
  k3d image import \
    "$REGISTRY/ml-api:v1" \
    "$REGISTRY/backend-api:v1" \
    "$REGISTRY/load-generator:v1" \
    -c "$CLUSTER_NAME"
fi

# --- Bootstrap Flux ---
echo ""
echo "--- Bootstrapping Flux CD ($GITHUB_OWNER/$GITHUB_REPO_NAME, branch: $GITHUB_BRANCH) ---"
flux bootstrap github \
  --owner="$GITHUB_OWNER" \
  --repository="$GITHUB_REPO_NAME" \
  --branch="$GITHUB_BRANCH" \
  --path="clusters/devops-cs" \
  --personal

# --- Wait for workloads ---
echo ""

echo "Waiting for all target namespaces to be created..."
for ns in "${NAMESPACE_LIST[@]}"; do
  until kubectl get namespace "$ns" &>/dev/null; do
    echo "Waiting for namespace '$ns' ..."
    sleep 5
  done
  kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/"$ns" --timeout=60s
done

echo "--- Waiting for workloads to be deployed ---"
kubectl wait --for=condition=Available deployment/postgres -n postgres --timeout=180s
kubectl wait --for=condition=Available deployment/ml-api -n ml-api --timeout=180s
kubectl wait --for=condition=Available deployment/backend-api -n backend-api --timeout=180s

echo ""
echo "=== Bootstrap complete! ==="
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Flux source: $GITHUB_OWNER/$GITHUB_REPO_NAME ($GITHUB_BRANCH)"
echo ""
echo "Verify everything is running:"
echo "  kubectl get pods -A"
echo "  flux get all"
echo ""
echo "Services:"
echo "  ML API:      kubectl port-forward -n ml-api svc/ml-api 8001:8000"
echo "  Backend API: kubectl port-forward -n backend-api svc/backend-api 8002:8000"
echo "  PostgreSQL:  kubectl port-forward -n postgres svc/postgres 5432:5432"
