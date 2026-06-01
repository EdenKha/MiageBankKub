# 📘 Guide de Déploiement Complet : MIAGE-Bank (Kubernetes & GitOps)

Ce guide détaille pas à pas l'installation, la compilation, la sécurisation et le déploiement de l'application **MIAGE-Bank** sur un cluster Kubernetes local (Minikube). 

> [!IMPORTANT]
> Ce projet utilise une architecture **DevOps moderne (GitOps et conteneurisation)** :
> 1. **Aucune installation locale** de Java, Maven ou Node n'est requise. Toute la compilation s'effectue dans des conteneurs éphémères.
> 2. **Déploiement GitOps** via ArgoCD : toute modification de la configuration Kubernetes doit être poussée sur GitHub pour être synchronisée automatiquement.

---

## 🗺️ 1. Architecture du Système

Voici comment les différents composants de la stack MIAGE-Bank interagissent au sein du cluster Kubernetes :

```mermaid
graph TD
    User([Utilisateur / Testeur]) -->|localhost:10000| Gateway[bnkapigateway (API Gateway)]
    
    subgraph Cluster Kubernetes (Minikube)
        subgraph Core Stack (miage-bank namespace)
            Gateway -->|Routage| Composite[bnkcompositeservice]
            Composite -->|Synthèse| Client[bnkclientservice]
            Composite -->|Synthèse| Compte[bnkcompteservice]
            
            Client -->|MongoDB| Mongo[(MongoDB)]
            Compte -->|MongoDB| MongoCompte[(MongoDB Compte)]
            
            %% Enregistrement Eureka
            Client -.->|Enregistrement| Annuaire[bnkannuaire (Eureka)]
            Compte -.->|Enregistrement| Annuaire
            Composite -.->|Enregistrement| Annuaire
            Gateway -.->|Enregistrement| Annuaire
            
            %% Config Server
            Client -->|Configuration| ConfigSrv[bnkconfigsrv]
            Compte -->|Configuration| ConfigSrv
            Composite -->|Configuration| ConfigSrv
            Gateway -->|Configuration| ConfigSrv
        end

        subgraph Security & Secrets (default namespace)
            Vault[Hashicorp Vault] -->|Secrets DB| ESO[External Secrets Operator]
            ESO -->|Génère le K8s Secret| DBSecret[Secret: vault-token / db]
            DBSecret -.->|Injecté dans| Client
            DBSecret -.->|Injecté dans| Compte
        end
        
        subgraph GitOps CD (argocd namespace)
            Argo[ArgoCD Controller] -.->|Surveille & Synchronise| K8sResources[Chart Helm miage-bank]
        end
    end
    
    GitHub[(Dépôt GitHub Distant)] -.->|Lit la configuration| Argo
```

---

## 🛠️ 2. Pré-requis de l'Environnement

Avant de commencer, assurez-vous d'avoir les outils suivants installés sur votre machine hôte :

| Outil | Rôle | Commande de vérification |
| :--- | :--- | :--- |
| **Docker Desktop** | Moteur de conteneurs sous-jacent | `docker --version` |
| **Minikube** | Cluster Kubernetes local de test | `minikube version` |
| **kubectl** | CLI pour interagir avec Kubernetes | `kubectl version --client` |
| **Helm v3** | Gestionnaire de paquets Kubernetes | `helm version` |
| **Git** | Gestionnaire de version (requis pour GitOps) | `git version` |

> [!NOTE]
> Pour exécuter ce projet confortablement, nous recommandons d'allouer au moins **4 Go de RAM** et **2 CPUs** à Minikube.

---

## 🚀 3. Guide pas à pas d'installation et déploiement

### Étape 1 : Démarrage du Cluster local (Minikube)

Démarrez votre cluster local à l'aide de la commande suivante :

```bash
minikube start --driver=docker --memory=4096 --cpus=2
```
* **Temps d'attente estimé** : 1 à 2 minutes.
* **Que se passe-t-il ?** Minikube crée une machine virtuelle / conteneur système contenant le plan de contrôle Kubernetes et y connecte votre client Docker local.

---

### Étape 2 : Compilation & Construction des images Docker

> [!CAUTION]
> ⚠️ **PIÈGE TECHNIQUE (Windows / Minikube)** :
> Minikube fonctionne dans un conteneur isolé. Si vous tentez de lancer la compilation Maven directement dans le démon Docker de Minikube, celle-ci échouera car le démon interne de Minikube ne peut pas monter de répertoires de votre système Windows hôte (`C:\Users\...`).
> 
> **La solution consiste à procéder en deux phases bien distinctes :**

#### Phase A : Compiler le code Java sur le Docker Hôte (Docker Desktop)
Assurez-vous que votre terminal n'est **PAS** branché sur Minikube (fermez et réouvrez un terminal propre), puis lancez la compilation. Le conteneur Maven éphémère va générer les fichiers `.jar` directement sur votre disque physique hôte.

