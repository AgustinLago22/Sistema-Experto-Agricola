# Sistema Experto Agrícola — Paquete de contexto para un agente

> **Generado el 17/09/2026** (plan v48). Estado verificado contra Supabase y contra los JSON exportados, no contra lo que afirma la documentación.
>
> Este archivo existe para que un agente pueda trabajar **sin leer `implementation_plan.md`**, que tiene 5.500 líneas y 587 KB. Acá está comprimido lo que hace falta para operar; el plan queda como referencia para profundizar en un punto concreto (mapa al final de este archivo).

---

## 0 · Cómo usar este documento

**Leé, en este orden:**

1. Este archivo, entero (~40 KB).
2. `WORKFLOWS/WF1.json` — es el corazón del sistema y donde está casi todo el trabajo abierto.
3. `WORKFLOWS/WF3.json` — el segundo en importancia, con una anomalía sin resolver.
4. WF2, WF4, WF5 **solo si la tarea los toca.** WF4 está apagado a propósito.

**No leas `implementation_plan.md` entero.** Si necesitás el detalle de un hallazgo, abrí solo esa sección — el **mapa del final** dice dónde está cada una.

**El usuario es Agustín.** Habla en español rioplatense y prefiere respuestas cortas, en castellano simple, una cosa por vez. Es su tesis **y** un producto que piensa vender. No tiene navegador conectado a n8n: cualquier cambio en un workflow se lo pasás como instrucción exacta (nodo, campo, expresión, código completo) y lo aplica él. Para Supabase sí hay MCP directo.

---

## 1 · Qué es el sistema

Un sistema experto agrícola de loop cerrado. En una frase:

> Un sensor en la maceta manda mediciones → n8n las procesa contra umbrales agronómicos → Supabase las guarda → si algo anda mal, avisa por Telegram y riega solo.

**Componentes:**

| Pieza | Qué es | Dónde corre |
|---|---|---|
| ESP32 + sensor 7-en-1 | Mide humedad, pH, N, P, K. Manda foto opcional | **No existe todavía.** Se simula con PowerShell |
| n8n | Orquestación. 5 workflows | Docker en la PC de Agustín, `localhost:5678` |
| Supabase | Postgres + Storage (bucket `fotos-cultivos`) | Proyecto `xypqsthwquegftcnoqyi`, "Tesis Cultivos" |
| Google Gemini | Visión: diagnóstico de emergencia y validación de etapa | `gemini-3.5-flash` (WF4 quedó en `2.5`) |
| Telegram | Canal de notificación | `chatId` 5593622386, repetido en 5 nodos |

**El ESP32 no está armado y nada depende de él.** La orquestación se construye primero, desacoplada a propósito: el sistema solo habla vía HTTP contra Supabase, nunca al revés.

**Idea central del dominio:** cada especie tiene etapas fenológicas ordenadas (Germinación → Plántula → Vegetativo → Floración → Cosecha), y cada etapa tiene sus propios umbrales de humedad, pH y NPK. El diagnóstico es *lectura contra umbral de la etapa actual*, no contra un valor fijo.

---

## 2 · Flujo, de punta a punta

```
ESP32 (o PowerShell)
   │  POST /webhook/telemetria   (Header Auth: X-Device-Key)
   ▼
 WF1 ──► guarda telemetría ──► ¿requiere alerta? ──┬──► Telegram
   │                                               ├──► WF2 (si hay foto)
   │                                               └──► WF5 (si hay sequía)
   │
   └─ si vino foto: la sube a Storage y actualiza cultivo.ultima_foto_path

 WF3 (cada 8 h, solo)  ──► mira la última foto ──► Gemini ──► ¿avanzó de etapa?
 WF4 (apagado)         ──► análisis preventivo de rutina
```

---

## 3 · Los 5 workflows

### WF1 — `Orquestacion - Tesis` · 18 nodos · **activo**

Webhook `/telemetria`. Es el único que mueve datos en cada lectura.

