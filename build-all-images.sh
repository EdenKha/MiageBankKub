#!/bin/bash
set -e

echo "Building all Miage-Bank microservices..."

# On s'assure d'être à la racine du projet
cd "$(dirname "$0")/BanqueMSSol"

echo "=== Compilation via Maven ==="
mvn clean package -DskipTests

echo "=== Build Docker : banque-annuaire ==="
docker build -t banque-annuaire:7.0 ./Banque-Annuaire

echo "=== Build Docker : banque-configsrv ==="
docker build -t banque-configsrv:7.0 ./Banque-ConfigServer

echo "=== Build Docker : banque-clientservice ==="
docker build -t banque-clientservice:7.0 ./Banque-ClientService

echo "=== Build Docker : banque-compteservice ==="
docker build -t banque-compteservice:7.0 ./Banque-CompteService

echo "=== Build Docker : banque-compositeservice ==="
docker build -t banque-compositeservice:7.0 ./Banque-CompositeService

echo "=== Build Docker : banque-apigateway ==="
docker build -t banque-apigateway:7.0 ./Banque-APIGateway

echo "Build terminé avec succès ! Les images sont disponibles localement."
echo "Vous pouvez maintenant les utiliser avec Minikube ou Docker Desktop."