* **Windows (PowerShell)** :
  ```powershell
  docker run --rm -v "c:/Users/Hugues/Documents/MiageBankKub/BanqueMSSol:/usr/src/app" -w /usr/src/app maven:3.8.4-openjdk-11-slim mvn clean package -DskipTests
  ```
* **Bash (Linux / macOS / Git Bash)** :
  ```bash
  docker run --rm -v "$(pwd)/BanqueMSSol:/usr/src/app" -w /usr/src/app maven:3.8.4-openjdk-11-slim mvn clean package -DskipTests
  ```
* **Temps d'attente estimé** : 1 à 2 minutes (le temps de compiler les 7 modules).

#### Phase B : Pointer le terminal sur Minikube et Builder les images Docker
Une fois les `.jar` créés localement sur votre disque, connectez votre session de terminal au démon Docker interne de Minikube, puis lancez le build des images. Les images Docker compilées seront immédiatement stockées dans le registre de Minikube.

* **Windows (PowerShell)** :
  ```powershell
  # 1. Connecter le terminal au Docker de Minikube :
  minikube docker-env | Invoke-Expression

  # 2. Builder les images (depuis la racine du projet) :
  cd BanqueMSSol
  docker build -t banque-annuaire:7.0 ./Banque-Annuaire
  docker build -t banque-configsrv:7.0 ./Banque-ConfigServer
  docker build -t banque-clientservice:7.0 ./Banque-ClientService
  docker build -t banque-compteservice:7.0 ./Banque-CompteService
  docker build -t banque-compositeservice:7.0 ./Banque-CompositeService
  docker build -t banque-apigateway:7.0 ./Banque-APIGateway
  cd ..
  ```
* **Windows (CMD - Invite de commande)** :
  ```cmd
  @FOR /f "tokens=*" %i IN ('minikube -p minikube docker-env') DO @%i
  cd BanqueMSSol
  docker build -t banque-annuaire:7.0 ./Banque-Annuaire
  :: (répétez pour chaque service...)
  ```
* **Bash (Linux / macOS / Git Bash)** :
  ```bash
  eval $(minikube docker-env)
  ./build-all-images.sh
  ```

---

### Étape 3 : Pousser les correctifs locaux sur GitHub

> [!WARNING]
> ⚠️ **ÉTAPE CRUCIALE POUR ARGOCD (GITOPS)**
> ArgoCD n'utilise pas vos fichiers locaux pour déployer sur Kubernetes ; il lit en temps réel la configuration stockée sur votre **dépôt GitHub distant**. 
> Si vous apportez des modifications au dossier `miage-bank/` (port de la passerelle, adresses Eureka, MongoDB), vous devez absolument pousser ces correctifs en ligne :

```bash
git add miage-bank/
git commit -m "Fix: correctifs de configuration réseau, ports et intégration Eureka/MongoDB"
git push origin main
```

---

### Étape 4 : Déploiement de Vault & External Secrets (Gestion des secrets)

L'application utilise Hashicorp Vault pour sécuriser les identifiants des bases de données et External Secrets Operator (ESO) pour les injecter sous forme de secrets Kubernetes natifs.

#### 1. Installer Vault en mode de développement :
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault --set "server.dev.enabled=true" --set "server.dev.devRootToken=root" -n default
```

#### 2. Installer External Secrets Operator (ESO) :
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --set installCRDs=true
```
* **Temps d'attente estimé** : 30 secondes pour le démarrage complet des contrôleurs d'API Secrets.

#### 3. Initialiser les secrets dans le coffre-fort Vault :
> [!IMPORTANT]
> Attendez que le pod `vault-0` soit au statut `Running` (`kubectl get pods -l app.kubernetes.io/name=vault`) avant de lancer la commande suivante.

```bash
kubectl exec -it vault-0 -n default -- vault kv put secret/miage-bank/db username="dummy-user" password="dummy-password"
```

---

### Étape 5 : Déploiement de l'Application via ArgoCD (GitOps)

#### 1. Installer ArgoCD avec Server-Side Apply :
> [!WARNING]
> Les définitions de ressources d'ArgoCD (CRDs) sont volumineuses. Une commande `kubectl apply` standard échouera sous Windows en raison d'une limite de taille d'annotation (`Too long: may not be more than 262144 bytes`). Utilisez **obligatoirement** l'option `--server-side`.