```
Webhook → Resolver Cultivo → Conocimiento Experto → Obtener Ultimo Riego → Motor de Inferencia
   → Hay foto nueva?  ─[sí]→ Preparar Foto binaria → Subir Foto a Storage → Actualizar Ultima Foto Cultivo ─┐
                      └[no]────────────────────────────────────────────────────────────────────────────────┤
   → Consolidar datos → fn_registrar_telemetria → Esta en mantenimiento ─[no]→ Requiere Alerta?
        → [3 ramas PARALELAS e INDEPENDIENTES]  Dispara WF 2 · Alerta Telegram · Dispara WF5
```

**`Motor de Inferencia`** (Code, ~350 líneas) es el cerebro. Devuelve **tres ramas** con contrato de salida uniforme (~34 campos):

| Rama | Cuándo | `estado` |
|---|---|---|
| **A · Sin Umbrales** | la etapa no tiene fila en `parametro_etapa` | `Sin Umbrales - Configuracion Incompleta` |
| **B · Lectura Sospechosa** | los 5 sensores llegan en 0 | `Lectura Sospechosa - Revisar Sensor` |
| **C · normal** | el resto | `OK` / `Sequía` / `Exceso Hídrico` / `Estrés Químico` / `Sequía + Estrés Químico` / `Falla de Riego - Revisar Sistema` |

**⚠️ Las ramas A y B NO emiten `foto_base64` ni `etapas_especie_id`.** `foto_base64` sí se consume aguas abajo — eso es el hallazgo **16.39**, confirmado en vivo.

Los IF rutean sobre **booleanos de dominio**, nunca sobre el string `estado`:
`requiere_alerta` · `hay_sequia` · `hay_estres_quimico` · `hay_exceso_hidrico` · `lectura_sospechosa` · `en_mantenimiento` · `falla_riego_persistente` · `tiene_foto` · `tiene_actuador_riego`

`Dispara WF5` exige las tres: `hay_sequia = true` **y** `falla_riego_persistente = false` **y** `tiene_actuador_riego = true`.

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

**`Registrar Evaluacion`** llama a `fn_registrar_evaluacion_fenologica`, que escribe tabla + avance de etapa **en una sola transacción**. Reemplazó tres escrituras sueltas. Tiene política de terminación (`p_max_intentos`, default 3).

**Deduplicación:** `Validacion de foto` exige `ultima_foto_path` no vacío **y** distinto de `ultima_foto_evaluada_path`, para no re-analizar la misma foto cada 8 h para siempre.

### WF4 — `Análisis Preventivo de Rutina` · 10 nodos · **APAGADO a propósito**

Schedule cada 6 h. Sin ESP32 real no hay telemetría fresca; activarlo solo generaría corridas vacías. **Es una decisión, no un pendiente.** Quedó en `gemini-2.5-flash` (16.30).

### WF5 — `Control de Riego` · 7 nodos · **activo**

Webhook `/control-riego`. Lo dispara WF1 ante sequía.

```
Webhook → Get many rows [alwaysOutputData] → Verificar Cooldown → Cooldown Activo? ─[no]→ Calcular Dosis
  → Registrar Riego (fn_registrar_riego) → Enviar Mensaje de riego
```

`fn_registrar_riego` escribe `comando_dispositivo` + `evento_riego` en una transacción. **Nunca fue auditado contra el plan.**

---

## 4 · Modelo de datos (Supabase, esquema `public`)

**Tablas principales:**

| Tabla | Para qué | Columnas que importan |
|---|---|---|
| `cultivo` | La planta | `id`, `active`, `dispositivo_id`, `especie_id`, `etapa_actual_id`, `fecha_inicio_etapa`, `ultima_foto_path`, `ultima_foto_evaluada_path`, `mantenimiento_hasta`, `volumen_maceta_litros` |
| `dispositivo` | El ESP32 | `mac_address`, `tiene_actuador_riego`, `caudal_bomba_ml_s` |
| `lectura_sensores` | Telemetría, **formato largo** | `metrica_id`, `valor`, `fecha_hora` — **una fila por métrica**, así que una lectura completa son 5 filas |
| `tipos_metricas` | Catálogo de métricas | id 1=Humedad, 3=pH, 4=Nitrógeno, 5=Fósforo, 6=Potasio |
| `especie_planta` / `tipo_etapa` / `etapas_especie` / `parametro_etapa` | **La base de conocimiento** | `etapas_especie` ordena las etapas por especie; `parametro_etapa` guarda los umbrales de cada una |
| `evento_riego` | Riegos | `resultado` (`pendiente`/…), `fecha_recheck`, `humedad_recheck`, `comando_id` → FK a `comando_dispositivo` |
| `comando_dispositivo` | Órdenes para el ESP32 | `tipo_comando`, `duracion_segundos`, `estado` |
| `seguimiento_fenologico` | Historia clínica (la escribe WF2) | `diagnostico_ia jsonb`, `path_foto` |
| `evaluacion_fenologica` | Evaluaciones de etapa (la escribe WF3) | `resultado`, `etapa_detectada`, `diagnostico jsonb` |

