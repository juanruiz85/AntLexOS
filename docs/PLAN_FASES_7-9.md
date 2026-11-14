# Plan de Fases 7–9 — Ejecutables, escritorio y tienda de aplicaciones

> **Este documento es el registro duradero del plan.** Vive en el repositorio
> (GitHub) para que sobreviva a cualquier reciclado del entorno de trabajo: es
> la fuente única de verdad del "qué falta" y del "qué ya está hecho".
> Cada hito completado se marca aquí con su commit, se registra en
> `docs/PRUEBAS.md` y se sincroniza con GitHub (commits como `juanruiz85`).
>
> Regla de trabajo acordada con el propietario: **push en cada hito**,
> identidad `juanruiz85`, nada de lo que se haga puede depender de patentes
> de terceros (ver §0).

| Fase | Qué | Versión | Estado |
|------|-----|---------|--------|
| 7 | Ejecutables `.ALX`: bit de ejecutable, asociaciones por extensión, loader y primeras apps | v1.2.0 | 🔨 en curso |
| 8 | Escritorio estilo Windows 3.11: iconos, minimizar a icono, Program Manager, relieve 3D | v1.3.0 | ⏳ planificada |
| 9 | Red: driver virtio-net, TCP, TLS 1.3, HTTP, comando `descargar` y tienda de apps en GitHub | v1.4.0 | ⏳ planificada |

---

## 0. Restricción de patentes (aplica a TODO el plan)

Nada de lo implementado puede usar tecnología bajo patentes sin licencia
libre. Decisiones tomadas por eso:

| Pieza | Elección | Por qué es segura |
|---|---|---|
| Formato ejecutable | `.ALX`, diseño propio (cabecera+imagen plana) | Formato original del proyecto, sin patente |
| Bit de ejecutable / asociaciones | Ideas de SO de hace décadas (bit exec de UNIX, asociaciones de extensiones) | Abundante arte previo, no patentable en la práctica |
| Estética del escritorio | Estilo Windows 3.11 *reinterpretado* con código y gráficos propios | No se copia código ni recursos de Microsoft; las ideas de interacción (minimizar a icono, grupos de programas) son funcionales y llevan décadas reimplementadas |
| Red (Fase 9) | **virtio-net** (estándar abierto OASIS, especificación BSD) | Paravirtual, simple y explícitamente libre |
| Cripto (Fase 9) | TLS 1.3 (RFC 8446) con X25519 (RFC 7748), ChaCha20-Poly1305 (RFC 8439) o AES-GCM, SHA-256/HKDF | Todos son IETF con criptografía diseñada/liberada sin regalías (X25519 y ChaCha20 son de dominio público por diseño) |
| HTTP (Fase 9) | HTTP/1.1 (RFC 9112) | Estándar abierto de texto plano |

Lo que NO se usa: nada de GRUB/Limine (ya era así), ninguna librería
propietaria, ningún códec ni algoritmo con licencia onerosa.

---

## Fase 7 (v1.2.0) — Ejecutables `.ALX`

**Objetivo**: el sistema puede abrir aplicaciones desde disco, con bit de
ejecutable y asociaciones por extensión, sin romper nada de lo existente.

### Diseño

**Formato `.ALX`** (nuestro, documentado en `docs/manual_tecnico.md`):

```
offset 0    "ALX1" (magic)          offset 20   nombre[16] ("CALC", "RELOJ"…)
offset 4    u16 version (=1)        offset 36   reservado[28] = 0
offset 6    u16 flags (=0)          offset 64   imagen (código+datos,
offset 8    u32 bss_len                         enlazada en 16 MiB)
offset 12   u32 entry_off (de alx_evento)
offset 16   u32 image_len
```

**Modelo de ejecución** (cooperativo, sin anillo 3 todavía — documentado):
- La app exporta `alx_evento(api: *Api, ev: *Evento)` con ABI C.
- Eventos: `EV_INIT` (definir título/tamaño), `EV_TECLA`, `EV_DIBUJAR`
  (pintar su área de cliente), `EV_TICK` (≈1 Hz, para relojes), `EV_CERRAR`.
- La `Api` (tabla de funciones del kernel, misma fuente de verdad en
  `src/kernel/alx_def.zig` compartida con las apps): `texto`, `rect`,
  `bisel` (relieve 3D simple), `tam` (tamaño de ventana, solo en init),
  `titulo`, `tics`, `hora`, `consola` (imprime en consola+serial),
  `leer`/`escribir` archivos de ALFS (rutas como `/NOTAS.TXT`).
