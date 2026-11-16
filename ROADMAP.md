# Hoja de ruta de Mirlo Weather

Mirlo Weather nace como la versión multiusuario y gratuita de la app personal
`netatmo-menubar`. La app personal **no se toca**: sigue siendo la referencia
funcional y la fuente de ideas. Esta hoja de ruta ordena qué funciones hay que
heredar, en qué orden y con qué adaptaciones.

- Referencia: `../netatmo-menubar` (`main.swift`, v0.11, git `5cd9128`).
- Destino: `netatmo-free-app` (Mirlo Weather, `es.privado.netatmo-free`).
- Servicio: `netatmo-free-worker` (Workers Free + D1, solo lectura).

## Principios

1. **La app personal manda en comportamiento, no en código.** Se porta la
   funcionalidad, adaptándola al modelo multiusuario y multiestación.
2. **Nada compartido con la app personal**: ni bundle ID, ni Llavero
   (`netatmo-free`), ni `~/.netatmo-free/`, ni el esquema `netatmofree://`.
3. **Todo lo local vive en `~/.netatmo-free/`**, nunca en `~/.netatmo-menubar/`.
4. **El menú normal sigue limpio**: sin “Reconectar” ni técnicos. Lo técnico
   solo con ⌥ Opción. Los avisos no rompen esa regla.
5. **Nada de memoria de más**: los datos personales (historial, avisos) se
   quedan en el Mac; no se suben al Worker.
6. **Sin dependencias nuevas**: AppKit/UserNotifications y JSON local, como la
   app personal.

## Diferencia de modelo que afecta a casi todo

La app personal asume **una instalación** con `exterior`/`interior` fijos. Mirlo
es **multiusuario y multiestación**: el Worker devuelve `modulos[]` con varias
estaciones, módulos interiores extra, anemómetro, pluviómetro y sensores
futuros.

Por eso, al portar cada función hay que sustituir las claves fijas por
**identificadores de módulo**:

| App personal | Mirlo Weather |
| --- | --- |
| `exterior.temperatura` | `modulo:<id>.temperatura` |
| `interior.co2` | `modulo:<id>.co2` |
| historial único `historial.jsonl` | una muestra por lectura con `modulos[]` |
| reglas sobre campos fijos | reglas sobre cualquier módulo presente |
| caldera de la instalación | caldera del termostato de cada estación |

El Worker ya expone `termostato` (`temperatura`, `consigna`, `modo`,
`caldera`) y `modulos[]` con `tipo`, `principal`, `nombre`, `estacion` y
`datos`. No hace falta tocar el Worker para las fases 1–5; solo para ampliar
campos si aparece un sensor nuevo.

## Estado actual (paridad)

| Función | App personal | Mirlo |
| --- | --- | --- |
| Menú en barra: exterior/interior/min-max/viento/lluvia/ninguno | Sí | **Sí** (viento con rachas, lluvia actual + 24 h) |
| Humedad, CO₂, ruido, termostato en barra | Sí | **Sí** |
| Pausar/reanudar consultas | Sí | **Retirado** (siempre activas) |
| Antigüedad del dato (“Dato: hace…”) | Sí | **Sí** |
| Historial local + gráfica 24 h | Sí | **Sí** (Netatmo `getmeasure` vía Worker + `historial.jsonl` de respaldo) |
| Tendencias 30/60 min | Sí | **Parcial** (en reglas de aviso; falta mostrar en menú/barra) |
| Reglas de aviso configurables | Sí | **Sí** |
| Datos obsoletos / resumen diario / no molestar | Sí | **Sí** |
| Caldera: estado y tiempo hoy/mes | Sí | **Sí** |
| Icono en barra | SF Symbols | **Sí** |
| Icono de la app | Sol/nube | **Adoptado** (ver decisión) |
| Multiusuario OAuth | No | **Sí** |
| Varias estaciones y módulos | No | **Sí** |
| Estación cercana pública (lluvia/viento) | No | **Sí** |
| Actualizaciones desde GitHub | No | **Solo compilación interna** (la App Store es el canal oficial) |
| App Store (sandbox, privacidad, es/en) | No | **Sí** (1.0 build 1 subida a App Store Connect) |
| Ajustes + inicio al arrancar | Parcial (config) | **Sí** |

