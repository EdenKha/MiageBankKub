# Guide de Déploiement et Test Complet - MIAGE-Bank KUB

Ce guide vous explique de A à Z comment déployer l'intégralité des microservices MIAGE-Bank sur votre cluster Kubernetes local en utilisant l'approche GitOps avec ArgoCD, et comment tester les APIs.

---

## 1. Pré-requis

- **Minikube** (ou Docker Desktop K8s) installé et démarré.
- Outils **kubectl**, **helm**, et **git** installés.
- (Optionnel) Si les images ne sont pas sur un registre public, configurez votre terminal sur Minikube et buildez-les :

  ```bash
  eval $(minikube docker-env)
  ./build-all-images.sh
  ```

**Attention** : Ce projet utilise la classe Ingress `traefik`. Assurez-vous d'avoir Traefik installé sur votre cluster (installé par défaut sur k3d, mais nécessite l'activation de l'addon ingress approprié ou une installation Helm sur Minikube)
---

## 2. Pousser les derniers correctifs sur GitHub

⚠️ **ÉTAPE CRUCIALE POUR ARGOCD** ⚠️
Nous venons d'apporter plusieurs correctifs vitaux aux fichiers locaux du Chart Helm (correction du port de l'API Gateway, correction de l'URL MongoDB du CompteService, et enregistrement IP sur Eureka).
Puisque **ArgoCD va lire la configuration directement depuis GitHub**, vous devez absolument commiter et pousser ces changements sur votre dépôt distant avant de continuer :

```bash
git add miage-bank/templates/
git commit -m "Fix: Configuration MongoDB, API Gateway targetPort et Eureka IP registration"
git push origin main
```

---

## 3. Configuration de Vault (Gestion des Secrets)

L'application utilise Hashicorp Vault et External Secrets Operator (ESO) pour sécuriser les identifiants de bases de données.

1. **Installer Vault en mode Dev** :

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault --set "server.dev.enabled=true" --set "server.dev.devRootToken=root" -n default
```

1. **Installer ESO** :

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --set installCRDs=true
```

1. **Injecter les secrets factices dans Vault** :
*(Patientez que le pod `vault-0` soit prêt, environ 30s)*

```bash
kubectl exec -it vault-0 -n default -- vault kv put secret/miage-bank/db username="dummy-user" password="dummy-password"
```

---

## 4. Déploiement GitOps avec ArgoCD

Nous allons déployer l'application automatiquement depuis GitHub grâce à ArgoCD.

1. **Installer ArgoCD sur le cluster** :

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

1. **Préparer le terrain (Namespace et Jeton Vault)** :

```bash
kubectl create namespace miage-bank
kubectl create secret generic vault-token --from-literal=token=root -n miage-bank
```

1. **Déployer l'application MIAGE-Bank via ArgoCD** :

```bash
kubectl apply -f argocd-app.yaml
```

*ArgoCD va automatiquement synchroniser le dossier `miage-bank` depuis GitHub et déployer toutes les ressources !*

1. **Accéder à l'interface Web ArgoCD (Optionnel mais recommandé)** :
Pour visualiser l'arbre de vos déploiements en temps réel :

- **Lancer le port-forward** :

  ```bash
  kubectl port-forward svc/argocd-server -n argocd 8080:443
  ```

- **Récupérer le mot de passe admin** :

  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

- Allez sur [https://localhost:8080](https://localhost:8080) (acceptez l'avertissement de sécurité). Connectez-vous avec l'identifiant `admin` et le mot de passe récupéré ci-dessus.

**Surveillez le démarrage des pods :**

```bash
kubectl get pods -n miage-bank -w
```

*(Le démarrage complet prend environ 1 à 2 minutes. Les bases de données, ConfigServer et Annuaire démarrent en premier, suivis des autres microservices).*

---

## 5. Tests des APIs (Postman ou PowerShell)

Une fois que **tous les pods sont au statut `Running`**, vous pouvez tester votre cluster métier !

1. **Ouvrir l'accès à l'API Gateway** :
L'API Gateway centralise les appels vers tous les autres microservices.

```bash
kubectl port-forward svc/bnkapigateway 10000:10000 -n miage-bank
```

*(En cas d'erreur "address already in use", relancez la commande avec un autre port local, par exemple `10002:10000`)*.

1. **Tester avec Postman (ou cURL/PowerShell)** sur `http://localhost:10000` :

**A. ClientService (`/api/clients`)**

- **Créer un client (POST)**
  *URL* : `http://localhost:10000/api/clients`
  *Body (JSON)* : `{"id": 1, "nom": "Dupont", "prenom": "Jean"}`
- **Lister les clients (GET)**
  *URL* : `http://localhost:10000/api/clients`

**B. CompteService (`/api/comptes`)**

- **Créer/Consulter un compte**
  *URL* : `http://localhost:10000/api/comptes`
  *(Utilisez les payloads JSON correspondants à votre entité Compte)*

**C. CompositeService (`/api/clientscomptes`)**

- **Récupérer la synthèse Client + Comptes (GET)**
  *URL* : `http://localhost:10000/api/clientscomptes/1` *(où 1 est l'id du client)*

---

## 6. Visualiser le Tableau de Bord Eureka (Bonus)

Si vous souhaitez voir comment les microservices s'enregistrent dynamiquement :
Ouvrez un *autre* terminal et lancez :

```bash
kubectl port-forward svc/bnkannuaire 10001:10001 -n miage-bank
```

Allez sur **<http://localhost:10001>** dans votre navigateur pour voir le registre Spring Eureka en temps réel !

---

## 7. Nettoyage Complet de l'Environnement

Pour détruire proprement toute la stack de test et libérer les ressources de votre ordinateur :

1. **Arrêter les accès (Port-forwards)** :
Dans chaque terminal où tourne une commande `kubectl port-forward`, appuyez sur `Ctrl + C`.

2. **Supprimer l'application sur ArgoCD** :

```bash
kubectl delete application miage-bank -n argocd
```

*(ArgoCD s'assurera de nettoyer tous les microservices et pods qu'il a déployés).*

1. **Mettre en pause Minikube** :

```bash
minikube stop
```

*(Ceci suspendra la machine virtuelle Kubernetes sans perdre la configuration (ArgoCD, Vault) pour votre prochaine session !)*
