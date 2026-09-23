# REVISIÓN 01 — ¿El sistema abarca la vida de una planta?

Fecha: 18/09/2026 · Misión 1 del brief · Revisión, no implementación.

## 0 · Qué leí y qué verifiqué

Leí `CONTEXTO_AGENTE.md`, `WF1.json` y `WF3.json` enteros. Además abrí **WF2, WF4 y WF5** (la misión toca plagas → WF2, tendencia → WF4, riego por etapa → WF5) y `SQL/16.25_evaluacion_fenologica.sql` (es el único artefacto que dice qué pasa en la base cuando un cultivo llega a la etapa terminal). No abrí `implementation_plan.md`.

Las pistas las verifiqué con consultas **de solo lectura** contra Supabase (`xypqsthwquegftcnoqyi`), no contra el contexto:

| Pista | Verificación | Resultado |
|---|---|---|
| No existe "Fructificación" | `select * from tipo_etapa` | 5 filas: Germinación, Plántula, Vegetativo, Floración, Cosecha. **Confirmado.** |
| 3 etapas sin umbrales | `etapas_especie LEFT JOIN parametro_etapa` | Tomate/Cosecha, Albahaca/Germinación, Albahaca/Plántula con todos los umbrales `null`. **Confirmado.** Albahaca termina en Vegetativo (3 etapas). |
| Nada contempla el fin del ciclo | columnas de `cultivo`, triggers, funciones, grep en los 5 JSON | `cultivo.active` existe pero **ningún workflow ni función lo escribe**; no hay `fecha_fin`; cero triggers en `public`; solo 3 funciones (`fn_registrar_telemetria`, `fn_registrar_riego`, `fn_registrar_evaluacion_fenologica`). **Confirmado.** |
| Plagas solo con foto | WF1 `Dispara WF 2` + prompts de WF2/WF3 | Peor que la pista: se necesita foto **y** alerta de umbral al mismo tiempo (ver 16.43). |
| No mide temperatura, luz ni HR ambiente | `tipos_metricas` según contexto; grep `temperatura`/`luz` en JSON | Cero apariciones en los 5 workflows. **Confirmado.** `cultivo.entorno` (`indoor`/`outdoor`) existe y **nadie lo lee**. |

Estado del único cultivo real hoy: `fecha_inicio` 15/06 (95 días de vida), Floración desde 12/08 (37 días de una etapa de 20), `evaluacion_fenologica` = 0, `ultima_foto_evaluada_path` = null, 8 riegos en `pendiente`. Coincide con el contexto.

Convención de gravedad (regla 4): **🌱💀 daña el cultivo** · **📉 pierde un dato** · **🎨 queda feo**.

## 1 · La vida de la planta contra el sistema

Recorrido para Tomate Cherry (la especie con el catálogo completo). Donde Albahaca difiere, lo digo.

