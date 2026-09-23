# REVISIÓN 02 — Capa de medición y capacidad de anticipación

> **Fecha:** 18/09/2026 · **Base:** plan v48 vía `CONTEXTO_AGENTE.md`, `WORKFLOWS/WF1.json`, `WF3.json`, más `WF4.json` y `WF5.json` (los toca la misión: promedios y cooldown), y la **estructura** de Supabase (columnas, definiciones de vistas, cuerpo de las RPC, índices, triggers, extensiones). No se leyó `implementation_plan.md`.
>
> **Sobre los datos:** no se calculó ninguna estadística sobre `lectura_sensores`. Las ~220 filas son sintéticas y la base está congelada desde el 20/08. Todo lo que dice este documento sobre el comportamiento físico de un sustrato es conocimiento general de dominio o hipótesis, y se marca como tal. La base se consultó solo para saber **qué** se guarda, no **cuánto vale**.
>
> **Convención de severidad:** 🎨 *queda feo* · 📉 *pierde un dato* · 🌱 *daña el cultivo*.
>
> **Numeración:** hallazgos nuevos desde **16.41**, diferidos desde **B.15**. No se reusa ningún número.

---

## 0 · Resumen

1. La lógica temporal del sistema es una sola: `valor < umbral` en el instante del POST. Hay **un bit de memoria** (`resultado` del último riego, que nada escribe) y **un rate limiter** (15 min entre órdenes de riego). No hay confirmación, filtro, derivada ni detección de silencio.
2. Alcanza para el diagnóstico informativo y **no para el actuador**: una lectura espuria baja produce un riego real, y hoy **no hay tope a cuántos riegos seguidos puede ordenar** (16.41). Es lo único de este documento que puede matar una planta con el código actual.
3. Tres huecos de lo que se guarda **no se reparan retroactivamente con más datos**: sin timestamp de dispositivo ni secuencia (16.42), temperatura descartada en el borde (16.43), y nadie detecta que el nodo dejó de mandar (16.45). La base congelada desde el 20/08 sin una alerta es la demostración en vivo del tercero.
4. Cuatro puntos se resuelven con más datos y tres exigen cambiar la arquitectura. La sección 9 los separa.
5. La anticipación de etapa por NPK (punto 7) es hipótesis válida pero **no verificable dentro de la tesis**; se propone qué registrar desde ahora y una alternativa agronómica más barata.

---

## 1 · Cadencia de muestreo

### Qué hay hoy

Nada. `CONTEXTO_AGENTE.md §1` dice que el ESP32 no existe y que se simula con PowerShell; `WF1.json` acepta cualquier POST cuando llegue. El esquema tampoco fija cadencia: `lectura_sensores.fecha_hora` tiene `DEFAULT now()` y la RPC `fn_registrar_telemetria` no recibe timestamp. La cadencia es una decisión del firmware que **todavía nadie tomó**, y este documento la propone como contrato, no como parche.

Un dato estructural que habilita la propuesta: **el pipeline ya soporta cadencias distintas por variable.** El Motor evalúa cada métrica solo si `!== undefined && !== null`, `Consolidar datos` convierte la ausencia en `null` antes de la RPC (16.34), y `fn_registrar_telemetria` filtra `WHERE v.valor IS NOT NULL`. Un POST que traiga solo humedad se procesa y se guarda sin tocar nada. Evidencia: `WF1.json`, nodos `Motor de Inferencia` y `Consolidar datos`; cuerpo de la RPC en `pg_proc`.

### Propuesta por variable

La regla que ordena todo: la cadencia la fija **la decisión más rápida que se toma con esa variable**, no el fenómeno más lento que la describe. La humedad cambia en horas, pero el sistema toma una decisión sobre ella cada 15 minutos (el cooldown de `Verificar Cooldown` en WF5). Esa es la restricción real.

| Variable | Constante de tiempo del fenómeno | Decisión más rápida que la usa | Cadencia propuesta | Alternativa descartada y por qué |
|---|---|---|---|---|
| **Humedad** | horas (secado de una maceta) | recheck de riego a 15 min (13.7.1); derivada sobre ~2 h (punto 5) | **10 min** | *1 min:* siete mil filas/día por planta, ruido del sensor convertido en eventos, y una alerta Telegram por lectura mientras dure la sequía (hoy WF1 avisa en cada POST). *1 h:* el recheck a 15 min no tiene con qué medirse, un evento de 2 h queda con dos puntos, y el riego se ordena sobre un valor de hasta una hora de antigüedad. |
| **Temperatura** | horas, ciclo diario | ninguna hoy (se descarta, ver 16.43) | **10 min, en el mismo paquete que humedad** | *No medirla:* es la covariable que hace falta para los puntos 3, 5 y 6, y es gratis: el sensor la entrega en la misma consulta. |
| **pH** | días | alerta de estrés químico | **1 h** | *Cada 10 min:* no agrega información sobre un fenómeno de días, sextuplica filas y multiplica las alertas de un pH fuera de rango que va a durar días. *Diaria:* pierde la posibilidad de filtrar ruido por mediana intradiaria y de ver un desplome tras una fertilización (hipótesis: ocurre en horas). |
| **N, P, K** | días a semanas | alerta de estrés químico; tendencia (punto 7) | **1 h, mismo paquete que pH** | Igual que pH. Además (hipótesis marcada): los sensores 7-en-1 de bajo costo derivan NPK de la conductividad eléctrica, no miden iones; separarlos de pH no tiene sentido físico. |
| **Foto / etapa** | semanas | ventana de WF3 (80 % de la duración) | **1 por día, hora fija** | *Foto en cada POST:* payload enorme, Storage, y WF2 llama a Gemini en cada alerta con foto. *Semanal:* WF3 ya deduplica por `ultima_foto_evaluada_path`, así que evaluar cada 8 h una foto diaria cuesta una llamada por día; semanal atrasa hasta 7 días una transición que la ventana ya dejó abierta. |

