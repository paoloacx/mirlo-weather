# Propuesta de Mirlo Weather 1.1

> Documento de trabajo. No es un compromiso de fechas: ordena qué merece la
> pena hacer después de la 1.0 y qué se queda fuera.
>
> **Acordado:** alcance equilibrado, gráfica solo de 24 h, comienzo del
> desarrollo cuando la 1.0 esté aprobada en la App Store y reparto en **1.1
> (puesta a punto)** + **1.1.1 (gestión)**.

## Resumen

La 1.0 ya cubre el uso diario: barra, menú, avisos, caldera, histórico oficial,
modo localidad y App Store. La 1.1 no debería añadir otra gran función, sino
**explotar mejor los datos que ya existen** y quitar rozaduras.

Tema propuesto: **«Cada sensor con su historia»**.

- La gráfica deja de estar limitada a exterior/interior/termostato y pasa a
  mostrar cualquier módulo de cualquier estación.
- Las tendencias de 30/60 min, que ya se calculan para los avisos, se ven en el
  menú.
- Se puede elegir la estación principal y guardar varias localidades.
- Los avisos se pueden exportar/importar y silenciar desde la notificación.
- **Una sola ventana de Ajustes con barra lateral**, que integra Avisos,
  estaciones y apariencia.
- **Gráfica redimensionable y con interacción**, con tamaño recordado y opción
  de mantener encima.
- **Pulido visual de toda la app**: onboarding, avisos, menú y controles con el
  mismo lenguaje.
- Accesibilidad y textos en inglés al mismo nivel que el español.
- Nada de GPS, telemetría, escritura en Netatmo ni dependencias nuevas.

## Diagnóstico

Lo que hoy queda cojo, por orden de importancia:

| Carencia | Efecto para el usuario | Dónde está |
| --- | --- | --- |
| La gráfica usa una lista fija de campos | Con dos módulos interiores o dos estaciones, solo se puede graficar el «interior» principal | `CAMPOS_GRAFICA`, `camposGraficaDisponibles()` |
| Las tendencias solo existen en los avisos | El menú no dice si sube o baja | `Avisos.swift`, `*_cambio_30m` |
| La estación principal la decide Netatmo | No se puede elegir la de casa frente a la del pueblo | `modulos[].principal` |
| Solo se guarda una localidad | Cambiar de localidad obliga a repetir el onboarding | `LocalidadConfig` |
| Las reglas de aviso no se pueden mover de Mac | Rehacerlas a mano | `avisos-estado.json` |
| Ajustes y avisos viven en dos ventanas | Dos sitios donde buscar y dos tamaños que mantener | `SettingsWindow.swift`, `VentanaAvisos` |
| La interfaz mezcla estilos y medidas | Se ve de desarrollo, no de App Store | ventanas con `frame = …` y controles por defecto |
| La gráfica no se puede agrandar | Una serie de 24 h se ve pequeña y encima flota sobre todo | `construirVentanaGrafica()` |
| Sin etiquetas de accesibilidad | VoiceOver lee poco o nada | Sin `setAccessibility*` |
| Sin pruebas ni CI | Cada cambio se valida a mano | `test/` no existe en la app |

## Alcance recomendado

### 1.1 — «La puesta a punto»

> **Reparto acordado:** la 1.1 se centra en la gráfica, los ajustes con barra
> lateral y el rediseño visual. Las funciones de gestión —estaciones y avisos
> exportables— pasan a la 1.1.1.

#### 1. Gráfica por módulo y sensor

**Problema.** `CAMPOS_GRAFICA` es una lista fija. Si la cuenta tiene un módulo
en el salón y otro en el dormitorio, la gráfica solo muestra el primero que
encuentra. Lo mismo con una segunda estación.

**Solución.**

- Construir el catálogo de campos a partir de `datos["modulos"]`, con
  `id`, `tipo`, `nombre`, `estacion` y los datos disponibles.
- Agrupar el selector por estación y módulo:
  `Mi casa · Exterior`, `Mi casa · Salón`, `Casa del pueblo · Viento`.
