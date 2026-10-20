# Sistema Experto Agrícola — Paquete de contexto para un agente

> **Regenerado el 20/10/2026** (plan v62, cierre de la sesión 17). Estado verificado contra Supabase y contra los JSON exportados, no contra lo que afirma la documentación.
>
> Este archivo existe para que un agente pueda trabajar **sin leer `docs/implementation_plan.md`**, que tiene ~6.600 líneas y ~740 KB. Acá está comprimido lo que hace falta para operar; el plan queda como referencia para profundizar en un punto concreto (mapa al final de este archivo).
>
> **Este archivo es una foto, y envejece.** Fue escrito después de una ronda de cuatro revisiones externas que corrieron en paralelo leyendo la versión anterior. Tres de ellas numeraron hallazgos nuevos usando el "último número" que este archivo declaraba, y chocaron entre sí. La lección quedó registrada como regla, abajo: **no asignes números de hallazgo.**

---

## 0 · Cómo usar este documento

**Leé, en este orden:**

1. Este archivo, entero (~40 KB).
2. `WORKFLOWS/WF1.json` — es el corazón del sistema y donde está casi todo el trabajo abierto.
3. `WORKFLOWS/WF3.json` — el segundo en importancia. Re-exportado el 01/10 con el prompt nuevo (16.42).
   `WF5.json` se re-exportó el 19/10 (lazo de riego, 13.7.2); `WF1.json` y `WF7.json`, el **20/10** (contrato v1, Fase 18).
4. WF2, WF4, WF5 y WF7 **solo si la tarea los toca.** WF4 está apagado a propósito.

**No leas `implementation_plan.md` entero.** Si necesitás el detalle de un hallazgo, abrí solo esa sección — el **mapa del final** dice dónde está cada una.

**El usuario es Agustín.** Habla en español rioplatense y prefiere respuestas cortas, en castellano simple, una cosa por vez. Es su tesis **y** un producto que piensa vender. No tiene navegador conectado a n8n: cualquier cambio en un workflow se lo pasás como instrucción exacta (nodo, campo, expresión, código completo) y lo aplica él. Para Supabase sí hay MCP directo. **Quiere entender, y cuando se pueda construir él mismo, cada workflow:** antes de darle un JSON para importar, explicale nodo por nodo qué hace y por qué, y ofrecé armarlo guiado (lo pidió en la sesión 17).

---

## 1 · Qué es el sistema

Un sistema experto agrícola de loop cerrado. En una frase:

> Un sensor en la maceta manda mediciones → n8n las procesa contra umbrales agronómicos → Supabase las guarda → si algo anda mal, avisa por Telegram y riega solo.

**Componentes:**

| Pieza | Qué es | Dónde corre |
|---|---|---|
| ESP32 + sensor 7-en-1 | Mide humedad, temperatura, pH, conductividad, N, P, K. Manda foto opcional | **No existe todavía.** Se simula con PowerShell, con el formato del contrato v1 |
| n8n | Orquestación. 6 workflows: WF1–WF5 y WF7 (**WF6 está reservado** para los comandos de Telegram, 13.13, y no existe) | Docker en la PC de Agustín, `localhost:5678`. **Versión fijada `2.19.5`** (B.14), volumen `tesis_n8n_storage` respaldado (B.13) |
| Supabase | Postgres + Storage (bucket `fotos-cultivos`) | Proyecto `xypqsthwquegftcnoqyi`, "Tesis Cultivos" |
| Google Gemini | Visión: diagnóstico de emergencia y validación de etapa | `gemini-3.5-flash` (WF4 quedó en `2.5`) |
| Telegram | Canal de notificación | `chatId` 5593622386, repetido en 5 nodos |

**El ESP32 no está armado y nada depende de él.** La orquestación se construye primero, desacoplada a propósito: el sistema solo habla vía HTTP contra Supabase, nunca al revés.

**Idea central del dominio:** cada especie tiene etapas fenológicas ordenadas (Germinación → Plántula → Vegetativo → Floración → Cosecha), y cada etapa tiene sus propios umbrales de humedad, pH y NPK. El diagnóstico es *lectura contra umbral de la etapa actual*, no contra un valor fijo.

---

## 2 · Flujo, de punta a punta

```
ESP32 (o PowerShell)       Header Auth en las dos: X-Device-Key (credencial `ESP32 Telemetra Key`)
   │  al encender:   POST /webhook/arranque   ──► WF7 ──► la base le asigna un arranque_id
   │  cada lectura:  POST /webhook/telemetria (contrato v1)
   ▼
 WF1 ──► puerta: ¿cumple el contrato? ──[no]──► 400 + fila en lectura_rechazada
   │          └[sí]──► 200 "aceptada"
   ▼
 guarda telemetría ──► ¿requiere alerta? ──┬──► Telegram
   │                                       ├──► WF2 (si hay foto)
   │                                       └──► WF5 (si hay sequía)
   │
   └─ si vino foto: la sube a Storage y actualiza cultivo.ultima_foto_path

 WF3 (cada 8 h, solo)  ──► mira la última foto ──► Gemini ──► ¿avanzó de etapa?
 WF4 (apagado)         ──► análisis preventivo de rutina
```

---

## 3 · Los 6 workflows

### WF1 — `Orquestacion - Tesis` · 26 nodos · **activo**

Webhook `/telemetria`, con *Respond: Using 'Respond to Webhook' Node*. Es el único que mueve datos en cada lectura.

```
Webhook → Validar Contrato → Contrato Valido? ─[no]─────────────────────────────┐
                               └[sí]→ Verificar Arranque → Arranque Valido? ─[no]─┤
                                                            └[sí]→ Responder Aceptada (200)
                                          Responder Rechazo (400) ◄─────────────┘ → Registrar Rechazo
Responder Aceptada → Resolver Cultivo → Conocimiento Experto → Obtener Ultimo Riego → Motor de Inferencia
   → Hay foto nueva?  ─[sí]→ Preparar Foto binaria → Subir Foto a Storage → Actualizar Ultima Foto Cultivo ─┐
                      └[no]────────────────────────────────────────────────────────────────────────────────┤
   → Consolidar datos → fn_registrar_telemetria → Registrar Recheck de Riego → Esta en mantenimiento ─[no]→ Requiere Alerta?
        → [3 ramas PARALELAS e INDEPENDIENTES]  Dispara WF 2 · Alerta Telegram · Dispara WF5
```

**La puerta (contrato v1, paso 2, desde el 20/10).** `Validar Contrato` revisa el cuerpo contra `docs/contrato_telemetria.md`: campos presentes, las 7 mediciones como número dentro del rango **físico** o `null`, `v` = 1, MAC con formato. Arma `lectura`, el **único** objeto que leen los nodos de abajo (la MAC va en mayúsculas). `Verificar Arranque` (`fn_verificar_arranque`, siempre devuelve una fila, con reintento) comprueba que el `arranque_id` se le dio a esa placa. Si algo falla: `400` con la lista de errores y una fila en `lectura_rechazada` (el cuerpo sin la foto). Si pasa: `200 {"estado":"aceptada"}` **antes de procesar**, y el flujo sigue como siempre (el nodo Respond deja pasar los ítems). `Resolver Cultivo` toma la MAC de `$('Validar Contrato').first().json.lectura`, porque su entrada ya no trae el `body`. **El formato viejo (`planta`, sin `v`) se rechaza.**

