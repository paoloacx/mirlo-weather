# Cambios

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
