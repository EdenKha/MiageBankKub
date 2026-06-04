#!/bin/bash
# Script de construction layer by layer avec Buildah natif pour MIAGE-Bank
# Équivalent fonctionnel du Containerfile, sans fichier de description.
set -e

echo "=== Étape 1 : Création du conteneur builder ==="
builder=$(buildah from eclipse-temurin:11-jre-alpine)
buildah config --workingdir / $builder
buildah copy $builder target/*.jar /application.jar
buildah run $builder -- java -Djarmode=layertools -jar /application.jar extract

echo "=== Étape 2 : Création du conteneur final ==="
container=$(buildah from eclipse-temurin:11-jre-alpine)
buildah run $container -- mkdir -p /app

echo "=== Étape 3 : Copie des layers depuis le builder (via mount hôte) ==="
# On monte le système de fichiers du builder sur l'hôte,
# puis on utilise buildah copy pour transférer les fichiers vers le conteneur cible.
mnt=$(buildah mount $builder)
buildah copy $container "$mnt/dependencies/"          /app/ || true
buildah copy $container "$mnt/snapshot-dependencies/" /app/ || true
buildah copy $container "$mnt/spring-boot-loader/"    /app/ || true
buildah copy $container "$mnt/application/"           /app/ || true
buildah umount $builder

echo "=== Étape 4 : Configuration système et sécurité ==="
buildah copy $container startup.sh /startup.sh
buildah run $container -- chmod +x /startup.sh

buildah run $container -- wget -q -O /wait https://github.com/ufoscout/docker-compose-wait/releases/download/2.9.0/wait
buildah run $container -- chmod +x /wait

echo "=== Étape 5 : Création de l'utilisateur non-root ==="
buildah run $container -- addgroup -S appgroup
buildah run $container -- adduser -S appuser -G appgroup
buildah run $container -- chown -R appuser:appgroup /app /startup.sh /wait

echo "=== Étape 6 : Configuration de l'environnement d'exécution ==="
buildah config --user appuser $container
buildah config --workingdir /app $container
buildah config --port 8081 $container
buildah config --entrypoint '["/bin/sh","-c","/startup.sh"]' $container

echo "=== Étape 7 : Commit de l'image finale ==="
buildah commit $container miage-bank:latest

echo "=== Nettoyage ==="
buildah rm $container $builder

echo "Build natif terminé avec succès !"
