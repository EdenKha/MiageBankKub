# Guide de Test Local - MIAGE-Bank KUB

Ce guide vous permet de vérifier pas à pas que l'architecture que j'ai mise en place fonctionne correctement sur votre poste.

---

## 1. Tester la Partie A (La pipeline CI/CD)

La pipeline de build (Buildah, Trivy, Dive) s'exécute automatiquement via GitHub Actions à chaque commit. 

1. Rendez-vous sur mon dépôt GitHub : [https://github.com/EdenKha/MiageBankKub](https://github.com/EdenKha/MiageBankKub)
2. Allez dans l'onglet **Actions**.
3. Cliquez sur le dernier run du workflow **"CI Pipeline MIAGE-Bank"**.
4. Vous pourrez vérifier que les étapes de build Maven, Hadolint, Buildah, Trivy et Dive sont toutes au vert.
   - *Note : Les rapports complets Trivy et Dive sont disponibles dans le dossier `build-reports/` du code source.*

---

## 2. Tester la Partie B (Kubernetes & Helm)

### Pré-requis
- Docker Desktop (avec l'option Kubernetes activée) OU **Minikube**.
- Les outils en ligne de commande : `kubectl` et `helm`.
- Avoir cloné ce dépôt en local sur votre machine.

### Étape 2.1 : Validation du Chart Helm
Placez-vous à la racine du projet et vérifiez la syntaxe du Chart :
```bash
# Vérifier le formattage
helm lint ./miage-bank

# Prévisualiser les manifestes Kubernetes qui seront générés
helm template ./miage-bank
```

### Étape 2.2 : Lancement du cluster et déploiement manuel
Si vous utilisez Minikube, lancez-le en activant l'Ingress :
```bash
minikube start
minikube addons enable ingress
```

1. **Créer le namespace** :
   ```bash
   kubectl create namespace miage-bank
   ```
2. **Pré-requis Vault / ESO** :
   Le projet utilise *External Secrets Operator* couplé à *Hashicorp Vault*. Assurez-vous d'avoir déployé Vault et ESO sur votre cluster, et d'avoir injecté des identifiants factices dans le chemin `secret/data/miage-bank/db` de Vault.
3. **Installer l'application via Helm** :
   ```bash
   helm install miage-bank-release ./miage-bank -n miage-bank
   ```
4. **Vérifier que les pods démarrent** :
   ```bash
   kubectl get pods -n miage-bank -w
   ```
   *(Vous devriez voir **DEUX** pods se créer : l'application Java et la base de données MySQL. L'application va s'y connecter et les deux pods afficheront le statut `Running 1/1` sans aucune erreur de type CrashLoopBackOff !)*

### Étape 2.3 : Tester le GitOps avec ArgoCD

Voici comment tester la synchronisation automatique GitOps :

1. **Installer ArgoCD sur votre Minikube** (si ce n'est pas déjà fait) :
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
2. **Appliquer l'application ArgoCD** :
   Le fichier `argocd-app.yaml` est déjà préconfiguré pour pointer sur mon dépôt GitHub.
   ```bash
   kubectl apply -f argocd-app.yaml
   ```
3. **Accéder à l'interface ArgoCD** :
   - Récupérez le mot de passe admin : `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
   - Faites un port-forward : `kubectl port-forward svc/argocd-server -n argocd 8080:443`
   - Connectez-vous sur `https://localhost:8080` (login: admin)
4. **Faire le test de Dérive (Drift)** :
   - Regardez les pods : `kubectl get pods -n miage-bank`. Il doit y en avoir 1.
   - Forcez une modification manuelle locale : `kubectl scale deployment miage-bank --replicas=5 -n miage-bank`
   - Patientez quelques secondes et refaites `kubectl get pods -n miage-bank` (ou regardez l'interface web d'ArgoCD). Vous verrez qu'ArgoCD va automatiquement "tuer" les pods en trop pour revenir à 1, prouvant que la réconciliation GitOps fonctionne à merveille !

---

## 3. Nettoyer l'environnement
Une fois les tests validés, vous pouvez tout désinstaller proprement pour laisser le cluster vierge :
```bash
helm uninstall miage-bank-release -n miage-bank
kubectl delete namespace miage-bank
```