- Enviar el `id` del módulo a `/v1/history` para que el Worker consulte ese
  módulo concreto, no solo el tipo.
- Mantener el respaldo local y la nota `sin histórico de Netatmo`.
- Campo por defecto: temperatura exterior de la estación principal.

**Worker.** `/v1/history` gana `id`. La clave de caché incluye `id` y `tipo`.
Validar que el módulo pertenece a la cuenta antes
de llamar a `getmeasure`. Tests de la ruta y de la caché.

**Criterio de aceptación.** Con dos módulos interiores, ambos aparecen; elegir
«Salón» dibuja su serie de Netatmo; un módulo sin serie no rompe la ventana.

**Esfuerzo.** 3–4 sesiones de app + 1–2 de Worker. Riesgo medio.

#### 2. Tendencias visibles

**Problema.** El motor de avisos ya calcula `..._cambio_30m` y `..._cambio_60m`,
pero el usuario no las ve si no crea una regla.

**Solución.**

- Reutilizar `valorTendencia` y `leerHistorial` de `Avisos.swift`.
- Menú: `Interior: 21,4 °C ↑0,6° en 30 min`; sin historial suficiente, no se
  muestra nada (nunca una flecha falsa).
- Opción de barra **«Interior con tendencia»**, desactivada por defecto.
- En la gráfica, marcar el último tramo con una flecha o un punto final.

**Criterio de aceptación.** Con 60 min de muestras, una subida real de 0,6 °C
aparece como `↑0,6°`; con 10 min de muestras no aparece.

**Esfuerzo.** 1–2 sesiones. Riesgo bajo.

#### 3. Accesibilidad y textos

**Problema.** No hay etiquetas de accesibilidad y el inglés se ha revisado menos
que el español.

**Solución.**

- `setAccessibilityLabel/Value/Help` en menú, gráfica, ajustes, avisos y
  onboarding.
- Navegación con teclado: `⌘,` ajustes, `⌘R` actualizar, `Esc` cerrar.
- Respetar **Reducir movimiento** y **Aumentar contraste**.
- Revisión completa de `Localizable.strings`: plurales, fechas, unidades y
  textos de error.
- Etiqueta de accesibilidad de App Store Connect.

**Criterio de aceptación.** VoiceOver puede recorrer el menú y leer el resumen
de la gráfica; no queda ninguna clave sin traducir en inglés.

**Esfuerzo.** 2–3 sesiones. Riesgo bajo.

#### 4. Calidad de la 1.1

- Pruebas unitarias de lo nuevo: catálogo de campos, serie por módulo,
  tendencias y claves de localización.
- TestFlight interno antes de la 1.1.

**Esfuerzo.** 1–2 sesiones. Riesgo bajo.

#### 5. Unificar Ajustes y Avisos en una sola ventana

**Problema.** Hoy hay dos ventanas y dos sitios donde buscar: **Ajustes**
(440×590, posiciones absolutas) y **Avisos** (680×660, con su propio editor).
El menú tiene dos entradas y el usuario tiene que recordar cuál abrir.

**Solución.**

- Una sola ventana **Ajustes** con **barra lateral** nativa, al estilo de
  Ajustes del Sistema:
  - **General**: inicio al iniciar sesión, idioma, versión y actualizaciones
    (solo en la compilación independiente).
  - **Barra y menú**: valor de la barra, resaltado por bloques, color y texto.
  - **Estaciones**: estación principal de la cuenta, localidades guardadas y
    selección manual de estaciones públicas.
  - **Avisos**: lista de reglas, activar/desactivar, editar, probar, permisos,
    datos obsoletos, resumen diario y no molestar.
  - **Avanzado** (solo con ⌥): restablecer conexión, borrar historial,
    diagnóstico y servicio.
- Ventana de 760×560 (mínimo 720×520), redimensionable. Barra lateral de 210 px
  con `NSVisualEffectView` (material `.sidebar`) y una lista de origen
  (`NSOutlineView`, estilo `.sourceList`) con iconos SF Symbols:
  `gearshape`, `menubar.rectangle`, `house`, `bell.badge` y
  `wrench.and.screwdriver`.
