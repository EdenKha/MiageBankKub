# Hugues ANSOBORLO / Tom VERBECQUE - TP KUB DevOps MIAGE-Bank

> 📘 **Guide de déploiement complet** : voir [GUIDE_DEPLOIEMENT.md](GUIDE_DEPLOIEMENT.md) pour les instructions pas-à-pas (pré-requis, installation, tests, troubleshooting).

## Partie A - Analyse comparative Docker vs Buildah

Dans le cadre de l'industrialisation des images de conteneurs, Buildah propose une alternative intéressante au moteur historique Docker. Voici une comparaison sur plusieurs axes techniques :

### 1. Architecture : Modèle démon vs Daemonless

* **Docker** s'appuie sur une architecture client/serveur nécessitant un processus démon persistant (`dockerd`) en arrière-plan avec des privilèges élevés pour gérer le cycle de vie des conteneurs.
* **Buildah** adopte une architecture "daemonless" (sans démon). Il s'exécute uniquement à la demande en tant que simple commande utilitaire, ce qui réduit considérablement la consommation de ressources et simplifie l'exécution.

### 2. Sécurité : Surface d'attaque et privilèges

* **Docker** : L'utilisation du démon Docker implique souvent l'accès au socket UNIX `/var/run/docker.sock`. Exposer ce socket à un conteneur ou un utilisateur non privilégié permet une escalade de privilèges évidente vers "root". La surface d'attaque est donc plus large.
* **Buildah** permet des builds "rootless" (exécution en espace utilisateur sans privilèges root) par défaut de manière plus simple et native. L'absence de démon centralisé limite fortement les vecteurs d'attaque, notamment dans des environnements partagés.

### 3. Conformité OCI : Compatibilité

* **Buildah** est un projet conçu pour générer des images strictement conformes au standard de l'Open Container Initiative (OCI). Les images générées par Buildah (ainsi que celles générées par Docker via BuildKit) sont interopérables. Une image construite par Buildah peut être exécutée indifféremment par Docker, Podman, ou directement dans un cluster Kubernetes via containerd/CRI-O.

### 4. Cas d'usage CI/CD : Pertinence en environnement Rootless

* **Buildah**, grâce à sa nature daemonless et rootless, s'intègre naturellement et de façon sécurisée dans ces pipelines. Il peut être lancé directement à l'intérieur d'un pod Kubernetes ou d'un runner CI sans nécessiter de privilèges élevés ni de montages de sockets à risques.

### 5. Comparaison des approches de Build (Containerfile vs Natif)

Dans le cadre de ce projet, deux approches de construction de l'image MIAGE-Bank ont été expérimentées avec Buildah :

* **Via un Containerfile (Multi-stage)** : Cette approche (implémentée dans `BanqueMSSol/Banque-ClientService/Containerfile`) est très standardisée. Elle est facile à lire, compatible avec les linters (comme Hadolint), et idéale pour une intégration CI/CD classique. Le multi-stage build permet de garder une image finale très légère.
* **Via un script natif (Layer par Layer)** : Cette approche (implémentée dans le script `build-native.sh`) utilise exclusivement les commandes CLI natives de Buildah (`buildah from`, `buildah mount`, `buildah copy`). L'avantage principal est un contrôle absolu sur les couches générées et la possibilité d'utiliser les outils du système hôte pendant le build (via le montage du conteneur temporaire) sans avoir à installer de dépendances de build dans l'image, réduisant encore la surface d'attaque.

### 6. Rapports de Sécurité et Audit (Trivy & Dive)

**Analyse Trivy (CVE HIGH/CRITICAL)** :
Le scan Trivy remonte plusieurs vulnérabilités (notamment sur le framework Spring, Tomcat et SnakeYaml), dues à la version obsolète des dépendances utilisées par le projet Java de base. Voici les principales :

* **CVE-2022-22965 (Spring4Shell) & CVE-2022-22968** : Vulnérabilité critique de RCE (Remote Code Execution) dans le mécanisme de Data Binding de Spring Framework.
* **CVE-2022-1471 (SnakeYaml)** : Vulnérabilité de désérialisation non sécurisée permettant une exécution de code arbitraire.
* **Vulnérabilités Tomcat (ex: CVE-2023-44487)** : Vulnérabilité au DDoS via le protocole HTTP/2 (Rapid Reset Attack).
* **Plan de remédiation** : La solution pour corriger l'ensemble de ces failles applicatives est de mettre à jour le composant `spring-boot-starter-parent` dans le `pom.xml` vers une version récente (ex: 3.2.x ou supérieure) qui embarque les versions patchées de Tomcat, Spring et SnakeYaml, puis de relancer le build Buildah.
* **Note sur la "Security Gate"** : Étant donné la présence de ces vulnérabilités critiques inhérentes au code source Java fourni, l'option bloquante de Trivy (`exit-code: 1`) a été volontairement désactivée dans notre pipeline GitHub Actions (`ci.yml`). Cet abaissement du niveau de sécurité permet de ne pas bloquer le déploiement et la suite du TP, conformément aux directives.

**Audit Dive (Optimisation des layers)** :