- La app se carga en la región fija de 16 MiB (identidad 4 GiB ya mapeada
  por stage2; el kernel acaba antes de 4 MiB y el heap empieza en 32 MiB):
  una app externa a la vez (v1), imagen ≤ 256 KiB, región de 1 MiB.
- Sin aislamiento: la app corre en ring 0 como todo el sistema; una app
  maliciña o defectuosa puede colgar el sistema. Riesgo registrado en la
  auditoría REV de la fase; el aislamiento (ring 3 + syscalls) es trabajo
  futuro. Por eso `instalar` (poner el bit) es explícito y manual.

**Bit de ejecutable en ALFS**: la entrada de directorio ya tenía un byte
`flags` reservado (siempre 0) → bit `0x01` = ejecutable. Retrocompatible:
volúmenes v1.1.0 leen sin cambios (flags 0 = no ejecutable).

**Asociaciones por extensión** (tabla en el kernel, consultable/modificable
con `asociar`): por defecto `TXT → editor`, `ALX → ejecutar`. El comando
`abrir <archivo>` y el doble clic del explorador usan la tabla.

**Comandos nuevos** (alias inglés): `ejecutar/run` (exige bit + `.ALX`),
`instalar/install` (pone el bit), `abrir/open` (asociaciones),
`asociar/assoc <ext> <editor|ejecutar|mostrar>`, `atributos/attrib`
(muestra tipo, tamaño y bit).

**Apps de la fase** (compiladas como ELF freestanding en 16 MiB y
convertidas con `tools/mkalx.zig` — el mismo flujo usará la tienda):
1. **Calculadora** (CALC.ALX) — enteros de 64 bits, `+ - * /`, `C` limpia,
   retroceso borra, INTRO o `=` evalúa; imprime el resultado en consola
   (`calculadora: 12 + 34 = 46`) — así el arnés la verifica de punta a punta.
2. **Reloj** (RELOJ.ALX) — hora del RTC del sistema vía `api.hora()`,
   redibujo por `EV_TICK`; demuestra tick + título dinámico.

Editor de texto y gestor de archivos ya existen como apps del sistema
(compiladas dentro del kernel, como el propio shell); convertirlas a
`.ALX` es opcional y queda anotado en el registro de abajo.

### Registro de avance (Fase 7)

| Hito | Qué | Commit | Estado |
|---|---|---|---|
| A | Este plan + registro duradero | — | ✅ |
| B | Kernel + loader + apps CALC/RELOJ funcionando (build, 44+ pruebas host, arneses) | — | 🔨 |
| C | Documentación (manuales, CHANGELOG, PRUEBAS), auditoría REV-v1.2.0, batería completa | — | ⏳ |

---

## Fase 8 (v1.3.0) — Escritorio estilo Windows 3.11

**Objetivo**: un escritorio *tradicional y reconocible*: al arrancar se ve
el escritorio con iconos, ventanas con relieve biselado 3D y minimizar a
icono sobre el escritorio. Descripción de referencia (aportada por el
propietario; se reinterpreta con gráficos propios):

### El modelo de ventanas
- **Barra de título**: azul con texto blanco si está activa; gris con texto
  atenuado si no. Botones arriba a la derecha: **▼** (menú de control:
  Restaurar/Mover/Tamaño/Minimizar/Maximizar/Cerrar), **▲**
  (maximizar/restaurar), **✕** (cerrar). Icono del programa arriba a la
  izquierda (doble clic = cerrar). Doble clic en la barra de título =
  maximizar/restaurar.
- **Bordes con relieve 3D biselado**: claro arriba/izquierda, oscuro
  abajo/derecha; sombra gris detrás de la ventana activa.

### Minimizar a icono (lo más icónico)
- Sin barra de tareas: al minimizar, el programa se convierte en un icono
  sobre el escritorio, apilándose en la parte baja de la pantalla.
- El icono muestra el dibujo del programa y su nombre debajo.
- Volver: doble clic en el icono (o clic + INTRO). Cerrar un minimizado:
  clic → menú de control o Alt+F4.

### Program Manager (el "menú de inicio" de la época)
- Ventana con **grupos de programas** (Inicio, Principal, Accesorios…)
  representados como iconos; doble clic en un grupo abre su ventana con los
  programas dentro; doble clic en un programa lo lanza.
- Se podrá cerrar y trabajar solo con los iconos del escritorio.