| Momento del cultivo | ¿Lo cubre? | Cómo (evidencia) | Qué falta |
|---|---|---|---|
| **Siembra / trasplante (alta del cultivo)** | Manual | No hay workflow que cree un `cultivo`. La fila se inserta a mano con `etapa_actual_id`, `fecha_inicio_etapa`, `volumen_maceta_litros`. WF1 la resuelve por `dispositivo_mac` en `vista_cultivos_activos`. | Ningún chequeo de que la fila esté completa antes de que llegue la primera lectura. Un cultivo sin `etapa_actual_id` cae en los LEFT JOIN de la vista con `etapa_actual = null` → `Conocimiento Experto` no devuelve nada → rama A. Se avisa, no se rompe. 🎨 |
| **Sensor recién enterrado (post-trasplante)** | Parcial | Motor, rama B: solo si **los 5** valores llegan en 0. | Un sensor mal insertado que reporta humedad 5 % con NPK plausibles no es "sospechoso": es sequía, y dispara riego real. El propio mensaje de `falla_riego_persistente` menciona el caso, pero ese código es inalcanzable (13.7.1). 🌱💀 |
| **Germinación (tomate, 10 d)** | Sí | Umbrales 80–95 % / pH 6–7 / NPK 10. Sequía → WF5. Exceso → solo Telegram. | Transición a Plántula depende de una foto (ver fila "cambio de etapa"). |
| **Germinación + Plántula (albahaca, 7+12 d)** | **No** | Sin umbrales → rama A en cada lectura: `requiere_alerta: true`, `hay_sequia: false`. | **19 días sin riego automático en la ventana más sensible al secado**, con una alerta por cada lectura. Cubierto por B.1/16.37/16.38, pero la consecuencia agronómica no está escrita en ningún lado. 🌱💀 |
| **Plántula (tomate, 15 d)** | Sí | Umbrales cargados. | Damping-off por exceso de agua (hongos del cuello; conocimiento hortícola general, *a verificar* con bibliografía de Fase 17): el sistema detecta "Exceso Hídrico" y avisa, pero no tiene acción posible ni ve HR ambiente. Correcto para un sistema que solo puede regar. |
| **Vegetativo (tomate 40 d / albahaca 45 d)** | Sí | Umbrales cargados. Es el tramo donde el sistema hace exactamente lo diseñado. | Poda, tutorado, despunte (albahaca): manual, fuera de alcance. 🎨 Para albahaca es la **etapa terminal**: el sistema nunca va a decir "cosechá hojas" ni detectar floración (que arruina la hoja; *a verificar*). |
| **Floración (tomate, 20 d)** | Sí | Umbrales 50–65 % / K 60. | Cuaje: el cultivo es `indoor` y sin polinizadores. El tomate cherry es autógamo pero necesita vibración/movimiento (*a verificar*). El sistema no lo sabe ni lo puede saber: no lee `entorno`, no mide temperatura ni luz. |
| **Fructificación / engorde (no existe en el catálogo)** | **No** | No hay `tipo_etapa`. El tomate cherry lleva **37 días** en una Floración de 20: es esta etapa, sin nombre. | Se usan los umbrales de Floración para toda la vida reproductiva. En fruto, el riego **irregular** produce podredumbre apical y el riego súbito tras sequía raja el fruto (conocimiento hortícola general, *a verificar*). Ambos fenómenos son de **regularidad**, no de valor puntual (ver §3). 🌱💀 |
| **Cambio de etapa (cualquiera)** | Parcial | WF3 cada 8 h: ventana `diasEnEtapa >= 0.8 × duración` **y** foto nueva **y** Gemini confirma **y** nombra exactamente `etapa_siguiente`. | Si no llega foto nueva (la manda el ESP32, opcional), la planta queda en la etapa anterior para siempre con sus umbrales. Hoy: la última foto es del 16/08 y nunca se evaluó (anomalía abierta). La transición **Floración → Cosecha no tiene criterio visual en el prompt** (lista solo 3 transiciones hasta Vegetativo → Floración). Ver 16.42. |
| **Cosecha (tomate, 30 d)** | **No** | Sin umbrales → rama A. WF3 no evalúa más (`hayEtapaSiguiente = false`). | **30 días sin riego automático con la planta cargada de fruto**, más una alerta Telegram por cada lectura que llegue. Ver 16.41. 🌱💀 |
| **Plaga o enfermedad** | Solo por coincidencia | WF2 se dispara desde `Dispara WF 2` únicamente si `requiere_alerta` **y** `tiene_foto`. WF3 mira la foto solo para etapa. | Una foto con sensores en rango se sube a Storage y **nadie la mira**. Pulgón, mosca blanca, oídio: ninguno mueve humedad, pH ni NPK. Ver 16.43. `seguimiento_fenologico`: 24 filas, **0 con `plagas_detectadas` no vacío**. 🌱💀 |
| **Estrés ambiental (calor, frío, poca luz, HR alta)** | **No** | Ninguna métrica. | Golpe de calor, helada, Botrytis por HR alta, tomate sin luz suficiente indoor: invisibles. El sistema solo vería el efecto indirecto (sequía por evapotranspiración alta) y lo respondería con más agua, que en un golpe de calor puede ser correcto o no (*a verificar*). B.18. |
| **Planta muerta o con raíz podrida** | **No** | Si la planta no transpira, el sustrato se queda húmedo y en rango → `OK`. | Un cultivo muerto se reporta sano indefinidamente. Solo se ve en la **tendencia** (la humedad deja de bajar entre riegos). Ver §3. 📉 → 🌱💀 |
| **Sensor/ESP32 deja de mandar** | **No** | Todos los caminos son webhook (WF1/2/5) o schedule que lee `vista_cultivos_activos` sin mirar frescura de telemetría (WF3/WF4). WF4 hace `skip` si no hay promedios. | El silencio no es un estado: no hay heartbeat ni "última lectura hace X horas". La planta queda sin riego y el sistema dice que está todo bien. Es la misma clase de falla que la anomalía de WF3. Ver 16.44. 🌱💀 |
| **Riego ordenado, ¿ocurrió?** | **No** | 13.7.1 conocido: 8 de 8 en `pendiente`. | No lo repito; el brief lo trata en la misión 4. 🌱💀 |
| **Fin del ciclo** | **No** | Nada escribe `active = false`. No hay `fecha_fin`, ni evento "cosechado", ni "murió". | La rama A de Cosecha sigue alertando por cada lectura hasta que alguien edite la fila a mano. B.15. 📉 + fatiga. |
| **Nuevo ciclo en la misma maceta** | **No** | Sin procedimiento. Opciones hoy: editar a mano la fila vieja (`etapa_actual_id`, `fecha_inicio_etapa`, `ultima_foto_path`, `ultima_foto_evaluada_path`, `fecha_inicio`) o insertar una nueva con el mismo `dispositivo_id` → cae en 16.33 (dos activos, uno se pierde en silencio). | Historia clínica mezclada si se reutiliza la fila. Sustrato reutilizado (sales, patógenos): no medible. B.16. 📉 |