- El detalle usa `NSStackView` y `NSGridView`, no posiciones absolutas: tarjetas
  agrupadas, etiquetas alineadas, controles a la derecha y texto secundario
  debajo. La sección elegida se recuerda en `config.json`.
- El editor de una regla sigue siendo una hoja (`EditorAviso`) sobre la misma
  ventana, no otra ventana suelta.
- El menú **Avisos…** se conserva como atajo, pero abre **la misma ventana** en
  la sección de Avisos. Nada de duplicar estado ni ventanas.
- Refactor en dos pasos: extraer de `VentanaAvisos` una vista reutilizable y
  después montarla dentro de la ventana única. La lógica del motor no se toca.
- La variante App Store no muestra la sección de actualizaciones; el resto es
  idéntico.

**Criterio de aceptación.** `⌘,` y **Avisos…** abren una sola ventana; no se
pueden abrir dos copias; las reglas existentes siguen funcionando; el tamaño, la
posición y la sección se recuerdan; la barra lateral se ve nativa en modo claro
y oscuro.

**Esfuerzo.** 4–6 sesiones. Riesgo medio-alto por la refactorización de UI.

#### 6. Ventana de gráfica redimensionable

**Problema.** La ventana mide 360×250 y no se puede agrandar. La vista solo
crece a lo ancho, el selector y el botón están anclados a posiciones fijas y
una serie de 24 h se ve pequeña.

**Solución.**

- Añadir `.resizable` y un tamaño mínimo de 380×260; tamaño inicial 560×380.
- Pasar el contenido a Auto Layout: la gráfica ocupa todo el espacio libre y
  los controles quedan anclados abajo.
- Recordar tamaño y posición con `setFrameAutosaveName("MirloGrafica")`.
- Adaptar el dibujo al tamaño: más etiquetas de hora (cada 3/6 h) cuando hay
  ancho, 4–5 líneas de guía y tipografía algo mayor.
- Añadir **Mantener encima** (desactivado por defecto): una ventana grande
  flotando sobre todo molesta; el pin se guarda en `config.json`.
- El botón verde de zoom y el doble clic en la barra de título funcionan como
  en cualquier ventana.

**Criterio de aceptación.** Se puede agrandar hasta pantalla completa sin
recortes ni deformación; al cerrar y abrir conserva tamaño y posición; la
gráfica sigue legible en 380×260 y en 1200×800.

**Esfuerzo.** 1–2 sesiones. Riesgo bajo.

#### 7. Lenguaje visual y pulido de toda la app

**Problema.** La app funciona, pero se nota que cada ventana se ha ido montando
por separado: posiciones absolutas, controles por defecto, márgenes distintos,
checkbox donde debería haber un interruptor y una gráfica pequeña sin
interacción. El resultado es correcto pero **tosco**, y la primera impresión
(onboarding) no está a la altura de la App Store.

**Solución.** Un sistema de diseño pequeño y reutilizable, sin reescribir en
SwiftUI ni añadir dependencias.

> No hace falta SwiftUI para que se vea actual: AppKit con Auto Layout,
> materiales nativos y SF Symbols da el mismo resultado y evita mezclar dos
> arquitecturas. Si algún día se quisiera probar, la única candidata sería la
> ventana de Ajustes, nunca el motor ni la barra.

**7.1 Sistema de diseño**

- Rejilla de 8 pt; márgenes de 20/24; relleno de tarjeta 16; radios de 10
  (tarjetas) y 6 (controles).
- Tipografía con `NSFont.preferredFont(forTextStyle:)`: título 22/17 semibold,
  sección 13 semibold, cuerpo 13, secundario 11. Números con
  `monospacedDigitSystemFont` para que no bailen.
- Colores semánticos (`labelColor`, `secondaryLabelColor`, `separatorColor`,
  `controlBackgroundColor`, `windowBackgroundColor`, accent del sistema). Nada
  de colores fijos salvo el resaltado que elige el usuario.
- Materiales nativos: barra lateral `.sidebar`, fondo de ventana y tarjetas
  `controlBackgroundColor` con borde `separatorColor`.