**Vistas:** `vista_cultivos_activos` (la que consumen WF1/WF3/WF4), `vista_conocimiento_experto` (umbrales por especie+etapa), `vista_promedios_recientes`, `vista_ultimo_riego`.

**Funciones RPC:** `fn_registrar_telemetria`, `fn_registrar_riego`, `fn_registrar_evaluacion_fenologica`.

> ⚠️ **`vista_conocimiento_experto` hace INNER JOIN contra `parametro_etapa`.** Una etapa sin umbrales no devuelve nulos: **no devuelve nada**. Es la raíz del hallazgo 16.37.

**Base de conocimiento cargada hoy:**

```
Tomate Cherry (especie 3)                     Albahaca (especie 4)
  Germinación  10d  80-95  6.0-7.0  10/10/10    Germinación   7d  — SIN UMBRALES —
  Plántula     15d  70-85  6.0-6.5  20/15/15    Plántula     12d  — SIN UMBRALES —
  Vegetativo   40d  60-75  6.0-6.8  50/30/30    Vegetativo   45d  60-80  6.0-7.0  40/20/20
  Floración    20d  50-65  6.2-6.8  30/50/60    (no tiene más etapas: terminal por diseño)
  Cosecha      30d  — SIN UMBRALES —
```

**3 etapas sin umbrales.** No existe "Fructificación" en el catálogo, así que el tomate salta de Floración a Cosecha (B.1).

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

11. **Cuidado con la coerción:** `Number(null) === 0` y `Number('') === 0`. Un sensor ausente convertido a 0 no es "falta el dato": es 0 % de humedad, o sea **sequía**, que dispara riego real. La ausencia se decide **antes** de convertir.

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

## 7 · Estado verificado el 17/09/2026

Consultado contra Supabase, no asumido.

| Dato | Valor |
|---|---|
| Cultivos activos | 1 — Tomate Cherry, **Floración desde el 12/08** |
| Días en etapa | **35** (la etapa dura 20) |
| `lectura_sensores` | 220 · **última del 20/08** |
| `evento_riego` | 8 — **las 8 en `pendiente`** |
| `comando_dispositivo` | 8 |
| `seguimiento_fenologico` | 24 |
| `evaluacion_fenologica` | **0** |
| `ultima_foto_evaluada_path` | `null` |
| Etapas sin umbrales | 3 |

**Workflows:** WF1 ✅ · WF2 ✅ · WF3 ✅ · WF4 ⬜ (a propósito) · WF5 ✅

### 🔴 Anomalía sin resolver — mirala primero

El cultivo lleva **35 días** en una Floración de 20. La ventana de evaluación de WF3 (80 % = 16 días) está abierta **desde el 28/08**. WF3 está activo y corre cada 8 h, así que debería haber evaluado decenas de veces.

**`evaluacion_fenologica` sigue en 0 y `ultima_foto_evaluada_path` sigue en `null`.**

Dato conocido: **la última ejecución de WF3 fue el 28/08**. Y el 31/08 n8n estuvo corriendo (se ejecutaron pruebas de WF1 esa noche), así que "la máquina estaba apagada" no explica el silencio del 31/08.

**Cómo resolverlo (2 minutos, se lo pedís a Agustín):**
- ¿WF3 figura como **Active** en n8n ahora mismo?
- La ejecución del 28/08: ¿verde o roja, a qué hora, y en qué nodo terminó?

**Interpretación:** la etapa empezó el 12/08 19:39 UTC, así que la ventana se abrió el **28/08 19:39 UTC**. Si esa corrida fue *antes* de esa hora, dio 15 días, se cortó limpio en `Hay cultivos a evaluar?` y estuvo bien. Lo que no se explica es el silencio posterior.

