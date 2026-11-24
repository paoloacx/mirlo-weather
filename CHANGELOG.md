# Cambios

## 1.1.1 (en preparación) — «Sin fricción»

- Estación principal en cuentas con varias estaciones: se elige en Ajustes →
  Estaciones y el menú, la barra y la gráfica usan sus datos. Sin cambios en el
  Worker: se agrupa por el nombre de estación que ya publica.
- Hasta cinco localidades guardadas. El menú **Localidad** permite cambiar,
  añadir, renombrar y quitar sin repetir la bienvenida; la activa se recuerda
  entre arranques y las respuestas antiguas se descartan al cambiar.
- Migración transparente de `config.json`: la localidad que ya existía pasa a
  formar parte de la lista.
- Avisos exportables e importables en JSON con versión: al importar se elige
  entre fusionar con los actuales o reemplazarlos. El archivo solo lleva
  reglas, nunca historial ni silencios.
- Acciones en la notificación: **Silenciar 1 h** y **Abrir Mirlo**.
- Diagnóstico ampliado (última consulta, último error y tamaño del historial)
  disponible también en ⌥ → Avanzado del menú de barra.
- CI preparado en GitHub Actions (pruebas + compilación sin firmar); pendiente
  de activar el flujo con un token con permiso `workflow`.
- Pruebas de la estación principal, las localidades, la migración, el archivo
  de avisos y su validación: `./pruebas.command` sube a 55 comprobaciones.

## 1.1 (en preparación) — «La puesta a punto»

- Gráfica por módulo y sensor: selector agrupado por estación con el catálogo
  que publica el Worker, consulta por `id` de Netatmo y respaldo local cuando
  el campo no tiene histórico oficial.
- Gráfica redimensionable (560×380 inicial, mínimo 380×260): recuerda tamaño y
  posición, se puede fijar encima de otras ventanas y exportar como PNG.
- Tendencias de temperatura en el menú (`↑/↓ 0,6° en 30 min`) y nueva opción de
  barra «Temperatura interior con tendencia».
- Ajustes en una sola ventana con barra lateral: General, Barra y menú,
  Estaciones, Avisos y Avanzado (esta solo con ⌥). La sección elegida se
  recuerda y `Avisos…` abre la misma ventana.
- Onboarding rediseñado con tarjetas, foco visible y sugerencias de localidad
  ancladas al campo.
- Accesibilidad: la gráfica se anuncia con su último valor, los botones de solo
  icono tienen etiqueta y `⌘,` / `⌘R` / `Esc` funcionan con una ventana abierta.
- Pruebas mínimas (`./pruebas.command`) del motor de avisos y comprobación de
  las 467 claves de localización en español e inglés.

## 0.4.1 (17) — compilación independiente

- La gráfica 24 h usa el histórico oficial de Netatmo (`getmeasure`) para
  temperatura, humedad, CO₂, presión y ruido, aunque la app haya estado cerrada.
- El eje es siempre de 24 h y los huecos de más de 45 minutos se dejan en blanco
  en vez de unirse con una recta.
- Si un campo no tiene histórico en Netatmo (viento o lluvia de una estación
  cercana, caldera), el pie lo indica y se usan las muestras de este Mac.
- Corrige la 0.4.0 instalada, que no llegaba a pedir el histórico al Worker.

## 1.0 (1) — App Store

- Primera versión distribuida en la App Store (macOS 13 o posterior).
- Sandbox, llavero de datos protegidos y `PrivacyInfo.xcprivacy`.
- Sin actualizador propio: las actualizaciones llegan por la App Store.
- Español e inglés.
- Modo con cuenta Netatmo y modo sin cuenta por localidad.
- Estaciones públicas cercanas, selección automática por mediana y selector
  manual.
- Barra configurable, avisos, gráfica 24 h, caldera oficial y resaltado por
  bloques.

## 0.4.0 (16)

- Añadido el modo «solo localidad»: geocodificación por texto, búsqueda de
  estaciones públicas con `/v1/public/around`, caché compartida en D1 y
  composición automática o manual.
- Ventana de bienvenida con las dos vías de uso.
- Selector de estaciones para elegir la fuente de temperatura, viento y lluvia.
- Gráfica limitada a los campos disponibles en modo localidad.

## 0.3.x

- Estación pública cercana para lluvia y viento.
- Histórico oficial de caldera, avisos configurables, gráfica 24 h, resaltado
  por bloques, inicio al arrancar y actualizador de GitHub (retirado en 1.0).

## 0.2.x

- Primeras versiones públicas con OAuth multiusuario, varios módulos y barra de
  menús.
