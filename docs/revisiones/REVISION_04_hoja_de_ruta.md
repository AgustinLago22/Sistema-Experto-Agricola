# REVISIÓN 04 — Hoja de ruta: de hoy a un producto terminado

> **Fecha:** 18/09/2026 · **Base:** `CONTEXTO_AGENTE.md`, `WF1.json`, `WF3.json`, `WF5.json` (lo toca la misión: es el actuador), `REVISION_01_cobertura.md`, `REVISION_02_medicion.md`, `REVISION_03_workflows.md`, `docker-compose.yaml`. De `implementation_plan.md` leí **solo** 13.6, 13.7 y 13.7.1 (el mapa del contexto manda ahí para el lazo de riego) y un grep por `comando_dispositivo` para no afirmar de memoria cómo llega una orden al dispositivo. Una consulta de solo lectura a Supabase, marcada *(BD)*. WF2 y WF4 no los abrí: REVISION_03 los cubre y esta misión no los toca.
>
> **Dos cosas que la misión no dice y resolví sola:** el nombre del archivo (uso `REVISION_04_hoja_de_ruta.md`, siguiendo la serie) y el límite de extensión (me fijé el de las revisiones anteriores, ~40 KB, y quedé abajo). Los archivos que la misión llama `REVISION_02_lectura_y_anticipacion.md` y `REVISION_03_flujos.md` no existen con ese nombre; en disco son `REVISION_02_medicion.md` y `REVISION_03_workflows.md`. Asumo que son los mismos.
>
> **Severidad:** 🎨 *queda feo* · 📉 *pierde un dato* · 🌱 *daña el cultivo*. **Esfuerzo:** una tarde / unos días / una semana; lo que excede una semana lo digo así, sin inventar un número.

---

## 0 · Numeración: no arranco desde 16.41

La misión dice "seguí desde 16.41 y B.15". **Eso ya no es cierto en los artefactos**, y REVISION_03 §0 lo documenta: el plan ya integró 16.41–16.45 y B.15–B.18 desde REVISION_01; REVISION_02 usó los mismos números para hallazgos distintos; REVISION_03 dejó libres 16.46–16.50 y B.19–B.21 para renumerar REVISION_02 y ocupó 16.51–16.62 y B.22–B.23.

Acá cito los de REVISION_02 con la renumeración que propuso REVISION_03, marcada como provisoria: **16.46** riegos sin tope · **16.47** sin timestamp/secuencia · **16.48** temperatura descartada · **16.49** `vista_promedios_recientes` · (su 16.45 se funde con el **16.44** del plan) · **B.19** cadencia · **B.20** trazabilidad lectura→riego · **B.21** retención e índice. Si preferís otra asignación, en este documento se cambian por título sin pérdida. Lo nuevo mío empieza en **16.63** y **B.24**. Abro uno solo (16.63, §1). Corregir el §8 de `CONTEXTO_AGENTE.md` es parte de la hoja de ruta (ítem A6), porque es lo que generó el choque dos veces.

---

## 1 · El lazo de riego: qué está abierto exactamente, y a qué carril va

Antes de clasificar hay que decir con precisión **cuántos** agujeros tiene el lazo, porque el brief habla de uno y son dos.

**Lo que hay, con evidencia.** WF5 termina en `fn_registrar_riego`, que inserta `comando_dispositivo` + `evento_riego` en una transacción (`WF5.json`, nodo `Registrar Riego`; 13.5.3). El diseño de 13.6 dice que el ESP32 **consulta** esa cola por polling, marca `entregado`, ejecuta, marca `ejecutado` (13.6, pasos 2–3), y manda una lectura extra a los 15 min (paso 4) para que WF1 cierre `evento_riego.resultado` (13.7). Y 13.7.1 documenta que el paso de WF1 no existe.