## 2 · Huecos, por gravedad agronómica

Cada uno con lo que le pasa a la planta si nadie interviene, y la alternativa que descarté (regla 3). No propongo parches.

### 16.41 · 🌱💀 Cosecha = 30 días sin riego automático y una alerta por lectura
**Evidencia:** `parametro_etapa` sin fila para `etapas_especie_id = 8` (Cosecha); Motor rama A devuelve `hay_sequia: false`, `requiere_alerta: true`; `Dispara WF5` exige `hay_sequia = true`. El mensaje de la rama A lo dice textualmente: "sin riego automático". Está documentado como comportamiento, **no como hallazgo con severidad**.
**A la planta:** un tomate cherry en cosecha sigue transpirando y llenando fruto; en maceta de 20 L indoor, sin riego, marchita en días (*a verificar* el plazo). El agricultor recibe un Telegram por lectura diciendo "configuración incompleta", no "tu planta se está secando". Con lecturas cada pocas horas, eso es fatiga de alertas (B.7) justo cuando importa.
**Alternativa descartada:** copiar los umbrales de Floración a Cosecha para "destrabar". Descartada porque tapa B.1 (la etapa que falta es Fructificación, no un duplicado de Floración) y porque la demanda hídrica y de K en fruto no es la de Floración (*a verificar*). Lo correcto es cargar valores con fuente (Fase 17), y ese es un trabajo agronómico, no de n8n.
**Relación:** compone B.1 + 16.37 + 16.38. Es distinto de ellos porque ninguno describe la consecuencia en la etapa terminal.

