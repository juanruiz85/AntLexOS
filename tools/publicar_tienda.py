#!/usr/bin/env python3
"""AntLex OS — publica la tienda de aplicaciones (fase 9b).

Crea (si no existe) el repo juanruiz85/AntLexApps y sube el INDICE y
las apps .ALX de zig-out/apps con sus sha256 reales. El kernel las
consume con `tienda` y `descargar <nombre>` sobre TLS 1.3.

Uso:  python3 tools/publicar_tienda.py [--repo AntLexApps]
"""
import argparse
import base64
import hashlib
import json
import os
import sys
import urllib.request

TOKEN = open("/home/z/my-project/.token").read().strip()
USUARIO = "juanruiz85"
API = "https://api.github.com"

DESCRIPCIONES = {
    "CALC": "calculadora con IA (suma y resta por lenguaje natural)",
    "RELOJ": "reloj analogico y digital en el escritorio",
}


def api(metodo, ruta, cuerpo=None):
    req = urllib.request.Request(
        API + ruta,
        data=json.dumps(cuerpo).encode() if cuerpo else None,
        method=metodo,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "AntLexOS-tienda",
        })
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read()
            return r.status, json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def subir_archivo(repo, ruta, datos, mensaje):
    """PUT del archivo (con sha si ya existía para actualizar)."""
    _, act = api("GET", f"/repos/{USUARIO}/{repo}/contents/{ruta}"
                 f"?ref=main")
    sha = act.get("sha")
    cuerpo = {
        "message": mensaje,
        "content": base64.b64encode(datos).decode(),
        "branch": "main",
    }
    if sha:
        cuerpo["sha"] = sha
    cod, resp = api("PUT", f"/repos/{USUARIO}/{repo}/contents/{ruta}", cuerpo)
    if cod not in (200, 201):
        print(f"FALLA al subir {ruta}: {cod} {resp.get('message', '')}")
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="AntLexApps")
    args = ap.parse_args()
    repo = args.repo

    repo_dir = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "zig-out", "apps")
    if not os.path.isdir(repo_dir):
        print("FALLA: no existe zig-out/apps (ejecuta zig build antes)")
        return 1

    # 1) crear el repo si no existe
    cod, _ = api("GET", f"/repos/{USUARIO}/{repo}")
    if cod == 404:
        cod2, resp = api("POST", "/user/repos", {
            "name": repo,
            "description": "Tienda de aplicaciones de AntLex OS "
                           "(indice: nombre|archivo|bytes|sha256|descripcion)",
            "private": False,
            "auto_init": True,
        })
        if cod2 not in (201,):
            print(f"FALLA al crear el repo: {cod2} {resp.get('message', '')}")
            return 1
        print(f"repo {USUARIO}/{repo} creado")
    else:
        print(f"repo {USUARIO}/{repo} ya existe")

    # 2) INDICE con los .ALX reales de la build
    indice = ""
    subidos = 0
    for nombre_archivo in sorted(os.listdir(repo_dir)):
        if not nombre_archivo.endswith(".ALX"):
            continue
        nombre = nombre_archivo[:-4]
        datos = open(os.path.join(repo_dir, nombre_archivo), "rb").read()
        sha = hashlib.sha256(datos).hexdigest()
        desc = DESCRIPCIONES.get(nombre, "aplicacion de AntLex OS")
        indice += f"{nombre}|APPS/{nombre_archivo}|{len(datos)}|{sha}|{desc}\n"
        print(f"  {nombre}: {len(datos)} bytes, sha256 {sha[:16]}…")
        if subir_archivo(repo, f"APPS/{nombre_archivo}", datos,
                         f"app: {nombre} ({len(datos)} bytes)"):
            subidos += 1

    if not indice:
        print("FALLA: no hay archivos .ALX en zig-out/apps")
        return 1

    if not subir_archivo(repo, "INDICE", indice.encode(),
                         "indice de la tienda (autogenerado)"):
        return 1
    print(f"INDICE subido ({len(indice.splitlines())} apps, {subidos} .ALX)")
    print(f"ver: https://raw.githubusercontent.com/{USUARIO}/{repo}/main/INDICE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