**Lo que verifiqué hoy** *(BD)*: `comando_dispositivo` 8 filas, **las 8 en `pendiente`**; `evento_riego` 8 filas, **las 8 en `pendiente`**; `evaluacion_fenologica` 0; última lectura 20/08 18:47 UTC. Y un grep sobre los cinco JSON: **ningún workflow menciona `comando_dispositivo`, `entregado` ni `ejecutado`.**

### 16.63 · 🌱 El lazo está abierto en dos lugares, no en uno, y el segundo nunca se ejerció ni con el simulador

**Qué.** 13.7.1 describe el hueco del **recheck** (nadie escribe `evento_riego.resultado`). Pero aguas arriba de eso hay otro: el lado de **entrega y acuse** de la orden. Las 8 órdenes siguen en `pendiente` en `comando_dispositivo`, lo que significa que el simulador de 13.6 —el script PowerShell que hace de ESP32— **nunca corrió** contra esas órdenes (si hubiera corrido, estarían en `ejecutado`). Y aunque corriera, **ningún workflow lee el estado del comando**: el sistema no distingue "ordené y el dispositivo ejecutó" de "ordené y nadie lo levantó". El recheck de 13.7 mide humedad; no mide si la bomba recibió la orden. Son dos preguntas distintas con dos respuestas distintas: *"no subió la humedad porque la bomba no anduvo"* y *"no subió la humedad porque nadie ejecutó la orden"* llevan a acciones opuestas (revisar la bomba vs. revisar la conectividad del nodo).

**Por qué importa.** El plan dice (13.6) que "toda la Fase 13 se puede testear de punta a punta antes de tener una placa soldada". La base dice que la punta de entrega no se testeó nunca. La afirmación de cierre del lazo es, hoy, una afirmación sobre un diseño, no sobre un sistema. Es exactamente la categoría que el proyecto definió como la peor: el documento dice una cosa y el artefacto otra.

**Alternativa que descarté:** tratarlo como parte de 13.7.1. Descartada porque 13.7.1 se cierra con un nodo en WF1 y una señal de humedad, y este se cierra con un consumidor de `comando_dispositivo.estado` (o con la decisión explícita de no tenerlo y decirlo). Se pueden arreglar juntos; no son lo mismo.

### A qué carril va el lazo, y por qué

**A los dos, A y B, y es el único ítem que está en los dos.** No es una evasión; son dos versiones del mismo cierre con distinta evidencia:

- **Carril A (tesis).** `CONTEXTO_AGENTE.md §1` define el sistema como "de loop cerrado". El circuit breaker (`falla_riego_persistente`) está escrito, explicado y es **código inalcanzable**. Un jurado que pregunte "¿qué pasa si la bomba no anda?" recibe hoy una respuesta que es verdad sobre el diseño y falsa sobre el sistema que corre. Eso no se defiende. **Pero la versión A se cierra sin hardware**: el simulador de 13.6 + el nodo de recheck de 13.7.1 + el tope duro (16.46) se ejercen contra la base y dejan filas en `ejecutado` / `exitoso` / `insuficiente` / `Falla de Riego`. Es lo que el plan diseñó para esto (v19) y nunca se hizo.
- **Carril B (venta).** La versión A demuestra la lógica; no demuestra que **agua real** llega a **tierra real** y que el sensor la ve en 15 minutos. Eso exige hardware, y exige el piloto de REVISION_02 §9 (respuesta del sensor al agua: un día; ruido de base: 48 h). Sin eso, `TIEMPO_ABSORCION_MIN = 15` sigue siendo un número sin dato detrás (REVISION_02 y 03 coinciden: no tiene procedencia).

**La alternativa que descarté** es ponerlo solo en B ("no daña nada hasta que haya bomba"). Es cierto que hoy no riega nada, pero la tesis no defiende que no dañe: defiende que cierra el lazo. Dejarlo para B convierte la afirmación central del trabajo en una promesa.

---

## 2 · Criterio de carriles

