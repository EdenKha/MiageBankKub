#!/bin/bash
# Script de construction layer by layer avec Buildah natif pour MIAGE-Bank
set -e

echo "Création du conteneur de base (builder)..."
builder=$(buildah from eclipse-temurin:11-jre-alpine)
buildah copy $builder target/*.jar application.jar
buildah run $builder java -Djarmode=layertools -jar application.jar extract
buildah commit $builder miage-bank-builder

echo "Création du conteneur final..."
container=$(buildah from eclipse-temurin:11-jre-alpine)

echo "Ajout des layers de l'application..."
buildah run $container mkdir /app
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/dependencies/* /app/ || true'
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/snapshot-dependencies/* /app/ || true'
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/spring-boot-loader/* /app/ || true'
buildah run $container sh -c 'cp -r $(buildah mount miage-bank-builder)/application/* /app/ || true'

echo "Configuration système et sécurité..."
buildah copy $container startup.sh /startup.sh
buildah run $container chmod +x /startup.sh

buildah run $container wget -q -O /wait https://github.com/ufoscout/docker-compose-wait/releases/download/2.9.0/wait
buildah run $container chmod +x /wait

echo "Création de l'utilisateur non-root..."
buildah run $container addgroup -S appgroup
buildah run $container adduser -S appuser -G appgroup
buildah run $container chown -R appuser:appgroup /app /startup.sh /wait

echo "Configuration de l'environnement d'exécution..."
buildah config --user appuser $container
buildah config --workingdir /app $container
buildah config --entrypoint '["/bin/sh","-c","/startup.sh"]' $container

echo "Commit de l'image finale..."
buildah commit $container miage-bank:latest

echo "Nettoyage..."
buildah rm $container
buildah rmi miage-bank-builder

echo "Build terminé avec succès !"
