#!/usr/bin/env bash
# Crée le cluster k3d du lab, avec les ports 80 et 443 de l'hôte mappés sur son
# loadbalancer. Ne touche ni ~/.kube/config, ni le contexte courant.
source "$(dirname "$0")/lib.sh"

need k3d
need kubectl

if cluster_exists "$CLUSTER"; then
  echo "!! Le cluster '$CLUSTER' existe déjà. ./scripts/99-teardown.sh pour repartir de zéro." >&2
  exit 1
fi

# Le port 80 est la seule ressource vraiment partagée de la machine : autant le
# dire tout de suite plutôt que de laisser k3d échouer au milieu de sa création.
for port in 80 443; do
  if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE "[:.]$port\b"; then
    echo "!! Le port $port est déjà occupé — libère-le avant de créer le cluster." >&2
    exit 1
  fi
done

others="$(cluster_names | grep -vx "$CLUSTER" || true)"
if [ -n "$others" ]; then
  echo ">> Note : d'autres clusters k3d existent, ils ne sont pas touchés :"
  printf '     %s\n' $others
fi

echo "== Création du cluster k3d '$CLUSTER' =="
# --kubeconfig-* à false : k3d n'écrit rien dans ~/.kube/config.
# @loadbalancer : le trafic entre par le proxy k3d, qui le route vers Traefik.
env -u KUBECONFIG k3d cluster create "$CLUSTER" \
  --servers 1 --agents 1 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false \
  --wait

echo ">> Kubeconfig dédié : $KUBECONFIG"
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
chmod 600 "$KUBECONFIG"

kc get nodes -o wide

# Traefik est embarqué dans k3s et se déploie tout seul au premier démarrage.
echo "== Attente de Traefik (fourni par k3s) =="
kc -n kube-system rollout status deployment/traefik --timeout=120s

echo
echo ">> Cluster prêt. Vérification que le contexte par défaut n'a pas bougé :"
echo -n "   current-context de ~/.kube/config : "
KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null || echo "(aucun)"