- Controles: `NSSwitch` para activar/desactivar, `NSPopUpButton` para elegir,
  botón `.push` para la acción principal y `.rounded` para la secundaria.
- Iconos SF Symbols con el mismo peso y tamaño; nada de imágenes sueltas.
- Componentes reutilizables en un archivo nuevo `UI.swift`: `TarjetaAjustes`,
  `FilaAjustes`, `CabeceraSeccion`, `EstadoVacio`, `BotonPrimario`.
- Nada de posiciones absolutas en código nuevo: `NSStackView` y `NSGridView`.

**7.2 Onboarding**

- Ventana de 520×480 con icono de 64, título de 24 y subtítulo.
- Dos tarjetas grandes: **Tengo una estación Netatmo** y **Ver el tiempo de mi
  localidad**, con icono, explicación y botón. La tarjeta completa es pulsable.
- El paso de localidad usa el mismo campo de búsqueda con sugerencias, spinner,
  error en línea y botón **Volver** secundario.
- **Ahora no** discreto, no un botón perdido en el centro.

**7.3 Avisos**

- Cada regla es una tarjeta con nombre, resumen legible, interruptor, último
  disparo y menú de acciones (editar, duplicar, borrar).
- Estado vacío con `bell.slash` y un botón **Crear la primera regla**.
- Permiso de notificaciones como insignia de estado con acción directa.
- Editor en hoja de 520×440 con filas alineadas, **Probar** y guardar/cancelar.
- Sustituir el `NSScrollView` con borde biselado por una lista limpia.

**7.4 Gráfica**

- Barra de herramientas con selector de campo, **Mantener encima** y
  **Compartir/Exportar PNG**.
- Relleno degradado bajo la línea, línea de 2 pt, rejilla discontinua suave,
  punto final y estado vacío con `chart.line.uptrend.xyaxis`.
- Al pasar el ratón: cruz vertical y globo con `13,4 °C · 14:30`. Es la mejora
  que más «moderniza» la ventana sin tocar los datos.
- Insignia de origen (`Netatmo` / `local`) y contador de muestras en el pie.

**7.5 Menú y barra**

- Iconos SF Symbols en los ítems principales: termómetro, casa, viento, lluvia,
  llama, gráfica, engranaje.
- Números con dígitos monoespaciados también en el menú.
- Cabeceras de sección, separadores consistentes y ningún icono decorativo de
  más.
- La barra mantiene iconos template y texto; no se fuerza color.

**7.6 Movimiento y accesibilidad**

- Transiciones de 150–200 ms con `easeOut`; si **Reducir movimiento** está
  activo, sin animación.
- Foco visible, orden de tabulación lógico y `Esc` para cerrar hojas.
- Probar en claro, oscuro, aumento de contraste y VoiceOver.

**Criterio de aceptación.** Todas las ventanas comparten márgenes, tipografía y
controles; no hay ninguna ventana nueva con posiciones absolutas; clear/dark se
ven igual de cuidados; las capturas de la App Store se pueden hacer sin retocar.

**Esfuerzo.** 5–8 sesiones. Riesgo medio (mucho detalle visual, poca lógica).

### 1.1.1 — «Sin fricción»

> **Estado:** siguiente entrega, después de la 1.1. No bloquea la salida de la
> 1.1.

#### 8. Estación principal y localidades guardadas

**Problema.** En cuentas con varias estaciones, la principal la decide Netatmo.
En modo localidad solo hay una ubicación y cambiarla es un onboarding.

**Solución.**

- **Cuenta:** `estacion_principal` (nombre de la estación) en `config.json`;
  selector en Ajustes → Estaciones. El menú agrupa por estación.
- **Localidad:** hasta 5 localidades con nombre, coordenadas y selección
  automática/manual propia. Menú **Localidad** con lista, **Añadir**,
  **Renombrar** y **Quitar**.
- Migración transparente: si no hay lista, la localidad actual pasa a ser la
  primera. La activa sigue viviendo en `localidad`.
- Cambiar de estación o localidad reutiliza la última respuesta
  (`datosBrutos`) o pide una lectura nueva, y descarta respuestas antiguas con
  un contador de generación.