**A — bloquea la tesis:** sin esto, una afirmación central del trabajo es falsa sobre el artefacto, o el sistema no puede demostrarse, o el documento se contradice consigo mismo. **No incluyo** hardware en A: el plan decidió explícitamente (v19) construir y defender la orquestación con simulador. *No sé* si el documento de tesis promete un dispositivo físico; si lo promete, el hardware sube a A y esta hoja de ruta cambia. Es la primera pregunta que hay que contestar.

**B — bloquea la venta:** sin esto no se puede instalar en una maceta ajena sin riesgo para la planta o para el cliente, o no se puede operar sin que Agustín esté mirando.

**C — deuda tolerable:** se convive; algunas con fecha (la que fija el piloto o el primer cliente), otras sin ella.

Dependencias transversales, con nombre corto porque aparecen en muchos ítems: **HW** (el ESP32 real con firmware que cumpla 13.6 y válvula local de 30 s) · **D-auth** (decisión pendiente del plan: cómo autentica el dispositivo real contra `comando_dispositivo`; hoy el simulador usa la **Secret key**, o sea acceso total a la base) · **D-deploy** (dónde corre n8n en producto: ¿la PC del cliente, una máquina siempre encendida de Agustín, la nube?) · **D-estado** (REVISION_02 §9.1: si el Motor consulta las últimas N lecturas o mantiene un estado persistido por cultivo) · **Piloto** (las 2–4 semanas de sensor real de REVISION_02 §9).

---

## 3 · Carril A — Bloquea la tesis