## Distribución

La versión oficial es **solo la de la App Store** (`com.paoloac.mirloweather`,
macOS 13+, sandbox, sin actualizador propio). El repositorio de GitHub queda como
**código fuente y seguimiento de issues**: no se publican `.zip` ni releases.
La compilación independiente (`es.privado.netatmo-free`, macOS 12+) se conserva
para desarrollo y no se distribuye.

Por eso, a partir de la 1.0:

- `Updater.swift` y el menú de actualización existen solo bajo `#if !APPSTORE`.
- La variante App Store usa el llavero de datos protegidos y no pide permisos de
  Llavero ajenos.
- Las releases antiguas v0.2.x se han eliminado del repositorio.

## Decisión: icono

Se adopta el icono de la app personal (sol/nube troquelado,
`netatmo-menubar/icono-1024.png` y su `AppIcon.icns`), que es el que el usuario
considera correcto. El icono de mirlo generado por `make-icon.swift` queda como
respaldo (`AppIcon-mirlo.icns`). El nombre “Mirlo Weather” no cambia.

---

# Fase 1 — Paridad de barra y control

> **Estado: completada en v0.3.0 (build 10).**
> Incluye 1.1–1.6, con el envío de
> `X-Time-Zone` al Worker para que la hora del servicio sea la local.

Objetivo: que el uso diario se sienta como la app personal. Es la fase más
barata y la de mayor valor inmediato.

### 1.1 Más valores en la barra

Portar de `VALORES_BARRA` y `barraActual()`:

- Humedad exterior.
- Humedad interior.
- CO₂ interior (ppm).
- Ruido interior (dB).
- Termostato y consigna (`20,4° / 21°`).
- Mantener exterior, interior, min/max, viento, lluvia y “solo el icono”.

Adaptación: si hay varias estaciones, los valores “interior”/“exterior” usan la
estación **principal** y el módulo del tipo correspondiente; si no existe, se
muestra `--` en vez de inventar. Persistencia en `~/.netatmo-free/config.json`
(`valor_barra`), como ahora.

Criterio de aceptación: cambiar de valor en “Ver en barra” se refleja al
instante, sobrevive al reinicio y no rompe con módulos ausentes.

### 1.2 Pausar y reanudar consultas

> **Estado: retirado en v0.3.0 (build 11).** Las consultas permanecen siempre activas y al cargar configuraciones antiguas se fuerza `polling = true`.

Portar `toggle(_:)` y el campo `consultas_iniciadas`:

- Ítem “Pausar consultas” / “Iniciar consultas”.
- Al reanudar: consulta inmediata.
- Estado persistido y visible (icono o título atenuado).

Criterio: pausado no hay tráfico al Worker; al reanudar se actualiza sin
esperar al siguiente ciclo.

### 1.3 Antigüedad del dato y aviso de lectura rancia

Portar `ageLabel()` y `comprobarDatosObsoletos()` (sin las reglas, que llegan
en la fase 4):

- Línea “Dato: hace 2 min” en el menú.
- Umbral por defecto 20 min (`STALE_SECONDS`), con margen tras despertar el Mac:
  `max(120, poll_seconds * 1.5)`.
- Se usa la hora que declara el Worker (`actualizado`) además de la hora local.

Adaptación multiusuario: `actualizado` viene del Worker, así que sirve igual
para todos; no se debe avisar antes del primer intento tras arrancar.

Criterio: dormir el Mac 30 min no genera un falso aviso; un Worker que responde
con datos viejos sí lo genera (una vez por hora como máximo).

### 1.4 Caldera: estado y tiempos oficiales

El estado sale de `boiler_status` del termostato (`NATherm1`/`OTM`/`OTH`), no
del relé `NAPlug`, que no publica ese campo.