Volumen resultante, por planta: 2 filas cada 10 min + 4 filas por hora ≈ 384 filas/día ≈ 140 000/año. Trivial para Postgres. Lo que **no** es trivial: 144 ejecuciones de WF1 por día por planta en n8n. No sé cómo está configurada la poda de ejecuciones en el contenedor (no leí el compose; es un dato a verificar y toca B.13/B.14).

### Qué se pierde si se elige mal

Demasiado lento: el sistema **no puede** ver nada más rápido que su intervalo. Con 1 h, una maceta volcada o una fuga se ven cuando ya pasaron, el recheck es imposible de implementar y el riego se ordena sobre un valor viejo, que es la manera más silenciosa de regar dos veces. 🌱.

Demasiado rápido: el costo no es el disco, es el **ruido convertido en decisiones**. Cada lectura es hoy una decisión completa (alerta + riego): multiplicar lecturas multiplica falsos positivos, y multiplica alertas Telegram mientras persista cualquier condición. **Subir la cadencia sin resolver B.7 rompe el producto**: 🎨 que escala a "el usuario apaga las notificaciones", peor que 🌱 porque después no se entera de nada.

### Cuánta operación real hace falta para verificarla

La cadencia correcta **no se puede deducir, se mide una vez**. Hace falta un piloto corto con un sensor real: **una a dos semanas** grabando a la máxima cadencia que el hardware permita (1–2 min), sin decidir nada, y después submuestrear offline para ver a partir de qué intervalo la curva de secado ya no se distingue. Más un experimento de un día: tres o cuatro riegos forzados midiendo cuánto tarda el sensor en reflejar el agua. Ese número —la constante de tiempo del *sensor*, no del sustrato— es el que fija el cooldown, el retraso del recheck y la cadencia mínima de humedad. Hoy los 15 minutos de `TIEMPO_ABSORCION_MIN` son una constante escrita en un nodo Code sin ningún dato detrás (hipótesis, y la marco como tal: no encontré en los artefactos leídos de dónde salió).

Se abre **B.15**: *La cadencia de muestreo es una decisión de contrato entre firmware y webhook, y queda registrada como pendiente con la propuesta de esta sección.*

---

## 2 · Ausencia de memoria

### Qué hay hoy, con precisión

Decir "no hay memoria" es casi cierto. Hay exactamente dos lecturas del pasado en el camino que actúa:

- `Obtener Ultimo Riego` en WF1 lee `vista_ultimo_riego` y el Motor usa `resultado === 'insuficiente'` para levantar `falla_riego_persistente`. Es memoria de un bit. Pero `fn_registrar_riego` inserta `evento_riego` con `resultado` en su default `'pendiente'`, no hay trigger en el esquema (verificado: cero triggers no internos en `public`) y ningún workflow escribe esa columna. El bit **existe y nadie lo enciende.** Coincide con lo que dice `CONTEXTO_AGENTE.md §8` sobre 13.7.1.
- `Get many rows` en WF5 lee la misma vista para el cooldown: recuerda *cuándo se ordenó* el último riego, no si ocurrió.

`vista_promedios_recientes` existe (ventana fija de 6 h, `avg` por métrica, `count(DISTINCT ls.id)` como `total_lecturas`) y la consume **solo** el nodo `Consultar Promedios` de WF4, que está inactivo (`"active": false`). WF1 no la referencia en ningún nodo. Verificado en los dos JSON.

Dos observaciones de estructura sobre esa vista, porque van a importar cuando alguien la use: `total_lecturas` cuenta **filas**, y una lectura son cinco filas (formato largo), así que el número está inflado ×5 (🎨); y una media de 6 h tiene un retraso inherente de ~3 h ante un cambio de escalón, lo cual es adecuado para pH/NPK y **contraproducente para humedad**, donde retrasaría 3 h la detección de una sequía. Es una herramienta para el punto 7, no para el punto 3.

### Qué decisiones mejoran con historia

- **Regar o no regar.** Es la decisión irreversible y hoy es sin memoria. Mejora en dos sentidos: confirmar la entrada (punto 3) y saber si el riego anterior sirvió (recheck, 13.7.1). Sin historia, el sistema no puede distinguir "sigue seca porque no la regué" de "sigue seca aunque la regué", que son dos diagnósticos opuestos con dos acciones opuestas.
- **`falla_riego_persistente`.** Es literalmente una decisión con memoria que hoy no tiene de dónde leerla. Código inalcanzable, como dice el plan.
- **Estrés químico (pH, NPK).** Cambian en días. Una lectura aislada fuera de tolerancia es, con probabilidad que no puedo cuantificar sin datos, ruido de un sensor de conductividad. La historia convierte "un valor raro" en "tres días de tendencia", y esa es la diferencia entre una alerta que el usuario ignora y una que atiende.
- **Alertar.** B.7 (notificar por transición, no por nivel) es imposible sin recordar el estado anterior. Es la mejora de producto más grande y depende enteramente de este punto.
- **Exceso hídrico.** Tras un riego es esperable y transitorio; persistente durante horas es un problema de drenaje. Sin historia son el mismo número.