| # | Qué es | Depende de | Qué desbloquea | Esfuerzo |
|---|---|---|---|---|
| **A1** | **Resolver la anomalía de WF3.** 0 evaluaciones con la ventana abierta 21 días. REVISION_03 §1 la acotó a cuatro causas y dio la observación que las separa (modo de ejecución + `docker ps`). | Nada. Dos minutos de Agustín en *Executions*. | Saber si WF3 funciona. Hoy uno de los dos pilares del sistema (validación fenológica) **nunca corrió en producción**; una tesis no puede presentar como funcionando algo con cero ejecuciones. Además destraba A4: sin WF3 vivo, Fructificación es una fila que nadie va a usar. | Una tarde el diagnóstico. El arreglo depende de la causa: si es H1 (n8n apagado), no hay código y sale una decisión (D-deploy); si es H3, es 16.15 en WF3. |
| **A2** | **B.13 + B.14: respaldar `n8n_storage` y fijar versión.** El compose (leído) no tiene `N8N_ENCRYPTION_KEY`; la clave vive en el volumen. | Nada. | Todo lo que toque el contenedor. Perder el volumen antes de la defensa = credenciales irrecuperables = demo muerta. | Una tarde. |
| **A3** | **Cerrar el lazo con simulador**: 13.7.1 (nodo de recheck que escribe `evento_riego.resultado`), 16.46 (tope duro de riegos por ventana, independiente del recheck), 16.63 (correr el simulador de 13.6 y decidir quién lee `comando_dispositivo.estado`). Demostrar los cuatro caminos con filas en la base: `exitoso`, `insuficiente`, `Falla de Riego - Revisar Sistema`, tope alcanzado. | A2. Una decisión chica: el diseño de 13.7.1 (nodo en WF1) alcanza para A; la máquina de estados de REVISION_02 §4 es C. | La afirmación "loop cerrado". Y el hecho de que **cuando llegue el hardware, lo único nuevo que se prueba es el hardware**, no la lógica. | Unos días. |
| **A4** | **Base de conocimiento completa para la especie que se demuestra**: B.1 (Fructificación en el catálogo, en el prompt de WF3 y en `parametro_etapa`), umbrales de Cosecha (16.41 R01: hoy son 30 días sin riego), lo que ejerce 16.37 (aplicado a ciegas) y cierra 16.42 R01 (Floración→Cosecha sin criterio visual). Para albahaca: umbrales de Germinación y Plántula, o declarar que albahaca no está soportada. | A7 (los valores tienen que tener fuente). A1 (para verificar que WF3 avanza con la nueva etapa). | El cultivo de demo lleva 37 días en una etapa que no tiene nombre en el catálogo. Un jurado que mire la base ve eso. Y es lo que permite probar 16.37 en vez de creerlo. | Unos días, y es trabajo **agronómico**, no de n8n. |
| **A5** | **Escribir el contrato del webhook (B.22)** con tipos, `null` vs. ausente, unidades, y **desde ya** `timestamp_dispositivo` + `secuencia` (16.47) y `temperatura` (16.48). Aplicar 16.39 (fix escrito, sin aplicar). Ejercer 16.52 (`""` y `"0"` como strings) **antes** de arreglarlo, y arreglarlo en el borde. | A2. | El firmware (B1): sin contrato escrito, el contrato de facto será lo que el firmware mande el primer día, y el Motor decide sobre el valor crudo. El piloto (B3): REVISION_02 §9.4 dice que un piloto sin 16.47/16.48 "es tirar el mes". Y la tesis: el contrato entre dispositivo y sistema es una sección obligada. | Unos días. |
| **A6** | **Integridad documental**: renumerar REVISION_02 (§0), fusionar 16.45(R02) con 16.44, corregir `CONTEXTO_AGENTE.md §8`, y volcar al plan las tres revisiones y esta. | Nada. | Que la próxima sesión no vuelva a chocar números. Una tesis con dos hallazgos "16.41" distintos en sus anexos es un problema de defensa, no de estética. | Una tarde. Antes de la próxima sesión de plan. |
| **A7** | **Fase 17: procedencia de las constantes.** `FACTOR_RETENCION_HIDRICA = 0,25`, `TIEMPO_ABSORCION_MIN = 15`, `NPK_TOLERANCIA = 0,30`, el 80 % de la ventana de WF3, y cada umbral de `parametro_etapa`. Hoy ninguna tiene fuente en los artefactos leídos (REVISION_02 y 03 lo dicen; no lo repito como hallazgo). | Nada para empezar; el 15 se **mide** en el piloto (B3), no se cita. | A4. Y la pregunta "¿de dónde sale ese número?" en la defensa. | Una semana de bibliografía, en paralelo con todo. |
| **A8** | **Declarar los límites en el documento**: lo que el sistema no ve por construcción — variables ambientales (B.18), procesos vs. estados (REVISION_01 §3, B.17), plagas sin alerta de sustrato (16.43), silencio del dispositivo (16.44) y del planificador (16.62), fertirriego (Fase 15). | Nada. | Que ninguno de esos huecos aparezca como "descubierto" por el jurado. Presentar el umbral por etapa como **primera capa** correcta, no como suficiente (REVISION_01 §3). | Una tarde de escritura, si los hallazgos ya están. |

**Lo que revisé para A y dejé afuera a propósito:** 16.33/16.38 (índices únicos) van a B7 — con un solo cultivo de demo no se ejercen; 16.51/16.53/16.54/16.56 van a B4 por la misma razón, aunque conviene hacerlos en la misma sesión que A3 porque tocan el mismo nodo (REVISION_03 lo sugiere y coincido).

---

## 4 · Carril B — Bloquea la venta