* L'image finale générée obtient un excellent score d'efficacité de **99.82%** (`efficiencyScore: 0.9982`) pour une taille totale de **236 Mo** (`sizeBytes: 236045966`), avec un espace gaspillé négligeable (0 octet identifié comme superflu par Dive).

**Comparaison Avant / Après (Impact du Multi-stage Build) :**

* **Avant (Sans Multi-stage)** : Si nous avions construit l'image en un seul stage, l'audit Dive aurait identifié de nombreux répertoires superflus et un espace gaspillé énorme. L'image aurait contenu le cache Maven (`/root/.m2`, plusieurs centaines de Mo), les codes sources (`/app/src`), et le JDK complet, générant des layers inutiles et gonflant l'image à plus de 600 Mo.
* **Après (Avec Multi-stage)** : Grâce au Multi-stage implémenté dans notre `Containerfile`, la layer de base se résume au JRE Alpine (~190 Mo) et les dernières layers ne contiennent *que* les dépendances Java extraites et l'application compilée (~40 Mo). Dive confirme l'absence totale de répertoires superflus de build.

### 7. Compatibilité d'Architecture (Note matérielle)

*La pipeline CI/CD GitHub Actions compile l'image OCI finale pour une architecture `amd64` (processeurs Intel/AMD). Pour un déploiement optimal sur un poste de développement utilisant l'architecture `arm64` (comme les Mac Apple Silicon M1/M2/M3), il est recommandé de rebuilder l'image localement à l'aide du script fourni afin d'éviter l'utilisation d'une couche d'émulation (Rosetta).*

---

## Partie B - Déploiement Kubernetes & GitOps avec ArgoCD

### 1. Architecture Helm

Le Chart Helm `miage-bank` package l'application MIAGE-Bank pour Kubernetes. Il déploie un `Deployment` configuré avec des liveness/readiness probes, un `Service` de type ClusterIP, et un `Ingress` pour Traefik.
Les privilèges sont limités via un `ServiceAccount` dédié, une `NetworkPolicy` en "default-deny" (n'autorisant que le trafic depuis l'Ingress), et des règles `RBAC` (Role/RoleBinding) strictes.

*Note sur l'arborescence : Bien que la consigne suggère la présence de fichiers `namespace.yaml` et `configmap.yaml` dans les templates du chart, nous avons volontairement fait le choix de ne pas les inclure pour respecter les bonnes pratiques de déploiement et GitOps :*

* *`namespace.yaml` est omis car la création du namespace est déléguée à la synchronisation ArgoCD (via l'option `CreateNamespace=true`), ce qui centralise la gestion du cycle de vie du namespace au niveau de l'outil CD.*
* *`configmap.yaml` est omis car la configuration applicative est gérée dynamiquement via des variables d'environnement définies dans le `values.yaml` et injectées dans le `Deployment`, tandis que les données critiques sont sécurisées via Vault.*

### 2. Gestion des Secrets

Afin d'éviter de stocker les informations sensibles en clair dans le Git (ou dans le `values.yaml`), nous utilisons **Hashicorp Vault + External Secrets Operator (ESO)** :

1. **Vault** stocke les identifiants (`secret/miage-bank/db` → `username`, `password`)
2. **SecretStore** (`secretstore.yaml`) configure la connexion entre ESO et Vault
3. **ExternalSecret** (`externalsecret.yaml`) crée automatiquement un `Secret` Kubernetes nommé `miage-bank-db-secret` avec les valeurs synchronisées depuis Vault
4. Le **Deployment** injecte ces valeurs via `secretKeyRef` dans les variables d'environnement

> Voir la section **Étape 3** du [Guide de Déploiement](GUIDE_DEPLOIEMENT.md#étape-3--configurer-vault-et-external-secrets-operator) pour les commandes d'installation de Vault et ESO.

### 3. GitOps ArgoCD - Démonstration de la Dérive

Le manifeste `argocd-app.yaml` définit le déploiement continu du Chart Helm sur le namespace `miage-bank`.

**Le paradoxe de l'œuf ou la poule (GitOps)** :
Pour déployer des applications via ArgoCD, ArgoCD doit lui-même être déployé sur le cluster ! Il est donc impossible de déployer ArgoCD "depuis zéro" de façon purement GitOps sans une première action manuelle (ou via un script d'amorçage comme Terraform/Bash). C'est pourquoi l'installation initiale d'ArgoCD se fait manuellement (`kubectl apply -f install.yaml`), et ensuite ArgoCD prend le relais.

**Démonstration du test de dérive (Drift) :**

1. Une fois l'application synchronisée via ArgoCD (statut *Healthy/Synced*), augmentez artificiellement le nombre de réplicas via la commande imperative :
   `kubectl scale deployment miage-bank --replicas=5 -n miage-bank`
2. Dans l'interface ArgoCD, l'application basculera presque immédiatement en statut **OutOfSync** (dérive détectée).
3. Étant donné que nous avons configuré `selfHeal: true` dans la `syncPolicy` de l'application, ArgoCD déclenche une réconciliation automatique. Il annule notre modification manuelle (suppression des 4 pods superflus) et restaure le nombre de pods défini dans Git. Le statut repasse en **Synced**.