```bash
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

#### 2. Configurer le Namespace de destination et le token Vault :
ArgoCD va déployer l'application dans le namespace `miage-bank`. Nous devons pré-configurer le token d'accès Vault (`root`) pour permettre à External Secrets de déchiffrer les secrets.

```bash
kubectl create namespace miage-bank
kubectl create secret generic vault-token --from-literal=token=root -n miage-bank
```

#### 3. Déployer l'application ArgoCD :
> [!NOTE]
> Avant d'appliquer cette ressource, ouvrez le fichier [argocd-app.yaml](file:///c:/Users/Hugues/Documents/MiageBankKub/argocd-app.yaml) et assurez-vous que la propriété `spec.source.repoURL` (ligne 9) cible bien **votre dépôt GitHub personnel**.

```bash
kubectl apply -f argocd-app.yaml
```

---

## 🔍 4. Accès, Supervision & Tests des Services

### 📊 Option A : Visualiser la synchronisation sur le Dashboard ArgoCD

1. **Lancer le tunnel d'accès (Port-forward)** :
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
   *(Laissez ce terminal ouvert)*

2. **Récupérer le mot de passe Administrateur d'ArgoCD** :
   * **Windows (PowerShell)** :
     ```powershell
     [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}")))
     ```
   * **Linux / macOS / Git Bash** :
     ```bash
     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
     ```
3. Connectez-vous sur [https://localhost:8080](https://localhost:8080) (acceptez l'avertissement de certificat auto-signé) avec l'identifiant `admin` et le mot de passe décodé. Vous verrez l'application `miage-bank` s'auto-synchroniser en temps réel !

---

### 🌐 Option B : Surveiller les Pods Métiers & Eureka

Suivez le démarrage de vos pods applicatifs :
```bash
kubectl get pods -n miage-bank -w
```
*(Le démarrage complet prend environ 1 à 2 minutes. ConfigServer, MongoDB et Annuaire démarrent d'abord, puis les microservices se connectent).*

#### Visualiser l'Annuaire Spring Eureka :
Une fois le pod `bnkannuaire` actif, ouvrez un nouveau terminal et lancez :
```bash
kubectl port-forward svc/bnkannuaire 10001:10001 -n miage-bank
```
Rendez-vous sur **<http://localhost:10001>** pour voir tous vos microservices (`CLIENTSERVICE`, `COMPTESERVICE`, etc.) enregistrés dynamiquement.

---

### 🧪 Option C : Tester les APIs avec l'API Gateway

Pour exposer votre point d'entrée unique (l'API Gateway) :
```bash
kubectl port-forward svc/bnkapigateway 10000:10000 -n miage-bank
```

Vous pouvez maintenant tester les routes HTTP via Postman, cURL, ou PowerShell sur `http://localhost:10000` :

1. **Créer un Client (POST)** :
   * **URL** : `http://localhost:10000/api/clients`
   * **Body JSON** : `{"id": 1, "nom": "Dupont", "prenom": "Jean"}`
2. **Consulter la synthèse client + comptes (GET)** :
   * **URL** : `http://localhost:10000/api/clientscomptes/1`

---

## 🛠️ 5. Résolution des Problèmes Courants (FAQ)

### ❌ Problème 1 : Minikube refuse de démarrer / Erreur de droits sur `id_rsa.pub`
* **Symptôme** : L'accès au répertoire `.minikube\machines\minikube` est refusé, bloquant un nouveau démarrage.
* **Solution** : Sous Windows, certains processus ou machines virtuelles peuvent verrouiller ces clés. Ouvrez PowerShell en tant qu'administrateur et forcez la suppression du dossier corrompu via CMD (qui contourne les blocages de permissions de fichiers individuels) :
  ```powershell
  cmd.exe /c "rmdir /s /q C:\Users\Hugues\.minikube\machines\minikube"
  minikube delete
  minikube start --driver=docker
  ```

### ❌ Problème 2 : L'erreur `lstat /target: no such file or directory` lors du Docker build
* **Symptôme** : Les Dockerfiles échouent à la ligne `COPY target/*.jar`.
* **Solution** : Vous avez oublié l'Étape 2 (Phase A). Le code source n'a pas été compilé sur votre machine hôte Docker Desktop. Lancez la compilation Maven sur le Docker hôte, puis re-buildez sur Minikube.

### ❌ Problème 3 : Le Port-Forward renvoie `address already in use`
* **Symptôme** : Impossible de démarrer le tunnel vers l'API Gateway ou ArgoCD.
* **Solution** : Un autre processus ou tunnel écoute déjà sur ce port (par exemple le port 10000 ou 8080). Identifiez-le ou utilisez un autre port externe lors de la commande :
  ```bash
  kubectl port-forward svc/bnkapigateway 10002:10000 -n miage-bank
  ```
  *(Vous accéderez alors à la Gateway via `http://localhost:10002`)*

---

## 🧹 6. Nettoyage complet

Pour arrêter proprement votre cluster de test et libérer toutes les ressources système :

1. Dans chaque terminal où un tunnel `kubectl port-forward` est actif, coupez-le avec la combinaison de touches `Ctrl + C`.
2. Supprimez l'application ArgoCD :
   ```bash
   kubectl delete application miage-bank -n argocd
   ```
3. Arrêtez Minikube :
   ```bash
   minikube stop
   ```
