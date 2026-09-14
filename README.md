# gitops-demo — un bac à sable Kubernetes + CD avec ArgoCD

Un lab **reproductible** qui montre une chaîne de livraison complète :

> un commit mergé sur `main` arrive en production **sans que personne ne tape `kubectl apply`**.

```
   merge sur main
        │
        ▼
┌───────────────────────┐
│   GitHub Actions      │  1. go vet + go test
│   release.yml         │  2. docker build (VERSION = sha du commit)
│                       │  3. push ghcr.io/<owner>/gitops-demo:sha-abc1234
│                       │  4. kustomize edit set image → commit sur main
└──────────┬────────────┘
           │   le dépôt git est la seule source de vérité
           ▼
┌───────────────────────┐
│   ArgoCD (dans k3d)   │  voit le diff (30s) → sync automatique
└──────────┬────────────┘
           ▼
   Rollout canary ─→ Service ─→ Ingress Traefik ─→ http://app.k3d.lab
```

Tout tient dans **un seul dépôt** : le code, les manifests et la CI. Pas de dépôt
« infra » séparé à tenir synchronisé.

---

## Sommaire

- [Ce que la démo montre](#ce-que-la-démo-montre)
- [Prérequis](#prérequis)
- [Mise en route](#mise-en-route)
- [Tokens et permissions GitHub](#tokens-et-permissions-github)
- [Anatomie du dépôt](#anatomie-du-dépôt)
- [Déroulé de la démo](#déroulé-de-la-démo)
- [Dépannage](#dépannage)
- [Démontage](#démontage)
- [Annexe : revenir à un Deployment](#annexe--revenir-à-un-deployment)

---

## Ce que la démo montre

| Sujet | Ce qu'on voit |
|---|---|
| **Ingress** | Un nom de domaine, un port 80, plusieurs applications derrière — sans reverse proxy à configurer à la main. |
| **GitOps** | L'état du cluster est lisible dans l'historique git. Un `git log` répond à « qu'est-ce qui tourne, et depuis quand ». |
| **Déploiement sans downtime** | Une boucle `curl` tourne pendant le déploiement et n'affiche **que des 200**. C'est le travail conjoint des probes et de l'arrêt propre du processus. |
| **Canary** | 1 pod sur 5 passe en nouvelle version, les deux cohabitent visiblement, on promeut quand on veut. |
| **Self-heal** | Une modification faite à la main dans le cluster est annulée par ArgoCD. Git gagne, y compris contre l'opérateur. |

---

## Prérequis

Versions utilisées pour valider ce lab :

| Outil | Version testée | Rôle |
|---|---|---|
| `k3d` | v5.9.0 (k3s v1.35.5) | cluster Kubernetes dans Docker |
| `kubectl` | v1.36.1 | |
| `docker` | 29.2.1 | |
| `helm` | v4.2.2 | installation d'ArgoCD et d'Argo Rollouts |
| `kustomize` | v5.8.1 | rendu des manifests (uniquement en local, la CI l'installe elle-même) |
| `go` | 1.26 | build local, facultatif |
| `gh` | 2.45 | création du dépôt, facultatif |

Il faut aussi **les ports 80 et 443 libres** sur la machine, et un compte GitHub.

> **Sécurité.** Ce lab n'écrit **jamais** dans `~/.kube/config`. Il utilise un kubeconfig
> dédié (`kubeconfig-gitops-demo.yaml`, gitignoré), et `scripts/lib.sh` contient un
> garde-fou qui refuse d'exécuter la moindre commande si le contexte courant n'est pas
> un contexte `k3d-*` — protection contre un cluster de production présent sur le poste.

---

## Mise en route

### 1. Créer le dépôt GitHub — **public**

```bash
git init && git add -A && git commit -m "init"
gh repo create <owner>/gitops-demo --public --source=. --remote=origin --push
```

Le dépôt doit être **public** : ArgoCD y accède alors sans aucune credential git.
C'est la simplification qui rend ce lab court.

Si votre compte n'est pas `thewhitewizard`, remplacez-le partout :

```bash
grep -rl thewhitewizard . --exclude-dir=.git | xargs sed -i 's/thewhitewizard/<owner>/g'
```

### 2. Autoriser la CI à écrire

Dans **Settings → Actions → General → Workflow permissions**, cocher
**« Read and write permissions »**.

Sans cette case, le job `bump` échoue avec un `403` au moment de pousser le commit.
C'est de loin la cause n°1 d'échec au premier essai. Voir
[Tokens et permissions GitHub](#tokens-et-permissions-github).

### 3. Laisser tourner la CI une première fois

Le push initial déclenche le workflow `release`. Il publie l'image et **commit
lui-même** le vrai tag dans `deploy/overlays/dev/kustomization.yaml`.

```bash
gh run watch          # suivre le workflow
git pull              # récupérer le commit de bump écrit par le bot
```

Vérifier que `deploy/overlays/dev/kustomization.yaml` ne contient plus `newTag: dev`
mais `newTag: sha-xxxxxxx`.

### 4. Rendre l'image publique sur GHCR

Au premier push, le package GHCR est **privé par défaut** : le cluster ne pourra pas
le télécharger et les pods resteront en `ImagePullBackOff`.

**GitHub → votre profil → Packages → `gitops-demo` → Package settings →
Danger Zone → Change visibility → Public.**

(Solution de repli si le package doit rester privé :
[voir le dépannage](#imagepullbackoff).)

### 5. Créer le cluster

```bash
./scripts/01-cluster-up.sh
```

Le script crée un cluster k3d à 2 nœuds et **mappe les ports 80 et 443 de la machine
sur son loadbalancer**. Traefik est déjà embarqué dans k3s : rien à installer.

### 6. Déclarer les noms de domaine

```bash
echo "127.0.0.1 app.k3d.lab argocd.k3d.lab" | sudo tee -a /etc/hosts
```

Ces entrées survivent au démontage du cluster : à ne faire qu'une fois.

### 7. Installer ArgoCD et Argo Rollouts

```bash
./scripts/02-install-argocd.sh    # affiche le mot de passe admin à la fin
./scripts/03-install-rollouts.sh
```

ArgoCD est alors sur **http://argocd.k3d.lab** (login `admin`).

### 8. Brancher l'application

```bash
./scripts/04-bootstrap-app.sh
```

C'est **le dernier `kubectl apply` du lab**. Il déclare une `Application` ArgoCD qui
pointe sur `deploy/overlays/dev`, en sync automatique. Tout le reste passe par git.

```bash
curl -s http://app.k3d.lab
# {"app":"gitops-demo","node":"k3d-gitops-demo-agent-0","pod":"demo-6f8b...","uptime":"12s","version":"sha-abc1234"}
```

---

## Tokens et permissions GitHub

Le point qui bloque le plus souvent. Il y a **trois** autorisations distinctes, et
dans le cas nominal **aucune ne demande de créer un token**.

### 1. Publier l'image sur GHCR — aucun token à créer

`GITHUB_TOKEN` est fabriqué automatiquement pour chaque run. Le workflow lui demande
juste la bonne permission :

```yaml
permissions:
  packages: write
```

et s'en sert comme mot de passe :

```yaml
- uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

### 2. Commiter le bump sur `main` — aucun token à créer non plus

Même mécanisme, avec `contents: write`. **Mais** il faut que le dépôt l'autorise :
*Settings → Actions → General → Workflow permissions* → **Read and write permissions**.
Si l'option est restée sur *Read repository contents*, la permission demandée par le
workflow est plafonnée et le `git push` renvoie `403`.

Effet de bord utile : un push authentifié par `GITHUB_TOKEN` **ne déclenche aucun
workflow**. C'est un second rempart contre la boucle infinie décrite plus bas.

### 3. Quand un PAT devient nécessaire

Uniquement si `main` est protégée (branch protection, review obligatoire, statuts
requis) : `GITHUB_TOKEN` est alors refusé comme n'importe quel autre auteur.

Créer un **fine-grained PAT** :

- *Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token*
- **Repository access** : *Only select repositories* → ce dépôt uniquement
- **Permissions → Repository permissions → Contents : Read and write**
- **Expiration** : les fine-grained expirent obligatoirement. Notez la date — un lab
  qui marchait « avant les vacances » et plus après, c'est presque toujours ça.

Puis :

- stocker le token en secret de dépôt nommé **`GITOPS_PAT`**
  (*Settings → Secrets and variables → Actions → New repository secret*) ;
- ajouter le compte à la **bypass list** de la règle de protection de branche.

Le workflow est déjà écrit pour les deux cas :

```yaml
token: ${{ secrets.GITOPS_PAT || secrets.GITHUB_TOKEN }}
```

Le secret absent, l'expression retombe sur `GITHUB_TOKEN`. Rien à modifier.

> ⚠️ Avec un PAT, le commit de bump **redéclenche** les workflows (contrairement à
> `GITHUB_TOKEN`). Le `paths-ignore` sur `deploy/**` devient alors le seul rempart
> contre la boucle infinie — il est déjà en place, ne le retirez pas.

### 4. ArgoCD et le dépôt git — aucun token

Le dépôt est public : ArgoCD clone en HTTPS anonyme. C'est tout l'intérêt du choix
« public » pour un lab. Sur un dépôt privé il faudrait en plus déclarer un
`Repository` dans ArgoCD avec un PAT `Contents: Read`.

### Récapitulatif

| Ce qu'on veut faire | Token | Condition |
|---|---|---|
| Pousser sur GHCR | `GITHUB_TOKEN` | `permissions: packages: write` |
| Commiter le bump | `GITHUB_TOKEN` | *Workflow permissions* = Read **and write** |
| Commiter le bump sur une branche protégée | **PAT fine-grained** `GITOPS_PAT` | Contents: RW + bypass list |
| ArgoCD lit le dépôt | aucun | dépôt public |
| Le cluster tire l'image | aucun | package GHCR public |

---

## Anatomie du dépôt

```
main.go                              service Gin, ~130 lignes
Dockerfile                           multi-stage → distroless nonroot
.github/workflows/ci.yml             sur PR : vet + test + build, sans push
.github/workflows/release.yml        sur main : build, push GHCR, bump du manifest
deploy/base/                         Rollout + Service + Ingress
deploy/overlays/dev/                 namespace + tag d'image ← écrit par la CI
argocd/application.yaml              l'Application ArgoCD
scripts/                             création du cluster, installs, bootstrap, teardown
```

### Le service Go

Trois routes, et une seule raison d'exister : rendre visible ce que fait Kubernetes.

| Route | Rôle |
|---|---|
| `GET /` | renvoie `version` (le SHA du commit, injecté au build) et `pod`. C'est ce qui rend le canary lisible dans une boucle `curl`. |
| `GET /healthz` | **liveness** — « le processus est-il vivant ». Reste verte pendant l'arrêt. |
| `GET /readyz` | **readiness** — « puis-je recevoir du trafic ». Passe en 503 dès le `SIGTERM`. |

**L'arrêt propre**, qui est ce qui fait qu'un déploiement ne coupe aucune connexion :

1. Kubernetes envoie `SIGTERM` et, *en parallèle*, retire le pod des endpoints.
2. Le processus met immédiatement `/readyz` en 503 — mais **continue de servir**.
3. Il attend `DRAIN_DELAY` (5s) : le temps que Traefik et kube-proxy aient réellement
   pris en compte la suppression. **C'est cette attente qui supprime les 502**, pas
   `Shutdown()`. Sans elle, le serveur fermerait alors qu'on lui envoie encore du trafic.
4. Puis `srv.Shutdown()` avec 15s pour laisser finir les requêtes en vol.

Le manifest accorde `terminationGracePeriodSeconds: 30`, soit plus que 5 + 15.

> Piège associé, côté image : l'`ENTRYPOINT` du Dockerfile est en **forme exec**
> (`ENTRYPOINT ["/app"]`). En forme shell, le binaire tournerait sous `/bin/sh`, qui
> ne relaierait pas le `SIGTERM` : tout ce mécanisme ne se déclencherait jamais et
> chaque déploiement couperait des connexions.

### La boucle infinie (et comment on l'évite)

La CI commit sur `main`. Ce commit déclencherait la CI, qui commiterait, etc.
Deux protections indépendantes :

```yaml
on:
  push:
    branches: [main]
    paths-ignore: ["deploy/**", "**.md"]   # le bump ne touche que deploy/
```

et, par construction, un push signé `GITHUB_TOKEN` ne déclenche pas de workflow.
La seconde saute dès qu'on passe à un PAT : la première reste indispensable.

### Pourquoi le tag est un SHA

`:latest` est un tag mobile : le cluster ne peut pas dire *quelle* version il fait
tourner, et un redémarrage de pod peut changer de code sans qu'aucun commit n'ait eu
lieu. Le tag `sha-abc1234` est immuable et remonte au commit exact.
`:latest` est publié quand même, mais uniquement pour le confort d'un `docker pull` à la main.

---

## Déroulé de la démo

**Terminal 1** — la preuve que rien ne casse :

```bash
while true; do curl -s http://app.k3d.lab | jq -r '"\(.version)  \(.pod)"'; sleep 0.3; done
```

**Terminal 2** — l'état du déploiement :

```bash
kubectl argo rollouts get rollout demo -n demo --watch
```

Puis, à l'écran :

1. **Montrer l'état initial.** Le terminal 1 affiche une seule version, répartie sur
   5 pods différents. Premier point : le Service équilibre la charge tout seul.
2. **Modifier le code.** Changer le champ `"app"` dans `handleRoot` (`main.go`).
   Ouvrir une PR → la CI teste et construit sans rien publier → merger.
3. **Suivre GitHub Actions.** Le workflow `release` publie
   `ghcr.io/<owner>/gitops-demo:sha-xxxxxxx`, puis **commit lui-même** le nouveau tag.
   Montrer ce commit dans l'historique : *« voilà le déploiement, c'est une ligne de git »*.
4. **Basculer sur ArgoCD** (http://argocd.k3d.lab). L'application passe `OutOfSync`
   puis se synchronise seule. Personne n'a rien déployé.
5. **Le canary.** Le terminal 2 montre 1 pod sur 5 en nouvelle version ; le terminal 1
   montre **les deux versions qui alternent**, et **aucune erreur**. Le Rollout est
   en pause : il attend une décision humaine.
6. **Promouvoir.**
   ```bash
   kubectl argo rollouts promote demo -n demo
   ```
   Montée à 60 %, puis 100 %. La boucle curl n'a toujours affiché que des 200.
7. **Le self-heal** (facultatif, très parlant) :
   ```bash
   kubectl -n demo scale rollout/demo --replicas=1
   ```
   ArgoCD détecte l'écart et remet 5 répliques en quelques secondes.
   *« Le cluster n'est pas ce qu'on y a tapé, c'est ce qui est écrit dans git. »*
8. **Le rollback**, s'il reste du temps : `git revert` du commit de bump, push.
   Le rollback n'est pas une commande magique, c'est de l'historique.

**Conclusion :** on n'a jamais tapé `kubectl apply`, et l'état complet du cluster se
relit dans `git log`.

---

## Dépannage

### ImagePullBackOff

Le package GHCR est privé. Vérifier :

```bash
kubectl -n demo describe pod -l app=demo | grep -A3 Events
```

Correctif normal : rendre le package public (voir [étape 4](#4-rendre-limage-publique-sur-ghcr)).

S'il doit rester privé, créer un PAT **classique** avec le scope `read:packages` puis :

```bash
kubectl -n demo create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=<owner> --docker-password=<PAT>
```

et ajouter `imagePullSecrets: [{name: ghcr}]` dans `deploy/base/rollout.yaml`
(sous `spec.template.spec`).

### 404 page not found sur http://app.k3d.lab

Traefik ne connaît pas cet hôte. Dans l'ordre :

```bash
getent hosts app.k3d.lab                  # l'entrée /etc/hosts existe-t-elle ?
kubectl -n demo get ingress               # l'Ingress est-il créé ?
kubectl -n kube-system logs deploy/traefik | tail
```

Attention aussi à `curl http://app.k3d.lab` **sans port** : le routage ne marche que
si le cluster a bien été créé avec `--port 80:80@loadbalancer`.

### `403` au push du job `bump`

*Settings → Actions → General → Workflow permissions* n'est pas sur **Read and write**.
Si `main` est protégée, il faut en plus un PAT — voir
[Tokens et permissions GitHub](#3-quand-un-pat-devient-nécessaire).

### La CI boucle

Le `paths-ignore` a été retiré du `release.yml`, ou le bump touche un fichier hors
de `deploy/`. Annuler les runs en cours (`gh run cancel`) et rétablir le `paths-ignore`.

### ArgoCD reste `OutOfSync`

```bash
kubectl -n argocd logs deploy/argocd-repo-server | tail -30
```

Souvent : `kustomize build` échoue côté ArgoCD. Reproduire en local avec
`kustomize build deploy/overlays/dev` — l'erreur y est identique et plus lisible.

### Le Rollout ne progresse pas

Normal s'il est à l'étape `pause: {}` : il attend
`kubectl argo rollouts promote demo -n demo`. Sinon :

```bash
kubectl argo rollouts get rollout demo -n demo
kubectl -n argo-rollouts logs deploy/argo-rollouts | tail
```

### Le port 80 est déjà pris

```bash
sudo ss -ltnp | grep ':80'
```

Souvent Apache, nginx ou un autre cluster k3d. Sinon, changer le mapping dans
`scripts/01-cluster-up.sh` (`--port "8080:80@loadbalancer"`) et utiliser
`http://app.k3d.lab:8080`.

---

## Démontage

```bash
./scripts/99-teardown.sh
```

Supprime le cluster et son kubeconfig. Les entrées `/etc/hosts` restent ; pour les
retirer : `sudo sed -i '/k3d.lab/d' /etc/hosts`.

---

## Annexe : revenir à un Deployment

Si Argo Rollouts pose problème, ou pour une démo plus courte, le canary se remplace
par un rolling update standard. Créer `deploy/base/deployment.yaml` en reprenant
`rollout.yaml` avec :

```yaml
apiVersion: apps/v1
kind: Deployment
# ... même spec.template, sans le bloc strategy.canary :
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0    # aucun pod retiré avant qu'un nouveau ne soit prêt
      maxSurge: 1
```

puis remplacer `rollout.yaml` par `deployment.yaml` dans
`deploy/base/kustomization.yaml`. Le reste de la chaîne — CI, tag SHA, ArgoCD,
Ingress, arrêt propre — est inchangé, et la démo « zéro downtime » fonctionne à
l'identique. Seule l'étape de promotion manuelle disparaît.
