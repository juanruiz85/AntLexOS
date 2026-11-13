#!/bin/sh
# AntLex OS — configura la identidad de git para commits del proyecto.
# Convención (ver CONTRIBUTING.md): commits bajo el usuario juanruiz85.
# Úsalo tras clonar el repositorio en una máquina o entorno nuevo:
#   sh tools/configurar_identidad.sh
set -e
cd "$(dirname "$0")/.."
git config user.name "juanruiz85"
git config user.email "juanruiz85@users.noreply.github.com"
echo "identidad de commits: $(git config user.name) <$(git config user.email)>"