**Criterio de aceptación.** Cambiar de estación o localidad se hace en dos
clics, sin onboarding, y sobrevive al reinicio.

**Esfuerzo.** 3–4 sesiones. Riesgo medio (migración de configuración).

#### 9. Avisos: exportar, importar y silenciar desde la notificación

**Problema.** Las reglas viven en un solo Mac y silenciar una regla obliga a
abrir la ventana.

**Solución.**

- Exportar/importar reglas en JSON con `version` y validación; preguntar
  **fusionar** o **reemplazar**.
- Acciones en la notificación: **Silenciar 1 h** y **Abrir Mirlo**.
- No exportar historial ni estados de anti-spam, solo reglas.

**Criterio de aceptación.** Exportar en un Mac e importar en otro reproduce las
reglas; silenciar desde la notificación no vuelve a avisar en 1 h.

**Esfuerzo.** 2–3 sesiones. Riesgo medio (notificaciones y formato).

#### 10. CI, diagnóstico y pruebas completas

- Pruebas de migración de configuración, exportación/importación y cobertura
  completa de claves de localización.
- CI en GitHub Actions (requiere un token con permiso `workflow` o crearlo
  desde la web).
- **Copiar diagnóstico** en ⌥: versión, modo, última lectura, último error y
  tamaño del historial, sin tokens ni coordenadas.

**Esfuerzo.** 2–3 sesiones. Riesgo bajo.

### Conviene entrar si hay tiempo

> Cualquiera de las dos entregas. No bloquea la salida.

- **Exportar historial a CSV** (24 h; más adelante, rangos mayores) para hojas
  de cálculo.
- **Comparar con ayer** en la gráfica (misma hora, misma escala).
- **Resumen semanal**: mín/máx, media, días de caldera y lluvia acumulada.
- **Compartir gráfica como imagen** (PNG) para soporte o para enseñarla.
- **Aviso de helada** con la mínima prevista de la propia estación, si hay
  histórico suficiente; sin inventar pronóstico.
- **Modo compacto de barra**: solo icono + valor, o icono + color de estado.

### Fuera de 1.1 (valorar 1.2)

- **Widget de macOS** (WidgetKit): requiere App Group, otro target y probar el
  sandbox. Es la mejora más vistosa, pero no cabe con garantías en 1.1.
- **Rango de 7 días en la gráfica**: primero hay que validar límites de
  `getmeasure`, ampliar la caché y decidir cómo se representa. Se pospone a 1.2.
- **Atajos / App Intents**: «¿Qué tiempo hace?», «Abre la gráfica».
- **WeatherKit / pronóstico**: añade permiso, atribución y una dependencia de
  Apple; cambia el producto de «mi estación» a «el tiempo».
- **Histórico público compartido** para el modo localidad: hoy `getpublicdata`
  solo da el dato actual. Habría que muestrear estaciones en el Worker con un
  cron y asumir coste y privacidad; no es un cambio de app.
- **Sincronización entre Macs**: exige cuentas y nube; contradice el diseño
  actual.
- **Escritura en Netatmo o caldera**: nunca.

## Cambios en el Worker

Solo los necesarios para la gráfica por módulo:

1. `/v1/history` acepta `id` de módulo.
2. La caché de D1 usa una clave que incluye cuenta, módulo y tipo.
3. Se valida que el módulo pertenece a la cuenta antes de `getmeasure`.
4. Tests de ruta, permisos, caché y límites de Netatmo.
5. Sin secretos nuevos y sin cambios en el contrato de `/v1/readings`.

El Worker sigue **privado**. Si algún día se publica, será un repositorio aparte
con `DEPLOY.md`, configuración de ejemplo y sin credenciales.

## Plan de publicación

1. **1.0.x**: solo si Apple pide cambios o aparece un fallo crítico. No mezclar
   con 1.1.
2. **1.1 beta**: TestFlight interno (la cuenta del autor) durante una semana.
3. **1.1 App Store**: capturas nuevas, texto de novedades, privacidad sin
   cambios y despliegue por fases si Apple lo permite.
