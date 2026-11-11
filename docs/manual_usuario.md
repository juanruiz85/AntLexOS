# Manual de usuario — AntLex OS v0.1.0

Bienvenido a **AntLex OS**, un sistema operativo experimental que arranca
en modo gráfico desde el primer instante. Este manual cubre la versión
**0.1.0** (Fase 1: arranque y consola). Los comandos completos llegan en la
Fase 3 y el escritorio con ventanas y la asistente LEX en las Fases 4-5.

## 1. Requisitos

- Un PC con BIOS (o QEMU/virtualizador) x86_64 y al menos 512 MiB de RAM.
- Teclado (español por defecto; se puede cambiar a US).

## 2. Arrancar

### 2.1 Con QEMU (recomendado para probar)

Descarga `antlexos-vX.Y.X-x86_64.img` del
[release](https://github.com/juanruiz85/AntLexOS/releases) y ejecuta:

```bash
qemu-system-x86_64 -hda antlexos-v0.1.0-x86_64.img -m 512 -vga std
```

Deberías ver, en orden:

1. **Splash**: logo ANTLEX grande, eslogan y barra de progreso azul
   (dura ~2 segundos).
2. **Consola gráfica**: fondo azul oscuro con el mensaje de bienvenida y
   el símbolo del sistema `antlex> `.

Si algo falla, el sistema escribe el diagnóstico por el **puerto serie
COM1** (en QEMU: añade `-serial stdio` a la línea de arranque para verlo).

### 2.2 En hardware real (experimental)

Graba la imagen `.img` en un USB (**borra el USB entero**):

```bash
sudo dd if=antlexos-v0.1.0-x86_64.img of=/dev/sdX bs=4M status=progress
```

y arranca el PC desde el USB con BIOS legacy. No instala nada: todo corre
desde el medio. *Advertencia: proyecto experimental; pruébalo en hardware
que no contenga datos importantes.*

## 3. Usar la consola (v0.1.0)

En esta versión la consola es de demostración:

- Escribe con el teclado y pulsa **INTRO**: el sistema responde
  `RECIBIDO: "..." (N bytes)`.
- **Retroceso** borra el último carácter.
- La distribución es **española**: `ñ` está en su tecla, los acentos son
  teclas muertas (´ + a = á), `¿` y `¡` funcionan.
- El intérprete de comandos real (`lista`, `mostrar`, `lex`, …) llega en
  la Fase 3.

### 3.1 Cambiar a teclado US

A partir de la Fase 3 existirá el comando `teclado us`. En v0.1.0 la
distribución es siempre española.

## 4. ¿Qué hace el sistema durante el arranque?

1. El **stage1** (sector de arranque) comprueba el BIOS y carga el stage2.
2. El **stage2** lee el kernel del disco, activa el modo gráfico
   (1024×768, 16,7 millones de colores), consulta el mapa de memoria y
   prepara el modo largo de 64 bits.
3. El **kernel** inicializa sus tablas (GDT/IDT), el temporizador, el
   teclado y la pantalla, ejecuta **8 autopruebas** y muestra el splash.
4. Si alguna autoprueba fallara, verías `[FALLA]` en el diagnóstico serie
   y `ANTLEX BOOT CON ERRORES` en vez de `ANTLEX BOOT OK`.

## 5. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Pantalla negra en QEMU | Falta `-vga std` | Añade `-vga std` |
| "error cargando stage2" | Imagen corrupta o BIOS muy antiguo sin int 13h LBA | Re-descarga la imagen; usa QEMU o PC posterior a ~1998 |
| No aparece `antlex>` | Fallo en autopruebas | Arranca con `-serial stdio` y revisa el volcado |
| Teclas salen raras | Distribución no es | v0.1.0 es siempre ES; espera el comando `teclado` (Fase 3) |

## 6. Atajos de teclado (v0.1.0)

| Tecla | Efecto |
|---|---|
| INTRO | Enviar la línea |
| Retroceso | Borrar carácter |
| Mayús/Bloq Mayús | Mayúsculas (Bloq Mayús solo afecta letras) |
| ´ ` ¨ | Teclas muertas (siguiente vocal se acentúa) |

## 7. Novedades entre versiones

Consulta `CHANGELOG.md`. Cada versión publica su imagen en GitHub Releases
con sumas de verificación (`SHA256SUMS`).