### 16.42 · 🌱💀 (indirecto) La transición Floración → Cosecha es inalcanzable por WF3
**Evidencia:** el prompt de `IA Vision Fenologica` enumera tres transiciones (Germinación→Plántula, Plántula→Vegetativo, Vegetativo→Floración) y **ninguna para Floración→Cosecha**. `Parsear y decidir` exige `etapa_detectada` normalizada **igual** a `etapa_siguiente` ("cosecha"). Con una planta con fruto verde, lo esperable es que Gemini diga "Fructificación" (el caso del 17/08 que cita el propio código) → `etapa_no_coincide` → foto marcada, sin avance, sin aviso (16.31). Esto es **hipótesis sobre el modelo**, no observación: se ejerce mandando una foto con fruto y mirando `evaluacion_fenologica.etapa_detectada`.
**A la planta:** vive toda la fase reproductiva (para un cherry indeterminado, semanas o meses, *a verificar*) con umbrales de Floración. Menos grave que 16.41 porque **sí** riega. Pero la ausencia de Fructificación tiene un efecto no obvio: **es lo que hoy protege a la planta de 16.41**, porque nunca llega a Cosecha. Cargar Fructificación sin cargar Cosecha empeora las cosas.
**Alternativa descartada:** agregar "Fructificación" al prompt sin agregarla al catálogo. Descartada: `etapaCoincide` seguiría fallando; el prompt y el catálogo tienen que moverse juntos.

### 16.43 · 🌱💀 Una foto con lecturas normales no la mira nadie
**Evidencia:** `Dispara WF 2` = `lectura_sospechosa = false AND tiene_foto = true`, pero está **aguas abajo de `Requiere Alerta?`**, así que la condición real es alerta de umbral **y** foto. WF3 solo pregunta por etapa y solo dentro de la ventana. WF4 no usa fotos. En `seguimiento_fenologico`, 0 de 24 diagnósticos tienen `plagas_detectadas` con contenido, y el Telegram de WF2 ni siquiera muestra ese campo (muestra `severidad`, `explicacion_agricultor`, `acciones_inmediatas`).
**A la planta:** una plaga foliar o un hongo avanza semanas sin que ningún sensor de sustrato se mueva. La única vía de detección es que el agricultor **vea** la foto él mismo, y la foto no se le manda salvo en un cambio de etapa. Sin fuente puntual, pero es consenso hortícola que las plagas de invernadero se controlan por detección temprana (*a verificar*).
**Alternativa descartada:** mandar toda foto a Gemini. Descartada por costo por cultivo (misión 5) y porque el ESP32 puede mandar foto en cada lectura. El hueco es de **diseño**: falta un consumidor de fotos cuyo disparador sea "llegó foto nueva", no "hubo alerta".

### 16.44 · 🌱💀 El silencio del dispositivo no existe como estado
**Evidencia:** WF1/WF2/WF5 son webhooks (solo corren si algo llega). WF3 y WF4 leen `vista_cultivos_activos`, que **no expone** la fecha de la última lectura; WF4 hace `return [{ json: { skip: true } }]` si `vista_promedios_recientes` (ventana de 6 h) viene vacía, o sea que convierte "no hay datos" en "nada que hacer". Hoy mismo: última lectura 20/08, cultivo activo, cero avisos en 29 días.
**A la planta:** ESP32 sin batería, WiFi caído, sensor desenterrado → sin riego, sin alerta, cultivo "activo". Es el mismo patrón que la anomalía abierta de WF3 ("dice que funciona y no funciona"), aplicado al sensor. **Puede que el backlog ya lo tenga** bajo otro número; lo numero para que no se pierda, y se fusiona si corresponde.
**Alternativa descartada:** resolverlo en el ESP32 (que avise cuando falla). Descartada porque un dispositivo muerto no avisa; la detección de ausencia tiene que vivir del lado que sigue vivo.

### B.1 (existente) · 🌱💀 Albahaca arranca 19 días sin umbrales
No abro número: es B.1/16.37/16.38. Solo dejo escrita la consecuencia que no está en el contexto: para albahaca el hueco está **al principio**, en germinación y plántula, donde una maceta chica se seca en horas (*a verificar*). Un cliente que planta albahaca hoy no tiene sistema durante casi tres semanas.