4. **1.1.1**: misma ficha y mismas capturas salvo que cambie la UI; actualizar
   `CHANGELOG` y notas de la versión.
5. **Documentación**: enlace de App Store, página de soporte y privacidad en
   `mirloapps.es`, y `CHANGELOG` al día.
6. **GitHub**: solo código y issues; sin binarios ni releases.

## Calendario orientativo

Con el reparto acordado, la 1.1 se queda en **17–26 sesiones** (10–15 jornadas
reales; 9–12 semanas a ratos). Si se hubiera mantenido todo junto, habrían sido
24–36.

#### Calendario 1.1 — «La puesta a punto»

| Semana | Trabajo |
| --- | --- |
| 1 | Worker (`id`) + tests + catálogo de campos |
| 2–3 | Gráfica por módulo + tendencias |
| 4–5 | Ajustes con barra lateral (incluye la sección de Avisos) |
| 6–7 | Lenguaje visual: onboarding, avisos, gráfica y menú |
| 8 | Accesibilidad + inglés + pruebas + TestFlight |
| 9 | Beta + App Store + colchón |

**Total: 17–26 sesiones**, 10–15 jornadas reales; 9–12 semanas a ratos.

#### Calendario 1.1.1 — «Sin fricción»

| Semana | Trabajo |
| --- | --- |
| +1–2 | Estación principal + localidades guardadas |
| +2–3 | Avisos: exportar/importar/acciones |
| +1 | Tests, CI y documentación |

**Total: 7–10 sesiones.**

Así la 1.1 sale moderna y coherente, y las funciones de gestión no retrasan la
parte que más se ve. Si prefieres mantenerlo todo en una sola versión, el total
sube a 24–36 sesiones y el calendario a 12–16 semanas a ratos.

## Métricas de éxito

**1.1**

- Al menos el 80 % de las aperturas de la gráfica en modo cuenta usan la serie
  de Netatmo, no la local.
- Cero aumentos de errores de red o de crashes en la beta.
- VoiceOver recorre menú, gráfica y ajustes sin saltos.
- Todas las ventanas comparten márgenes, tipografía y controles; no hay ninguna
  ventana nueva con posiciones absolutas.
- La gráfica se lee bien de 380×260 a pantalla completa y recuerda su tamaño.
- El soporte se reduce: menos correos de «solo veo datos desde que abrí la app».

**1.1.1**

- Cambiar de estación o localidad se hace en dos clics.
- Ninguna regla de aviso se pierde al exportar/importar.
- La integración continua compila las dos variantes en cada cambio.

## Decisiones tomadas

1. **Alcance:** partido en **1.1 (puesta a punto)** y **1.1.1 (localidades y
   avisos exportables)**. Acordado.
2. **Gráfica:** solo 24 h en 1.1. El rango de 7 días se valora en 1.2, cuando el
   contrato del Worker y la caché estén asentados.
3. **Inicio:** cuando Apple apruebe la 1.0. Hasta entonces no se toca el código
   de la app; el Worker puede prepararse en local sin desplegar.
4. **Accesibilidad:** requisito de salida de la 1.1.
5. **Widget y pronóstico:** se deciden para 1.2 después de ver la acogida de la
   1.0.
6. **Worker:** sigue privado.
7. **Ajustes:** una sola ventana con **barra lateral**, no pestañas;
   **Avisos…** se mantiene como atajo a su sección.
8. **Gráfica:** redimensionable, con tamaño y posición recordados, pin opcional y
   tooltip al pasar el ratón.
9. **Pulido visual:** entra en 1.1 y no es opcional; afecta a onboarding,
   ajustes, avisos, gráfica, menú y barra.
10. **Localidades y exportación de avisos:** a 1.1.1. Acordado para no retrasar
    la puesta a punto visual de la 1.1.

## Checklist de arranque

Cuando Apple apruebe la 1.0:

1. Etiquetar localmente el estado publicado (`git tag 1.0`), sin crear releases
   en GitHub.