Los tiempos se leen del histórico oficial de Netatmo con `getmeasure`
(`scale=1day`, `type=sum_boiler_on`) para el termostato. La API devuelve
segundos aunque la documentación hable de minutos; el Worker los convierte y
expone `/v1/boiler` con `hoy_min`, `ayer_min` y `mes_min`.

- Sin muestreo local ni `caldera.jsonl`: no se estima a partir de lecturas
  periódicas.
- Caché en la app de 15 min; una actualización manual fuerza la consulta.
- Menú: “Caldera: encendida/apagada” y
  “Caldera hoy: X · ayer: Y · este mes: Z”.
- Segundo ítem de barra opcional mientras está encendida
  (`actualizarIconoCaldera`).

Criterio: los minutos cuadran con el histórico oficial de Netatmo para el mismo
día; sin termostato el histórico no aparece.

**Estimación:** 1–2 sesiones. Riesgo bajo.

### 1.5 Color de destacado y secciones del menú

El menú se divide con separadores nativos en Exterior, Interior,
Termostato/Caldera y estaciones externas. Los datos que no son de la estación
principal se marcan de forma sobria: la favorita aparece como
`Estación <nombre>` y sus datos como `Viento: …` / `Lluvia: …`; los módulos de
otras estaciones de la cuenta, como `Estación <nombre>: …`. No se repiten
“pública”, distancia ni el nombre en cada línea.

En Ajustes, la sección **Menú** permite activar “Destacar los datos con color”,
elegir un único color sólido con `NSColorWell` y marcar qué bloques se
resaltan: Exterior, Interior, Termostato, Caldera, Viento, Lluvia, estación
cercana y otras estaciones. Cada bloque seleccionado se pinta entero con una
vista propia (`FilaResaltada`): ocupa todo el alto y el ancho de la fila, de
borde a borde, exactamente igual que el resaltado azul del ratón. El texto se
dibuja encima con el color elegido en **Texto del resaltado**: **Automático**
(elige el de mayor contraste WCAG), **Blanco** o **Negro**. El negro se guarda
como un azul muy oscuro porque macOS adapta los grises al color de texto del
menú y los volvería invisibles sobre un fondo claro. Se guarda en
`config.json` como `destacar_datos`, `color_destacado` (`#RRGGBB`),
`texto_destacado` y `destacar_items`.

Criterio: activar/desactivar, cambiar el color o marcar bloques se refleja al
instante al abrir el menú; las lecturas propias y las externas siempre se
distinguen y el texto sigue siendo legible sobre el color.

**Estimación:** 1 sesión. Riesgo bajo.

### 1.6 Arranque inmediato y edad del dato

Tras un reinicio del Mac, la app solicita datos en cuanto arranca en lugar de
esperar al primer ciclo de consulta. Si el Llavero aún está bloqueado o la red
no está lista, reintenta cada 10 s durante unos dos minutos y se detiene al
recibir el primer dato. La línea **Cuenta** incluye la edad del último dato
(`Último dato hace X min`), calculada con la hora que declara el servicio.

Criterio: tras reiniciar, el menú deja de estar vacío sin intervención; la edad
del dato aparece en la línea de Cuenta y se marca con ⚠︎ si supera 20 min.

**Estimación:** 1 sesión. Riesgo bajo.

---

# Fase 2 — Historial local y gráfica

Objetivo: dar contexto temporal sin nube ni cuentas.

### 2.1 Historial

Portar `guardarMuestra`, `recortarHistorialSiConviene`, `leerHistorial*`.

- `~/.netatmo-free/historial.jsonl`, una línea por lectura correcta.
- Recorte por tamaño (~600 KB) y por número de líneas (~2000).
- Formato ampliado para multiusuario:

```json
{"ts": 1765000000, "modulos": {"station-1": {"temperatura": 21.5, "humedad": 48}, "module-outdoor": {"temperatura": 12.3}}}
```

Se guardan solo números (no nombres ni ubicaciones) para no crecer ni exponer
datos innecesarios.

### 2.2 Gráfica de 24 h