### Otras particularidades
- Organización en **mosaico (Tile) y cascada (Cascade)** desde el menú.
- **Alt+Tab** sin vista previa (recuadro con el nombre del programa).
- Arrastrar la barra de título mueve; arrastrar bordes redimensiona.
- Foco por clic. Fondo del escritorio de color sólido, sin wallpapers.
- Paleta gris/beige; fuente bitmap propia del proyecto (ya existe);
  botones con el mismo relieve 3D (apretado = relieve invertido).

### Plan técnico (aproximado)
- `gui.zig` gana: escritorio con iconos (los del Program Manager + apps
  instaladas con bit de ejecutable), iconos de ventanas minimizadas,
  menú de control ▼, tile/cascade, Alt+Tab, bisel 3D en ventanas y botones.
- La terminal y el chat pasan a ser ventanas más (o paneles rediseñados
  con el mismo look) — decisión de diseño a tomar en la fase con capturas.
- El botón de minimizar reemplaza a "cerrar" en ventanas que quieran
  persistir (calculadora, editor…); ✕ sigue cerrando de verdad.
- Pruebas: extender `probar_escritorio.py` (minimizar/restaurar, menú de
  control, tile/cascade, Alt+Tab) — el arnés ya sabe clicar y teclear.

### Registro de avance (Fase 8)

| Hito | Qué | Commit | Estado |
|---|---|---|---|
| — | Por empezar (arrancar tras cerrar la Fase 7) | — | ⏳ |

---

## Fase 9 (v1.4.0) — Red, `descargar` y tienda de aplicaciones

**Objetivo**: `descargar CALC` trae una app `.ALX` desde un repositorio
GitHub que hace de tienda, la instala (bit de ejecutable) y queda lista
para abrir con doble clic — el "wget" propio del sistema.

### Diseño

- **Hardware**: QEMU ofrece virtio-net (`-netdev user` + `virtio-net-pci`);
  driver propio virtio 1.0 (colas virtqueue, MMIO/PCI). Sin patentes.
- **Pila**: ARP + IPv4 + **TCP cliente mínimo** (conectar/enviar/recibir/
  cerrar con retransmisión básica) + **TLS 1.3 cliente** con un juego fijo
  (X25519 + AES-128-GCM o ChaCha20-Poly1305 + SHA-256), usando las
  primitivas ya disponibles en Zig (`std.crypto`) — sin TLS de std porque
  no hay sockets; se implementa el handshake sobre nuestra pila.
- **Certificados**: anclaje (pinning) de las CA raíz de GitHub.com
  embebidas en la imagen; sin webhook ni actualización automática (la
  rotación de raíces requiere actualizar el sistema). Suficiente y honesto
  para un SO de juguete; documentado en la auditoría.
- **Tienda**: repositorio GitHub aparte (p. ej. `juanruiz85/AntLexApps`)
  con un `INDICE` de texto plano:
  `nombre|archivo|bytes|sha256|descripción` y los `.ALX` al lado. El
  comando `tienda` lista, `descargar <nombre>` verifica SHA-256 y
  escribe en `/APPS/` + `instalar`.
- **HTTP/1.1 GET** sobre TLS a `raw.githubusercontent.com`; sin DNS
  inicialmente (IP anclada en la tabla, editable con `red ip <addr>`) —
  DNS (UDP/53, sin patentes) se añade si da tiempo.

### Riesgos y orden
1. Driver virtio-net + ARP/ping interno (arnés con servidor local).
2. TCP mínimo contra un servidor HTTP local del arnés (sin TLS).
3. TLS 1.3 contra el servidor local de prueba del arnés (Python puede
   hacer de par TLS 1.3 con certificado de prueba).
4. HTTP + `tienda`/`descargar` contra GitHub real.
5. Batería completa + auditoría REV (superficie nueva: red — muy visible).

### Registro de avance (Fase 9)

| Hito | Qué | Commit | Estado |
|---|---|---|---|
| — | Por empezar (arrancar tras cerrar la Fase 8) | — | ⏳ |

---

## Reglas del registro

1. Al completar un hito: rellenar su fila con el hash del commit, añadir
   las filas de `docs/PRUEBAS.md` que correspondan y **push a GitHub**.
2. Si una fase se subdivide o cambia de alcance, se edita este documento
   en el mismo commit que introduce el cambio (el historial de git guarda
   la evolución).
3. Toda decisión de diseño importante queda aquí o enlazada desde aquí.
4. Los commits van como `juanruiz85` (ver `CONTRIBUTING.md` y
   `tools/configurar_identidad.sh`).
