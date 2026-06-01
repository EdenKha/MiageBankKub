# Self-contained build script for Windows PowerShell
Write-Host "Building all Miage-Bank microservices..." -ForegroundColor Cyan

# Set directory to the script folder
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = $PSScriptRoot
}
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Get-Location
}

cd "$ScriptDir\BanqueMSSol"

Write-Host "=== Compilation via Maven (dans Docker) ===" -ForegroundColor Cyan
# On convertit le chemin local au format compatible avec Docker sous Windows
$LocalPath = (Get-Item .).FullName
docker run --rm -v "${LocalPath}:/usr/src/app" -w /usr/src/app maven:3.8.4-openjdk-11-slim mvn clean package -DskipTests

Write-Host "=== Build Docker : banque-annuaire ===" -ForegroundColor Cyan
docker build -t banque-annuaire:7.0 ./Banque-Annuaire

Write-Host "=== Build Docker : banque-configsrv ===" -ForegroundColor Cyan
docker build -t banque-configsrv:7.0 ./Banque-ConfigServer

Write-Host "=== Build Docker : banque-clientservice ===" -ForegroundColor Cyan
docker build -t banque-clientservice:7.0 ./Banque-ClientService

Write-Host "=== Build Docker : banque-compteservice ===" -ForegroundColor Cyan
docker build -t banque-compteservice:7.0 ./Banque-CompteService

Write-Host "=== Build Docker : banque-compositeservice ===" -ForegroundColor Cyan
docker build -t banque-compositeservice:7.0 ./Banque-CompositeService

Write-Host "=== Build Docker : banque-apigateway ===" -ForegroundColor Cyan
docker build -t banque-apigateway:7.0 ./Banque-APIGateway

Write-Host "`nBuild terminé avec succès ! Les images sont disponibles localement." -ForegroundColor Green
Write-Host "Vous pouvez maintenant les utiliser avec Minikube ou Docker Desktop." -ForegroundColor Green
