# Política de seguridad — AntLex OS

## Versiones compatibles

AntLex OS es software experimental en desarrollo; se corrige únicamente la
última versión publicada.

## Cómo reportar una vulnerabilidad

Abre un *issue* privado en GitHub (Security Advisories) o un issue normal
marcado `[seguridad]` si no permite datos sensibles. Se responde en menos de
72 horas. Las vulnerabilidad aceptadas se corrigen, se documentan en
`docs/revision_seguridad.md` y aparecen en el CHANGELOG de la versión que
las corrige.

## Modelo de amenazas (honesto)

- **Sin red**: no hay pila de red; la superficie de ataque es el medio de
  arranque (imagen de disco), el teclado físico y (en fases futuras) los
  archivos del volumen ALFS.
- El bootloader confía en el disco que lo contiene (como cualquier MBR);
  el kernel **valida** el `boot_info` recibido (magia, límites del mapa de
  memoria, geometría del framebuffer) para no depender ciegamente del
  cargador.
- Todo buffer con entrada externa (búfer de teclado, consola, cabeceras de
  disco en mkimage) tiene límites explícitos.
- No hay secretos en el sistema operativo ni en el repositorio; el escáner
  `tools/auditar.py` se ejecuta en cada push de CI.

## Prácticas de desarrollo

- Revisión/auditoría registrada por fase (`docs/revision_seguridad.md`).
- `zig fmt --check` + pruebas unitarias + arranque verificado en QEMU en
  cada push; nada llega a un tag sin pasar CI.
- Zig en modo ReleaseSafe para el kernel (comprobaciones en tiempo de
  ejecución activas).