### Qué decisiones no cambian

Revisadas una por una, estas están bien sin memoria:

- **Rama A (sin umbrales)** y **rama B (cinco ceros)**: describen configuración y hardware, no el cultivo. (La B ganaría con historia en un caso: sensor *clavado* en un valor no nulo. Eso es punto 5.)
- **`en_mantenimiento`**: ventana explícita con fecha; ya es memoria, guardada donde corresponde.
- **Ruteo de foto** (`tiene_foto`): decisión sobre el payload actual.
- **WF3 entero**: tiene su propia memoria (`fecha_inicio_etapa`, `ultima_foto_evaluada_path`) y escala de semanas.

### Cuánta operación real hace falta

Para **decidir la arquitectura**, ninguna: el argumento es estructural. Para **verificar que la historia mejora las alertas de pH/NPK**, hace falta al menos **una etapa completa** (semanas) con sensor real, porque hay que ver cuántas alertas por nivel se habrían suprimido por transición y cuántas de esas eran reales. No se puede simular: la tasa de falsos positivos es una propiedad del sensor en ese sustrato.

---

## 3 · Actúa sobre una sola muestra

### Consecuencia física de una lectura espuria

Recorrido en el JSON, sin suposiciones:

Una lectura de humedad por debajo de `humedad_min` en un cultivo con actuador → `hay_sequia = true` → `Requiere Alerta?` abre **tres ramas en paralelo** (Telegram, WF2 si hay foto, WF5) → WF5 pasa el cooldown si el último riego fue hace más de 15 min → `Calcular Dosis` calcula `volumen × 1000 × 0,25 × déficit/100` sobre el centro del rango, con tope de 30 s y `caudal_bomba_ml_s || 50` → `fn_registrar_riego` inserta comando + evento en una transacción. Con los defaults del código (`volumen || 10`, `caudal || 50`) el tope de 30 s son 1,5 litros por pulso sobre una maceta cuya capacidad de agua disponible el propio modelo estima en 2,5 litros. Esto es aritmética sobre las constantes del nodo, no sobre datos.

Los dos defaults merecen una línea: si `volumen_maceta_litros` o `caudal_bomba_ml_s` vienen nulos, el sistema **no aborta, inventa**, en la misma función que aborta explícitamente si faltan los umbrales. Un caudal real de 100 ml/s con default 50 duplica la dosis. Lo dejo señalado para la auditoría pendiente de WF5 (§3), sin número.

La asimetría que decide todo:

- **Falso positivo (lectura espuria baja):** riego real, irreversible. El agua no se retira. Con la planta en 60 % real, un pulso máximo la lleva a exceso hídrico. Un solo evento es 🌱 leve; repetido, es raíz podrida.
- **Falso negativo (lectura espuria alta enmascara una sequía real):** se pierde *una* decisión. La lectura siguiente vuelve a evaluar. El error **se cura solo en un intervalo de muestreo.**

Conclusión: la confirmación hay que exigirla del lado de la **acción**, no del diagnóstico. Un Telegram sobre una sola muestra es 🎨 y se arregla con B.7. Un riego sobre una sola muestra es 🌱.

### El intercambio falsos positivos ↔ latencia, con nombre

Llamémoslo **costo de confirmación**: cada muestra adicional que se exige antes de actuar multiplica por el intervalo de muestreo el retraso de la acción, y divide la probabilidad de actuar por ruido por algo que depende de la distribución del ruido, que **no conozco** porque no hay datos reales.

Dónde ubicarse: el retraso tolerable lo fija la constante de tiempo del sustrato (horas). Con cadencia de 10 min, exigir **dos lecturas consecutivas** bajo umbral cuesta 10 min de latencia; una **mediana de tres** cuesta 10–20 min. Contra un secado de horas, ambos son despreciables; contra un evento de 2 h (punto 5), siguen dejando margen. La propuesta es ubicarse ahí: confirmación de dos muestras para la acción, y ninguna para el diagnóstico.

Alternativas descartadas:

- *Banda muerta sola (sin confirmación):* protege del ruido de amplitud pequeña alrededor del umbral, no de un pico aislado grande (un cable que hace falso contacto). Son dos defensas para dos fallas distintas y hace falta la de confirmación primero.
- *Filtro exponencial (EMA) en vez de mediana:* introduce retraso proporcional al factor de suavizado y no rechaza un pico, lo atenúa y lo reparte. Para un actuador binario, la mediana es más honesta: o hay sequía en la mayoría de la ventana o no la hay.
- *Confirmación también para las alertas:* añade latencia a algo que no daña nada y B.7 resuelve mejor el mismo problema.

### Cuánta operación real hace falta

Dos experimentos cortos, no meses:

1. **Línea de base de ruido:** el sensor en una maceta sin planta ni riego, **24–48 h** a cadencia máxima. Da la distribución de la variación sin causa física. Eso fija el ancho de la banda muerta (punto 4) y cuántas muestras vale confirmar. Sin este dato, cualquier N es una adivinanza.
2. **Inyección de fallas:** desconectar a medias, tocar el cable, sacar y volver a poner el sensor. Un día. Da la forma de los picos que la confirmación tiene que rechazar.

