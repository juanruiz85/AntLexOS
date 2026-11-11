# Manual de usuario — AntLex OS v0.3.0

Bienvenido a **AntLex OS**, un sistema operativo experimental que arranca
en modo gráfico desde el primer instante. Este manual cubre la versión
**0.3.0** (Fase 3: intérprete completo con historial, autocompletado y
reloj real). El escritorio con ventanas y la asistente **AntLex** llegan en
las Fases 4-5.

## 1. Requisitos

- Un PC con BIOS o UEFI (o QEMU/virtualizador) x86_64 y al menos 512 MiB de RAM.
- Teclado (español por defecto; se puede cambiar a US).

## 2. Arrancar

### 2.1 Con QEMU (recomendado para probar)

Descarga `antlexos-vX.Y.Z-x86_64.img` del
[release](https://github.com/juanruiz85/AntLexOS/releases) y ejecuta:

```bash
qemu-system-x86_64 -hda antlexos-vX.Y.Z-x86_64.img -m 512 -vga std
```

Deberías ver, en orden:

1. **Splash**: logo ANTLEX grande, eslogan y barra de progreso azul
   (dura ~2 segundos).
2. **Consola gráfica**: fondo azul oscuro con el mensaje de bienvenida y
   el símbolo del sistema `antlex:/> `.

Si algo falla, el sistema escribe el diagnóstico por el **puerto serie
COM1** (en QEMU: añade `-serial stdio` a la línea de arranque para verlo).

### 2.2 En hardware real (experimental)

Graba la imagen `.img` en un USB (**borra el USB entero**):

```bash
sudo dd if=antlexos-vX.Y.Z-x86_64.img of=/dev/sdX bs=4M status=progress
```

y arranca el PC desde el USB con BIOS legacy o UEFI. No instala nada: todo
corre desde el medio. *Advertencia: proyecto experimental; pruébalo en
hardware que no contenga datos importantes.*

## 3. Usar la consola (v0.3.0)

La consola tiene un intérprete real con **25 comandos** en español (y alias
en inglés). El símbolo del sistema muestra el directorio actual:
`antlex:/> ` (raíz) o `antlex:/ejemplos> ` (dentro de la carpeta).

Consejos rápidos: **↑/↓** recorren el historial, **TAB** autocompleta
comandos y nombres de archivo, **Ctrl+C** cancela la línea.

### 3.1 Comandos de archivos (ALFS)

| Comando (alias) | Qué hace | Ejemplo |
|---|---|---|
| `lista` (`ls`) | contenido de un directorio | `lista` · `lista /ejemplos` |
| `ir` (`cd`) | cambia de directorio | `ir ejemplos` · `ir ..` |
| `ruta` (`pwd`) | muestra el directorio actual | `ruta` |
| `mostrar` (`cat`) | muestra un archivo de texto | `mostrar LEEME.TXT` |
| `escribir` (`write`) | crea o sustituye un archivo | `escribir nota.txt hola mundo` |
| `anexar` (`append`) | añade texto al final | `anexar nota.txt segunda linea` |
| `nuevodir` (`mkdir`) | crea un directorio | `nuevodir fotos` |
| `borrar` (`rm`) | borra archivo o directorio vacío | `borrar nota.txt` |
| `copiar` (`cp`) | copia un archivo | `copiar nota.txt copia.txt` |
| `renombrar` (`mv`) | cambia el nombre de un archivo | `renombrar nota.txt lista.txt` |
| `buscar` (`find`) | busca archivos por nombre (recursivo) | `buscar nota` · `buscar txt /ejemplos` |
| `espacio` (`df`) | espacio libre del volumen | `espacio` |
| `sincronizar` (`sync`) | guarda los cambios en el disco | `sincronizar` |

### 3.2 Comandos del sistema

| Comando (alias) | Qué hace |
|---|---|
| `ayuda` (`help`) | lista todos los comandos; `ayuda <cmd>` detalla uno |
| `ver` (`version`) | versión, memoria, teclado, disco, reloj y modo de arranque |
| `sistema` (`sysinfo`) | resumen gráfico con logo, CPU, memoria, pantalla, disco y encendido |
| `fecha` (`date`) | fecha del reloj de tiempo real, en texto largo e ISO (UTC) |
| `hora` (`time`) | hora actual (UTC) y tiempo de encendido |
| `historia` (`history`) | historial numerado de comandos (también con ↑/↓) |
| `pruebas` (`test`) | ejecuta las 12 autopruebas del sistema y las muestra en pantalla |
| `eco` (`echo`) | repite el texto que escribas |
| `limpiar` (`cls`) | borra la pantalla |
| `teclado es` / `teclado us` | cambia la distribución del teclado |
| `apagar` (`shutdown`) | sincroniza y apaga (en QEMU la ventana se cierra sola) |
| `reiniciar` (`reboot`) | sincroniza y reinicia la máquina |

### 3.3 Persistencia: importante

Los cambios en archivos viven en memoria hasta que ejecutas
**`sincronizar`**, que escribe el volumen ALFS completo al disco. Si apagas
o reinicias sin sincronizar, los cambios se pierden. Tras `sincronizar`,
tus archivos siguen ahí aunque apagues el equipo (comprobado
automáticamente en las pruebas del proyecto: el test reinicia la máquina y
verifica el archivo).

### 3.4 Reglas de los archivos y teclado

- Nombres de hasta 44 caracteres, sin espacios ni `/`. No se distinguen
  mayúsculas de minúsculas (`LEEME.TXT` = `leeme.txt`).
- Rutas absolutas (`/ejemplos/NOTA-1.TXT`) o relativas al directorio
  actual; `.` es el directorio actual y `..` el padre.
- Máximo 256 entradas (archivos + directorios) y 4 MiB por archivo.
- La distribución de teclado es **española** por defecto (ñ, acentos
  muertos, ¿¡); cambia a US con `teclado us`.

## 4. ¿Qué hace el sistema durante el arranque?

1. El **stage1** (sector de arranque) comprueba el BIOS y carga el stage2
   (en UEFI hace lo mismo el **bootloader EFI**).
2. El **stage2** lee el kernel del disco, activa el modo gráfico
   (1024×768, 16,7 millones de colores), consulta el mapa de memoria y
   prepara el modo largo de 64 bits.
3. El **kernel** inicializa sus tablas (GDT/IDT), el temporizador, el
   teclado y la pantalla, detecta el **disco ATA**, monta el volumen
   **ALFS**, ejecuta **12 autopruebas** (incluido el reloj) y muestra el
   splash.
4. Si alguna autoprueba fallara, verías `[FALLA]` en el diagnóstico serie
   y `ANTLEX BOOT CON ERRORES` en vez de `ANTLEX BOOT OK`.

## 5. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| Pantalla negra en QEMU | Falta `-vga std` | Añade `-vga std` |
| "error cargando stage2" | Imagen corrupta o BIOS muy antiguo sin int 13h LBA | Re-descarga la imagen; usa QEMU o PC posterior a ~1998 |
| No aparece `antlex:/>` | Fallo en autopruebas | Arranca con `-serial stdio` y revisa el volcado |
| "ALFS no esta montado" | Volumen corrupto o disco ausente | Ver el diagnóstico serie (`init: alfs`); volver a grabar la imagen |
| Teclas salen raras | Distribución no es | `teclado us` para cambiar a US |
| Cambios perdidos tras reiniciar | Falta `sincronizar` | Sincroniza antes de apagar |
| "no hay bloques contiguos" | Fragmentación | Borra archivos que no necesites y vuelve a intentar |

## 6. Atajos de teclado (v0.3.0)

| Tecla | Efecto |
|---|---|
| INTRO | Enviar la línea |
| Retroceso | Borrar carácter |
| **↑ / ↓** | Historial de comandos (conserva la línea en edición) |
| **TAB** | Autocompletar comando o nombre de archivo (lista opciones si hay varias) |
| Ctrl+C | Cancelar la línea actual |
| Mayús/Bloq Mayús | Mayúsculas (Bloq Mayús solo afecta letras) |
| ´ ` ¨ | Teclas muertas (siguiente vocal se acentúa) |

## 7. Novedades entre versiones

Consulta `CHANGELOG.md`. Cada versión publica su imagen en GitHub Releases
con sumas de verificación (`SHA256SUMS`). Novedades principales:

- **v0.3.0**: intérprete completo — historial con flechas, autocompletado
  con TAB, reloj de tiempo real (`fecha`/`hora`), `sistema`, `buscar`,
  `renombrar`, `pruebas` bajo demanda y `apagar`/`reiniciar` reales. La IA
  del sistema se llamará **AntLex** (Fase 4).
- **v0.2.0**: sistema de archivos propio **ALFS** con persistencia real,
  driver ATA, 16 comandos (archivos, ayuda, teclado…), protocolo de
  arranque v2 y volumen inicial con manuales dentro del propio sistema
  (`mostrar MANUAL-CONSOLA.TXT`).
- **v0.1.1**: bootloader UEFI propio (además del BIOS).
- **v0.1.0**: arranque gráfico completo y consola de demostración.
