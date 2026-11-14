# AntLex OS — Informe de la Fase 4 (v0.4.0): IA embebida AntLex

**Fecha**: 2026-11-13 · **Repositorio**: https://github.com/juanruiz85/AntLexOS
**Release**: https://github.com/juanruiz85/AntLexOS/releases/tag/v0.4.0
**Commits**: `918496b` (Fase 4) · `126fddc` (v0.4.0) · `76fbddd`+`ba198ed`
(registro CI y limpieza) — todos bajo `juanruiz85`.

## Qué se ha construido

AntLex —la IA del sistema, con su misma identidad— ya vive DENTRO del kernel:

1. **Red neuronal entrenada al compilar**: bolsa de palabras → 16 neuronas
   ocultas (ReLU) → 24 intenciones (softmax). `tools/entrenar_antlex.zig`
   entrena en el host con SGD plano determinista (LCG de semilla fija) y
   **para por margen**: todo el corpus debe clasificar con ≥85% de confianza
   usando la red YA cuantizada (la que se embarca). Los pesos se generan en
   `src/kernel/antlex/pesos.zig` (commiteado y reproducible:
   `zig build entrenar-verificar` lo comprueba en CI).

2. **Inferencia 100% entera, sin FPU**: el kernel no activa la FPU, así que
   todo es punto fijo — pesos Q4.11 (i16), activaciones Q16.16 (i32/i64 con
   clamp), y softmax con una LUT `exp2` calculada en comptime.

3. **Solo sabe del sistema (a propósito)**: corpus español de 161 ejemplos
   en 24 intenciones (memoria, CPU, pantalla, disco, ALFS, espacio, fecha,
   hora, uptime, comandos, teclado, arranque, licencia, versión, identidad,
   autor, archivos, sincronizar, apagar, reiniciar…). Las respuestas usan
   **datos en vivo** del hardware (CPUID, mapa E820, framebuffer, ATA,
   bloques libres de ALFS, reloj RTC, uptime, modo BIOS/UEFI).

4. **Doble regla de rechazo (falla cerrado)**: para aceptar una pregunta
   exige confianza ≥75% Y que más de la mitad de sus palabras estén en el
   vocabulario. Los 8 adversariales del corpus ("la capital de Francia",
   "una tarta de queso"…) se rechazan educadamente.

5. **Memoria aprendida persistente**: `antlex aprende <clave> = <respuesta>`
   guarda hasta 64 pares en `/memoria/antlex.txt` (ALFS). El cotejo usa la
   forma canónica (sin mayúsculas/acentos/palabras vacías): "¿Cuál es tu
   color favorito?" casa con la clave "color favorito". `antlex memoria`
   lista, `antlex olvida` borra, y con `sincronizar`/`apagar` sobrevive a
   reinicios (verificado por arnés).

6. **Explicabilidad**: `antlex por que` desglosa la última respuesta —
   tokens reconocidos, cobertura, intención con confianza y umbral, segunda
   opción y los aportes gradiente×entrada de cada palabra; o la clave
   aprendida que coincidió; o el motivo exacto del rechazo.

## Pruebas (todas en verde)

| Batería | Resultado |
|---|---|
| Pruebas host (`zig build test`) | **32/32** (núcleo de la IA, corpus 100% con inferencia de punto fijo, canon 12/12, adversariales 8/8, coherencia de pesos) |
| Autopruebas del kernel (BIOS y UEFI) | **13/13** (la 13ª, `antlex_canonica`, clasifica 12 preguntas canónicas en cada arranque) |
| Arnés `probar_antlex.py` (conversación real por QMP, teclado español) | **24/24**: intenciones en vivo, aprende→pregunta→persiste→lista→olvida, "por qué" en sus tres modos, dos rechazos, apagado ACPI real |
| Regresiones | BIOS, UEFI (OVMF), persistencia ALFS (reinicio verificado), arnés del intérprete 22 pasos, `zig fmt --check`, auditoría sin hallazgos |
| CI GitHub (main y tag v0.4.0) | **SUCCESS** (incluye `entrenar-verificar`: los pesos commiteados son reproducibles) |
| Release v0.4.0 | **Publicado**: imagen x86_64 (29 MiB), src.tar.gz, NOTAS.md, SHA256SUMS |

## Auditoría de seguridad (REV-FASE4)

Registrada en `docs/revision_seguridad.md`: 8 hallazgos corregidos durante
la fase — los más relevantes: cotejo de memoria aprendida por forma
canónica (S1), formato Q4.11 para que la cuantización no destruya la red
(S3), bug de signo en la LUT exp2 (S4), normalización UTF-8+Latin-1 (S5) y
regla de cobertura contra falsos positivos (S7) — más 3 informativos.

## Cómo probarla

```
qemu-system-x86_64 -hda antlexos-v0.4.0-x86_64.img -m 512 -vga std
```
Dentro del sistema (teclado español):
```
antlex quien eres
antlex cuanta memoria tienes
antlex que es alfs
antlex aprende mi color favorito = azul
antlex cual es mi color favorito
antlex por que
```
La captura `antlex-v0.4.0-conversacion.png` muestra esa misma conversación.

## Siguiente fase

**Fase 5 (v0.5.0): escritorio con ventanas** — ratón PS/2, escritorio
dividido terminal|chat de AntLex, barra de tareas y ventanas flotantes
(explorador, editor). Ver `TODO.md` y `docs/RESUMEN_PROYECTO.md` (con las
9 lecciones de la Fase 4 para quien continúe).