Registro que hoy **no existe** y haría falta para evaluarlo después: nada vincula un `evento_riego` con la lectura que lo disparó (hay `humedad_inicial`, no hay id de lectura, y `lectura_sensores` no tiene id de lectura agrupada; las cinco filas comparten `fecha_hora` porque `now()` es estable dentro de la transacción de la RPC, y esa es la única clave implícita). Se abre **B.16**: *trazabilidad lectura → riego.* Severidad 📉: cuando haya que auditar por qué regó, no se va a poder.

---

## 4 · Histéresis

### Qué resuelve el intervalo mínimo entre riegos

`Verificar Cooldown` compara `now() - fecha_inicio` del último `evento_riego` contra 15 minutos y corta si es menor. Eso es un **rate limiter temporal**. Resuelve una cosa concreta y real: que el agua tarda en llegar al sensor, y sin espera el sistema regaría de nuevo antes de ver el efecto del primer pulso.

No es una banda muerta. Una banda muerta es una condición sobre el **valor**: "no vuelvas a considerar sequía hasta que hayas visto Y". El cooldown es una condición sobre el **tiempo**: "no riegues hasta dentro de 15 min, pase lo que pase con el valor". Y son distintas en el caso que importa:

- Humedad oscila alrededor del umbral por ruido (49,8 → 50,3 → 49,7…): cada bajada es un `hay_sequia`. WF1 manda **un Telegram por cada una**, porque `Alerta Telegram` cuelga de `Requiere Alerta?` en paralelo con `Dispara WF5` y el cooldown vive dentro de WF5, aguas abajo. El cooldown silencia la bomba; no silencia nada más. Evidencia: conexiones de `Requiere Alerta?` en `WF1.json`.
- Humedad se queda baja tras el riego (dosis corta, o el sensor no ve el agua aún a los 15 min): al minuto 16 el sistema vuelve a regar. Y al 31. Y al 46. **No hay tope.** `falla_riego_persistente`, que sería el freno, depende de `resultado = 'insuficiente'` que nadie escribe. Recorrí WF1, WF5, la RPC, los triggers y las vistas: no existe ningún límite de riegos por ventana de tiempo. Esto lo abro como **16.41**.

### 16.41 · Riegos consecutivos sin tope — 🌱

**Qué:** el único limitador entre dos órdenes de riego es el cooldown de 15 min. Un sensor que se queda clavado en un valor bajo no nulo (mal insertado, cable, sustrato seco alrededor de la sonda pero no en la maceta) produce una orden de riego cada 15 minutos indefinidamente, cada una hasta el tope de 30 s. La rama B solo cubre el caso "los cinco en cero"; un sensor en 20 % de humedad con pH y NPK plausibles pasa todas las guardas.

**Por qué importa:** es el único hallazgo de este documento que daña el cultivo **con el código actual**, sin hipótesis sobre el futuro. Hasta que haya bomba real es inofensivo; es la precondición número uno antes de conectarla, junto con 13.7.1, y no es lo mismo que 13.7.1: el recheck dice si el riego *sirvió*; el tope dice cuántos se permiten aunque el recheck no exista o falle. Defensa en profundidad: dos mecanismos independientes para la misma falla catastrófica.

**Alternativa descartada:** confiar en que 13.7.1 lo cubre. El recheck necesita una lectura posterior; si el nodo deja de mandar justo después de regar (lo que hoy tampoco se detecta, ver 16.45), el recheck nunca ocurre y el estado queda en `pendiente`, que es exactamente el estado que hoy **no frena nada**.

### Hace falta histéresis explícita

Sí, pero con una precisión: **ya hay un Y implícito**. `Calcular Dosis` apunta al centro del rango, `(min + max) / 2`. Para Floración del tomate es 57,5 % contra un umbral de 50 % (umbrales en `CONTEXTO_AGENTE.md §10`). Ese es el Y natural. Lo que falta no es inventar Y sino usarlo como **condición de rearme**: después de un riego, no se vuelve a considerar sequía hasta haber *observado* humedad ≥ Y, o hasta que el recheck declare que el riego no llegó (`insuficiente` → falla, no → otro riego).

Dicho así, histéresis y recheck **son el mismo mecanismo**: una máquina de estados por cultivo con al menos `normal → regando → verificando → (rearmado | falla)`. Esto no es un parche a un nodo; es la sección 9.

**Alternativa descartada:** bajar `humedad_min` para "ensanchar la banda". Mueve el umbral, no elimina la oscilación alrededor del nuevo umbral, y mezcla un parámetro **agronómico** (la base de conocimiento) con un parámetro de **control** (el rearme). Son de distinta naturaleza y de distinto dueño: uno lo carga un agrónomo, el otro lo fija el ingeniero según el sensor.

### Cuánta operación real hace falta

El ancho de la banda sale del experimento de ruido del punto 3 (24–48 h). El tiempo hasta rearme sale del experimento de riegos forzados del punto 1 (un día). Para validar que la máquina de estados no se queda pegada en un estado, hace falta **una a dos semanas de riegos reales** con la planta secándose y volviendo a regarse varias veces. Es el mismo piloto de la sección 1: todo lo de esta mitad del documento se verifica en el mismo mes.