**`Motor de Inferencia`** (Code, ~350 líneas) es el cerebro. Lee `$('Validar Contrato').first().json.lectura`, nunca el cuerpo crudo del Webhook (eso cerró 16.52). Devuelve **tres ramas** con contrato de salida uniforme (~34 campos):

| Rama | Cuándo | `estado` |
|---|---|---|
| **A · Sin Umbrales** | la etapa no tiene fila en `parametro_etapa` | `Sin Umbrales - Configuracion Incompleta` |
| **B · Lectura Sospechosa** | los 5 que deciden llegan en 0, **o** los 5 en `null` | `Lectura Sospechosa - Revisar Sensor` / `Lectura Sin Datos - Revisar Sensor` |
| **C · normal** | el resto | `OK` / `Sequía` / `Exceso Hídrico` / `Estrés Químico` / `Sequía + Estrés Químico` / `Falla de Riego - Revisar Sistema` |

**⚠️ Las ramas A y B NO emiten `foto_base64` ni `etapas_especie_id`.** `foto_base64` sí se consume aguas abajo — eso es el hallazgo **16.39**, confirmado en vivo.

Los IF rutean sobre **booleanos de dominio**, nunca sobre el string `estado`:
`requiere_alerta` · `hay_sequia` · `hay_estres_quimico` · `hay_exceso_hidrico` · `lectura_sospechosa` · `en_mantenimiento` · `falla_riego_persistente` · `tiene_foto` · `tiene_actuador_riego`

`Dispara WF5` exige las tres: `hay_sequia = true` **y** `falla_riego_persistente = false` **y** `tiene_actuador_riego = true`.

**El control del último riego ("recheck", 13.7.2, desde el 19/10).** Si el último riego está `pendiente`, ya pasó la absorción (15 min) y no venció el control (60 min), **la lectura actual es el control**. El Motor lo evalúa **en la misma lectura, antes de decidir**:
- `exitoso`: la humedad volvió a estar ≥ al mínimo.
- `insuficiente`: subió ≥ 3 puntos pero sigue baja. Puede volver a regar.
- `fallo_sistema`: no subió. Activa el freno (`falla_riego_persistente`).

El freno también lee el resultado guardado de lecturas anteriores, y se suelta **por evidencia**: cuando una lectura posterior a la falla muestra la maceta húmeda (`humedad_max_posterior`). El mensaje de falla distingue, según `comando_estado`, "la placa no tomó la orden" de "la tomó y la humedad no subió".

El Motor emite `recheck_riego` (null si la lectura no es un control) **en las tres ramas**. `Consolidar datos` arma `rpc_recheck`, y `Registrar Recheck de Riego` llama a `fn_registrar_recheck_riego` **en cada lectura**: con `p_evento_id` null no hace nada. Ese nodo tiene *Retry* encendido, porque la RPC es idempotente.

### WF2 — `Diagnostico IA Emergencia` · 7 nodos · **activo**

Webhook `/diagnostico-ia`. Lo dispara WF1 cuando hay alerta **y** foto.

```
Webhook → IA Vision Gemini → Parsear Respuesta IA → Diagnostico Valido? ─[sí]→ Persistir Diagnotico → Telegram
                                                                        └[no]→ Diagnostico Fallido (Stop and Error)
```

Escribe en `seguimiento_fenologico`. **El nodo se llama `Persistir Diagnotico`, sin la `s`** — `$('...')` resuelve por coincidencia literal, así que el typo es el nombre real.

### WF3 — `Validacion Fenologica` · 17 nodos · **activo** · Schedule cada 8 h

Decide si el cultivo avanzó de etapa, mirando una foto con Gemini.

```
Schedule (8h) → Obtener Cultivos Activos → Obtener Orden Etapas [executeOnce] → Calcular Dias en Etapa
  → Hay cultivos a evaluar? → Validacion de foto → Descargar Foto → Extract from File
  → Convertir a Base64 → Foto Descargada? → IA Vision Fenologica → Parsear y decidir
  → Registrar Evaluacion (RPC transaccional) → Cambio de etapa? → Notificar Cambio de Etapa
  → Generar URL Firmada → Mandar foto
```

**Ventana de evaluación:** solo evalúa si `diasEnEtapa >= duracion_estimada_dias * 0.8`, y solo si **hay etapa siguiente** en el catálogo (si no, saltea en silencio — ver B.11).

**Prompt (desde el 01/10, 16.42):** no tiene transiciones escritas a mano. `Obtener Orden Etapas` trae `criterio_visual` del catálogo, `Calcular Dias en Etapa` pasa `criterio_etapa_actual` y `criterio_etapa_siguiente` (y corta con error si alguno llega vacío), e `IA Vision Fenologica` pregunta solo por esa transición. `cambio_confirmado` = "la planta ya dejó la etapa actual"; si ve otra etapa, la nombra (señal de 16.31). El contrato de respuesta no cambió: `Parsear y decidir` es el mismo.

**`Registrar Evaluacion`** llama a `fn_registrar_evaluacion_fenologica`, que escribe tabla + avance de etapa **en una sola transacción**. Reemplazó tres escrituras sueltas. Tiene política de terminación (`p_max_intentos`, default 3).

**Deduplicación — tiene DOS capas:** `Validacion de foto` exige `ultima_foto_path` no vacío **y** distinto de `ultima_foto_evaluada_path`; y la RPC tiene su propia clave de idempotencia `(cultivo_id, path_foto)` y devuelve `duplicado` si la foto ya tiene conclusión. **Limpiar la marca a mano no hace reevaluar** (la RPC frena igual). Regla: **para reevaluar, se manda una foto nueva por WF1; la marca no se toca a mano.**

### WF4 — `Análisis Preventivo de Rutina` · 10 nodos · **APAGADO a propósito**

Schedule cada 6 h. Sin ESP32 real no hay telemetría fresca; activarlo solo generaría corridas vacías. **Es una decisión, no un pendiente.** Quedó en `gemini-2.5-flash` (16.30).

### WF5 — `Control de Riego` · 9 nodos · **activo**

Webhook `/control-riego`. Lo dispara WF1 ante sequía.

```
Webhook → Get many rows [alwaysOutputData] → Verificar Cooldown → Cooldown Activo? ─[no]→ Calcular Dosis
  → Registrar Riego (fn_registrar_riego) → Riego Registrado? ─[sí]→ Enviar Mensaje de riego
                                                             └[no]→ Aviso Tope de Riego
```