> **Estado: completada en v0.3.3 (build 15).** La serie principal viene del
> histórico oficial de Netatmo (`/v1/history` → `getmeasure`, escala `30min`,
> 24 h, cacheado 15 min en D1). Si el campo no tiene serie en Netatmo
> (caldera o viento/lluvia de la estación cercana), se usa `historial.jsonl`
> y la leyenda indica `Netatmo` o `local`. La gráfica se abre en una ventana
> flotante con los valores en el eje Y (máximo, medio y mínimo) y las horas en
> el eje X (−24 h, −12 h, ahora). El selector **Campo** permite cambiar entre
> temperatura, humedad, CO₂, presión, ruido, termostato, caldera, lluvia o
> viento sin cerrar la ventana, y se incluye el borrado del historial local con
> confirmación.

Portar `VistaGrafica` (sparkline dibujada a mano, sin librerías):

- Submenú “Gráficas” con “Temperatura exterior, últimas 24 h”.
- Selector de módulo/campo cuando haya varios (temperatura exterior, interior,
  CO₂…). Empezar por exterior y añadir el selector en la misma fase.
- “Borrar historial” con confirmación.

Criterio: la curva aparece tras unas horas de uso; borrar historial vacía la
gráfica y el archivo sin tocar la conexión.

**Estimación:** 1–2 sesiones. Riesgo bajo.

---

# Fase 3 — Tendencias

Objetivo: responder “¿sube o baja?” de un vistazo.

### 3.1 Cálculo

Portar `leerHistorial(horas:)`, `claveHistorial`, `valorTendencia`:

- Diferencia entre el valor actual y el de hace 30 y 60 min.
- Tolerancia de búsqueda para no exigir una muestra exacta.
- Solo se calcula si hay historial suficiente (si no, no se muestra).

### 3.2 Presentación

- En el menú: “Interior: 21,4° (↑0,6° en 30 min)”.
- En barra: opción “Interior con tendencia” (sin recargar la barra por defecto).
- Campos disponibles para reglas en la fase 4
  (`..._cambio_30m`, `..._cambio_60m`).

Criterio: una subida real de 0,6° en 30 min se muestra como `↑0,6°`; sin
historial no aparece una flecha falsa.

**Estimación:** 1 sesión. Depende de la fase 2.

---

# Fase 4 — Avisos configurables

> **Estado: completada en v0.3.0 (build 11)** en `Avisos.swift` (`MotorAvisos`, `VentanaAvisos`, `EditorAviso`). Evalúa sensores propios, estación cercana favorita, caldera oficial y tendencias de 30/60 min usando `historial.jsonl`, con silencios por regla, anti-spam, duración sostenida y registro en `avisos.jsonl` / `avisos-estado.json`.

Objetivo: heredar el motor de reglas, que es la función más grande de la app
personal. Se puede dividir en dos entregas.

### 4.1 Motor (entrega A)

Portar de `main.swift`:

- `ReglaAviso` (`campo`, `operador`, `valor`, `valor2`, `duracionMin`,
  `esperaMin`, `activo`).
- Operadores `gt`, `gte`, `lt`, `lte`, `eq`, `fuera`, `dentro`.
- `cumpleCondicion`, `evaluarAvisos`, `valorCampoAviso`.
- `AjustesAvisos` con candado, `condDesde`, `ultimoDisparo`.
- Estado persistido en `~/.netatmo-free/avisos-estado.json`.
- Registro en `~/.netatmo-free/avisos.jsonl` (últimos 20 en el menú).
- Silencio por regla (`silencios: id -> instante`).
- Entrega con `GestorNotificaciones`; si no hay permiso: sonido + aviso en el
  menú y en la barra (`bell.badge` + `Aviso`) durante 20 s + registro.
- Nunca evaluar con datos más viejos que `STALE_SECONDS` (mejor callar que
  mentir).

Adaptación: los campos se generan **a partir de `modulos[]`**, no de una lista
fija. Catálogo inicial por tipo de módulo:

- Estación/interior: temperatura, humedad, CO₂, ruido, presión.
- Exterior: temperatura, humedad, mínima/máxima de hoy.
- Termostato: temperatura, consigna, caldera (1/0), minutos hoy, horas mes.
- Viento: velocidad, racha, dirección.
- Lluvia: lluvia actual, 1 h, 24 h.
- Tendencias de la fase 3.

### 4.2 Ventana de avisos (entrega B)

Portar `VentanaAvisos` y el editor de reglas:

- Lista de reglas con estado, descripción legible, activar/desactivar,
  editar, borrar, añadir, probar.
- Editor con campo, operador, valor(es), duración, espera y nombre.
- Silenciar regla 1 h / 4 h / hasta mañana / reactivar.
- “Probar notificación” y estado del permiso con acceso directo a Ajustes del
  Sistema.
- Botón de avisos en el menú con contador de avisos de hoy.

Reglas de diseño propias de Mirlo:

- El submenú “Avisos” es funcional, no técnico: puede estar siempre visible.
- Nada de “Avanzado” aquí; la ventana se abre desde “Avisos…”.
- Si no hay ningún módulo que soporte una regla, el editor lo dice en vez de
  guardar una regla muda.

Criterio: crear “CO₂ > 1200 durante 10 min, máximo 1 aviso cada 2 h” y verlo
dispararse con datos reales; con notificaciones denegadas, suena y aparece en
el menú; la regla silenciada no entrega nada.

**Estimación:** 3–4 sesiones. Es la fase con más superficie de UI.

---

# Fase 5 — Avisos de sistema

> **Estado: completada en v0.3.0 (build 11)** en `Avisos.swift` y `main.swift`: datos obsoletos, resumen diario con caldera oficial y horario de no molestar.

Objetivo: completar el comportamiento “de fondo” de la app personal.

### 5.1 Datos obsoletos

Portar la parte de avisos de `comprobarDatosObsoletos`:

- Activable, umbral configurable (por defecto 20 min, mínimo 5).
- Anti-spam de 1 h mientras el problema siga.
- Respeta el horario de no molestar y el registro.

### 5.2 Resumen diario

Portar `comprobarResumenDiario`:

- Hora configurable (por defecto 21:00), una vez al día.
- Contenido: mín/máx exterior con horas, interior actual, caldera hoy/mes,
  avisos registrados hoy.
- Si no hay datos recientes, lo dice explícitamente.

### 5.3 Horario de no molestar

Portar `enHorarioSilencio`:

- Ventana configurable (por defecto 22:00–08:00), con el caso que cruza
  medianoche.
- Lo silenciado se registra como `[silenciado]`, no se pierde.

Criterio: un aviso a las 23:30 no suena, pero queda en el registro; el resumen
de las 21:00 llega una sola vez al día.

**Estimación:** 1–2 sesiones. Depende de la fase 4.

---

# Fase 6 — Herramientas y distribución

Objetivo: mantener la app fácil de probar y de publicar.

- **Modo demo** (`demo: true` en config): datos sintéticos, marca “DEMO” en el
  menú, sin red ni historial. Útil para capturas y para enseñar la app.
- **Argumentos de diagnóstico** equivalentes a `--abrir-avisos`,
  `--abrir-editor`, `--caldera` (con nombres propios de Mirlo, p. ej.
  `--mirlo-avisos`), solo en builds de desarrollo.
- **DMG** de distribución, adaptando `crear-dmg.command` de la app personal,
  con verificación de firma previa y acceso a Aplicaciones. Solo para la
  compilación independiente de desarrollo; el canal oficial es la App Store.