| # | Qué es | Depende de | Qué desbloquea | Esfuerzo |
|---|---|---|---|---|
| **B1** | **HW: ESP32 + sensor + bomba + firmware** que cumpla los 4 pasos de 13.6 (telemetría, polling, acuse, lectura extra) con **válvula local de 30 s** hardcodeada (13.9), independiente del comando. | A5 (contrato). D-auth (no se puede escribir el firmware sin saber con qué se autentica; el plan pospuso esa decisión "hasta escribir firmware real": ese momento es este). | Todo el carril B. Sin dispositivo no hay piloto, ni recheck real, ni cliente. | **Más de una semana, fuera de escala.** El plan (v19) registra que Agustín "no sabe programarlo todavía"; no sé si eso cambió. Es el camino crítico entero y conviene decirlo así. |
| **B2** | **Seguridad mínima de un sistema que actúa**: D-auth (el dispositivo no puede llevar la Secret key: es acceso total a la base de todos los clientes), rotar `X-Device-Key` (expuesta, §9.9 del contexto), 16.55 (WF5 ejecuta lo que le mandan sin verificar contra la base), B.23 (una credencial para leer y para actuar), 16.13 (`anon` con `ALL` en 18 tablas), B.9 (`fn_registrar_telemetria` ejecutable por `anon`). | D-deploy (si n8n corre en la PC del cliente con el puerto publicado, 16.55 es alcanzable desde su LAN). | B1 (firmware) y cualquier instalación fuera de la casa de Agustín. | Una semana, la mayor parte decisiones y SQL. |
| **B3** | **Cerrar el lazo con agua real + piloto de datos** (REVISION_02 §9): respuesta del sensor al riego (1 día) → fija cooldown y retraso del recheck; ruido de base (24–48 h) → fija N de confirmación y banda muerta; cadencia por variable (1–2 semanas de sobremuestreo, B.19). | B1, A3, A5. | El valor de `TIEMPO_ABSORCION_MIN`, la cadencia (B.19), B9, y la afirmación "riega solo" sobre tierra. | Unos días de trabajo, **2–4 semanas de calendario**. |
| **B4** | **Endurecer WF5**: 16.51 (volumen/caudal faltantes → abortar, no inventar; hacerlos precondición de `tiene_actuador_riego`), 16.53 (cooldown, fallos y recorte tienen que contarse), 16.54 (dos sequías simultáneas: la exclusión vive en la base), 16.56 (body por interpolación). | A2. Ejercer 16.54 con dos POST paralelos antes de arreglarlo. | Instalar en una maceta cuya ficha la cargó alguien que no sabe de tecnología. Con el cultivo de demo (20 L y 40 ml/s cargados) no se dispara; con el primer cliente, sí. | Unos días, en la misma sesión que A3. |
| **B5** | **Detección de silencio + decisión de dónde corre**: 16.44 (watchdog de telemetría: "no sé nada de esta planta hace X"), 16.62 (latido del planificador: quien detecta la ausencia tiene que estar del lado vivo), y **D-deploy**, porque REVISION_03 §1.5 lo dice y coincido: un producto con triggers por intervalo no puede correr en la PC del cliente. Con D-deploy va también el `chatId` hardcodeado en los 5 workflows (grep: 6 apariciones del mismo número): hoy hay un solo destinatario para todos los cultivos del mundo. | D-deploy. Nada de código hasta decidirlo. | Que el cliente se entere cuando el sistema deja de mirar. Hoy: 29 días sin telemetría, cero avisos *(BD)*. Es la falla más probable (batería, wifi) con el peor resultado (planta seca, sistema "activo"). | Una semana, y la decisión pesa más que el código. |
| **B6** | **B.7: alertar por transición, no por nivel.** | D-estado (imposible sin recordar el estado anterior). B3 (la cadencia decide cuántas alertas son). | Que el usuario no apague las notificaciones. Si las apaga, también apaga el watchdog (B5): es el mecanismo por el que 🎨 se vuelve 🌱. | Unos días después de D-estado. |
| **B7** | **Restricciones en la base**: 16.33 (dos cultivos activos por dispositivo), 16.38 (etapa sin umbrales), 16.61 (`duracion_estimada_dias` y `etapa_actual_id` nulables sin default). | Nada. SQL ya escrito para dos de las tres. | El primer cliente con dos macetas, o con una ficha a medias. Todo lo que hoy falla "en silencio y en verde" por una fila incompleta. | Una tarde. Se puede hacer antes que todo lo demás de B. |
| **B8** | **Ciclo de vida del cultivo sin tocar Supabase a mano**: alta (hoy es un INSERT manual, REVISION_01 fila 1), cierre (B.15: nada escribe `active = false`), nuevo ciclo en la misma maceta (B.16). | D-deploy (define la interfaz: ¿comandos de Telegram como `/reanudar` de 13.12, un formulario, Agustín por SSH?). B7. | Un cliente que no sea Agustín. Sin esto, cada alta es un ticket. | Una semana. |
| **B9** | **Confirmación de dos muestras antes de actuar** (REVISION_02 §3): el riego, no el diagnóstico. | B3 (el N sale del ruido medido, si no es una adivinanza). D-estado. | Que una lectura espuria no sea un riego real. | Unos días después de B3. |
| **B10** | **Campos del contrato en la base**: `lectura_sensores` con tiempo de dispositivo y secuencia (16.47), temperatura y conductividad por el pipeline entero (16.48). | A5 (el contrato los define). | B3: sin esto el piloto produce una serie que no sirve para lo que se lo hizo (REVISION_02 §9.4). | Una tarde de esquema + Motor + RPC; el lado firmware va con B1. |

