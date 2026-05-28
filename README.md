# Hugues Ansoborlo - TP KUB DevOps MIAGE-Bank

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

---

## Partie B - Déploiement Kubernetes & GitOps avec ArgoCD

### 1. Architecture Helm
Le Chart Helm `miage-bank` package l'application MIAGE-Bank pour Kubernetes. Il déploie un `Deployment` configuré avec des liveness/readiness probes, un `Service` de type ClusterIP, et un `Ingress` pour Traefik.
Les privilèges sont limités via un `ServiceAccount` dédié, une `NetworkPolicy` en "default-deny" (n'autorisant que le trafic depuis l'Ingress), et des règles `RBAC` (Role/RoleBinding) strictes.

### 2. Gestion des Secrets
Afin d'éviter de stocker les informations sensibles en clair dans le Git (ou dans le values.yaml), nous utilisons un Kubernetes Secret natif défini en dehors du Chart.
Pour l'appliquer sur le cluster (avant le déploiement ArgoCD) :
```bash
kubectl apply -f db-secret.yaml
```

### 3. GitOps ArgoCD - Démonstration de la Dérive
Le manifeste `argocd-app.yaml` définit le déploiement continu du Chart Helm sur le namespace `miage-bank`.

**Démonstration du test de dérive (Drift) :**
1. Une fois l'application synchronisée via ArgoCD (statut *Healthy/Synced*), augmentez artificiellement le nombre de réplicas via la commande imperative :
   `kubectl scale deployment miage-bank --replicas=5 -n miage-bank`
2. Dans l'interface ArgoCD, l'application basculera presque immédiatement en statut **OutOfSync** (dérive détectée).
3. Étant donné que nous avons configuré `selfHeal: true` dans la `syncPolicy` de l'application, ArgoCD déclenche une réconciliation automatique. Il annule notre modification manuelle et restaure le nombre de pods défini dans Git. Le statut repasse en **Synced**.
