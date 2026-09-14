#!/usr/bin/env bash
# Déclare l'application auprès d'ArgoCD. C'est le dernier kubectl apply du lab :
# tout ce qui suit passe par git.
#
# À n'exécuter qu'APRÈS un premier run réussi de la CI : c'est elle qui publie
# l'image et écrit son tag dans deploy/overlays/dev. Bootstrapper avant laisserait
# ArgoCD déployer un tag inexistant, et les pods tourneraient en ImagePullBackOff.
source "$(dirname "$0")/lib.sh"

guard

tag="$(awk '/newTag:/ {print $2}' "$REPO/deploy/overlays/dev/kustomization.yaml")"
if [ "$tag" = "dev" ]; then
  echo "!! L'overlay pointe encore sur le tag 'dev' (placeholder)." >&2
  echo "   Pousse sur main, attends la fin du workflow 'release', fais un git pull," >&2
  echo "   puis relance ce script." >&2
  exit 1
fi
echo ">> L'overlay déploiera l'image taguée '$tag'."

kubectl apply -f "$REPO/argocd/application.yaml"

echo "== Attente du premier sync =="
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/demo --timeout=180s

kubectl -n demo get rollout,pod,ingress
echo
echo ">> Application disponible sur http://$APP_HOST"