**Por qué importa más de lo que parece:** si WF3 figura Active y no dispara, es el peor tipo de falla para un producto — **el sistema dice que está funcionando y no está**. No hay aviso, no hay error, no hay ejecución roja. No hay nada.

---

## 8 · Hallazgos abiertos

Nomenclatura: `16.x` = hallazgo de auditoría · `B.x` = diferido a propósito. **Los números no se reasignan nunca.**

| # | Sev | Dónde | Qué | Estado |
|---|---|---|---|---|
| **16.39** | 🟠 | WF1 | Sensor desconectado + foto: la lectura se pierde entera y sin aviso | Confirmado en vivo 31/08. Fix escrito, sin aplicar |
| **16.33** | 🟠 | WF1·BD | Un dispositivo con dos cultivos activos pierde uno en silencio | SQL sin aplicar |
| **16.38** | 🟠 | BD | Nada impide que el hueco de umbrales vuelva | SQL sin aplicar |
| **16.31** | 🟠 | WF3 | `etapa_no_coincide` es estado absorbente y nadie se entera | Sin aplicar |
| **16.15** | 🟠 | WF3 | La degradación no deja señal operativa | Aplicado solo en WF2 |
| **B.14** | 🟠 | Infra | n8n corre con `:latest`, sin versión fijada | Fijarla es una línea |
| **B.7** | 🟠 | Producto | Fatiga de alertas: notifica por nivel, no por transición | Diferido |
| **16.37** | 🟡 | WF1 | Cultivo en etapa sin umbrales se reporta sano | Guarda aplicada, **inalcanzable** hasta cargar el dato de B.1 |
| **16.13** | 🟡 | BD | `anon`/`authenticated` con `ALL` sobre 18 tablas | SQL propuesto |
| **16.21** | 🟡 | WF3 | Re-análisis de la misma foto | Aplicado a medias |
| **B.1** | 🟡 | BD | Falta "Fructificación" en el catálogo | **Ligado a 16.37** |
| **B.13** | 🟠 | Infra | El volumen `n8n_storage` no está respaldado | **Precondición de todo lo que toque el contenedor** |
| **16.1 · 16.6 · B.9 · B.10** | 🟡 | varios | Secretos (Gemini), mínimo privilegio, `SECURITY DEFINER`, dedup de foto | — |
| **16.8 · 16.9 · 16.29 · 16.30 · B.2–B.6 · B.8 · B.11 · B.12** | 🟢 | varios | Cosméticos y diferidos | — |

**13.7.1 — el recheck de riego.** No tiene número de hallazgo porque es una fase sin implementar, pero **es lo más importante que queda**: el sistema ordena regar y nadie confirma que el riego ocurrió. Las 8 órdenes están en `pendiente` desde siempre, así que el circuit breaker de `falla_riego_persistente` **es código inalcanzable**. Es la última precondición antes de conectar una bomba real.

---

## 9 · Qué hacer, en orden

1. **Resolver la anomalía de WF3** (ver *Estado verificado*). Dos minutos y decide si hay un hallazgo nuevo.
2. **B.13 — respaldar el volumen `n8n_storage`.** Ahí viven los workflows, las credenciales y la clave que las descifra; no hay `N8N_ENCRYPTION_KEY` en el compose, así que n8n la generó sola y la guardó adentro. Si se pierde el volumen, las credenciales **no se recuperan ni con backup**. Precondición de cualquier cosa que toque el contenedor.
3. **B.14 — fijar la versión de n8n** en `docker-compose.yaml` (hoy `:latest`).
4. **B.1 + 16.37 juntos** — cargar `parametro_etapa` de Cosecha y agregar Fructificación. Es lo que **desbloquea poder probar 16.37**, hoy aplicado a ciegas.
5. **16.39** — fix de dos capas: cerrar el contrato en las ramas A y B del Motor (agregar `foto_base64` y `etapas_especie_id`), **y** que `Preparar Foto binaria` falle con un mensaje que nombre la causa real.
6. **13.7.1** — el recheck de riego.
7. **16.33 y 16.38** — índices únicos.
8. **Auditar WF5 y WF4**, los dos con estado desconocido.
9. **Rotar la clave del webhook** (`X-Device-Key`), que quedó expuesta en un chat.