---

## 5 · Carril C — Deuda tolerable

| Ítem | Por qué se tolera | Fecha |
|---|---|---|
| **WF4 entero**: 16.57, 16.58, 16.59, 16.60, 16.45 (R01), 16.30, 16.49 | Está apagado a propósito y nada de eso daña. La única regla: **no encenderlo** hasta portar 16.16 (cardinalidad) y el IF sobre `skip`. Cuando se decida B.17 (tendencia) se decide si WF4 se arregla o se reemplaza. | Sin fecha; condición: sigue apagado. |
| **Máquina de estados de riego** (REVISION_02 §4: `normal → regando → verificando → rearmado/falla`) e histéresis con rearme en el centro del rango | Es la forma correcta a largo plazo; para A alcanza el diseño de 13.7.1 y para B el tope duro + B9. Diseñarla antes del piloto es diseñar filtros sin conocer el ruido. | Después de B3. |
| **B.17 capa de tendencia, D-estado en su forma completa, anticipación por NPK (REVISION_02 §7), tiempo térmico** | Trabajo futuro legítimo, declarado en A8. La anticipación por NPK necesita >1 año de ciclos etiquetados: no es producto ahora. | Sin fecha; declarado. |
| **B.18 variables ambientales, Fase 15 fertirriego, registro de eventos exógenos** | Dependen de hardware que no existe y de tablas que no existen. Declarados en A8. | Sin fecha. |
| **16.43 una foto sin alerta nadie la mira** | 🌱 según REVISION_01, y coincido, **si el producto promete detección de plagas**. Si no la promete, es un feature futuro. Condición: que el material de venta no diga "detecta plagas". *No sé* qué promete el material de venta. | Decidir con la primera oferta comercial. |
| **16.31, 16.15 en WF3, 16.21, B.10, B.11, B.2–B.6, B.8, B.12, 16.8, 16.9, 16.29** | Degradaciones sin señal y cosméticos. 16.31 (`etapa_no_coincide` absorbente) pierde parte de su peso con A4: si Fructificación existe, el caso del 17/08 no se repite. | Sin fecha. |
| **B.20 trazabilidad lectura→riego, B.21 retención e índice `(cultivo_id, fecha_hora)`** | 📉 cuando haya que auditar un riego; 🎨→📉 con volumen. Ambos se deciden con la cadencia real. | Con B3. |
| **16.1, 16.6, B.9 en lo que exceda B2** | Mínimo privilegio completo es más de lo que el primer cliente necesita; B2 toma lo que actúa. | Después de B2. |

Revisé si algo de C debía subir: 16.43 es el único dudoso, y la duda no es técnica sino de qué se vende.

---

## 6 · Secuencia recomendada