---

## 5 · Valor contra derivada

### Qué puede ver el sistema hoy

Solo el valor. El Motor recibe `$('Webhook').first().json` y los umbrales; no hay ninguna expresión en WF1 que reste dos lecturas ni que consulte `lectura_sensores`. Verificado.

### Fenómenos que solo existen en la derivada

Todos son hipótesis de dominio (no hay serie para confirmar magnitudes), pero la **forma** de cada uno es razonablemente conocida:

| Fenómeno | Firma en la señal | Lo ve el valor absoluto | Severidad de no verlo |
|---|---|---|---|
| Fuga, maceta volcada, sensor arrancado a medias | caída brusca de humedad a una meseta no nula | No: 55 % estable y 55 % tras caer de 70 son el mismo número | 🌱 (si además cruza el umbral, dispara riego sobre una maceta que quizá ya no existe) |
| Golpe de calor | pendiente de secado varias veces mayor que la habitual, con temperatura alta | No | 🌱 (llega a sequía más rápido que la cadencia elegida para el caso normal) |
| **Riego que no llegó** | ausencia de la subida esperada tras `fecha_inicio` | No: es exactamente el hueco de 13.7.1 | 🌱 |
| Riego que llegó de más / drenaje malo | subida y **no** bajada en las horas siguientes | Parcialmente (exceso hídrico), sin distinguir transitorio de persistente | 📉 |
| Deriva del sensor de pH | tendencia monótona lenta sin evento que la explique | No | 📉 hoy, 🌱 cuando haya fertirriego (Fase 15) |
| Fertilización | escalón en NPK / conductividad | No | 📉 (sin este evento registrado, el punto 7 no se puede evaluar) |
| Sensor clavado | derivada **cero** durante horas en una variable que debería moverse | No: el valor puede ser perfectamente plausible | 🌱 (es el caso de 16.41) |

La última fila es la más importante y la menos intuitiva: **una derivada nula también es un evento.** Un sustrato vivo se seca; una humedad que no cambia en ocho horas es un sensor, no una planta.

Y la tercera fila es el puente con el plan: **el recheck de riego (13.7.1) es una medida de derivada.** No es un feature de análisis; es la precondición que el plan ya llama "lo más importante que queda". La derivada no es un lujo de anticipación: el sistema la necesita para cerrar el loop que ya tiene abierto.

### Qué exige que hoy no se guarda

- **Tiempo de medición real (16.42).** `fecha_hora` es `now()` del servidor al insertar. No hay timestamp del dispositivo ni número de secuencia en el contrato del webhook ni en la tabla. Una derivada es Δvalor/Δt; si Δt es el instante en que n8n terminó de procesar y no el instante en que el sensor midió, cualquier retraso (n8n ocupado, reintentos, el dispositivo reenviando lecturas que guardó sin conexión) **fabrica pendientes falsas**. Y sin secuencia no se puede saber si faltan lecturas entre dos puntos, que es la diferencia entre "cayó 15 puntos en 10 min" y "cayó 15 puntos en las 3 h que no mandó nada".
- **Temperatura (16.43).** Sin ella, "golpe de calor" y "fuga" son la misma pendiente.
- **Eventos exógenos:** riegos ya se registran (`evento_riego`); fertilizaciones no tienen tabla; intervenciones manuales (trasplante, cambio de sensor) solo existen como `mantenimiento_hasta`, que es una ventana, no un evento.

### 16.42 · Sin timestamp de dispositivo ni secuencia — 📉 hoy, 🌱 cuando la derivada decida

**Qué:** `lectura_sensores.fecha_hora DEFAULT now()`; `fn_registrar_telemetria` no acepta tiempo; el payload del webhook (`§10`, ejemplo PowerShell) no lo lleva. **Por qué importa:** es el único hueco de este documento que **no se rellena retroactivamente**. Cada día que el sistema funcione sin esto es un día de serie temporal con eje X aproximado. Para el diagnóstico por valor da igual; para todo lo que sigue, no. **Alternativa descartada:** aceptar `now()` y asumir latencia despreciable. Es asumible mientras el dispositivo esté siempre conectado; se rompe el primer día que el ESP32 guarde lecturas offline y las mande en ráfaga, que es la manera normal de comportarse de un nodo de campo.

### 16.43 · Temperatura y conductividad en el catálogo, descartadas en el borde — 📉

**Qué:** `tipos_metricas` tiene 7 filas: Humedad, **Temperatura**, pH, N, P, K, **Conductividad**. El contrato del webhook, el Motor, `Consolidar datos` y la RPC manejan exactamente cinco. Alguien previó las otras dos al diseñar el esquema y el pipeline las tira. **Por qué importa:** la temperatura es la covariable de tres de los siete puntos de esta misión (ruido del sensor, derivada, ritmo diario) y del enfoque agronómico estándar para anticipar etapa (sección 7). Como 16.42, **no se recupera**: el día que se quiera normalizar por temperatura, la historia anterior no la tiene. **Alternativa descartada:** agregarla "cuando haga falta". El costo de guardarla desde el primer día es una fila más cada 10 min; el costo de no tenerla es no poder responder los puntos 5 y 6 nunca sobre el período inicial.

### Cuánta operación real hace falta

