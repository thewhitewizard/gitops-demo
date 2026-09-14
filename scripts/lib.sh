# Helpers communs — ce fichier est sourcé, pas exécuté.
#
# SÉCURITÉ : ce poste a un contexte AKS de production dans ~/.kube/config.
# Tout passe donc par un KUBECONFIG dédié au lab, et aucune commande kubectl ou
# helm ne s'exécute sans être passée par guard().
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPTS_DIR/.." && pwd)"

CLUSTER="gitops-demo"
APP_HOST="app.k3d.lab"
ARGOCD_HOST="argocd.k3d.lab"

# Versions épinglées : un lab qui se remonte à l'identique dans six mois.
ARGOCD_CHART_VERSION="9.4.3"
ROLLOUTS_CHART_VERSION="2.40.6"

export KUBECONFIG="$REPO/kubeconfig-$CLUSTER.yaml" # JAMAIS ~/.kube/config
export PATH="$HOME/.local/bin:$PATH"               # helm et le plugin rollouts en user-space

# Refuse d'exécuter quoi que ce soit si le kubeconfig ne pointe pas sur le k3d du lab.
guard() {
  local ctx srv
  ctx="$(kubectl config current-context 2>/dev/null || echo none)"
  srv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo none)"

  if printf '%s' "$srv" | grep -qi 'azmk8s.io'; then
    echo "!! ABORT : le kubeconfig pointe vers AKS ($srv)" >&2
    exit 1
  fi

  case "$ctx" in
  k3d-*) ;;
  *)
    echo "!! ABORT : contexte '$ctx' non-k3d — on ne touche pas à la prod" >&2
    exit 1
    ;;
  esac

  echo ">> Garde OK (contexte=$ctx)"
}

kc() { guard && kubectl "$@"; }
hlm() { guard && helm "$@"; }

# k3d renvoie une erreur quand on lui demande un cluster qui n'existe pas : on lit
# donc la liste complète plutôt que de se fier à son code retour.
cluster_names() { k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}'; }

cluster_exists() { cluster_names | grep -qx "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "!! '$1' est introuvable dans le PATH" >&2
    exit 1
  }
}