```
Semana 0 (una tarde cada uno, en este orden):
  A2 respaldo + versión ─► A1 diagnóstico WF3 ─► A6 numeración ─► B7 restricciones
        │
Semanas 1–2:
  A5 contrato (incluye B10) ──────────────┐
  A3 cierre con simulador + B4 WF5 ──────┤ (misma sesión: mismo nodo)
  A4 base de conocimiento ‖ A7 fuentes ──┤ (en paralelo: es agronomía, no n8n)
        │                                 │
  A8 límites en el documento ◄────────────┘
        ═══ TESIS DEFENDIBLE (con simulador) ═══
        │
  D-auth + D-deploy (decisiones; una tarde de discusión, no de código)
        │
  B2 seguridad mínima ─► B1 HW + firmware (camino crítico, > 1 semana)
        │
  B3 piloto (2–4 semanas de calendario) ─► B9 confirmación
  B5 watchdog + latido (en paralelo con B3, ya con D-deploy decidido)
  B6 alertas por transición (después de D-estado, que el piloto informa)
  B8 ciclo de vida
        ═══ PRIMER CLIENTE ═══
```

**Por qué A va antes que B, con nombre y apellido:**

1. **A2 es precondición física de todo.** Cualquier sesión que toque n8n sin respaldo apuesta las credenciales.
2. **A5 antes de B1**, porque el firmware **es** el contrato: si se escribe primero, el contrato queda definido por `String(analogRead)` y el Motor lo asume (16.52). Y B10 tiene que estar en la base antes del piloto o el piloto no sirve.
3. **A3 antes de B3**, porque probar la lógica del recheck por primera vez con agua real mezcla dos fuentes de error (¿falló la bomba o falló el nodo?). Con la lógica ya demostrada contra la base, la primera prueba con bomba solo puede fallar por el hardware, que es lo que se quiere aprender.
4. **A4 antes del primer cliente**, aunque no parezca de B: un cliente que planta tomate llega a Cosecha, y hoy Cosecha son 30 días sin riego (16.41 R01).
5. **B7 va en la semana 0** aunque sea de B: es una tarde, no depende de nada, y cierra tres fallas silenciosas de una vez.

**Lo que puede ir en cualquier momento:** A7 (bibliografía), A6, A8. **Lo que no puede adelantarse:** B3 (necesita B1), B9 (necesita B3), B6 (necesita D-estado, y D-estado se decide mejor con datos del piloto).

---

## 7 · Lo mínimo indispensable para un primer cliente

Definición: **una maceta, una especie con catálogo completo (tomate cherry), un dispositivo, instalado y dado de alta por Agustín en persona, n8n corriendo en una máquina siempre encendida que opera Agustín, no el cliente.** No es la versión ideal; es la que no arriesga la planta.

**Entra (y por qué es irreducible):**

| Ítem | Sin esto… |
|---|---|
| **B1 con válvula local de 30 s** | No hay producto. La válvula local es lo que hace que ningún fallo de n8n, de la base o de la red riegue sin fin. |
| **A3 + B3 corto** (recheck, tope duro, simulador ejercido; respuesta del sensor al agua medida: 1 día; ruido: 48 h) | El sistema riega cada 15 min sin tope mientras un sensor clavado diga "seco" (16.46). Eso es la planta ahogada. El piloto largo (cadencia) puede seguir con el cliente puesto; el corto no. |
| **A5 + 16.52 arreglado en el borde + 16.51 abortando** | Un `""` es un riego de déficit total; un caudal nulo es el doble de agua. Son las dos formas de regar sobre basura con el código actual. |
| **A4 para tomate** | Cosecha = 30 días sin riego y una alerta por lectura. |
| **B5 en su versión mínima** (un aviso de "sin telemetría hace 1 h") | Es la única entrada que agrega riesgo **por existir el sistema**: sin sistema, el cliente riega a mano; con sistema, deja de mirar. Un sistema que induce confianza y se calla es peor que ninguno. |
| **B2 mínimo**: clave rotada, dispositivo sin Secret key (D-auth decidida), puerto de n8n no expuesto a la LAN del cliente | Cualquiera en la red del cliente riega su maceta con un POST (16.55). |
| **B7 + A2** | Una tarde cada uno; no tiene sentido dejarlos afuera. |
| **D-deploy = máquina siempre encendida de Agustín** | WF3 y el watchdog dependen de triggers por intervalo; en una PC que duerme no disparan (REVISION_03 §1, H1). |