2. Crear la rama `1.1` y dejar `main` como la versión en tienda.
3. Empezar por el Worker en local: `id` de módulo, validación y tests.
4. Portar el catálogo de campos y la gráfica por módulo.
5. No subir nada a `main` hasta que la 1.1 pase la beta interna.

## Estado del arranque

- [x] Rama `1.1` en la app y en el Worker (17/11/2026). `main` sigue intacto.
- [x] Worker: `/v1/history?id=` con catálogo por modelo, validación contra
  `getstationsdata`, caché por módulo y 8 tests nuevos (76 en total).
  **Desplegado** el 17/11/2026 (versión `568a87bc`) y verificado con una cuenta
  real: exterior e interior por `id`, compatibilidad con `modulo=` y caché en la
  segunda llamada.
- [x] App: catálogo de campos desde `modulos`, selector agrupado por estación y
  módulo, consulta por `id` y respaldo local. Compila en el target de Xcode
  (`APPSTORE`). Caldera y lluvia instantánea siguen como historial de este Mac.
- [x] Gráfica redimensionable: 560×380 inicial, mínimo 380×260, Auto Layout,
  tamaño y posición recordados, pin opcional (apagado por defecto), exportar
  PNG y ejes que se adaptan al ancho y al alto.
- [x] Ventana única de Ajustes (760×560, mínimo 720×520) con barra lateral
  nativa de 210 px (`NSSplitViewController` + `NSOutlineView` estilo
  `.sourceList` sobre `NSVisualEffectView` `.sidebar`). Secciones General,
  Barra y menú, Estaciones, Avisos y Avanzado (esta solo con ⌥). La sección se
  guarda en `config.json` (`ajustes_seccion`); `Avisos…` abre la misma ventana
  en su sección. `VistaAvisos` es una vista reutilizable y el editor sigue
  siendo una hoja sobre la ventana contenedora. Cada regla usa un menú «…»
  (silenciar/reactivar, editar, eliminar) para que la lista quepa sin recortes.
  Las tarjetas usan `TarjetaAjustes` con fondo y borde dinámicos.
- [x] Onboarding rediseñado: ventana de 520×480, icono de 60, título de 24 y
  dos tarjetas pulsables con icono, explicación y chevron. La pantalla de
  localidad usa Auto Layout, centra el formulario y la lista de sugerencias
  flota bajo el campo con altura ajustada. Las tarjetas tienen rol de botón,
  foco visible y fondo/borde que se adaptan al modo claro y oscuro.
- [x] Tendencias visibles: el menú añade `↑/↓ 0,6° en 30 min` a la temperatura
  exterior e interior reutilizando el cálculo de los avisos, tanto con cuenta
  como en modo localidad (solo exterior). Nueva opción de barra «Temperatura
  interior con tendencia». Sin historial suficiente (o con menos de 0,1° de
  cambio) no se muestra ninguna flecha.
- [x] Accesibilidad: la gráfica se expone como imagen con un resumen hablado
  (`Gráfica de Temperatura exterior, último valor 15,9 °C`) y con el origen de
  los datos como ayuda; los botones de solo icono (pin y exportar) tienen
  etiqueta. VoiceOver la anuncia y se actualiza al cambiar de campo.
- [x] Atajos de teclado: `⌘,` abre Ajustes y `⌘R` actualiza tanto con el menú
  abierto (equivalentes del menú) como con una ventana de Mirlo en primer
  plano (monitor local). `Esc` cierra la gráfica sin tocar el resto.
- [x] Localización completa: todas las claves usadas en el código están
  presentes en `es` y `en`. `Tests/claves.py` lo comprueba y falla si falta
  alguna (hoy, 503).
- [x] Pruebas mínimas: `./pruebas.command` compila el código real de avisos y
  localidades y ejecuta 55 comprobaciones del histórico local, el motor de
  avisos (umbral, espera mínima, duración, silencio, datos obsoletos,
  tendencia), la validación de la configuración, la estación principal, el
  archivo de avisos y la migración de localidades. No tocan `~/.netatmo-free`.
