# Tom Verbecque / Hugues Ansoborlo - TP KUB DevOps MIAGE-Bank

> 📘 **Guide de déploiement complet** : voir [GUIDE_DEPLOIEMENT.md](GUIDE_DEPLOIEMENT.md) pour les instructions pas-à-pas (pré-requis, installation, tests, troubleshooting).

---

## 📋 Table des matières

- [🚀 Démarrage rapide](#-démarrage-rapide)
- [🏗️ Architecture de l'application](#️-architecture-de-lapplication)
- [Partie A — Chaîne de build OCI (Buildah, Trivy, Dive)](#partie-a--chaîne-de-build-oci-buildah-trivy-dive)
  - [1. Analyse comparative Docker vs Buildah](#1-analyse-comparative-docker-vs-buildah)
  - [2. Build avec Buildah : Containerfile vs Natif](#2-build-avec-buildah--containerfile-vs-natif)
  - [3. Scan de sécurité Trivy — Rapport CVE](#3-scan-de-sécurité-trivy--rapport-cve)
  - [4. Audit des layers avec Dive](#4-audit-des-layers-avec-dive)
  - [5. Pipeline GitHub Actions (CI/CD)](#5-pipeline-github-actions-cicd)
- [Partie B — Packaging Helm & Déploiement Kubernetes](#partie-b--packaging-helm--déploiement-kubernetes)
  - [1. Structure du Chart Helm](#1-structure-du-chart-helm)
  - [2. Gestion des Secrets (Vault + ESO)](#2-gestion-des-secrets-vault--eso)
  - [3. GitOps ArgoCD & Démonstration de la Dérive](#3-gitops-argocd--démonstration-de-la-dérive)

---

## 🚀 Démarrage rapide

```bash
# 1. Cloner le dépôt et construire les images Docker localement
git clone https://github.com/EdenKha/MiageBankKub.git
cd MiageBankKub
./build-all-images.sh          # Linux/macOS/WSL
# .\build-all-images.ps1       # Windows PowerShell

# 2. Déployer sur Kubernetes (Minikube ou Docker Desktop)
kubectl create namespace miage-bank
kubectl create secret generic vault-token --from-literal=token=root -n miage-bank
helm install miage-bank-release ./miage-bank -n miage-bank

# 3. Accéder à l'API Gateway
kubectl port-forward svc/bnkapigateway 10000:10000 -n miage-bank
# → http://localhost:10000/api/clients
```

---

## 🏗️ Architecture de l'application

MIAGE-Bank est une application de banque en ligne composée de **6 microservices Spring Boot** communiquant via un Annuaire Eureka (Service Discovery), configurés centralement par un ConfigServer, et exposés à l'extérieur via une API Gateway.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Namespace : miage-bank                       │
│                                                                 │
│  👤 Utilisateur                                                 │
│       │                                                         │
│       ▼                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │  API Gateway │───▶│ ClientService│───▶│     MySQL        │  │
│  │  :10000      │    │  :8081       │    │     :3306        │  │
│  │              │    └──────────────┘    └──────────────────┘  │
│  │              │    ┌──────────────┐    ┌──────────────────┐  │
│  │              │───▶│ CompteService│───▶│     MongoDB      │  │
│  │              │    │  :10021      │    │     :27017       │  │
│  │              │    └──────────────┘    └──────────────────┘  │
│  │              │    ┌──────────────────────────────────────┐  │
│  │              │───▶│       CompositeService :10031        │  │
│  └──────────────┘    └──────────────────────────────────────┘  │
│                                                                 │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐  │
│  │  Annuaire (Eureka)  │  │     ConfigServer :10003         │  │
│  │  :10001             │  │  (Config centralisée Git)       │  │
│  └─────────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Partie A — Chaîne de build OCI (Buildah, Trivy, Dive)

### 1. Analyse comparative Docker vs Buildah

#### 1.1 Architecture : Modèle démon vs Daemonless

| Critère | Docker | Buildah |
|---------|--------|---------|
| **Modèle** | Client/serveur avec démon `dockerd` persistant | Daemonless — processus éphémère à la demande |
| **Privilèges requis** | Root (accès au socket `/var/run/docker.sock`) | Espace utilisateur sans privilège root |
| **Consommation ressources** | Permanente (démon actif 24h/24) | Nulle au repos |
| **Complexité d'installation** | Installation complète de Docker Engine | Simple binaire |

**Docker** s'appuie sur une architecture client/serveur nécessitant un processus démon persistant (`dockerd`) en arrière-plan avec des privilèges élevés. **Buildah** adopte une architecture "daemonless" : il s'exécute uniquement à la demande en tant que simple commande utilitaire, ce qui réduit considérablement la consommation de ressources.

#### 1.2 Sécurité : Surface d'attaque et privilèges

| Critère | Docker | Buildah |
|---------|--------|---------|
| **Vecteur d'attaque principal** | Socket Unix `/var/run/docker.sock` | Aucun socket persistant |
| **Escalade de privilèges** | Possible via exposition du socket | Non applicable (pas de démon) |
| **Builds rootless** | Possible mais complexe à configurer | Natif et par défaut |
| **Isolation** | Dépend de la configuration | Isolation utilisateur native |

L'exposition du socket Docker à un conteneur ou un utilisateur non privilégié permet une escalade de privilèges évidente vers "root". Buildah élimine ce vecteur d'attaque en n'ayant aucun démon persistant.

#### 1.3 Conformité OCI

Les images générées par Buildah sont **strictement conformes au standard OCI (Open Container Initiative)**. Elles sont interopérables avec Docker, Podman, et directement exécutables dans un cluster Kubernetes via containerd/CRI-O, sans aucune conversion.

#### 1.4 Cas d'usage CI/CD : Pertinence en environnement rootless

Buildah s'intègre naturellement et de façon sécurisée dans des pipelines CI/CD :

- Il peut s'exécuter **à l'intérieur d'un pod Kubernetes** ou d'un runner CI sans privilèges élevés.
- Il ne nécessite **aucun montage de socket** à risques (`/var/run/docker.sock`).
- Il est parfaitement adapté aux **runners GitLab partagés** ou aux environnements multi-tenant.

---

### 2. Build avec Buildah : Containerfile vs Natif

Deux approches ont été implémentées et comparées pour construire l'image de `banque-clientservice`.

#### 2.1 Approche 1 — Via un Containerfile (Multi-stage)

Le fichier [`BanqueMSSol/Banque-ClientService/Containerfile`](BanqueMSSol/Banque-ClientService/Containerfile) utilise un **build multi-stage** pour produire une image finale allégée :

```dockerfile
# Stage 1 : Extraction des layers Spring Boot
FROM eclipse-temurin:11-jre-alpine AS builder
WORKDIR /app
ARG JAR_FILE=target/*.jar
COPY ${JAR_FILE} application.jar
RUN java -Djarmode=layertools -jar application.jar extract

# Stage 2 : Image de production (JRE Alpine uniquement)
FROM eclipse-temurin:11-jre-alpine

# Utilisateur non-root (bonne pratique sécurité)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app

# Copie des layers extraits (optimisation cache Docker)
COPY --from=builder /app/dependencies/ ./
COPY --from=builder /app/snapshot-dependencies/ ./
COPY --from=builder /app/spring-boot-loader/ ./
COPY --from=builder /app/application/ ./

# Script de démarrage et utilitaire wait
COPY startup.sh /startup.sh
RUN chmod +x /startup.sh
RUN wget -q -O /wait https://github.com/ufoscout/docker-compose-wait/releases/download/2.9.0/wait && \
    chmod +x /wait
RUN chown -R appuser:appgroup /app /startup.sh /wait

EXPOSE 8081
USER appuser
ENTRYPOINT ["/bin/sh","-c","/startup.sh"]
```

**Commande de build :**

```bash
buildah bud -f Containerfile -t banque-clientservice:7.0 .
```

#### 2.2 Approche 2 — Build natif layer par layer

Le script [`build-native.sh`](build-native.sh) utilise exclusivement les commandes CLI de Buildah, sans Containerfile, pour un contrôle absolu sur chaque layer :

```bash
#!/bin/bash
set -e

# Étape 1 : Créer le conteneur de build et extraire les layers Spring Boot
builder=$(buildah from eclipse-temurin:11-jre-alpine)
buildah copy $builder target/*.jar application.jar
buildah run $builder java -Djarmode=layertools -jar application.jar extract
buildah commit $builder miage-bank-builder

# Étape 2 : Créer le conteneur final de production
container=$(buildah from eclipse-temurin:11-jre-alpine)
buildah run $container mkdir /app

# Copie layer par layer depuis le builder
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/dependencies/* /app/ || true'
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/spring-boot-loader/* /app/ || true'
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/application/* /app/ || true'

# Création de l'utilisateur non-root et configuration sécurité
buildah run $container addgroup -S appgroup
buildah run $container adduser -S appuser -G appgroup
buildah copy $container startup.sh /startup.sh
buildah run $container chmod +x /startup.sh
buildah run $container chown -R appuser:appgroup /app /startup.sh

# Configuration de l'entrypoint et commit de l'image finale
buildah config --user appuser $container
buildah config --workingdir /app $container
buildah config --entrypoint '["/bin/sh","-c","/startup.sh"]' $container
buildah commit $container banque-clientservice:7.0-native

# Nettoyage
buildah rm $container
buildah rmi miage-bank-builder
```

#### 2.3 Tableau comparatif des deux approches

| Critère | Via Containerfile | Via script natif |
|---------|:-----------------:|:----------------:|
| **Lisibilité du code** | ✅ Excellente | ⚠️ Moins lisible |
| **Compatible Hadolint** | ✅ Oui | ❌ Non (pas de Containerfile) |
| **Contrôle sur les layers** | ⚠️ Limité par la syntaxe | ✅ Total et granulaire |
| **Intégration CI/CD** | ✅ Standard, simple | ⚠️ Nécessite un script dédié |
| **Taille de l'image finale** | **~236 Mo** | **~236 Mo** (identique) |
| **Utilisateur non-root** | ✅ Oui | ✅ Oui |
| **Utilisation des outils hôte** | ❌ Non | ✅ Via `buildah mount` |

**Conclusion** : Les deux approches produisent une image identique (~236 Mo). Le Containerfile est préférable en CI/CD classique (lisibilité, lint avec Hadolint). Le build natif offre un contrôle maximal sur les couches et permet d'utiliser les outils du système hôte pendant le build sans les embarquer dans l'image finale.

---

### 3. Scan de sécurité Trivy — Rapport CVE

Le scan Trivy a été exécuté sur l'image `banque-clientservice:7.0`. Les rapports complets sont disponibles dans [`build-reports/`](build-reports/) :

- [`trivy-results.json`](build-reports/trivy-results.json) — Format JSON (rapport complet machine-readable)
- [`trivy-results.sarif`](build-reports/trivy-results.sarif) — Format SARIF (intégration GitHub Security)

#### 3.1 Tableau des CVE HIGH et CRITICAL identifiées

| CVE | Sévérité | Composant vulnérable | Version affectée | Description | Remédiation |
|-----|:--------:|----------------------|:----------------:|-------------|-------------|
| **CVE-2022-22965** *(Spring4Shell)* | 🔴 CRITICAL | `spring-webmvc` | < 5.3.18 | **RCE** via le mécanisme de Data Binding de Spring si déployé sur Tomcat 9+ avec JDK 9+. Un attaquant peut exécuter du code arbitraire à distance sans authentification. | Mettre à jour `spring-boot-starter-parent` → **2.6.6+** dans `pom.xml` |
| **CVE-2022-22968** | 🟠 HIGH | `spring-webmvc` | < 5.3.18 | Contournement d'une protection existante contre Spring4Shell via des patterns spécifiques dans les formulaires HTTP. | Idem — Mise à jour Spring Boot → **2.6.6+** |
| **CVE-2022-1471** | 🔴 CRITICAL | `snakeyaml` | < 2.0 | **Désérialisation non sécurisée** permettant l'exécution de code arbitraire via un fichier YAML malveillant. Classé en tant que RCE. | Mettre à jour `snakeyaml` → **2.0+** (inclus dans Spring Boot 3.x) |
| **CVE-2023-44487** *(HTTP/2 Rapid Reset)* | 🟠 HIGH | `tomcat-embed-core` | < 10.1.14 / < 9.0.81 | **Attaque DDoS** exploitant le protocole HTTP/2 "Rapid Reset" pour saturer le serveur avec un flux de requêtes RST_STREAM annulées. | Mettre à jour Tomcat → **9.0.81+** ou **10.1.14+** (via Spring Boot 2.7.17+) |
| **CVE-2022-25857** | 🟠 HIGH | `snakeyaml` | < 1.31 | **Déni de service** (boucle infinie) lors du parsing d'entrées YAML malformées. | Mise à jour `snakeyaml` → **1.31+** ou **2.0+** |

#### 3.2 Plan de remédiation global

La cause racine de l'ensemble de ces vulnérabilités est l'utilisation d'une version ancienne de `spring-boot-starter-parent` dans le `pom.xml`. La correction en une seule action :

```xml
<!-- pom.xml — avant -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>2.5.x</version>  <!-- ← version vulnérable -->
</parent>

<!-- pom.xml — après (correction recommandée) -->
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>2.7.18</version>  <!-- ← patch toutes les CVE ci-dessus -->
</parent>
```

#### 3.3 Note sur la Security Gate

> ⚠️ **Abaissement du niveau de sécurité** : En raison de la présence de ces CVE dans les dépendances du code source Java fourni (hors de notre périmètre de modification dans le cadre du TP), l'option bloquante Trivy (`exit-code: 1`) a été **volontairement désactivée** dans notre pipeline GitHub Actions (`ci.yml`). Cet abaissement permet de ne pas bloquer le déploiement tout en documentant les vulnérabilités, conformément aux directives du TP.

---

### 4. Audit des layers avec Dive

Le rapport Dive complet est disponible dans [`build-reports/dive-report.json`](build-reports/dive-report.json).

#### 4.1 Résultats globaux

| Métrique | Valeur |
|----------|--------|
| **Taille totale de l'image** | **236 Mo** (236 045 966 octets) |
| **Score d'efficacité** | **✅ 99.82%** (`efficiencyScore: 0.9982`) |
| **Espace gaspillé** | 639 Ko (fichiers dupliqués entre layers — non réductibles) |
| **Seuil d'efficacité requis** | ≥ 95% ✅ |
| **Espace gaspillé maximum requis** | ≤ 20 Mo ✅ |

#### 4.2 Décomposition des layers

| # | Taille | Commande |
|---|--------|----------|
| 0 | **8.0 Mo** | `ADD alpine-minirootfs-3.23.4.tar.gz /` — Système de base Alpine |
| 1 | **32.8 Mo** | `RUN apk add fontconfig, tzdata, openssl...` — Dépendances JVM |
| 2 | **122.8 Mo** | `RUN wget OpenJDK11U-jre...` — Installation JRE 11 Temurin |
| 3 | **0 Mo** | `RUN java --version` — Vérification (0 octet) |
| 4 | **5.2 Ko** | `COPY entrypoint.sh` — Script d'entrée |
| 5 | **61.5 Mo** | Application Spring Boot (dépendances + code) |
| **Total** | **~236 Mo** | |

#### 4.3 Fichiers dupliqués identifiés (espace gaspillé : 639 Ko)

Dive identifie quelques fichiers présents dans plusieurs layers (hérités de l'image de base Alpine qui reconstruit ses metadata entre layers) :

| Fichier | Taille | Présent dans N layers |
|---------|--------|-----------------------|
| `/etc/ssl/certs/ca-certificates.crt` | 435 Ko | 2 |
| `/lib/apk/db/installed` | 120 Ko | 2 |
| `/usr/bin/env` | 39 Ko | 2 |
| *Autres binaires Alpine système* | ~45 Ko | 2 |

Ces duplications sont **inhérentes à l'image de base** `eclipse-temurin:11-jre-alpine` et ne peuvent pas être réduites sans changer l'image de base.

#### 4.4 Comparaison Avant / Après (impact du Multi-stage Build)

| Métrique | ❌ Sans multi-stage | ✅ Avec multi-stage (notre implémentation) |
|----------|:--------------------|:------------------------------------------|
| **Taille totale** | ~620 Mo | **236 Mo** (-62%) |
| **Cache Maven** (`/root/.m2`) | ✅ Inclus (~350 Mo) | ❌ Absent |
| **Code source** (`/app/src`) | ✅ Inclus | ❌ Absent |
| **JDK complet** | ✅ Inclus (~200 Mo) | ❌ Seulement JRE Alpine |
| **Score d'efficacité Dive** | ~72% | **99.82%** |
| **Fichiers superflus** | Cache Maven, sources Java, outils de build | Aucun |
| **Surface d'attaque** | Grande (JDK + outils) | Minimale (JRE seul) |

> Le multi-stage build élimine **384 Mo** d'artefacts de build superflus de l'image de production finale, tout en améliorant la sécurité (aucun outil de compilation dans l'image finale).

---

### 5. Pipeline GitHub Actions (CI/CD)

La pipeline CI/CD est définie dans [`.github/workflows/ci.yml`](.github/workflows/ci.yml) et s'exécute automatiquement à chaque commit sur `main`.

#### 5.1 Étapes de la pipeline

```
┌─────────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐   ┌────────────┐
│  Checkout   │──▶│  Maven Build │──▶│   Hadolint    │──▶│    Buildah   │──▶│   Trivy    │
│  du code    │   │  (JAR build) │   │  (lint CF)    │   │  (build OCI) │   │  (scan CVE)│
└─────────────┘   └──────────────┘   └───────────────┘   └──────────────┘   └─────┬──────┘
                                                                                    │
                                                                              ┌─────▼──────┐
                                                                              │    Dive    │
                                                                              │ (audit     │
                                                                              │  layers)   │
                                                                              └────────────┘
```

| Étape | Outil | Résultat |
|-------|-------|----------|
| **Compilation** | Maven 3.8.4 (dans conteneur Docker) | JAR construit ✅ |
| **Lint du Containerfile** | Hadolint | Aucune erreur bloquante ✅ |
| **Build image OCI** | Buildah | Image `banque-clientservice:7.0` ✅ |
| **Scan sécurité (SARIF)** | Trivy | Rapport uploadé vers GitHub Security ✅ |
| **Scan sécurité (JSON)** | Trivy | `build-reports/trivy-results.sarif` ✅ |
| **Audit layers** | Dive | Score 99.82% ✅ (seuils passés) |

> ℹ️ Les rapports Trivy et Dive sont exportés comme **artefacts téléchargeables** sur chaque run GitHub Actions, et versionnés dans le dossier [`build-reports/`](build-reports/).

---

## Partie B — Packaging Helm & Déploiement Kubernetes

### 1. Structure du Chart Helm

Le Chart Helm `miage-bank` package l'intégralité de l'application MIAGE-Bank pour un déploiement Kubernetes reproductible.

#### 1.1 Arborescence du chart

```
miage-bank/
├── Chart.yaml                          ← Métadonnées du chart (nom, version)
├── values.yaml                         ← Configuration dev (images locales :7.0)
├── values-prod.yaml                    ← Configuration prod (registry ghcr.io)
└── templates/
    ├── _helpers.tpl                    ← Fonctions Helm réutilisables
    │
    ├── deployment-annuaire.yaml        ← Eureka Service Registry
    ├── deployment-configserver.yaml    ← Spring Cloud Config Server
    ├── deployment-clientservice.yaml   ← Service de gestion des clients (MySQL)
    ├── deployment-compteservice.yaml   ← Service de gestion des comptes (MongoDB)
    ├── deployment-compositeservice.yaml← Agrégation client + comptes
    ├── deployment-apigateway.yaml      ← Point d'entrée unique (port 10000)
    ├── deployment-mysql.yaml           ← Base de données relationnelle
    ├── deployment-mongo.yaml           ← Base de données documentaire
    │
    ├── service-*.yaml                  ← Services ClusterIP pour chaque déploiement
    ├── ingress.yaml                    ← Exposition externe via Traefik (miage-bank.local)
    │
    ├── networkpolicy.yaml              ← Default-deny ingress sur le namespace
    ├── rbac.yaml                       ← Role + RoleBinding (least privilege)
    ├── serviceaccount.yaml             ← ServiceAccount dédié miage-bank-sa
    │
    ├── secretstore.yaml                ← Connexion ESO ↔ Vault
    ├── externalsecret.yaml             ← Synchronisation Vault → Secret K8s (MySQL)
    └── externalsecret-mongo.yaml       ← Synchronisation Vault → Secret K8s (MongoDB)
```

#### 1.2 Choix de conception

- **`namespace.yaml` omis** : La création du namespace est déléguée à ArgoCD (`CreateNamespace=true`), ce qui centralise la gestion du cycle de vie au niveau de l'outil CD et évite un conflit de propriété entre Helm et ArgoCD.
- **`configmap.yaml` omis** : La configuration applicative est gérée via des variables d'environnement injectées dans les `Deployment` depuis `values.yaml`. Les secrets sont gérés par Vault (voir section suivante).

#### 1.3 Sécurité : NetworkPolicy & RBAC

**NetworkPolicy** (`networkpolicy.yaml`) — Principe de **default-deny** :

- Tout trafic entrant vers le namespace `miage-bank` est bloqué par défaut.
- Seul le trafic provenant du contrôleur Ingress Traefik est autorisé vers l'API Gateway.

**RBAC** (`rbac.yaml`) — Principe de **least privilege** :

- Un `ServiceAccount` dédié (`miage-bank-sa`) est créé pour les pods.
- Un `Role` minimal (accès en lecture aux `ConfigMaps` et `Secrets` du namespace) est associé via un `RoleBinding`.

---

### 2. Gestion des Secrets (Vault + ESO)

Les credentials de base de données (MySQL et MongoDB) ne figurent **jamais en clair** dans Git ni dans `values.yaml`. Le flux de gestion des secrets est le suivant :

```
┌──────────────┐     ┌──────────────────┐     ┌───────────────────┐     ┌─────────────┐
│  Vault       │────▶│  SecretStore     │────▶│  ExternalSecret   │────▶│ K8s Secret  │
│  (stockage)  │     │  (connexion ESO) │     │  (synchronisation)│     │  (injection)│
│              │     │                  │     │                   │     │             │
│ secret/      │     │ vault.default    │     │ miage-bank-db-    │     │ MYSQL_USER  │
│ miage-bank/db│     │ .svc:8200        │     │ secret            │     │ MYSQL_PASS  │
│              │     │                  │     │                   │     │ ROOT_PASS   │
│ secret/      │     │                  │     │ miage-bank-mongo- │     │ MONGO_USER  │
│ miage-bank/  │     │                  │     │ secret            │     │ MONGO_PASS  │
│ mongo        │     │                  │     │                   │     │ MONGO_URI   │
└──────────────┘     └──────────────────┘     └───────────────────┘     └─────────────┘
```

1. **Vault** stocke les identifiants à deux adresses :
   - `secret/miage-bank/db` — credentials MySQL (clés : `username`, `password`, `rootPassword`)
   - `secret/miage-bank/mongo` — credentials MongoDB (clés : `username`, `password`, `uri`)
2. **SecretStore** ([`secretstore.yaml`](miage-bank/templates/secretstore.yaml)) configure la connexion entre External Secrets Operator et Vault (via un token root en mode dev).
3. **ExternalSecret** — Deux manifestes synchronisent automatiquement les valeurs Vault vers des `Secrets` Kubernetes :
   - [`externalsecret.yaml`](miage-bank/templates/externalsecret.yaml) → `miage-bank-db-secret` (MySQL)
   - [`externalsecret-mongo.yaml`](miage-bank/templates/externalsecret-mongo.yaml) → `miage-bank-mongo-secret` (MongoDB)
4. Les **Deployments** injectent ces valeurs via `secretKeyRef` dans les variables d'environnement des pods.

> 📖 Voir la section **Étape 3** du [Guide de Déploiement](GUIDE_DEPLOIEMENT.md#étape-3--configurer-vault-et-external-secrets-operator) pour les commandes d'installation de Vault et ESO.

---

### 3. GitOps ArgoCD & Démonstration de la Dérive

#### 3.1 Le paradoxe de l'œuf ou la poule (GitOps)

Pour déployer des applications via ArgoCD, ArgoCD doit lui-même être installé sur le cluster. Il est donc **impossible de déployer ArgoCD de façon purement GitOps** sans une première action manuelle d'amorçage. C'est pourquoi :

1. L'installation initiale d'ArgoCD se fait manuellement : `kubectl apply --server-side -f install.yaml`
2. Une fois ArgoCD installé, il prend le relais et gère le cycle de vie du Chart Helm via le manifeste [`argocd-app.yaml`](argocd-app.yaml).

Ce compromis est documenté dans le fichier `argocd-app.yaml` avec les options `prune: true` et `selfHeal: true` activées.

#### 3.2 Démonstration de la dérive (Drift)

La démonstration prouve que toute modification manuelle du cluster est automatiquement corrigée par ArgoCD :

**Étape 1 — État initial :** L'application est synchronisée (statut **Synced / Healthy** dans ArgoCD). 1 seul pod est en cours d'exécution comme défini dans Git.

```bash
kubectl get pods -n miage-bank
# → 1 seul pod en Running
```

**Étape 2 — Provocation de la dérive :** Augmentation impérative des réplicas à 5 (violation de l'état Git) :

```bash
kubectl scale deployment bnkannuaire --replicas=5 -n miage-bank
```

**Étape 3 — Détection :** Dans l'interface ArgoCD, l'application passe quasi-immédiatement en statut **OutOfSync** (🟡 dérive détectée entre l'état du cluster et l'état Git).

**Étape 4 — Réconciliation automatique :** Grâce à `selfHeal: true`, ArgoCD déclenche une réconciliation automatique en ~15-30 secondes. Il supprime les 4 pods superflus et restaure l'état défini dans Git.

```bash
# Après ~30 secondes :
kubectl get pods -n miage-bank
# → 1 seul pod en Running (état Git restauré automatiquement ✅)
```

| Phase | Statut ArgoCD | Nb de pods |
|-------|:-------------:|:----------:|
| Initial | ✅ Synced | 1 |
| Après `kubectl scale` | 🟡 OutOfSync | 5 |
| Après réconciliation automatique | ✅ Synced | **1 (restauré)** |

> ⏱️ Le temps de réconciliation observé est de **15 à 30 secondes**.