### 16.45 · 📉 WF4 inventa la tendencia
**Evidencia:** el prompt de `Request a Gemini` dice: *"indicá también una tendencia aproximada (estable/mejorando/empeorando, a tu mejor criterio ya que no hay historial)"*. `vista_promedios_recientes` es un **promedio de 6 h**, no una pendiente. El Telegram lo muestra como "📈 Tendencia".
**Consecuencia:** una fila que miente, en la categoría que el proyecto definió como la peor. Está apagado a propósito, así que hoy no daña nada; importa porque es el único lugar donde el sistema pretende hablar de tendencia (§3). La misión 3 debería confirmarlo al auditar WF4.

### Diferidos propuestos (la clasificación B es decisión de Agustín, no mía)

- **B.15 · Cierre de ciclo.** No hay evento de fin (cosechado / murió / descartado), ni `fecha_fin`, ni quien escriba `active = false`. Sin esto, 16.41 dura para siempre y `evento_riego`/`lectura_sensores` acumulan datos de una planta que no existe. 📉
- **B.16 · Nuevo ciclo en la misma maceta.** Reset de `cultivo` es manual y sin lista de campos; la alternativa (nueva fila) choca con 16.33. Dos cultivos consecutivos en la misma fila mezclan historia clínica. 📉
- **B.17 · Capa de tendencia.** Ver §3. Es cambio de arquitectura, no de datos: el histórico ya existe (`lectura_sensores`, formato largo), lo que falta es un consumidor.
- **B.18 · Variables ambientales.** Temperatura, HR, luz. Depende de hardware que no existe. Sin esto, todo lo que es hongo, cuaje, golpe de calor o luz insuficiente queda fuera del sistema **por definición**, y conviene decirlo así en la tesis en vez de dejarlo implícito.

### Cosméticos 🎨 revisados
`cultivo.entorno` y `cultivo.fecha_inicio` existen y nadie los lee (el sistema no sabe la edad total de la planta: 95 días contra 115 del catálogo). El Telegram de WF2 omite `plagas_detectadas`. No abro números.

## 3 · La pregunta de fondo: ¿alcanza con evaluar cada lectura contra el umbral de la etapa?

**No alcanza, y no es un problema de datos: es de construcción.** El Motor recibe una lectura y una fila de umbrales; no recibe la lectura anterior. `Obtener Ultimo Riego` es el único acceso a historia, y solo lee `resultado` (que nunca cambia de `pendiente`). El histórico completo está en `lectura_sensores` (220 filas, desde 24/06), pero **ningún workflow activo lo consulta**. La única vista con memoria (`vista_promedios_recientes`) promedia 6 h, lo cual **borra** la pendiente en vez de calcularla, y la consume solo WF4 (apagado).

Fenómenos que este diseño **no puede ver** aunque el sensor sea perfecto:

| Fenómeno | Por qué el umbral instantáneo no lo ve | Gravedad |
|---|---|---|
| **Planta que dejó de transpirar** (muerta, raíz podrida, tallo quebrado) | El sustrato se queda húmedo dentro del rango. Solo se ve en la **velocidad de secado entre riegos**, que cae a cero. | 🌱💀 El sistema reporta OK sobre una planta muerta. |
| **Regularidad del riego en fruto** (podredumbre apical, rajado; *a verificar*) | El daño lo produce la **alternancia** seco/mojado, no un valor. Cada lectura por separado puede estar en rango. | 🌱💀 |
| **Maceta que se quedó chica** (raíz colmada) | Se ve como frecuencia de riego creciente con lecturas normales. | 📉 → 🌱💀 lento |
| **Agotamiento gradual de NPK** | Se detecta cuando cruza el ±30 %, o sea **tarde**; la pendiente permitiría anticipar. Es lo que Fase 15 (fertirriego, sin implementar) necesita. | 📉 |
| **Deriva de pH** (acidificación por fertilización, *a verificar*) | Idem: se ve el cruce, no la dirección. Un pH que va bajando 0.05/día está "OK" hasta que no. | 📉 |
| **Deriva del sensor** (calibración) | Indistinguible de un cambio real sin comparar contra la historia del mismo sensor. | 📉 → 🌱💀 (riego sobre dato falso) |
| **Oscilación alrededor del umbral** | Cada lectura es válida; el problema es la secuencia (regar, no regar, regar). El cooldown de 15 min de WF5 limita la frecuencia, **no** detecta la oscilación. | 🌱💀 por exceso acumulado |
| **Eficacia del riego** | Es una derivada por definición: humedad antes vs. después. Es 13.7.1. | 🌱💀 |
| **Golpe de calor / fuga / maceta volcada** | Humedad que cae 15 puntos en 2 h vs. la misma humedad estable: mismo número, distinta emergencia. | 🌱💀 |