Menos de lo que parece: las firmas de los eventos se verifican con **experimentos diseñados, en días** (volcar agua, sacar la sonda, acercar la maceta a una estufa). Lo que sí exige calendario es la **tasa de secado normal** contra la cual una pendiente es "anómala": **una a dos semanas por etapa**, porque una planta en floración transpira distinto que una plántula. A 10 min, un evento de 2 h tiene 12 puntos: suficiente para una pendiente robusta.

---

## 6 · Ritmo diario

### Decisión: no normalizar por hora del día ahora. Sí registrar lo necesario para decidirlo después.

Razones, en orden de peso:

1. **No hay con qué construir el perfil.** Una normalización circadiana es una función "valor esperado según hora" ajustada con semanas de datos reales del mismo cultivo, etapa y estación. No existe un solo día real; ajustarla hoy sería ajustar una curva a datos sintéticos, peor que no tenerla.
2. **Es un efecto de segundo orden.** Un umbral cruzado a las 15 h y a las 6 h significan cosas distintas, sí; pero la diferencia es del orden de la amplitud diaria, y la diferencia entre "actuar sobre una muestra" y "confirmar" (punto 3) es del orden de un riego entero. Primero lo grande.
3. **La mitad que importa se resuelve sin normalizar.** La dependencia térmica del sensor y la transpiración diurna se explican mejor por la temperatura medida (16.43) que por la hora. Con temperatura en la tabla, la hora es derivable a posteriori.
4. **`cultivo.entorno` tiene default `'indoor'`.** Bajo luz artificial el ciclo lo fija el temporizador de la lámpara, no el sol; normalizar por hora solar sería normalizar por la variable equivocada.

**Alternativa descartada:** umbrales distintos por franja horaria en `parametro_etapa`. Multiplica la base de conocimiento por N franjas, la vuelve inmantenible por un agrónomo y encima la hace depender del `entorno`. Es exactamente el cruce agronómico/control que descarté en el punto 4.

**Lo que sí vale la pena y no es normalización:** una **ventana horaria de riego**. Es práctica agronómica corriente regar temprano y no a pleno sol ni de noche (conocimiento general, no del artefacto). Eso no es modelar el ciclo: es una política del actuador de dos números. La dejo señalada, no propuesta, porque toca WF5 y esta misión no propone cambios concretos.

### Cuánta operación real hace falta para revisar esta decisión

**Dos a cuatro semanas continuas** a 10 min con humedad y temperatura, sin huecos, en una misma etapa: catorce ciclos diarios es lo mínimo para distinguir un patrón repetido de la variación entre días. Y se rehace por etapa y por estación, o sea que el perfil **caduca**. Si en un año de operación la amplitud diaria resulta comparable al ancho de la banda muerta del punto 4, la normalización pasa de sobre-ingeniería a necesaria. Es reversible, y por eso se decide del lado del "no" ahora.

---

## 7 · Anticipación de etapa

### El enfoque, evaluado

La idea de la fase no implementada: usar la tendencia de NPK y pH del sustrato para anticipar la transición fenológica antes de que se vea morfológicamente, en vez de esperar la ventana de calendario (`diasEnEtapa >= duracion_estimada_dias * 0.8`, `Calcular Dias en Etapa` en WF3).

**Cierto por construcción:** el sistema ya combina calendario (abre la ventana) y visión (confirma). La tendencia de NPK sería una tercera señal. Usarla *para abrir la ventana antes* es barato en riesgo porque Gemini sigue confirmando; usarla *para avanzar sin foto* sería otra cosa y no la recomiendo.

**Hipótesis agronómica plausible:** que la demanda relativa de N frente a P y K cambia al entrar en floración y eso se vea en la tasa de agotamiento del sustrato. La base cargada refleja ese cambio de ideales (N 50→30, P 30→50, K 30→60 entre Vegetativo y Floración del tomate, `§4`).

**Lo que juega en contra, y pesa más:**

- El sensor mide concentración en el sustrato, que depende de cuánto se regó (dilución), cuánto se fertilizó (escalón), la temperatura y —hipótesis— de una estimación derivada de conductividad, no de iones. La señal fenológica sería una **pendiente lenta** sobre una serie dominada por **escalones exógenos**. Sin registro de fertilizaciones, es inseparable.
- La ventana ya abre al 80 % de la duración (día 32 de un Vegetativo de 40). Una anticipación tendría que ganarle varios días para valer algo, con menos datos de esa etapa para detectarla.
- **La verificación exige etiquetas.** Hay que saber cuándo ocurrió la transición real, con independencia del sistema. Hoy `evaluacion_fenologica` tiene 0 filas y `cultivo` guarda solo `fecha_inicio_etapa` de la etapa actual, que se sobrescribe al avanzar. **Las transiciones pasadas no existen en ningún lado** salvo lo que WF3 empiece a escribir con `resultado = 'avanza'`, fechado por la foto en que Gemini lo vio, con hasta 8 h de cuantización y sesgo desconocido respecto de la transición biológica.

### Qué datos exige que hoy no se juntan