- [x] Menú revisado con datos reales: jerarquía de datos y acciones por
  separadores, tendencia junto a la temperatura y atajos visibles (`⌘R`, `⌘,`).
  macOS no dibuja imágenes en los ítems de este menú de barra (probado con un
  SF Symbol y con una imagen sólida), así que se descartaron los iconos en vez
  de dejar código muerto.
- [x] Movimiento y contraste: la app no usa animaciones y todo el color sale de
  colores dinámicos y materiales del sistema, así que «Reducir movimiento» y
  «Aumentar contraste» se respetan sin código extra.
- [ ] Etiqueta `1.0` cuando Apple apruebe.
- [ ] Subir las ramas `1.1` a GitHub cuando el usuario lo pida.

## Estado de la 1.1.1

- [x] Estación principal en cuentas con varias estaciones: `estacion_principal`
  en `config.json` (vacío = la que elige Netatmo), selector en Ajustes →
  Estaciones visible solo si hay dos o más. Al cambiarla se reaplican exterior
  e interior desde la última respuesta, sin esperar a otra consulta.
- [x] Hasta cinco localidades guardadas (`localidades`), con la activa en
  `localidad`. Migración transparente: la localidad existente entra en la lista
  al arrancar.
- [x] Menú **Localidad** con la lista (marca en la activa) y acciones para
  **Añadir localidad…**, **Renombrar esta localidad…** y **Quitar esta
  localidad…** (con confirmación; nunca queda vacía la lista).
- [x] Cambiar de localidad no repite el onboarding, limpia datos e histórico y
  descarta la respuesta de la consulta anterior con `generacionLocalidad`.
- [x] Verificado en vivo con dos localidades: añadir (Cillorigo de Liébana),
  renombrar (Algete → Algete casa), cambiar (barra y menú pasan de Daganzo de
  Arriba a San Vicente de la Barquera) y quitar la activa (vuelve a la otra).
- [x] 504 claves traducidas en `es` y `en`; `./pruebas.command` pasa a 55
  comprobaciones con las de localidades, estación principal, archivo de
  avisos (exportar, fusionar, reemplazar y validación) y migración.
- [x] Avisos: **Más → Exportar avisos…** e **Importar avisos…** en formato
  JSON con `version`, validación y elección entre fusionar o reemplazar. Solo
  viajan las reglas (ni historial ni silencios). Verificado en vivo: exportar
  un archivo con dos reglas, añadir una tercera y fusionarla en la app.
- [x] Acciones en la notificación: **Silenciar 1 h** (silencia esa regla) y
  **Abrir Mirlo** (abre el menú de la barra). La categoría se registra al
  preparar las notificaciones y cada aviso lleva el id de su regla.
- [ ] Acciones de notificación en vivo: la compilación de pruebas va sin firmar
  y macOS no la lista en Notificaciones; hay que probarlas con una compilación
  firmada o la beta de App Store Connect.

## Estado de la sección 10 (CI, diagnóstico y pruebas)

- [x] Pruebas de migración de localidades extraídas a
  `migrarLocalidades(activa:lista:)` en `Localidad.swift` y cubiertas por la
  suite: 55 comprobaciones en total.
- [x] **Copiar diagnóstico** también en ⌥ → Avanzado del menú de barra (ya
  estaba en Ajustes → Avanzado). Incluye versión, macOS, modo, servicio,
  idioma, último dato, última consulta, último error, módulos, muestras del
  historial local y avisos; sin credenciales ni coordenadas.
- [x] CI preparado en `.github/workflows/ci.yml`: dos trabajos en `macos-15`
  (pruebas + claves con `./pruebas.command`, y compilación Release sin firmar).
- [ ] **Activar el flujo en GitHub**: el token disponible no tiene permiso
  `workflow`, así que el archivo queda en el repo y hay que crear/editar el
  workflow desde la web (o con un PAT con `workflow`) para que Actions lo ejecute.
- [ ] Verificar ⌥ → Avanzado con el teclado físico: el ítem sigue el mismo
  patrón verificado de `itAvanzado` (`isHidden` en `menuWillOpen`), pero en esta
  sesión no se pudo mantener ⌥ pulsada con las herramientas de automatización.
