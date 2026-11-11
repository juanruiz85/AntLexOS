# Cómo contribuir — AntLex OS

¡Gracias por tu interés! AntLex OS es un proyecto educativo: un sistema
operativo desde cero en Zig. Cualquier aportación es bienvenida.

## Preparación

```bash
# dependencias: zig 0.14.1, nasm, qemu-system-x86_64, python3
zig build -Drelease=true   # construye zig-out/antlexos.img
zig build test             # pruebas unitarias en host
zig build probar           # arranque verificado en QEMU
python3 tools/auditar.py   # auditoría (secretos, TODO, versión)
```

## Reglas del proyecto

1. **Idioma**: código, comentarios y mensajes del sistema en español
   (identificadores técnicos en español o neutro). Comandos del sistema en
   español con alias en inglés.
2. **Sin dependencias externas en el kernel**: el kernel no enlaza contra
   librería C ni usa `std` en tiempo de ejecución; solo herramientas del
   host pueden usar `std` de Zig con libertad.
3. **Seguridad primero**: todo búfer con datos externos lleva límites
   explícitos. Si tocas manejadores de interrupción, recuerda
   `red_zone=false` y la convención del marco (`Marco` en `idt.zig`).
4. **Trazabilidad**: cada cambio que altere el comportamiento visible
   actualiza `CHANGELOG.md` y, si toca hardware, añade una fila a
   `docs/PRUEBAS.md` con la versión en la que se probó.
5. **Formato**: `zig fmt .` antes de commitear (CI lo exige).
6. **Commits**: mensajes en español, imperativo, con prefijo del área
   (`fase1:`, `alfs:`, `lex:`, `docs:` …).

## Flujo

1. Abre un issue describiendo el cambio (o comenta uno existente).
2. Rama `fase-<n>-<tema>` desde `main`.
3. PR pequeño y enfocado; CI debe pasar íntegro.
4. Una revisión (humano o agente de auditoría) antes del merge.
