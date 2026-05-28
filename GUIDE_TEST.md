# Guide de Test Local - MIAGE-Bank KUB

Ce guide vous permet de vérifier pas à pas que tout ce que nous avons mis en place fonctionne correctement avant de soumettre votre Pull Request à votre professeur.

---

## 1. Tester la Partie A (La pipeline CI/CD)

Puisque vous êtes sous Windows, exécuter nativement Buildah, Trivy et Dive est complexe (nécessite WSL2 configuré spécifiquement). La façon la plus simple et la plus fiable de tester la Partie A est d'utiliser GitHub.

1. Créez un dépôt sur votre compte GitHub (ou forkez le dépôt du professeur si demandé).
2. Poussez l'intégralité du dossier actuel sur la branche `main`.
3. Allez dans l'onglet **Actions** de votre dépôt sur GitHub.
4. Vous devriez voir le workflow **"CI Pipeline MIAGE-Bank"** se lancer automatiquement.
5. Cliquez dessus pour vérifier que les étapes de build Maven, Hadolint, Buildah, Trivy et Dive passent au vert.
   - *Note : Les rapports Trivy et Dive seront téléchargeables dans la section "Artifacts" en bas du résumé du build sur GitHub.*

---

## 2. Tester la Partie B (Kubernetes & Helm)

### Pré-requis
- Docker Desktop (avec l'option Kubernetes activée) OU **Minikube**.
- Les outils en ligne de commande : `kubectl` et `helm`.

### Étape 2.1 : Validation du Chart Helm
Avant de déployer, assurez-vous que la syntaxe du Chart est parfaite :
```powershell
# Vérifier le formattage
helm lint ./miage-bank

# Prévisualiser les manifestes Kubernetes qui seront générés
helm template ./miage-bank
```

### Étape 2.2 : Lancement du cluster et déploiement manuel
Si vous utilisez Minikube, lancez-le en activant l'Ingress :
```powershell
minikube start
minikube addons enable ingress
```

1. **Créer le namespace** :
   ```powershell
   kubectl create namespace miage-bank
   ```
2. **Pré-requis Vault / ESO** :
   Assurez-vous d'avoir déployé Vault et External Secrets Operator sur votre cluster, et d'avoir injecté les secrets dans `secret/data/miage-bank/db`.
3. **Installer l'application via Helm** :
   ```powershell
   helm install miage-bank-release ./miage-bank -n miage-bank
   ```
4. **Vérifier que les pods démarrent** :
   ```powershell
   kubectl get pods -n miage-bank -w
   ```
   *(Vous devriez voir le pod se créer. S'il y a un CrashLoopBackOff, c'est normal si la base de données MySQL n'est pas déployée en face, mais le Helm aura prouvé qu'il fonctionne !)*

### Étape 2.3 : Tester le GitOps avec ArgoCD (Si ArgoCD est installé)

Si le professeur a demandé d'installer ArgoCD sur votre cluster local, voici comment tester la synchronisation :

1. **Installer ArgoCD sur votre Minikube** (si ce n'est pas déjà fait en cours) :
   ```powershell
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```
2. **⚠️ IMPORTANT : Modifier le fichier argocd-app.yaml**
   - Ouvrez `argocd-app.yaml`.
   - Modifiez la ligne `repoURL: 'https://github.com/votre-user/votre-repo.git'` avec l'URL de votre dépôt GitHub où vous avez poussé le code.
3. **Appliquer l'application ArgoCD** :
   ```powershell
   kubectl apply -f argocd-app.yaml
   ```
4. **Faire le test de Dérive (Drift)** :
   - Regardez les pods : `kubectl get pods -n miage-bank`. Il doit y en avoir 1.
   - Forcez la modification : `kubectl scale deployment miage-bank --replicas=5 -n miage-bank`
   - Patientez quelques secondes et refaites `kubectl get pods -n miage-bank`. Vous verrez qu'ArgoCD va automatiquement "tuer" les pods en trop pour revenir à 1, prouvant que le GitOps fonctionne !

---

## 3. Nettoyer votre environnement
Une fois les tests validés, vous pouvez tout désinstaller proprement pour laisser votre cluster propre :
```powershell
helm uninstall miage-bank-release -n miage-bank
kubectl delete namespace miage-bank
```