Lo que **sí** ve bien el umbral instantáneo: sequía puntual, exceso puntual, pH fuera de rango, NPK fuera de tolerancia. Es decir, el diseño actual cubre los **estados**, no los **eventos** ni los **procesos**. Una planta muere más veces por proceso que por estado.

Dos cosas para la tesis: (1) el argumento "evaluación contra umbral de la etapa actual" es correcto y defendible como **primera capa**; lo que no es defendible es presentarlo como suficiente, y WF4 pidiéndole a un LLM que adivine la tendencia es la prueba de que el diseño ya sintió la falta. (2) La capa de tendencia **no necesita más sensores ni más frecuencia**: necesita que alguien lea `lectura_sensores`. Eso es exactamente la separación "más datos vs. cambiar arquitectura" que pide la misión 2; acá la respuesta es arquitectura.

## 4 · Cobertura, en una frase

El sistema cubre bien **el tramo vegetativo de una planta sana con sensor funcionando**: Germinación → Floración para tomate, Vegetativo para albahaca. No cubre el inicio de albahaca, ni la fase de fruto, ni la cosecha, ni el fin, ni el reinicio, ni la planta enferma sin alerta de sustrato, ni la planta que se calla, ni nada que sea proceso en vez de estado. Para un producto que se vende a alguien que cultiva tomates, **la parte que no cubre es la parte por la que planta tomates**.

## 5 · Lo que revisé y no encontré nada

- Riego en Germinación/Plántula/Vegetativo/Floración del tomate: la cadena `Motor → Dispara WF5 → Calcular Dosis` es coherente con los umbrales de la etapa; el fail-safe de WF5 sin umbrales (throw) es correcto y redundante con la rama A.
- Deduplicación de fotos en WF3 y atomicidad de `fn_registrar_evaluacion_fenologica`: correctas para lo que hacen; el retorno incluye `avanzo`, que es lo que lee `Cambio de etapa?`.
- Modo mantenimiento (`mantenimiento_hasta`): cubre "el agricultor está manipulando la maceta" sin disparar riego. Es el único momento de la vida del cultivo con un estado explícito de "no actuar", y está bien hecho.

## 6 · Afirmaciones agronómicas: en qué me baso

Todo lo marcado *a verificar* sale de conocimiento hortícola general (podredumbre apical y rajado por riego irregular, damping-off por exceso hídrico en plántula, cuaje de tomate indoor por vibración, floración de albahaca degradando la hoja, ventanas de secado en maceta chica). No tengo a mano una fuente primaria para ninguna, y no las presento como tales. Fase 17 del plan es el lugar donde deberían citarse antes de que entren al marco teórico. Lo que **no** está marcado son afirmaciones sobre el sistema, y cada una señala el artefacto donde la vi.

## 7 · Numeración usada en este documento

Nuevos: **16.41, 16.42, 16.43, 16.44, 16.45** · Diferidos propuestos: **B.15, B.16, B.17, B.18**. Ninguno reutiliza un número. 16.44 y B.17 pueden ya existir en el backlog bajo otro nombre: verificar antes de incorporarlos.
