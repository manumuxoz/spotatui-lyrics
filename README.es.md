# spotatui-lyrics

**Letras sincronizadas para YouTube en [spotatui](https://github.com/LargeModGames/spotatui), con reparación de metadatos y varios proveedores.**

[![CI](https://github.com/manumuxoz/spotatui-lyrics/actions/workflows/ci.yml/badge.svg)](https://github.com/manumuxoz/spotatui-lyrics/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![spotatui API v6](https://img.shields.io/badge/spotatui%20API-v6-1db954.svg)](https://spotatui.com/docs/scripting)

> [Read this in English](README.md)

## Por qué existe

La vista de letras integrada de spotatui consulta LRCLIB con el **título completo del vídeo de YouTube** y el **nombre del canal**. Eso no es un crédito musical:

- `Guxo - Si El Mundo Fuera Perfecto` → artista `Guxo`, pero el título incluye el artista.
- `Daft Punk - Get Lucky (Lyrics) ft. Pharrell Williams` en el canal `7clouds` → artista `7clouds`.
- `Ella Baila Sola (Video Oficial)` en `DEL Records` → artista `DEL Records`.

El resultado es *"No lyrics for this track"* aunque la canción exista. Este plugin limpia los metadatos, prueba varias consultas, consulta varios proveedores, puntúa las coincidencias y dibuja una pantalla de letras propia.

## Instalación

Requisitos: spotatui **0.48 o superior** con la feature `scripting` (incluida en las releases oficiales), `git` y conexión a los proveedores que actives.

```bash
spotatui plugin add manumuxoz/spotatui-lyrics
```

Añade el atajo en `~/.config/spotatui/config.yml` (o `$XDG_CONFIG_HOME/spotatui/config.yml`):

```yaml
plugin_commands:
  ytlyrics_open: "ctrl-l"
```

Reinicia spotatui y pulsa `ctrl-l` con un tema de YouTube sonando.

Para usar `B`, primero mueve la vista integrada:

```yaml
keybindings:
  lyrics_view: "ctrl-b"

plugin_commands:
  ytlyrics_open: "B"
```

Si no mueves `lyrics_view`, spotatui ignora el binding de `B` con un aviso en el log.

## Teclas

| Tecla | Acción |
|---|---|
| `j` / `Flecha abajo` | Bajar y pausar el seguimiento automático |
| `k` / `Flecha arriba` | Subir y pausar el seguimiento |
| `f` | Volver a seguir la reproducción |
| `s` | Saltar la reproducción a la línea seleccionada |
| `[` / `]` | Adelantar / atrasar la letra 250 ms |
| `{` / `}` | Adelantar / atrasar la letra 1 s |
| `0` | Reiniciar el desfase de este vídeo |
| `m` | Probar otra variante de metadatos |
| `r` | Reintentar y volver a la coincidencia 1 |
| `i` | Abrir la depuración |
| `Esc` / `q` | Volver |

El seguimiento se reanuda solo 8 segundos después del último scroll. El desfase se guarda por ID de vídeo y sobrevive al reinicio.

## Proveedores

| Proveedor | Timestamps | Cuenta | Estado | Por defecto |
|---|---|---|---|---|
| **LRCLIB** | Sí (LRC) | Ninguna | API abierta y documentada | **Sí** |
| **Genius** | No (texto plano) | Ninguna | Endpoint web público, sin API oficial de letras | **Sí** |
| **NetEase Cloud Music** | Sí (LRC/YRC) | Ninguna | Endpoints no oficiales; puede estar bloqueado por región | No |

Genius no tiene tiempos: el plugin estima una línea de tiempo y la marca como `texto · estimado`. NetEase está desactivado por defecto por ser un endpoint no oficial; actívalo para más cobertura sincronizada:

```bash
SPOTATUI_LYRICS_PROVIDERS=lrclib,netease,genius spotatui
```

## Configuración

Variables de entorno, leídas al cargar el plugin:

| Variable | Por defecto | Significado |
|---|---|---|
| `SPOTATUI_LYRICS_PROVIDERS` | `lrclib,genius` | Orden de proveedores separado por comas. Añade `netease`. |
| `SPOTATUI_LYRICS_SOURCES` | `youtube` | `youtube` o `all`. |
| `SPOTATUI_LYRICS_PREFETCH` | `0` | `1` busca letras en cada cambio de pista, sin esperar a abrir la pantalla. |
| `SPOTATUI_LYRICS_CONTEXT` | `6` | Líneas visibles arriba y abajo de la actual (2–20). |
| `SPOTATUI_LYRICS_OFFSET_STEP` | `250` | Paso del desfase en ms para `[` / `]`. |
| `SPOTATUI_LYRICS_BIAS_MS` | `120` | Compensa el retraso de un tick del snapshot de reproducción. |
| `SPOTATUI_LYRICS_TIMEOUT` | `15000` | Límite total de la búsqueda en ms. |
| `SPOTATUI_LYRICS_MAX_QUERIES` | `4` | Variantes de metadatos por búsqueda (1–8). |
| `SPOTATUI_LYRICS_ESTIMATE` | `1` | `0` muestra el texto plano sin línea de tiempo estimada. |
| `SPOTATUI_LYRICS_LANG` | auto | `en` o `es`; por defecto sigue `LANG`/`LC_ALL`. |
| `SPOTATUI_LYRICS_GENIUS_POST` | `1` | `0` desactiva el reintento de Genius con User-Agent de navegador. |
| `SPOTATUI_LYRICS_DEBUG` | `0` | `1` escribe detalles en el log. |
| `SPOTATUI_LYRICS_MAX_BODY` | `2097152` | Tamaño máximo de respuesta en bytes. |

Ejemplo:

```bash
export SPOTATUI_LYRICS_LANG=es
export SPOTATUI_LYRICS_CONTEXT=8
export SPOTATUI_LYRICS_PROVIDERS=lrclib,netease,genius
spotatui
```

PowerShell:

```powershell
$env:SPOTATUI_LYRICS_PROVIDERS = "lrclib,netease,genius"
spotatui
```

## Privacidad y aspectos legales

- Solo se envían **título, artistas candidatos y duración** a los proveedores activos. No hay cuenta, token, telemetría ni analítica.
- Las letras viven **solo en memoria**. El desfase y la variante elegida se guardan en el almacén JSON por plugin de spotatui; las letras nunca se escriben en disco.
- Con `SPOTATUI_LYRICS_PREFETCH=0` (por defecto), no sale nada de tu máquina hasta que abres la pantalla.
- LRCLIB es una base comunitaria abierta. Genius y NetEase son endpoints web públicos usados por muchos clientes de letras; pueden cambiar, limitar o bloquear peticiones. Desactívalos si prefieres solo LRCLIB.
- Las letras tienen derechos de autor. El plugin las muestra; no las descarga, empaqueta, cachea en disco ni redistribuye.
- Este proyecto no está afiliado a spotatui, Spotify, YouTube, LRCLIB, Genius ni NetEase.

## Limitaciones

- La pantalla es propia: la API de plugins no permite inyectar letras en la vista integrada ni apropiarse de `B` sin cambiar la configuración.
- Las pantallas de plugin no dibujan la playbar; por eso hay un medidor de progreso propio.
- Genius no tiene timestamps; la línea de tiempo es estimada y se etiqueta como tal. Si hay una fuente sincronizada, se prefiere.
- Si ningún proveedor tiene la canción, la pantalla lo dice. `m` prueba otras variantes; `i` muestra las consultas y los errores.
- No se ejecuta `yt-dlp` para enriquecer metadatos: bloquearía la UI o añadiría procesos y archivos temporales. El parser cubre las formas habituales de YouTube.
- Los vídeos muy largos (mixes, podcasts, streams) se omiten como no musicales. Pulsa `r` para buscar igualmente.

## Problemas frecuentes

**No encuentra letras**

1. Pulsa `i`: verás los metadatos crudos, cada consulta, cada petición y las puntuaciones.
2. Pulsa `m` para probar otra variante.
3. Pulsa `r` para reintentar desde la coincidencia 1.
4. Activa NetEase: `SPOTATUI_LYRICS_PROVIDERS=lrclib,netease,genius spotatui`.
5. Comprueba que el proveedor sea accesible desde tu red.

**El plugin no carga**

- `spotatui --version` debe ser 0.48 o superior.
- `spotatui plugin list`.
- Mira el log que spotatui imprime al arrancar (`Logging to: ...`).
- Reinicia spotatui; no hay hot reload.

**La tecla no hace nada**

- `B` choca con `lyrics_view`; mira la sección de instalación.
- El comando debe llamarse exactamente `ytlyrics_open`.
- Las teclas reservadas (`H`, `M`, `L`, flechas, `Backspace`, `Enter`) no se pueden asignar a comandos de plugin.

**El tiempo no cuadra**

- `[` / `]` ajustan 250 ms; `{` / `}` ajustan 1 s; `0` reinicia.
- Si la letra es texto plano, la línea de tiempo es una estimación; el desfase no la vuelve exacta.

**Canción equivocada**

- Pulsa `m` para ciclar las variantes (título limpio, fila cruda, artista/título intercambiados, solo título).
- Si ninguna coincide, los proveedores no tienen el registro; abre un issue con la depuración y la URL del vídeo.

## Desarrollo

Lua 5.4, sin dependencias externas:

```bash
git clone https://github.com/manumuxoz/spotatui-lyrics
cd spotatui-lyrics
lua5.4 tests/run.lua
```

La suite usa un mock de la API de spotatui (`tests/harness.lua`) y cubre reparación de metadatos, LRC, scoring, proveedores, cancelación, caché, variantes, timeouts y una carga completa del plugin con una pantalla renderizada.

Instalación de desarrollo:

```bash
ln -s "$PWD" "${XDG_CONFIG_HOME:-$HOME/.config}/spotatui/plugins/spotatui-lyrics"
```

Añade el binding, reinicia y usa `--debug` para ver el log. `scripts/smoke.sh` hace comprobaciones HTTP reales contra los tres proveedores (requiere `curl` y `jq`).

## Licencia

MIT. Consulta [`LICENSE`](LICENSE). Las letras no forman parte de este repositorio y siguen siendo propiedad de sus titulares.