**Queda afuera, y el riesgo que se asume:**

| Afuera | Riesgo asumido | Cómo se acota sin implementarlo |
|---|---|---|
| **B9 confirmación de dos muestras** | Una lectura espuria = un pulso real. | Acotado por el tope: ≤ 30 s (≤ 1,2 L a 40 ml/s) y ≤ N por ventana. Un pulso de más en 20 L no mata; N pulsos sí, y N está topeado. |
| **B6 alertas por transición** | Fatiga: durante una sequía sostenida, un Telegram por lectura. El cliente puede silenciar el bot **y con él el watchdog**. | Cadencia de humedad moderada para el primer cliente (a decidir con B3) y decirle explícitamente que no silencie. Es el riesgo más incómodo de la lista, y lo digo así. |
| **B8 ciclo de vida** | Cada alta/cierre es una intervención de Agustín. | Aceptable con **un** cliente. No escala a dos. |
| **Máquina de estados / histéresis** | Oscilación alrededor del umbral: riego, no riego, riego. | El cooldown + tope acotan la cantidad de agua; no eliminan la oscilación. Exceso acumulado lento, no ahogo. |
| **16.43 plagas, B.17 tendencia, B.18 ambientales, WF4** | Planta muerta o enferma con sustrato en rango se reporta OK. | **No prometerlo.** Decir al cliente qué mira el sistema y qué no. |
| **Albahaca** | 19 días sin umbrales. | No instalar en albahaca hasta A4 completa para esa especie. |
| **16.53 completo, B.20, B.21, WF3 16.15/16.31** | Cuando algo falle, el diagnóstico es más lento. | Agustín tiene acceso a la base y a n8n; el cliente no necesita saberlo. |
| **`chatId` único, multi-tenant** | No aplica: un cliente, un chat. | Cambia con el segundo cliente. |

**El riesgo que no se acota con nada de lo de arriba y hay que asumir con los ojos abiertos:** el hardware no existe y no sé cuánto tarda. Todo el carril B cuelga de B1, y B1 no tiene estimación honesta posible desde los artefactos. Lo único que se puede hacer para que ese tiempo no sea tiempo muerto es que, cuando el ESP32 llegue, **todo lo demás ya esté probado** (A3, A5, B4, B7, B10). Esa es la razón real del orden.

---

## 8 · Lo que revisé y no encontré nada, y lo que no sé

**Sin hallazgo:** la cadena `Motor → Dispara WF5 → Calcular Dosis → fn_registrar_riego` es coherente y transaccional; `Registrar Riego` sin reintento es correcto; `Cambio de etapa?` sobre `avanzo` está refutado como bug (REVISION_03 lo verificó en la RPC). No encontré nada nuevo en WF1 ni WF3 que las tres revisiones no tengan.

**Lo que no sé y no completé:** si la tesis promete hardware (cambia A); si Agustín puede escribir firmware hoy (cambia la escala de B1); qué promete el material de venta (decide 16.43); qué está configurado en n8n para poda de ejecuciones (afecta A1); dónde va a correr n8n (D-deploy: nada de B5 se puede diseñar sin eso). Las cinco son preguntas para Agustín, no deducciones que me toque hacer.

**Numeración usada:** abro **16.63**. No abro B.24. Cito los de REVISION_02 como 16.46–16.49 y B.19–B.21 con carácter provisorio (§0).
