#!/bin/sh
# Copia el modelo junto al Dockerfile (Docker solo ve archivos de esta carpeta).
set -e
cd "$(dirname "$0")"
mkdir -p modelos
cp ../modelos/best.pt modelos/best.pt
[ -f .env ] || { cp .env.example .env; echo "Creado .env: completa la clave y el dominio antes de seguir."; }
echo "Listo. Ahora: docker compose up -d --build"