---

## 10 · Cómo probar

**No hay ESP32.** Se simula con PowerShell desde la máquina de Agustín. Los webhooks tienen Header Auth (`X-Device-Key`); la clave está en la credencial de n8n, no en los JSON.

```powershell
# Telemetría normal (una línea — su terminal no acepta multilínea)
$body = @{dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry"; humedad=55.0; n=45; p=32; k=28} | ConvertTo-Json; Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body $body
```

Para incluir foto: agregar `foto_base64=(Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw).Trim()`.

**Umbrales vigentes (Tomate Cherry / Floración):** humedad 50–65 · pH 6.2–6.8 · N ideal 30 (tolerable 21–39) · P ideal 50 (35–65) · K ideal 60 (42–78). La tolerancia NPK es ±30 %.

**Reglas de testing no negociables:**

- **Antes de decir "ejecutá y mirá", confirmá que el workflow realmente llega a los nodos que se quieren probar.** Una vez casi se corrió un test que se cortaba en el primer IF y habría dado verde sin probar nada.
- **Diseñá los tests para que puedan fallar.** Si dos casos son indistinguibles, el test no detecta que se intercambiaron.
- **Verificá contra la base, no contra el verde del nodo.**
- **Los datos que crea un test son parte del test: limpiarlos es parte de haberlo terminado.** Hay dos scripts de referencia en `SQL/`.
- **Un fix aplicado antes del test convierte al test en una tautología.** Si la hipótesis es que algo falla, ejercela **antes** de arreglarla.
- **Los objetos de Storage no se borran por SQL.** `delete from storage.objects` borra la fila de metadatos y deja el archivo huérfano. Se borran desde el dashboard.

---

## 11 · Reglas de trabajo con Agustín

1. **Todo prolijo.** Es una tesis y un futuro producto.
2. **No toques tablas, columnas, políticas RLS ni datos** sin explicar antes qué y por qué, y esperar confirmación explícita.
3. **Verificá el estado real antes de asumir.** El documento y los JSON pueden estar desactualizados respecto de lo que corre en vivo. Ya hubo varios casos de drift.
4. **Verificá contra el estado persistido, no contra el output del nodo.**
5. **No tiene navegador en n8n.** Proponé el cambio exacto —nodo, campo, expresión, código completo para pegar— y él lo aplica y reporta.
6. **Al terminar algo, actualizá `implementation_plan.md`:** changelog, **Tablero**, **Hallazgos abiertos**, **Cierre de sesión**, y la sección numerada que corresponda. Lo diferido a propósito va al backlog. **Nada queda flotando en la conversación.**
7. **Antes de proponer una tabla, nodo o credencial nueva**, revisá si el backlog ya registra un intento anterior descartado por el mismo motivo.
8. **Decile cuando se equivoque.** Prefiere que discutas una decisión antes de implementarla.
9. **Explicá el razonamiento conceptual detrás de cada decisión**, nombrando el patrón o principio cuando exista. Es material para el marco teórico de la tesis.
10. **El proyecto está versionado con git** (local, sin remoto). Ritual de cierre: re-exportar los workflows tocados **sobrescribiendo `WORKFLOWS/WFn.json`** (nombre estable, nunca con fecha), actualizar el plan, y commitear. Si `git status` no queda limpio, hay algo sin documentar.

---

## 12 · Mapa del plan, si hace falta profundizar

`implementation_plan.md` (v48, 5.500 líneas). **Abrí solo la sección que necesites.**

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
| Riego automático y el recheck pendiente | `Fase 13`, y `13.7.1` para el hueco |
| La RPC transaccional de riego | `13.5.3` |
| La RPC transaccional de WF3 | `9.14` |
| Fertirriego (diseñado, sin implementar) | `Fase 15` |
| Trazabilidad de la base de conocimiento y bibliografía | `Fase 17` |

**Otros archivos del repo:** `SQL/` (esquema y scripts de prueba) · `test/` (fotos y escenarios de prueba) · `WORKFLOWS/` (los 5 JSON).
