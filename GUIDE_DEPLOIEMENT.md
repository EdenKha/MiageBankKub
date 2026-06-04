# Guide de Déploiement — MIAGE-Bank

> Ce guide vous permet de déployer MIAGE-Bank de A à Z sur votre poste, de vérifier la pipeline CI/CD, et de tester l'ensemble de l'architecture.  
> **Dépôt GitHub** : [https://github.com/EdenKha/MiageBankKub](https://github.com/EdenKha/MiageBankKub)

## Table des matières

- [Pré-requis](#pré-requis)
- [Partie A — Vérifier la pipeline CI/CD](#partie-a--vérifier-la-pipeline-cicd)
- [Partie B — Déploiement Kubernetes](#partie-b--déploiement-kubernetes)
  - [Étape 1 — Démarrer le cluster](#étape-1--démarrer-le-cluster-kubernetes)
  - [Étape 2 — Construire les images](#étape-2--construire-les-images-localement)
  - [Étape 3 — Configurer Vault et ESO](#étape-3--configurer-vault-et-external-secrets-operator)
  - [Étape 4 — Valider le Chart Helm](#étape-4--valider-le-chart-helm)
  - [Étape 5 — Déployer avec ArgoCD](#étape-5--déployer-avec-argocd-gitops)
  - [Étape 6 — Vérifier et tester les services](#étape-6--vérifier-et-tester-les-services)
  - [Étape 7 — Démonstration de la dérive ArgoCD](#étape-7--démonstration-de-la-dérive-argocd)
  - [Étape 8 — Nettoyage complet](#étape-8--nettoyage-complet)

---

## Pré-requis

### Outils à installer

| Outil | Version recommandée | Vérification |
|-------|-------|-------------|
| **Docker Desktop** ou **Minikube** | Dernière version stable | `docker version` / `minikube version` |
| **kubectl** | Compatible avec votre cluster | `kubectl version --client` |
| **Helm** | v3.x | `helm version` |
| **Git** | Dernière version | `git --version` |

> **Note DevOps** : La compilation Java est conteneurisée via un conteneur Maven éphémère — aucune installation locale de Java ou Maven n'est requise.

### Cloner le dépôt

```bash
git clone https://github.com/EdenKha/MiageBankKub.git
cd MiageBankKub
```

---

## Partie A — Vérifier la pipeline CI/CD

La pipeline de build (Buildah, Trivy, Dive) s'exécute automatiquement via GitHub Actions à chaque commit sur `main`.

### Comment vérifier

1. Rendez-vous sur le dépôt GitHub : [https://github.com/EdenKha/MiageBankKub](https://github.com/EdenKha/MiageBankKub)
2. Allez dans l'onglet **Actions**
3. Cliquez sur le dernier run du workflow **"CI Pipeline MIAGE-Bank"**
4. Vérifiez que les étapes suivantes sont au vert (✅) :
   - **Build with Maven** — Compilation du JAR
   - **Run Hadolint** — Lint du Containerfile
   - **Build image with Buildah** — Construction de l'image OCI
   - **Run Trivy vulnerability scanner (SARIF)** — Scan de sécurité (format SARIF)
   - **Run Trivy vulnerability scanner (JSON)** — Scan de sécurité (format JSON)
   - **Run Dive audit** — Audit des layers avec seuils d'efficacité
5. Les rapports complets sont téléchargeables via les **artefacts** du run, ou consultables dans le dossier `build-reports/` du code source :
   - `trivy-results.sarif` — Rapport Trivy format SARIF
   - `trivy-results.json` — Rapport Trivy format JSON
   - `dive-report.json` — Rapport Dive

---

## Partie B — Déploiement Kubernetes

### Étape 1 — Démarrer le cluster Kubernetes

Choisissez votre environnement :

#### Option A : Minikube (recommandé)

```bash
minikube start --memory=4096 --cpus=2
```

#### Option B : Docker Desktop

1. Ouvrez Docker Desktop → **Settings** → **Kubernetes** → **Enable Kubernetes**
2. Attendez que le cluster soit opérationnel (icône verte)

#### Vérifier la connexion au cluster

```bash
kubectl cluster-info
kubectl get nodes
```

> ⚠️ **Ingress Controller** : Ce projet utilise la classe Ingress `traefik`. Selon votre environnement :
>
> - **k3d** : Traefik est installé par défaut, rien à faire.
> - **Minikube** : Traefik n'est pas inclus par défaut. Vous pouvez soit installer Traefik via Helm, soit activer l'addon Nginx (`minikube addons enable ingress`) et modifier `ingress.className` dans `values.yaml`.
> - **Docker Desktop** : Activez Kubernetes dans les settings, puis installez Traefik via Helm.

---

### Étape 2 — Construire les images localement

Les images des microservices doivent être disponibles dans l'environnement Kubernetes.

#### Pour Minikube

```bash
# Pointer le client Docker vers le daemon de Minikube
eval $(minikube docker-env)
```

> ⚠️ Cette commande doit être exécutée dans **chaque** terminal où vous allez builder des images. Elle est temporaire et s'applique uniquement au terminal courant.

#### Pour Docker Desktop

Rien de spécial — les images buildées localement sont automatiquement disponibles pour le cluster K8s intégré.

#### Construire toutes les images

```bash
./build-all-images.sh
```

Ce script :

1. Compile tous les JARs via un conteneur Maven éphémère (aucune installation locale requise)
2. Construit les images Docker de chaque microservice (Annuaire, ConfigServer, ClientService, CompteService, CompositeService, APIGateway)

#### Vérification

```bash
docker images | grep banque
```

Vous devriez voir 6 images (`banque-annuaire`, `banque-configsrv`, `banque-clientservice`, `banque-compteservice`, `banque-compositeservice`, `banque-apigateway`), toutes taggées `7.0`.

---

### Étape 3 — Configurer Vault et External Secrets Operator

L'application utilise Hashicorp Vault + ESO pour sécuriser les identifiants de base de données. Cette étape est **obligatoire** avant le déploiement.

#### 3.1 Installer Vault (mode développement)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  -n default
```

Attendre que le pod soit prêt :

```bash
kubectl wait --for=condition=Ready pod/vault-0 -n default --timeout=120s
```

#### 3.2 Installer External Secrets Operator (ESO)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true
```

#### 3.3 Injecter les identifiants dans Vault

```bash
# Injecter les credentials MySQL
kubectl exec -it vault-0 -n default -- vault kv put secret/miage-bank/db \
  username="dummy-user" \
  password="dummy-password" \
  rootPassword="root"

# Injecter les credentials MongoDB
kubectl exec -it vault-0 -n default -- vault kv put secret/miage-bank/mongo \
  username="root" \
  password="root" \
  uri="mongodb://root:root@bnkmongo:27017/banquebd?authSource=admin"
```

#### 3.4 Préparer le namespace et le token Vault

```bash
kubectl create namespace miage-bank
kubectl create secret generic vault-token \
  --from-literal=token=root \
  -n miage-bank
```

---

### Étape 4 — Valider le Chart Helm

Avant de déployer, validez la syntaxe et le rendu du Chart :

```bash
# Vérifier la syntaxe (pas d'erreurs ni de warnings)
helm lint ./miage-bank

# Prévisualiser les manifestes Kubernetes qui seront générés
helm template miage-bank-release ./miage-bank -n miage-bank

# Simulation d'installation (dry-run)
helm install miage-bank-release ./miage-bank -n miage-bank --dry-run
```

> Si `helm lint` retourne des erreurs, corrigez-les avant de continuer. Les warnings ne sont généralement pas bloquants.

---

### Étape 5 — Déployer avec ArgoCD (GitOps)

> ⚠️ **Étape cruciale** : ArgoCD lit la configuration directement depuis GitHub. Assurez-vous que vos dernières modifications locales sont poussées sur le dépôt distant **avant** de continuer :
>
> ```bash
> git add -A
> git commit -m "Mise à jour du Chart Helm"
> git push origin main
> ```

#### 5.1 Installer ArgoCD

> Les définitions de ressources d'ArgoCD (CRDs) sont volumineuses. Une commande `kubectl apply` standard échouera sous Windows en raison d'une limite de taille d'annotation (`Too long: may not be more than 262144 bytes`). Utilisez **obligatoirement** l'option `--server-side`.

```bash
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Attendre que tous les pods ArgoCD soient opérationnels :

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

#### 5.2 Appliquer la configuration ArgoCD

Le fichier `argocd-app.yaml` est préconfiguré pour pointer vers le dépôt GitHub et le dossier `miage-bank/` :

```bash
kubectl apply -f argocd-app.yaml
```

#### 5.3 (Optionnel) Accéder à l'interface Web ArgoCD

```bash
# Dans un terminal séparé — laisser tourner
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Récupérer le mot de passe admin :

**Linux / macOS / Git Bash :**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

**PowerShell (Windows) :**

```powershell
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}")))
```

Puis ouvrez [https://localhost:8080](https://localhost:8080) dans votre navigateur (acceptez l'avertissement de sécurité) et connectez-vous avec :

- **Login** : `admin`
- **Mot de passe** : celui récupéré ci-dessus

---

### Étape 6 — Vérifier et tester les services

#### 6.1 Surveiller le démarrage des pods

```bash
kubectl get pods -n miage-bank -w
```

Le démarrage complet prend environ **1 à 2 minutes**. L'ordre de démarrage est :

1. 🗄️ Bases de données (MySQL, MongoDB)
2. ⚙️ ConfigServer
3. 📋 Annuaire (Eureka)
4. 🔧 Microservices métier (ClientService, CompteService, CompositeService)
5. 🌐 API Gateway

#### 6.2 Accéder à l'API Gateway

L'API Gateway centralise les appels vers tous les microservices :

```bash
kubectl port-forward svc/bnkapigateway 10000:10000 -n miage-bank
```

> En cas d'erreur `address already in use`, utilisez un port local différent :
>
> ```bash
> kubectl port-forward svc/bnkapigateway 10002:10000 -n miage-bank
> ```

#### 6.3 Tester les APIs

Une fois tous les pods au statut `Running`, testez sur `http://localhost:10000` avec Postman, cURL ou PowerShell :

**A. ClientService — `/api/clients`**

```bash
# Créer un client (POST)
curl -X POST http://localhost:10000/api/clients \
  -H "Content-Type: application/json" \
  -d '{"id": 1, "nom": "Dupont", "prenom": "Jean"}'

# Lister les clients (GET)
curl http://localhost:10000/api/clients
```

**B. CompteService — `/api/comptes`**

```bash
# Consulter les comptes (GET)
curl http://localhost:10000/api/comptes
```

**C. CompositeService — `/api/clientscomptes`**

```bash
# Synthèse client + comptes (GET) — remplacez 1 par l'id du client
curl http://localhost:10000/api/clientscomptes/1
```

#### 6.4 (Bonus) Visualiser le tableau de bord Eureka

Pour voir l'enregistrement dynamique des microservices, dans un autre terminal :

```bash
kubectl port-forward svc/bnkannuaire 10001:10001 -n miage-bank
```

Ouvrez [http://localhost:10001](http://localhost:10001) dans votre navigateur.

---

### Étape 7 — Démonstration de la dérive ArgoCD

Ce test prouve que le GitOps fonctionne : toute modification manuelle du cluster est automatiquement corrigée par ArgoCD.

1. **Vérifier l'état initial** — 1 seul pod doit être en cours d'exécution :

   ```bash
   kubectl get pods -n miage-bank
   ```

2. **Provoquer une dérive** — augmenter artificiellement les réplicas :

   ```bash
   kubectl scale deployment miage-bank --replicas=5 -n miage-bank
   ```

3. **Observer la détection** — dans l'interface ArgoCD, l'application passe en statut **OutOfSync** (dérive détectée).

4. **Observer la réconciliation automatique** — grâce à `selfHeal: true`, ArgoCD supprime automatiquement les 4 pods en trop et restaure le nombre défini dans Git (1 réplica). Le statut repasse en **Synced**.

   ```bash
   # Vérifier après quelques secondes
   kubectl get pods -n miage-bank
   # → 1 seul pod, comme défini dans Git
   ```

> Le temps de réconciliation est généralement de **15 à 30 secondes**.

---

### Étape 8 — Nettoyage complet

Pour détruire proprement toute la stack et libérer les ressources :

#### 1. Arrêter les port-forwards

Dans chaque terminal où tourne un `kubectl port-forward`, appuyez sur `Ctrl + C`.

#### 2. Supprimer l'application ArgoCD

```bash
kubectl delete application miage-bank -n argocd
```

#### 3. (Optionnel) Désinstaller les outils d'infrastructure

```bash
# Désinstaller ArgoCD
kubectl delete namespace argocd

# Désinstaller External Secrets Operator
helm uninstall external-secrets -n external-secrets
kubectl delete namespace external-secrets

# Désinstaller Vault
helm uninstall vault -n default

# Supprimer le namespace métier
kubectl delete namespace miage-bank
```

#### 4. Arrêter le cluster

```bash
# Minikube — arrêt simple
minikube stop

# Ou suppression complète du cluster Minikube
minikube delete
```