`fn_registrar_riego` escribe `comando_dispositivo` + `evento_riego` en una transacción, y desde el 19/10 aplica el **tope duro** (16.46): no más de 4 riegos automáticos por cultivo en 6 h, con bloqueo por cultivo. Si se llega al tope, no crea nada y devuelve `registrado = false`; WF5 avisa por Telegram con los números que devuelve la base. `Verificar Cooldown` ya no tiene su propio `15`: lee `absorcion_completa` de la vista. Abiertos en WF5: **16.51** (inventa volumen y caudal si faltan), **16.55**, y la dosis que se informa es la calculada, no la entregada.

---

### WF7 — `WF7 - Registro de arranque` · 8 nodos · **activo** (desde el 20/10)

Webhook `/arranque` (misma credencial de entrada que WF1). La placa lo llama **una vez por encendido**, antes de mandar lecturas.

```
Webhook → Validar Arranque → Pedido Valido? ─[no]→ Responder Pedido Invalido (400)
                                └[sí]→ Registrar Arranque (fn_registrar_arranque) → Arranque Registrado?
                                          ├[sí]→ Responder Arranque (200 {"arranque_id": N})
                                          └[no]→ Responder MAC Desconocida (404)
```

**El número lo asigna la base**, no n8n ni la placa: es el `id` de `arranque_dispositivo` (identity `GENERATED ALWAYS` + clave primaria), así que no puede repetirse. Un pedido repetido da otro número; un número sin usar es un hueco, nunca una repetición. `Registrar Arranque` no tiene reintento (no es idempotente).

---

## 4 · Modelo de datos (Supabase, esquema `public`)

**Tablas principales:**

| Tabla | Para qué | Columnas que importan |
|---|---|---|
| `cultivo` | La planta | `id`, `active`, `dispositivo_id`, `especie_id`, `etapa_actual_id`, `fecha_inicio_etapa`, `ultima_foto_path`, `ultima_foto_evaluada_path`, `mantenimiento_hasta`, `volumen_maceta_litros` |
| `dispositivo` | El ESP32 | `mac_address` (UNIQUE), `tiene_actuador_riego`, `caudal_bomba_ml_s`. **`version_firmware` se borró el 20/10:** el firmware vigente se deriva del último arranque |
| `arranque_dispositivo` | Un encendido de la placa (contrato v1) | `id` = `arranque_id`, `dispositivo_id`, `version_firmware`, `fecha_hora` |
| `lectura_rechazada` | Lecturas que no cumplieron el contrato (las escribe la puerta de WF1) | `dispositivo_mac` (tal como llegó), `errores text[]`, `cuerpo jsonb` (sin la foto) |
| `lectura_sensores` | Telemetría, **formato largo** | `metrica_id`, `valor`, `fecha_hora` — **una fila por métrica**, así que una lectura completa son 5 filas |
| `tipos_metricas` | Catálogo de métricas | id 1=Humedad, 3=pH, 4=Nitrógeno, 5=Fósforo, 6=Potasio |
| `especie_planta` / `tipo_etapa` / `etapas_especie` / `parametro_etapa` | **La base de conocimiento** | `etapas_especie` ordena las etapas por especie y guarda `criterio_visual` (**NOT NULL**: cómo se reconoce en una foto la entrada a esa etapa); `parametro_etapa` guarda los umbrales de cada una |
| `evento_riego` | Riegos | `resultado` (`pendiente` / `exitoso` / `insuficiente` / `fallo_sistema`), `fecha_recheck`, `humedad_recheck`, `comando_id` → FK a `comando_dispositivo` |
| `comando_dispositivo` | Órdenes para el ESP32 | `tipo_comando`, `duracion_segundos`, `estado` |
| `seguimiento_fenologico` | Historia clínica (la escribe WF2) | `diagnostico_ia jsonb`, `path_foto` |
| `evaluacion_fenologica` | Evaluaciones de etapa (la escribe WF3) | `resultado`, `etapa_detectada`, `diagnostico jsonb` |

**Vistas:** `vista_cultivos_activos` (la que consumen WF1/WF3/WF4), `vista_conocimiento_experto` (umbrales por especie+etapa), `vista_promedios_recientes`, `vista_ultimo_arranque` (firmware vigente por placa, `security_invoker`), `vista_ultimo_riego`. Esta última, desde el 19/10, trae además `evento_id`, `comando_estado`, `absorcion_completa` (≥ 15 min), `recheck_vencido` (> 60 min) y `humedad_max_posterior`. **Los dos tiempos se definen solo ahí**: los leen WF5 y el Motor.

**Funciones RPC:** `fn_registrar_telemetria`, `fn_registrar_riego` (con tope duro), `fn_registrar_recheck_riego` (solo cierra eventos `pendiente` del mismo cultivo), `fn_registrar_evaluacion_fenologica`, y desde el 20/10 `fn_registrar_arranque`, `fn_verificar_arranque` y `fn_registrar_rechazo` (las tres solo para `service_role`, sin `SECURITY DEFINER`; las tablas nuevas con RLS y sin permisos para `anon`/`authenticated`).

> ⚠️ **`vista_conocimiento_experto` hace INNER JOIN contra `parametro_etapa`.** Una etapa sin umbrales no devuelve nulos: **no devuelve nada**. Es la raíz del hallazgo 16.37.

**Base de conocimiento cargada hoy:** una sola especie, **Tomate Cherry (especie 3)**, con 6 etapas, todas con umbrales y con criterio visual. La tabla está en §7.

**La Albahaca (especie 4) se dio de baja el 01/10, por decisión de alcance:** el modelo supone un **ciclo lineal** (etapas en orden hasta una cosecha final) y la albahaca es de cosecha continua. El tomate cherry también se aparta un poco (crecimiento indeterminado: flores y frutos conviven), y los criterios visuales lo contemplan.

**Cargar una especie nueva** = por cada etapa: orden y duración (`etapas_especie`), umbrales (`parametro_etapa`) y `criterio_visual`. Un buen criterio se ve en una foto, describe la **entrada** a la etapa y dice qué puede coexistir. Se redactaron sobre los estadios BBCH. Agregar una especie es cargar conocimiento, no tocar n8n.

---

## 5 · Semántica de n8n: las reglas que este proyecto aprendió pagando

Esto es lo más valioso del paquete. Cada línea costó al menos una sesión de depuración.

1. **Un nodo que devuelve cero ítems corta la rama en silencio, sin marcar error.** `alwaysOutputData` es la defensa — pero convierte "no hay dato" en un ítem vacío `{}` que viaja aguas abajo como si fuera información. **Una protección contra un fallo silencioso puede crear otro de signo contrario** (así nació 16.37).

2. **Un nodo HTTP o Supabase corre una vez por cada ítem de entrada.** Un nodo que trae datos de referencia invariantes necesita `Execute Once`, o multiplica el resultado por N y corrompe a quien lo consume como lista.

3. **`.first()` colapsa la cardinalidad y el runtime no lo detecta**, porque devolver un ítem es legal. `.item` empareja por ítem, `.all()` da el conjunto. Mezclarlos en el mismo nodo produce desalineaciones que solo se ven con N>1.