- **Mac App Store (hecho en 1.0)**: `MirloWeather.xcodeproj` con
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS=APPSTORE`, sandbox, llavero de datos
  protegidos, localizaciones español/inglés, `PrivacyInfo.xcprivacy` y sin
  actualizador propio. Versión 1.0 build 1 subida a App Store Connect.

**Estimación:** 1 sesión para demo + argumentos + DMG. La preparación de App
Store ya está completada; queda la revisión de Apple y el enlace público.

---

# Fase 7 — Extra específico de Mirlo (no existe en la personal)

Solo cuando 1–6 estén cerradas, salvo la estación cercana, que ya está hecha
porque resolvía una carencia real de la cuenta:

- **Estación cercana (v0.3.0)**: si faltan anemómetro o pluviómetro, buscar
  estaciones públicas de Netatmo cerca de casa (`/v1/nearby`), guardar una
  favorita y mostrar su lluvia/viento etiquetados. El Worker filtra a las que
  publican lluvia o viento y usa la credencial de instalación; la app nunca ve
  tokens de Netatmo. Ventana `BuscarEstacionWindow.swift`. Los valores
  “Viento” y “Lluvia” de **Ver en barra** usan la estación cercana cuando la
  cuenta no tiene ese sensor.
- **Modo sin cuenta / solo localidad (v0.4.0)**: permite usar la app sin cuenta
  de Netatmo escribiendo la localidad (geocodificación con `CLGeocoder`, sin
  GPS). El Worker consulta las estaciones públicas alrededor con
  `/v1/public/around`, usando su cuenta de servicio y caché geográfica
  compartida en D1 (`public_cache`, 120 s). La app selecciona automáticamente la
  estación más representativa de la temperatura (cercana a la mediana de la zona)
  y las que tengan viento o lluvia. Si no hay estaciones en 10 km, amplía a
  20 km y abre el selector manual; si tampoco hay, avisa para probar otra
  localidad o conectar una estación. Oculta interior/termostato/caldera y limita
  la barra y la gráfica a exterior, humedad, viento y lluvia.
- Avisos por estación/módulo con nombre visible (“Salón”, “Exterior”).
- Historial y gráficas por módulo, no solo exterior/interior.
- Resumen diario multiestación (una línea por estación).
- Detección de módulos nuevos o sin batería en el menú, sin ruido visual.
- Exportar/importar reglas de avisos en JSON (para no reescribirlas al
  cambiar de Mac).

---

# Orden recomendado y dependencias

```
Fase 1 (barra + pausa + rancio + caldera)
   └── Fase 2 (historial + gráfica)
          └── Fase 3 (tendencias)
                 └── Fase 4 (motor de avisos → ventana)
                        └── Fase 5 (obsoletos + resumen + no molestar)
                               └── Fase 6 (demo + DMG + App Store)
                                      └── Fase 7 (extra multiusuario)
```

- Cada fase termina con: `./build.command`, prueba con datos reales, bump de
  versión en `Info.plist` y release firmada (`./release.command`).
- No se toca ni se ejecuta nada de `netatmo-menubar` salvo lectura.
- No se toca el Worker salvo que un sensor nuevo exija un campo; en ese caso,
  primero el contrato del Worker, luego la app.

# Notas de implementación

- **Rutas**: `~/.netatmo-free/historial.jsonl`, `avisos-estado.json`,
  `avisos.jsonl`. Nada bajo `~/.netatmo-menubar/`. La caldera no usa archivo
  local: su histórico viene del Worker.
- **Estación cercana**: la favorita vive en `favorito_publico` dentro de
  `config.json` (id público, nombre, coordenadas y qué mide). No se guarda
  nada en el Worker ni se mezcla con las lecturas propias.
- **Concurrencia**: el motor de avisos se evalúa en el hilo de consulta; la
  ventana edita en el principal. Usar el patrón `AjustesAvisos` con `NSLock`.
- **Hora**: el Worker entrega `actualizado` en la zona del usuario
  (`X-Time-Zone`); las tendencias y los cortes de día usan la hora local.
- **Persistencia**: `config.json` sigue siendo el sitio de preferencias;
  los datos voluminosos van a JSONL aparte.
- **Privacidad**: historial y avisos no salen del Mac; el Worker solo ve
  credenciales y lecturas, como ahora.
- **Compatibilidad**: macOS 12+ (`SMAppService` solo en 13+, ya resuelto con
  LaunchAgent).