1. Fecha de transición real, etiquetada por un humano o por WF3, por cada etapa de cada cultivo (empezará a existir cuando WF3 funcione; hoy 0 filas y la anomalía de `§7` sin resolver).
2. Registro de fertilizaciones (no hay tabla; Fase 15 sin implementar).
3. Temperatura (16.43).
4. Riegos con resultado (existen como orden; el `resultado` nunca se cierra).
5. **Varios ciclos completos de la misma especie.** Con una transición por etapa por cultivo, un ciclo da **una muestra** por transición. No se ajusta ni se valida nada con n = 1. Un mínimo defendible son tres a cinco ciclos; para tomate cherry según el catálogo (10+15+40+20+30 días) un ciclo son ~115 días. Son **más de un año de operación**, en paralelo si hay varias macetas.

### ¿Se acumularían con la cadencia del punto 1?

Sí, sobradamente: NPK y pH a 1 h dan 24 puntos por día y cientos por etapa; el volumen no es el cuello de botella. **El cuello de botella es el número de ciclos y las etiquetas, y ninguna cadencia lo acorta.** Es el caso más claro de "más datos no alcanza": hace falta más *tiempo de calendario* y más *eventos registrados*, que son cosas de arquitectura (tablas que no existen) y de operación (cultivos que nadie está haciendo).

### Veredicto y alternativa

El enfoque sigue siendo **correcto como hipótesis de investigación** y es trabajo futuro legítimo para la tesis. **No es un feature de producto ahora**, y no lo será hasta que exista el histórico etiquetado. Lo que sí conviene hacer ya es lo que permite responderla después: cerrar 16.42 y 16.43, registrar fertilizaciones y transiciones.

**Alternativa a evaluar en su lugar, más barata y con más respaldo:** anticipar por **tiempo térmico** (grados-día acumulados desde el inicio de etapa) en vez de por días de calendario. Es el predictor agronómico estándar de fenología (conocimiento general, no del artefacto), usa la variable que el sensor ya entrega y el sistema descarta (16.43), y encaja en el mecanismo actual sin cambiarle la naturaleza: la ventana de WF3 se abriría por acumulación térmica y Gemini seguiría confirmando. Se verifica con **un ciclo**, no con cinco, porque la relación grados-día → etapa está publicada para tomate y solo hay que calibrarla. **Descartado para hoy:** implementarla ya; sin temperatura guardada no hay con qué acumular. Primero 16.43.

---

## 8 · Un hallazgo que no está en los siete puntos y los atraviesa todos

### 16.45 · Nadie detecta que el nodo dejó de mandar — 🌱

**Qué:** no existe ningún mecanismo que compare "última lectura" contra "ahora". WF1 es reactivo (solo corre si llega un POST); WF3 mira fotos y calendario, no frescura de telemetría; WF4, el único programado que consulta lecturas recientes, está apagado a propósito; no hay trigger ni job en la base (`pg_cron` no está instalado). **Evidencia en vivo:** `CONTEXTO_AGENTE.md §7` — última lectura del 20/08, cultivo activo, WF1/WF3/WF5 activos, y **29 días sin una sola alerta.** El sistema no dice "no sé nada de esta planta hace un mes": no dice nada.

**Por qué importa:** es el peor tipo de falla para un producto, con las mismas palabras que usa el plan para la anomalía de WF3: *el sistema dice que funciona y no está funcionando.* Y para el cultivo es la falla más probable de todas (el ESP32 se queda sin batería, se cae el wifi, se desenchufa) con el peor resultado (la planta se seca sin riego y sin aviso). Es memoria en su forma más elemental: recordar cuándo fue la última vez que se supo algo.

**Alternativa descartada:** encender WF4 para que "cubra" esto. Hace otra cosa, está apagado por una razón válida, y su nodo `Obtener lecturas y conocimiento` ante ausencia de promedios devuelve `{skip: true}` en silencio: **tampoco avisaría.** El watchdog tiene que ser una pieza cuyo único trabajo sea ese, y correr aunque todo lo demás esté apagado.

**Cuánta operación real hace falta:** ninguna; la evidencia ya ocurrió. El umbral de silencio sale de la cadencia del punto 1: a 10 min, tres intervalos perdidos ya es anómalo.

---

## 9 · Cierre: más datos, o cambiar la arquitectura

Dos costos distintos. El primero es un piloto con un sensor y paciencia. El segundo es diseño, y conviene no pagarlo dos veces.

### Se resuelve con más datos (frecuencia, historia, retención)

| Pregunta | Qué juntar | Cuánto |
|---|---|---|
| Cadencia por variable (1) | sobremuestreo a 1–2 min y submuestreo offline | 1–2 semanas |
| Tiempo de respuesta del sensor tras riego → cooldown, retraso de recheck (1, 4) | 3–4 riegos forzados | 1 día |
| Ruido de línea de base → N de confirmación, ancho de banda muerta (3, 4) | sensor estático | 24–48 h |
| Firmas de eventos (5) | experimentos inyectados | días |
| Tasa de secado normal por etapa (5) | operación continua | 1–2 semanas por etapa |
| Perfil diario, y si hace falta normalizar (6) | continuo con temperatura | 2–4 semanas, por etapa y estación |
| Valor de la historia para alertas de pH/NPK (2) | operación | ≥ 1 etapa |
| Tendencia NPK como anticipador (7) | ciclos completos etiquetados | ≥ 3 ciclos, > 1 año |