4. **`$('NodeName')` resuelve por coincidencia literal de string.** Renombrar un nodo rompe referencias sin ningún aviso y no hay refactor seguro. Por eso conviven `Obtener Ultimo Riego` (sin tilde), `Preparar Foto binaria` (b minúscula) y `Persistir Diagnotico` (sin s): son los nombres **reales**.

5. **`typeValidation: strict` en los IF es un detector, no un obstáculo.** Activar "convert types" o agregar `.toBoolean()` para silenciar un error casi siempre esconde una expresión que no está evaluando.

6. **`retryOnFail` se habilita según la idempotencia de la operación, no según su importancia.** Reintentar un diagnóstico es seguro; reintentar un INSERT de riego crea un segundo riego real.

7. **`onError: continueRegularOutput` deja pasar el objeto de error como si fuera un dato.** Exige validación positiva aguas abajo.

8. **El `onError` por defecto es "detener workflow".** En un nodo del camino principal, eso convierte el fallo de una rama en un fallo total (16.39).

9. **Fan-out contra una API con límite de tasa requiere batching, no más reintentos:** el reintento compite contra las llamadas que causan la saturación.

10. **`undefined` en un campo binario no es un error de JavaScript.** El nodo Code reporta éxito habiendo producido basura.

11. **Cuidado con la coerción:** `Number(null) === 0` y `Number('') === 0`. Un sensor ausente convertido a 0 no es "falta el dato": es 0 % de humedad, o sea **sequía**, que dispara riego real. La ausencia se decide **antes** de convertir. Y en comparaciones, `"" < 60` es `true` (16.52, confirmado en vivo).

12. **`Respond to Webhook`:** con el Webhook en *Using 'Respond to Webhook' Node*, responde ese nodo, y **deja pasar los ítems**: el flujo sigue después de responder. Si el Webhook queda en *Immediately* con nodos Respond conectados, n8n corta con `500 "Unused Respond to Webhook node found in the workflow"` **antes de ejecutar ningún nodo**. Header Auth con clave incorrecta responde **403** (no 401).

---

## 6 · Principios de diseño del proyecto

- **Validación positiva, no negativa.** No alcanza con "no falló": hay que verificar afirmativamente que la respuesta contiene lo esperado. Validez sintáctica no es validez semántica.
- **Rutear por hechos de dominio, no por strings de presentación.** El texto que lee un humano es presentación; las decisiones se toman sobre booleanos explícitos.
- **La definición vive en el productor.** Si dos consumidores evalúan el mismo concepto con criterios propios, tarde o temprano discrepan.
- **Normalizar en el borde.** Los valores se convierten al tipo del contrato una sola vez, no se defienden en cada consumidor.
- **Contrato de salida uniforme.** Todos los caminos de un nodo devuelven los mismos campos. *Matiz aprendido en 16.39:* la pregunta útil no es "¿todas las salidas tienen los mismos campos?" sino **"¿está presente en todos los caminos cada campo que algún consumidor lee?"**.
- **Atomicidad donde hay dual-write.** Dos escrituras que deben pasar juntas van en una transacción de base, no en dos llamadas HTTP.
- **Fallar fuerte cuando la alternativa es un dato incorrecto y creíble.** Una excepción visible es mejor que una fila que miente.
- **Un fallo manejado tiene que seguir siendo contado.** Degradar bien de cara al usuario y no dejar señal para el operador son dos cosas distintas.
- **N=1 no prueba un sistema que itera.** Es el caso donde todas las formas de romper la iteración dan el mismo resultado correcto.
- **Verificar contra el estado persistido, no contra el output del nodo.**
- **Un modelo mental del runtime es una hipótesis, no evidencia.** Ningún hallazgo entra como 🔴 sin haber sido ejercido, si ejercerlo es barato. (16.32 se refutó así; 16.39 se confirmó así.)

**Con lente de producto:** esto se vende a gente que cultiva y no sabe de tecnología. Los errores no valen lo mismo — distinguí siempre entre "queda feo", "pierde un dato" y **"daña el cultivo"**. Cada fallo silencioso es un ticket que no se puede diagnosticar, y el soporte no escala como el software.

---

## 7 · Estado verificado el 20/10/2026

Consultado contra Supabase, no asumido.

| Dato | Valor |
|---|---|
| Cultivos activos | 1 — Tomate Cherry - Demo Tesis, **Fructificación desde el 23/09 23:18 UTC** (avanzó por WF3) |
| Próxima evaluación de etapa posible | **25/10, 23:18 UTC** (ventana = 80 % de 40 días, ver 16.65). **⚠️ Hoy no hay foto nueva** (`ultima_foto_path` = `ultima_foto_evaluada_path`): sin una foto nueva por WF1 antes de esa hora, WF3 la saltea en silencio |
| `lectura_sensores` | 230 · última del 01/10 23:10 UTC (de un test) |
| `evento_riego` | 8. Son los de agosto, en `pendiente`, con el control vencido: no frenan nada. Los de los tests del 19 y 20/10 se limpiaron |
| `arranque_dispositivo` | **0.** El próximo arranque será el **6** (los contadores no vuelven atrás: los tests consumieron números) |
| `lectura_rechazada` | 0 (los rechazos del test se limpiaron) |
| `comando_dispositivo` | 8 — **ninguno consumido por nadie** (la otra mitad de 16.63) |
| `evaluacion_fenologica` | **3** — 11 `etapa_no_coincide` (19/09), 12 `avanza` (23/09), 13 `no_avanza` (01/10, test) |
| `seguimiento_fenologico` | 25 |
| Especies | **1** (la Albahaca se dio de baja el 01/10) |
| Etapas sin umbrales | **0** |
| Claves JWT heredadas de Supabase | **deshabilitadas** (16.40 cerrado) |
| n8n | `n8nio/n8n:2.19.5`, clave de cifrado en `.env` (fuera de git), respaldo en `D:\respaldos_n8n` con simulacro de restauración ✅ |
| Contrato de telemetría | **Vigente desde el 20/10:** pasos 1 (arranque, WF7) y 2 (puerta de WF1) aplicados y verificados en vivo. Faltan los pasos 3 a 5 |

**Workflows:** WF1 ✅ (26 nodos, re-exportado 20/10) · WF2 ✅ · WF3 ✅ (re-exportado 01/10) · WF4 ⬜ (a propósito) · WF5 ✅ (9 nodos, re-exportado 19/10) · WF7 ✅ (8 nodos, re-exportado 20/10)

**Contrato v1, verificado en vivo el 20/10 (Fase 18.3):** arranque → 5 / MAC desconocida → 404 / sin `fw` → 400; formato viejo, `humedad: ""`, humedad 150 y arranque ajeno → `400` cada uno con su error y su fila en `lectura_rechazada`; lectura sana → aceptada; todo `null` → "Lectura Sin Datos"; sequía → riego → control `exitoso`. **T0 (19/10, antes del fix):** `humedad: ""` dio una sequía falsa y el riego no ocurrió solo porque 16.56 rompía WF5.

**Lazo de riego, verificado en vivo el 19/10 (13.7.2):** tope (el 5º riego no se creó), freno en la misma lectura y persistido, diagnóstico según el estado de la orden, rearme, espera de 15 min y `exitoso`. El riego 17 se cerró dos segundos antes de que se creara el 18: el control ocurre antes de la decisión.

> ⚠️ **El cultivo no existe físicamente.** No hay planta, ni sensor, ni temporada. Lo validado es la lógica de control del software, no el modelo agronómico. No confundas las dos cosas al razonar sobre este sistema, y no propongas "verificarlo con la planta".

### WF3 decide bien en los dos sentidos, verificado en vivo

- **23/09 — primer `avanza` de punta a punta pasando por el modelo:** Floración → Fructificación, 0,98. Las tres escrituras de la transacción con el mismo timestamp.
- **01/10 — `no_avanza` con el prompt nuevo:** la foto de demo tiene frutos verdes y el criterio de Cosecha pide cambio de color. La `evidencia_visual` del modelo reproduce el criterio del catálogo, o sea que el criterio llegó al modelo.
- **Antes:** la "anomalía" de agosto/setiembre no era un bug: el contenedor de n8n estuvo apagado y el Schedule Trigger no recupera corridas perdidas (**16.64**). El 23/09 los logs de Supabase mostraron cero pedidos de n8n en 24 h: posible segundo episodio, **no confirmado**.

### Catálogo del Tomate Cherry, vigente desde el 23/09 (criterio visual desde el 01/10)

| # | Etapa | Días | Humedad | pH | N | P | K | K:N |
|---|---|---|---|---|---|---|---|---|
| 1 | Germinación | 10 | 80–95 | 6.0–7.0 | 10 | 10 | 10 | 1.00 |
| 2 | Plántula | 15 | 70–85 | 6.0–6.5 | 20 | 15 | 15 | 0.75 |
| 3 | Vegetativo | 40 | 60–75 | 6.0–6.8 | 50 | 30 | 30 | 0.60 |
| 4 | Floración | 20 | 50–65 | 6.2–6.8 | 30 | 50 | 60 | 2.00 |
| 5 | **Fructificación** | 40 | 60–75 | 6.0–6.8 | 25 | 40 | 60 | 2.40 |
| 6 | Cosecha | 30 | 45–60 | 6.0–6.8 | 20 | 30 | 45 | 2.25 |

Criterio visual por etapa (resumido): Germinación = emergencia · Plántula = cotiledones abiertos · Vegetativo = ≥4 hojas verdaderas, sin botones · Floración = racimos con flores amarillas, sin frutos · **Fructificación = frutos cuajados verdes (puede haber flores)** · **Cosecha = frutos con cambio de color**. El texto exacto está en la base.

> **Las columnas de `parametro_etapa` NO tienen unidad declarada.** La literatura publica % de capacidad de campo o ppm en solución; esta escala no es ninguna de las dos. Los valores nuevos se derivaron de fuentes citadas transfiriendo **dirección y magnitud relativa**, nunca el número. Si vas a discutir un umbral, discutí la forma de la curva, no el valor absoluto. Ver Fase 17 del plan.

> **Trampa de esquema, para no perder tiempo:** `cultivo.etapa_actual_id` apunta a **`tipo_etapa.id`**, no a `etapas_especie.id`, pese al nombre. Para llegar a la duración hay que pasar por `etapas_especie` filtrando por `especie_id` **y** `etapa_id`. Y la FK en `parametro_etapa` se llama `etapa_especie_id`, en singular.

---

## 8 · Hallazgos abiertos

**El registro tiene 64 hallazgos numerados (`16.1`–`16.65`, con `16.50` sin asignar a propósito), 3 hallazgos nuevos todavía sin número, y 23 diferidos (`B.1`–`B.23`).** Nomenclatura: `16.x` = hallazgo de auditoría · `B.x` = diferido a propósito.

> [!IMPORTANT]
> **Numeración estable, y NO la asignes vos.** Los números no se reasignan nunca, ni siquiera los que quedan libres — un hueco es inocuo, reusar un número no lo es. **Si encontrás algo nuevo, describilo SIN número** y dejá que se le asigne al integrarlo al plan. Este archivo es una foto y puede estar desactualizado respecto del registro: el último número que ves acá no es necesariamente el último que existe. **El número lo da el registro, no el hallazgo.**

### Los 🔴, en el orden en que importan

| # | Dónde | Qué | Por qué es 🔴 |
|---|---|---|---|
| **16.51** | WF5 | Volumen de maceta y caudal se inventan cuando faltan (`\|\| 10`, `\|\| 50`) | **Desde que se cerró 16.46, es el 🔴 que más directamente daña el cultivo.** El tope de 30 s está expresado **en tiempo**, así que hereda el caudal inventado y deja pasar el doble de volumen |
| **16.63** | Lazo de riego | **El control del riego se cerró el 19/10 (13.7.2). Sigue abierta la entrega:** nadie consume `comando_dispositivo` | Falta decidir cómo lee la placa sus órdenes sin la clave maestra (D-auth, B.23). Para la defensa: trabajo futuro con diseño escrito |
| **16.37** | WF1 | Cultivo en etapa sin umbrales se reporta sano | Guarda aplicada, **nunca ejercida**, y ya **sin datos reales que la ejerzan** (la especie 4 se borró). Aplicar 16.38 hace el hueco imposible por construcción |

> ✅ **Cerrados:** **16.52** (20/10, la puerta del contrato, Fase 18; confirmado antes en vivo con T0) · **16.46** y **13.7.1** (19/10, lazo de riego, 13.7.2, verificado en vivo) · **B.1** y **16.41** (23/09, catálogo completo) · **16.40** (01/10, claves JWT heredadas deshabilitadas) · **16.42** (01/10, criterio visual desde el catálogo, test en vivo) · **B.13** y **B.14** (06/10, respaldo de n8n y versión fijada) · **B.22** (13/10, contrato de telemetría escrito).
>
> 🟠 **Hallazgo nuevo, SIN número (20/10):** una medición que decide, en `null`, **se saltea sin aviso**. Con solo la humedad en `null` la lectura sale `OK`, no hay sequía posible y no se riega: si el sensor de humedad muere y los demás siguen midiendo, la maceta se seca sin una alerta. Ya pasaba con el formato viejo; el contrato lo volvió un estado declarado. Compone con 16.44 y B.7. (El caso de **todo** `null` sí está resuelto: sale "Lectura Sin Datos".)
>
> 🟢 **Hallazgo nuevo, SIN número (19/10):** `dosis_ml` (en `evento_riego` y en el Telegram) es la dosis **calculada**, no la **entregada** después del tope de 30 s: en el test decía ~1.375 ml y se entregaron ~1.200. Compone con 16.51. Fix natural: guardar o derivar `duracion_segundos × caudal`.
>
> 🟢 **Hallazgo nuevo, SIN número:** el camino `duplicado` de `fn_registrar_evaluacion_fenologica` devuelve `foto_marcada: true` sin marcar la foto. Solo alcanzable si alguien limpia la marca a mano. **El fix se escribió y se descartó a propósito** (`SQL/sesion14_fix_rpc_duplicado_marca_foto.sql`, marcado DESCARTADO): agregaba código para defender una redundancia. La marca es un caché de "¿existe una evaluación no fallida para esta foto?"; la solución de fondo es **derivarla y quitar la columna**, no programada. **No lo vuelvas a proponer como fix incremental.**