Sobre **retención**: verificado que no hay ninguna política (sin `pg_cron`, sin particionado, sin trigger de poda), o sea que hoy la retención es "para siempre", y con el volumen de la sección 1 eso es razonable durante años. Lo que sí falta es un índice sobre `(cultivo_id, fecha_hora)` en `lectura_sensores` (solo existe la PK); toda consulta de historia va a barrer la tabla entera. Es 🎨 hoy y se vuelve 📉 (timeouts en n8n) a medida que crezca. Se abre **B.17**: *política de retención e índice temporal, decidir cuando haya cadencia real.*

**Trampa a evitar:** ninguna de estas preguntas se contesta con el histórico actual ni se acelera generando más datos sintéticos. Las cantidades que faltan —ruido, respuesta del sensor, tasa de secado— son propiedades del hardware en ese sustrato, no del código; un mes de una maceta real vale más que cualquier simulación.

### Exige cambiar la arquitectura

Estas no se arreglan con datos porque son **formas** que el sistema hoy no tiene:

1. **El Motor de Inferencia tiene que ver historia.** Hoy su contrato es `f(lectura, umbrales, último_riego)`. Confirmación (3), histéresis (4), derivada (5), transición para alertas (B.7) y silencio (16.45) exigen que sea `f(lectura, estado_del_cultivo, umbrales)`. Hay dos maneras de darle ese estado y hay que elegir una: consultar las últimas N lecturas en cada ejecución (sin estado persistido, más costoso por POST, todo derivable), o mantener un **estado por cultivo** persistido y actualizado en cada lectura (barato de leer, pero es un dual-write más, y el proyecto ya aprendió lo que cuestan; el patrón ya existe en `cultivo.ultima_foto_path` / `ultima_foto_evaluada_path`). No decido acá cuál; sí digo que la decisión es arquitectónica y previa a cualquiera de los puntos 2 a 6.
2. **El riego necesita una máquina de estados, no un cooldown.** `normal → regando → verificando → (rearmado | falla)`, con tope de riegos por ventana (16.41) independiente del recheck (13.7.1). `evento_riego` ya tiene las columnas (`fecha_recheck`, `humedad_recheck`, `resultado`): la forma está prevista en el esquema y no en el flujo.
3. **La telemetría necesita un watchdog** (16.45): una pieza programada, mínima, independiente de WF4.
4. **El contrato del webhook necesita tiempo de dispositivo y secuencia** (16.42) **y temperatura** (16.43). Es un cambio de contrato entre firmware y sistema, y es el único punto de este documento que conviene resolver **antes** del piloto, porque el piloto sin esos dos campos produce una serie que no sirve para lo que se lo hizo.
5. **Eventos exógenos como datos:** fertilización, intervención manual, cambio de sensor. Sin tabla no hay punto 7 ni punto 5 completo. Se liga a Fase 15.

Y el orden: **4 → piloto de datos → 1 y 2 → 3** puede ir en cualquier momento porque no depende de nada. Hacer 1 o 2 antes del piloto es diseñar filtros sin conocer el ruido; hacer el piloto antes de 4 es tirar el mes.

---

## 10 · Hallazgos y diferidos abiertos en esta revisión

| # | Sev | Dónde | Qué |
|---|---|---|---|
| **16.41** | 🌱 | WF5 · WF1 | Riegos consecutivos sin tope: el cooldown de 15 min es el único freno y `falla_riego_persistente` es inalcanzable |
| **16.42** | 📉→🌱 | contrato webhook · `lectura_sensores` · RPC | Sin timestamp de dispositivo ni secuencia; `fecha_hora = now()` del servidor. No se recupera retroactivamente |
| **16.43** | 📉 | contrato webhook · Motor · RPC | Temperatura y conductividad en `tipos_metricas`, descartadas por todo el pipeline. No se recupera retroactivamente |
| **16.44** | 🎨 | `vista_promedios_recientes` | `total_lecturas` cuenta filas (×5); ventana fija de 6 h inadecuada para humedad. Solo la consume WF4 (apagado) |
| **16.45** | 🌱 | sistema | Nadie detecta silencio del nodo. Demostrado: 29 días sin telemetría, cero alertas |
| **B.15** | — | firmware · webhook | Cadencia de muestreo como contrato: propuesta en §1, pendiente de piloto |
| **B.16** | 📉 | `evento_riego` · `lectura_sensores` | Sin trazabilidad lectura → riego (no hay id de lectura agrupada; la clave implícita es `fecha_hora` compartida) |
| **B.17** | 🎨→📉 | BD | Sin política de retención ni índice `(cultivo_id, fecha_hora)`; decidir con cadencia real |

Señalado sin número, para la auditoría pendiente de WF5: `volumen_maceta_litros || 10` y `caudal_bomba_ml_s || 50` inventan un valor cuando falta el dato, en la misma función que aborta explícitamente si faltan los umbrales.

**Lo que revisé y no encontré nada:** la ventana de evaluación de WF3 y su deduplicación por foto están bien para la escala de semanas de la etapa y no necesitan nada de esta revisión; las ramas A y B del Motor son correctas sin memoria; `mantenimiento_hasta` es memoria bien ubicada.

**Lo que no sé y no completé:** de dónde salió `TIEMPO_ABSORCION_MIN = 15`; cómo está configurada la poda de ejecuciones de n8n; qué sensor concreto se va a usar y por lo tanto su ruido, su dependencia térmica y si NPK es derivado de conductividad. Las tres cosas cambian números de este documento, no conclusiones.