### 🟠 — los que bloquean la venta

| # | Dónde | Qué |
|---|---|---|
| **16.47** | Contrato · BD | Sin tiempo de dispositivo ni número de secuencia. El `arranque_id` ya lo asigna la base (20/10) y la puerta valida `ts` y `seq`, pero **todavía no se guardan** por lectura (paso 4 del contrato) |
| **16.55** | WF5 | Ejecuta lo que le mandan sin verificar contra la base. Compone con B.23 |
| **16.64** | Infra · Producto | **El orquestador apagado es monitoreo apagado.** n8n no recupera corridas perdidas, la pantalla sigue diciendo *Active*, y no hay señal. Es 16.44 un piso más arriba |
| **16.44** | Todos | El silencio del dispositivo no existe como estado: 34 días sin lecturas y cero avisos |
| **16.43** | WF1 · WF2 | Una foto sin alerta de umbral no la analiza nadie |
| **16.39** | WF1 | Sensor desconectado + foto: la lectura se pierde entera y sin aviso. Confirmado en vivo 31/08, fix de 2 capas escrito |
| **16.33 · 16.38 · 16.61** | BD | Faltan restricciones: dos cultivos por dispositivo, el hueco de umbrales (**16.38 ya destrabado**: 0 etapas sin umbrales), y la tercera |
| **16.31 · 16.15** | WF3 | `etapa_no_coincide` es estado absorbente · la degradación no deja señal operativa |
| **B.17** | Arquitectura | Falta la capa de tendencia: el sistema ve estados, no procesos. Los datos ya existen, falta quien los lea |
| **B.7** | Producto | Fatiga de alertas: notifica por nivel, no por transición |

### 🟡 · 🟢 — agrupados

- **WF4, no encenderlo:** `16.57` (pérdida de cardinalidad — es 16.16 otra vez), `16.58` (ruteo), `16.59` (el error del modelo guardado como dato — es 16.14 otra vez), `16.49`, `16.60`, `16.45` (el prompt le pide al modelo que invente la tendencia), `16.30` (quedó en `gemini-2.5-flash`).
- **WF5, endurecer:** `16.53`, `16.54`, `16.56` (ya no tapa a 16.52), `16.62`.
- **Seguridad y base:** `16.1` (secretos), `16.6` (mínimo privilegio), `16.13` (`anon`/`authenticated` con `ALL` sobre 18 tablas), `B.9` (`SECURITY DEFINER` ejecutable por `anon`), `B.23` (separación de credenciales).
- **Contrato y datos:** `B.22` ✅ (contrato escrito el 13/10; pasos 1 y 2 vigentes desde el 20/10), `16.48` (temperatura y conductividad: **se guardan, no deciden**, definido en el contrato), `B.19` (cadencia: el contrato no la fija, sale del piloto), `B.20` (trazabilidad: el DNI de la lectura la habilita), `B.21` (retención).
- **Observabilidad de la planta:** `16.65` (la ventana de evaluación es el 80 % de la duración: Fructificación deja **32 días ciegos**), `16.43` (una foto sin alerta no la mira nadie), `B.17` (falta la capa de tendencia). Los tres son lo mismo visto de costado: **el sistema solo observa cuando sospecha, y sospecha por un único criterio.**
- **Resto:** `16.8` (a medias desde el 20/10: una MAC desconocida ya se rechaza y se registra; un dispositivo sin cultivo activo sigue mudo), `16.9`, `16.21`, `16.29`, `B.2`–`B.6`, `B.8`, `B.10`–`B.12`, `B.15`, `B.16`, `B.18`.

### Reglas que salieron de las últimas rondas

1. **Cuando una corrección establece un criterio, propagalo a todos los consumidores**, no solo al que mostró el síntoma (`16.56`). La construcción de cuerpos por interpolación se corrigió en WF1 y en WF3 y sobrevivió en WF5 dos meses.
2. **Un identificador único no se garantiza con una convención escrita, se garantiza con un registro que lo asigne** (`16.25`, reconfirmado por el choque de numeración de esta ronda).
3. **No se mantiene sincronizado a mano lo que se puede derivar** (sesión 14). Antes de proponer código que mantenga dos datos de acuerdo, preguntá si uno se puede calcular del otro. Agustín valora explícitamente que agregar más a veces es menos.
4. **Un mecanismo de dos capas no se resetea tocando una** (v53): limpiar la marca de WF3 dio verde y no reevaluó nada.
5. **Antes de construir un diseño del plan, seguilo contra el orden real de ejecución de los nodos** (13.7.2). El freno diseñado en 13.7.1 habría seguido sin activarse nunca, porque el nodo que cerraba el control corría después de que el Motor decidía. Se detectó leyendo la topología, no ejecutando.
6. **Ejercer antes de arreglar puede destapar un enmascaramiento** (sesión 17). En T0, 16.52 decidía una sequía falsa y 16.56 rompía la escritura del riego: lo visible era "no pasó nada". Antes de arreglar un defecto, preguntá si otro lo está tapando: arreglar 16.56 primero habría convertido a 16.52 en un riego real.

**El lazo de riego (13.7.2, cerrado el 19/10).** Hay tres defensas independientes contra regar de más: el control con su freno (realimentación), el tope duro en la base (interlock) y la válvula local de 30 s del firmware (13.6, todavía sin hardware). Las dos primeras están aplicadas y verificadas en vivo. Los números (3 puntos, 4 riegos en 6 h, 15 y 60 min) **no tienen fuente**: salen del piloto con hardware (B3). **Se validó la lógica de control, no los números.**

---

## 9 · Qué hacer, en orden

**El 27/10/2026 Agustín da una simulación de defensa de tesis.** **(1) Lazo de riego: ✅ 19/10** (13.7.2). **(2) Contrato, pasos 1 y 2: ✅ 20/10** (Fase 18; cerró 16.52; el test de riego corto con el simulador nuevo también pasó). **Lo que sigue: (3) guion de demo y ensayo, 24 y 25/10**, con el simulador nuevo: lectura sana → OK; sequía → alerta, riego y control; riego sin efecto → freno; lectura inválida → rechazo (mostrar la fila en `lectura_rechazada`); todo `null` → Sin Datos; foto → diagnóstico IA; y el resultado real de WF3 el 25/10. **Para WF3 hace falta mandar una foto nueva por WF1 antes del 25/10 a las 23:18 UTC** (hoy no hay ninguna sin evaluar), con la PC y n8n prendidos; el simulador `L` no manda foto, hace falta una variante con `foto_base64`. La foto de demo tiene frutos verdes: lo esperable es `no_avanza`. T0 sirve como relato de defectos que se enmascaran. **Queda como trabajo futuro, con diseño escrito:** pasos 3 a 5 del contrato, la entrega de órdenes a la placa (16.63), 16.51 y la dosis entregada, la medición en `null` sin aviso, 16.38, endurecer WF5 y WF4.

La lista de abajo es el orden general del proyecto, sin la fecha.

`docs/revisiones/REVISION_04_hoja_de_ruta.md` organiza lo que queda en **tres carriles** —lo que bloquea la tesis, lo que bloquea la venta, y la deuda tolerable— y define un **mínimo viable para un primer cliente**. Ese mínimo descansa en tres defensas independientes contra el mismo riesgo (regar de más): el control del riego (13.7.2 ✅), el tope duro por ventana (16.46 ✅) y **la válvula local de 30 segundos en el firmware**, la única que sigue funcionando si n8n, la red o Supabase se caen. Son capas separadas a propósito.

1. **Terminar el contrato** (`docs/contrato_telemetria.md`, sección 9): pasos 1 y 2 ✅ (20/10). Faltan el 3 (responder según el procesamiento, que también resuelve el resto de 16.8), el 4 (`ts`/`arranque_id`/`seq` por lectura con unicidad, **16.47**) y el 5 (temperatura y conductividad, **16.48**).
2. **Entrega de órdenes a la placa** (16.63): el control y el tope ya están (13.7.2, 19/10). Falta quien consuma `comando_dispositivo`, y decidir antes cómo se autentica la placa (D-auth, B.23).
3. **16.38** — la restricción que impide que vuelva el hueco de umbrales. Ya no la bloquea nada. SQL con confirmación (regla 2).
4. **Endurecer WF5**: 16.51, 16.55, 16.53, 16.56 (16.52 se cerró en la puerta de WF1).
5. **No encender WF4** hasta resolver 16.57, 16.58, 16.59, 16.49, 16.60 y 16.30.
6. **Pendientes chicos:** copia de la clave de n8n y del respaldo fuera de la laptop (los hace Agustín); confirmar 16.64 (indicio de ~5 días apagado, 01/10 → 06/10); sacar el duplicado `implementation_plan.md` de la raíz del repo; verificar las referencias BBCH antes de citarlas (17.3).

> **El 25/10 a las 23:18 UTC abre la ventana de evaluación de WF3** (16.65). Si n8n no está levantado en el tick siguiente, la corrida no ocurre y no deja rastro (16.64).

---

## 10 · Cómo probar

**No hay ESP32.** Se simula con PowerShell desde la máquina de Agustín, **con el formato del contrato v1** (desde el 20/10 el formato viejo, con `planta` y sin `v`, se rechaza con `400`). Los webhooks tienen Header Auth (`X-Device-Key`); la clave está en la credencial `ESP32 Telemetra Key`, no en los JSON. Un **403** es la clave mal puesta.

**Simulador** (en `SQL/sesion17_test_puerta_en_vivo.sql`). Se pega una vez por ventana, **una línea por vez** (su terminal no acepta multilínea):

```powershell
$K = "LA_CLAVE"; $U = "http://localhost:5678/webhook"; $MAC = "24:0A:C4:A1:B2:C3"
function Pedir($ruta, $obj){ try { Invoke-RestMethod -Uri "$U/$ruta" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = $K } -Body ($obj | ConvertTo-Json -Compress) } catch { "HTTP " + [int]$_.Exception.Response.StatusCode + " " + $_.ErrorDetails.Message } }
function A($fw = "sim"){ $r = Pedir "arranque" @{v=1; dispositivo_mac=$MAC; fw=$fw}; if ($r.arranque_id) { $global:a = $r.arranque_id; $global:s = 0 }; $r }
function L($h = 68.0, $arr = $global:a){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$arr; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=6.4; conductividad=1.2; n=25; p=40; k=60}; $global:s++; Pedir "telemetria" $b }
function N(){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$null; temperatura=$null; ph=$null; conductividad=$null; n=$null; p=$null; k=$null}; $global:s++; Pedir "telemetria" $b }
```

**Siempre `A` primero** (la placa "enciende" y guarda su arranque en `$a`), también después de cada limpieza, que borra los arranques. Después: `L 68` (sana), `L 55` (sequía), `L ""` o `L 150` (rechazo), `L 68 999999` (arranque ajeno), `N` (todo `null`). `Pedir` muestra los errores como `HTTP 400 {...}` en vez de cortar. **Todavía no hay una función que mande foto:** hay que agregar `foto_base64=(Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw).Trim()` al cuerpo de `L`.

**Umbrales vigentes (Tomate Cherry / Fructificación):** humedad 60–75 · pH 6.0–6.8 · N ideal 25 (tolerable 17,5–32,5) · P ideal 40 (28–52) · K ideal 60 (42–78). La tolerancia NPK es ±30 %. **Ojo: humedad 55 o 58 ahora es Sequía y dispara WF5.** Lectura sana de referencia: `humedad=68.0; ph=6.4; n=25; p=40; k=60`.

**La función `T` de la sesión 16 ya no sirve** (manda el formato viejo y vuelve `400`). En los guiones viejos, `T 55` se reemplaza por `L 55`. "Execute workflow" no hace falta: WF1 y WF7 activos escuchan en `/webhook/`.

**Probar el lazo de riego:** el guion está en `SQL/sesion16_test_lazo_riego_en_vivo.sql`, con tres escenarios (usa `T`: reemplazarla por `L`, con `A` antes). Para no esperar 15 min reales se usa el **ATRASAR**, que mueve el último riego 20 min hacia atrás. Reglas:
- Anotar los `max(id)` antes de empezar y limpiar por encima de ellos.
- Limpiar **entre escenarios**, porque el tope cuenta los riegos de las últimas 6 h.
- Desde 50, después de regar: subir de 53 a 59 es `insuficiente` (vuelve a regar); subir menos de 3 puntos es `fallo_sistema` (frena).

**Test de la base que se deshace solo:** `SQL/sesion16_lazo_riego.sql`, BLOQUE 3. Termina con un error a propósito, `TEST OK: …`, que revierte todo lo que escribió. Se comprobó que puede fallar: con tres defectos inyectados, los detectó los tres.

**Probar la puerta y el arranque:** `SQL/sesion17_test_puerta_en_vivo.sql` (arranque, cuatro rechazos con errores distintos, lectura sana, todo `null`, riego corto, y la LIMPIEZA FINAL, que también borra `lectura_rechazada` y `arranque_dispositivo`).

**Reglas de testing no negociables:**

- **Antes de decir "ejecutá y mirá", confirmá que el workflow realmente llega a los nodos que se quieren probar.** Una vez casi se corrió un test que se cortaba en el primer IF y habría dado verde sin probar nada.
- **Diseñá los tests para que puedan fallar.** Si dos casos son indistinguibles, el test no detecta que se intercambiaron.
- **Verificá contra la base, no contra el verde del nodo.**
- **Los datos que crea un test son parte del test: limpiarlos es parte de haberlo terminado.** Hay dos scripts de referencia en `SQL/`.
- **Un fix aplicado antes del test convierte al test en una tautología.** Si la hipótesis es que algo falla, ejercela **antes** de arreglarla.
- **Para probar WF3 hay que abrir la ventana a mano:** atrasar `fecha_inicio_etapa` y mandar una foto nueva por WF1; al terminar, restaurar la fecha. Modelo de script: `SQL/sesion14_test_16.42_criterio_visual.sql`.
- **Los objetos de Storage no se borran por SQL.** `delete from storage.objects` borra la fila de metadatos y deja el archivo huérfano. Se borran desde el dashboard.

---

## 11 · Reglas de trabajo con Agustín

1. **Todo prolijo.** Es una tesis y un futuro producto.
2. **No toques tablas, columnas, políticas RLS ni datos** sin explicar antes qué y por qué, y esperar confirmación explícita. **Forma de trabajo vigente:** los cambios de esquema o destructivos se escriben como script versionado en `SQL/` (con estado previo, reverso y bloque de verificación), **los ejecuta Agustín en el SQL Editor**, y el agente verifica por MCP en modo lectura. En la sesión 14 el control de permisos bloqueó la ejecución directa por MCP.
3. **Verificá el estado real antes de asumir.** El documento y los JSON pueden estar desactualizados respecto de lo que corre en vivo. Ya hubo varios casos de drift.
4. **Verificá contra el estado persistido, no contra el output del nodo.**
5. **No tiene navegador en n8n.** Proponé el cambio exacto —nodo, campo, expresión, código completo para pegar— y él lo aplica y reporta. **Explicale qué hace cada nodo antes de que lo aplique**, y si es un workflow nuevo, ofrecé que lo arme él, guiado.
6. **Al terminar algo, actualizá `docs/implementation_plan.md`:** changelog, **Tablero**, **Hallazgos abiertos**, **Cierre de sesión**, y la sección numerada que corresponda. Lo diferido a propósito va al backlog. **Nada queda flotando en la conversación.**
7. **Antes de proponer una tabla, nodo o credencial nueva**, revisá si el backlog ya registra un intento anterior descartado por el mismo motivo.
8. **Decile cuando se equivoque.** Prefiere que discutas una decisión antes de implementarla.
9. **Explicá el razonamiento conceptual detrás de cada decisión**, nombrando el patrón o principio cuando exista. Es material para el marco teórico de la tesis.
10. **El proyecto está versionado con git y publicado en GitHub** (`AgustinLago22/Sistema-Experto-Agricola`). **El repo es un entregable de la tesis**, porque muestra el historial: **los commits y los push los hace Agustín**, y **ningún commit lleva líneas de coautoría ni de sesión del agente** (`Co-Authored-By`, `Claude-Session`). El agente **no corre comandos de git que escriben** (`add`, `commit`): la carpeta montada no le deja borrar archivos y git deja `.git/index.lock` trabado. Lo que hace el agente: leer con `git --no-optional-locks`, dejar el mensaje del commit en `.git/COMMIT_MSG_<tema>` y pasarle los comandos (`add`, `commit -F`, borrar el archivo del mensaje, `push`). Ritual de cierre: re-exportar los workflows tocados **sobrescribiendo `WORKFLOWS/WFn.json`** (nombre estable, nunca con fecha), actualizar el plan, commit y push. Si `git status` no queda limpio y al día con `origin/main`, hay algo sin documentar.
11. **No inventes números de hallazgo.** Describí lo que encontrás y dejá que el número se asigne al integrarlo al plan. Ver la advertencia de *Hallazgos abiertos*.

---

## 12 · Mapa del plan, si hace falta profundizar

`docs/implementation_plan.md` (v62, ~6.700 líneas). **Abrí solo la sección que necesites.** (Hay una copia vieja en la raíz del repo: ignorala.)

| Buscás | Andá a |
|---|---|
| Estado, hallazgos abiertos, próximos pasos | **Tablero**, **Hallazgos abiertos**, **Cierre de sesión** |
| Contradicciones conocidas entre el doc y los artefactos | **Contradicciones** |
| Por qué se versiona y el ritual de sesión | **Versionado y ritual de sesión** |
| Cierres de sesiones anteriores | **Historial de sesiones** |
| Detalle de un hallazgo `16.x` | `Fase 16 · Registro de Hallazgos`, en orden numérico |
| Detalle de un diferido `B.x` | `Backlog`, al final |
| WF1 nodo por nodo | `Fase 4` |
| WF2 / WF3 / WF4 nodo por nodo | `Fase 8` / `Fase 9` / `Fase 10` |
| Riego automático | `Fase 13`. El lazo (control, freno, rearme, tope) y su test en vivo están en **`13.7.2`**; `13.7.1` es el diseño viejo con sus tres defectos |
| La RPC transaccional de riego | `13.5.3` (el tope duro se le agregó en `13.7.2`) |
| La RPC transaccional de WF3 | `9.14` |
| Fertirriego (diseñado, sin implementar) | `Fase 15` |
| Trazabilidad de la base de conocimiento y bibliografía (incluye BBCH de los criterios visuales) | `Fase 17` |
| El hallazgo sin número del camino `duplicado` y su fix descartado | Final de `Fase 16`, título **Hallazgo sin número** |
| Lo hecho en la sesión 17 | Changelog **v61 y v62**, **Cierre de sesión** y **Fase 18**. La sesión 16 (v59, v60) está en **Historial de sesiones** |
| El contrato aplicado: arranque, WF7, la puerta de WF1, T0 y el test en vivo | **`Fase 18`** (18.1 arranque, 18.2 puerta, 18.3 pruebas, 18.5 lo que queda) |
| El contrato de telemetría (qué manda el ESP32 y qué responde el sistema) | `docs/contrato_telemetria.md` (vigente desde el 20/10, pasos 1 y 2) |
| Respaldo, restauración y versión de n8n | `B.13` y `B.14`, en el Backlog |

**Las cuatro revisiones externas** (setiembre 2026, hechas por un agente que leyó este archivo y los workflows pero **no** el plan). Sus conclusiones ya están integradas al plan; los archivos quedan porque tienen el razonamiento completo:

| Archivo | Qué contiene |
|---|---|
| `docs/revisiones/REVISION_01_cobertura.md` | Si el sistema cubre el proceso real de una planta |
| `docs/revisiones/REVISION_02_medicion.md` | Qué se mide, qué falta medir, y la capa de tendencia que no existe |
| `docs/revisiones/REVISION_03_workflows.md` | Los cinco workflows nodo por nodo. Su §1 acota la anomalía de WF3 a cuatro causas |
| `docs/revisiones/REVISION_04_hoja_de_ruta.md` | Los tres carriles y el mínimo viable para un primer cliente |

**Otros archivos del repo:** `SQL/` (esquema y scripts de prueba) · `test/` (fotos y escenarios de prueba) · `WORKFLOWS/` (los 5 JSON).
