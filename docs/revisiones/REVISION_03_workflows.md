# REVISIÓN 03 — Ingeniería sobre los cinco workflows

> **Fecha:** 18/09/2026 · **Base:** `CONTEXTO_AGENTE.md` (plan v48), los cinco `WORKFLOWS/WFn.json` (WF1 y WF4 exportados el 31/08 y 24/08; WF2, WF3 y WF5 el 24/08), y **lectura de solo consulta de Supabase**: definiciones de las cuatro vistas, cuerpo de `fn_registrar_evaluacion_fenologica` y `fn_registrar_riego`, tipos y nulabilidad de columnas, la fila del cultivo activo, `storage.objects`. Cada dato que salió de la base está marcado *(BD)*.
>
> **Lo que leí fuera de la lista de la misión, y por qué:** (a) los **encabezados** de `implementation_plan.md` y el cuerpo de 16.3, 16.4, 16.11, 16.41–16.45 y B.15–B.18 — obligatorio, porque la regla de numeración me exige no reusar números y el plan ya tenía más de los que la misión declara (ver §0). (b) `docker-compose.yaml`, 336 bytes: fija qué variables de entorno de n8n **no** están seteadas, y eso acota la anomalía. (c) `SQL/sesion10_limpieza_residuos.sql`: es la única evidencia escrita de qué había en `evaluacion_fenologica` el 31/08. No leí ninguna otra sección del plan.
>
> **Datos:** la base está congelada desde el 20/08 con histórico sintético. La usé para ver **estructura y punteros** (qué columnas existen, a qué foto apunta el cultivo, qué devuelve una RPC), no para derivar estadística. Donde una conclusión depende de un valor guardado, lo digo.
>
> **Severidad:** 🎨 *queda feo* · 📉 *pierde un dato* · 🌱 *daña el cultivo*. Cuando un hallazgo es 🌱 solo bajo hipótesis, va como 🌱ʰ.

---

## 0 · Antes de nada: la numeración está rota

La misión dice que los hallazgos llegan a 16.40 y los diferidos a B.14. **No es así en los artefactos:**

- `implementation_plan.md` (modificado 18/09 21:05 UTC) ya tiene **16.41 a 16.45** y **B.15 a B.18**, integrados desde `REVISION_01_cobertura.md`.
- `REVISION_02_medicion.md` (18/09 21:34 UTC, en el proyecto de Claude) usa **también 16.41 a 16.45 y B.15 a B.17**, para hallazgos **distintos**. Se escribió desde el mismo `CONTEXTO_AGENTE.md`, que dice "seguí desde 16.41", y no vio el plan.

Hay colisión: hoy "16.41" significa *Cosecha sin riego* (plan) y *riegos consecutivos sin tope* (REVISION_02) al mismo tiempo. Además, el 16.44 del plan y el 16.45 de REVISION_02 son el **mismo hallazgo** (silencio del dispositivo) con dos números.

**Qué hago acá:** tomo como fuente de verdad la numeración del plan, porque es el registro. Para no chocar con la renumeración que REVISION_02 va a necesitar (cinco hallazgos y tres diferidos), **dejo libres 16.46–16.50 y B.19–B.21** y numero los míos **desde 16.51 y B.22**. Si preferís otra asignación, los míos se renumeran sin pérdida porque no se citan entre sí por número, sino por título.

**Qué te pido:** al integrar, renumerar REVISION_02 a 16.46–16.50 / B.19–B.21, fusionar su 16.45 con el 16.44 del plan, y corregir el §8 de `CONTEXTO_AGENTE.md`, que es el origen del choque. Es un hallazgo de proceso, no de código, pero el proyecto tiene una regla explícita ("los números no se reasignan nunca") que ya se violó dos veces sin que nadie lo notara.

---

## 1 · La anomalía de WF3: qué puedo acotar sin ver las ejecuciones

### 1.1 Lo que sé con evidencia

| Hecho | Fuente |
|---|---|
| Etapa Floración desde `2026-08-12 19:39:05 UTC`, duración 20 d → ventana abierta desde **28/08 19:39 UTC**. Hoy: 36 días | *(BD)* `vista_cultivos_activos` |
| El cultivo apunta a `…/1787251621094.jpg` (foto del 20/08 18:47 UTC) y `ultima_foto_evaluada_path` es `null` | *(BD)* |
| **Ese objeto existe en Storage** (67 386 bytes, bucket `fotos-cultivos`) | *(BD)* `storage.objects` |
| Catálogo del tomate: Floración `orden 4` → Cosecha `orden 5`. Hay etapa siguiente. El nombre `tipo_etapa.nombre_etapa` es idéntico al `etapa_actual` de la vista ("Floración"), porque la vista lo saca de la misma tabla | *(BD)* |
| `evaluacion_fenologica` = 0 filas | *(BD)* |
| El 31/08 ~20:24 UTC corrió WF1 con foto; `sesion10_limpieza_residuos.sql` (31/08 20:29 UTC) **esperaba `evaluacion_fenologica = 0`** tras limpiar, y no borra de esa tabla | `SQL/sesion10_limpieza_residuos.sql` |
| `docker-compose.yaml` no fija `EXECUTIONS_DATA_PRUNE`, `EXECUTIONS_DATA_MAX_AGE`, `EXECUTIONS_DATA_SAVE_ON_SUCCESS` ni `GENERIC_TIMEZONE`. `restart: always` | `docker-compose.yaml` |
| El `Schedule Trigger` es "cada 8 horas por intervalo", no a horas fijas | `WF3.json` |

### 1.2 Lo que eso descarta

Recorrí el camino de WF3 con el estado real del cultivo, nodo por nodo:

1. `Obtener Cultivos Activos` → 1 fila (verificado).
2. `Obtener Orden Etapas` → 5 filas del tomate, ≪ 1000.
3. `Calcular Dias en Etapa` → `idxActual = 3`, `hayEtapaSiguiente = true`, `diasEnEtapa ≥ 16` desde el 28/08 19:39 UTC. **Emite el cultivo, no `skip`.**
4. `Validacion de foto` → path no vacío y ≠ `''`. **Pasa.**
5. `Descargar Foto` → el objeto existe. Si la credencial de Storage funciona, pasa.
6. `IA Vision Fenologica` → cualquier resultado (éxito, 503, JSON roto) **termina en `Registrar Evaluacion`**, porque `Parsear y decidir` convierte el fallo en `diagnostico_fallido` y la RPC inserta una fila igual (`v_marca_foto = false`, pero **inserta**; leído del cuerpo de la función *(BD)*).

Conclusión: **si WF3 corrió completo una sola vez después del 28/08 19:39 UTC, hay una fila.** No la hay. Entonces, o no corrió, o se cortó **antes de la RPC** por uno de exactamente dos caminos silenciosos, o corrió y falló en rojo.

Y el script del 31/08 fija una cota más: **el silencio ya estaba en curso el 31/08 a las 20:29 UTC**, con la ventana abierta hacía tres días (hasta 9 disparos posibles) y con la foto del 20/08 apuntada. No es algo que empezó después.

### 1.3 Las causas que quedan, ordenadas por lo que cuesta descartarlas

**H1 — n8n no estaba levantado cuando tocaba disparar.** El trigger de intervalo dispara solo si el proceso está vivo en ese instante; n8n **no recupera disparos perdidos** al arrancar. `restart: always` levanta el contenedor cuando arranca Docker, no cuando arranca Windows, salvo que Docker Desktop esté en autoinicio. Si la PC se usa por sesiones cortas, un intervalo de 8 h puede no caer nunca dentro de una sesión: la ventana del 31/08 que conocemos duró ~20 minutos, es decir ~4 % de probabilidad de contener un disparo. **Es la explicación más barata y no requiere ningún bug.** Es consistente con "última ejecución 28/08" si esa fue manual.

**H2 — WF3 figura Active pero el trigger no está registrado.** n8n activa los triggers al arrancar y al guardar un workflow activo; si la activación falla, el toggle queda en verde y aparece un aviso que se pierde al cerrar la pestaña. El JSON se re-exportó el 24/08 tras editar `Parsear y decidir` (16.25), o sea que hubo al menos un guardado en caliente. Con `:latest` (B.14), un arranque posterior pudo subir de versión y cambiar el comportamiento de activación. **Hipótesis; se distingue de H1 solo con las ejecuciones.**

**H3 — corrió y se cortó en silencio antes de la RPC.** Solo hay dos nodos donde eso es posible sin rojo: `Obtener Cultivos Activos` devolviendo cero ítems (no tiene `alwaysOutputData`; una credencial vencida o un cambio de RLS/GRANT —16.13— lo hace morir en verde), y `Foto Descargada` en `false`, cuya salida **no está conectada a nada**: una descarga fallida (credencial de Storage, `responseFormat: file` devolviendo un ítem de error) termina la corrida en verde y sin mensaje. Esto es 16.15 aplicado a WF3, que el plan reconoce como "aplicado solo en WF2".

**H4 — corrió y falló en rojo** (Gemini, `Obtener Orden Etapas`, la RPC). Como el compose no cambia `EXECUTIONS_DATA_SAVE_ON_ERROR`, los rojos se guardan y se verían. Contradice el dato "última ejecución 28/08", **salvo que ese dato sea viejo** (ver 1.4).

**Descartado:** que hubiera filas y alguien las borró. El script del 31/08 esperaba 0 y ningún script del repo borra de `evaluacion_fenologica`.

### 1.4 Una observación que distingue todas, y un dato que hay que revisar

**La observación:** en n8n, *Executions* filtrado por WF3, con tres columnas: **fecha, estado y modo (manual / trigger)**.

- Si **no hay ninguna ejecución con modo "trigger"** en toda la historia de WF3 → el planificador **nunca disparó**, ni una vez. H1 o H2; se separan mirando `docker ps` (columna STATUS, "Up X hours") en un momento en que debería haber disparado. Si el contenedor lleva más de 8 h arriba y no hay ejecución, es H2 y se cierra apagando y encendiendo el toggle de WF3.
- Si hay ejecuciones verdes después del 28/08 → H3. Abrir una y ver en qué nodo termina; los dos candidatos son los de arriba.
- Si hay rojas → H4, y el nodo rojo dice el resto.

**El dato a revisar:** ¿*cuándo* se observó que "la última ejecución es del 28/08"? Con los defaults de n8n (`EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=336` h = 14 días), una ejecución del 28/08 ya no se vería el 12/09. Si se vio el 17/09, o la poda está desactivada por otra vía, o la observación es anterior y la lista puede haber cambiado. No sé cuál; hay que mirarlo con fecha.

**Hipótesis mía sobre el 28/08:** que esa ejecución fue **manual**, parte de la sesión 9/10 (los archivos de esa sesión son del 31/08, pero WF1.json y el script se tocaron ese día; el 28/08 puede haber sido una prueba de WF3 con la ventana todavía cerrada, como sugiere el §7 del contexto). Si fue manual y antes de las 19:39 UTC, dio `skip` y estuvo bien, y el planificador **jamás** produjo una ejecución. Se verifica con la columna "modo".

### 1.5 Por qué esto es un hallazgo aunque la causa resulte trivial

Si es H1, el sistema no tiene bug y aun así **un producto que corre en la PC del cliente y depende de intervalos no puede tener el planificador ahí**. Si es H2, es el peor caso que describe el contexto. En los dos, el problema estructural es el mismo y lo abro como **16.62** en §5: **nada distingue "no tuve nada que evaluar" de "no corrí"**. El 16.44 del plan cubre el silencio del sensor; éste cubre el silencio del orquestador, que es anterior: un latido de dispositivo implementado en WF4 o en un WF6 programado hereda exactamente esta falla.

---

## 2 · WF5 — Control de Riego (nunca auditado)

Es el único workflow que hace algo irreversible. Lo leí contra `fn_registrar_riego` *(BD)* y contra el contrato que WF1 le manda (`Consolidar datos` → `JSON.stringify` del ítem entero).

Lo que está bien y no toco: la RPC es transaccional (13.5.3); `Registrar Riego` **no** reintenta (correcto por regla 6); `Calcular Dosis` aborta con excepción si faltan umbrales o si no hay déficit real ("fallar fuerte"); los IDs de cultivo y dispositivo son `uuid` y el body los manda entre comillas, así que el cast funciona; `vista_ultimo_riego` es `DISTINCT ON (cultivo_id) … ORDER BY fecha_inicio DESC` *(BD)*, o sea que `limit: 1` es redundante pero inofensivo; `fecha_inicio` es `timestamptz` *(BD)*, así que `new Date(...)` en `Verificar Cooldown` no tiene ambigüedad de zona (era una hipótesis mía y la base la refuta).

### 16.51 — 🌱 Cuando falta volumen o caudal, WF5 inventa el número, y el tope de 30 s hereda el invento

**Dónde.** `Calcular Dosis`: `const volumenLitros = cultivo.volumen_maceta_litros || 10;` y `const caudal = cultivo.caudal_bomba_ml_s || 50;`. Cuatro líneas más arriba, el mismo nodo **aborta** si faltan los umbrales de humedad ("preferimos no regar a regar a ciegas"). *(BD)* `cultivo.volumen_maceta_litros` y `dispositivo.caudal_bomba_ml_s` son `numeric NULL` sin default; `fn_registrar_riego` no valida nada: inserta lo que recibe.

**Qué pasa.** La dosis es `volumen × 1000 × 0,25 × déficit/100` ml y la duración es `dosis / caudal`, recortada a [3, 30] s. El tope de seguridad está en **segundos**, que es una unidad del actuador, no del agua: 30 s son 1,2 L con la bomba registrada hoy (40 ml/s) y 6 L con una de 200 ml/s. Con caudal nulo el código asume 50 ml/s; si la bomba real da 100, **cada pulso entrega el doble de lo que el sistema cree y registra**, y `evento_riego.dosis_ml` guarda el número inventado. Con volumen nulo asume 10 L: una plántula en 1 L recibe la dosis de una maceta diez veces mayor, recortada a 30 s, que a 50 ml/s son 1,5 L en una maceta de 1 L. Eso es 🌱 sin hipótesis sobre el futuro: es la aritmética del nodo. Hoy no ocurre porque el único cultivo tiene 20 L y 40 ml/s cargados *(BD)*; ocurre el día que se da de alta un segundo dispositivo sin completar la ficha, que es exactamente lo que hace un usuario que no sabe de tecnología.

**Por qué es un hallazgo y no una nota.** REVISION_02 lo señaló sin número. Lo numero porque la política es **inconsistente dentro del mismo nodo**: aborta ante un dato agronómico faltante y adivina ante un dato físico faltante, y el segundo es el que fija cuánta agua sale. El principio del proyecto ("validación positiva", "fallar fuerte cuando la alternativa es un dato incorrecto y creíble") ya está aplicado a media función.

**Alternativa que descarté:** dejar los defaults y agregar un tope en mililitros absoluto (por ejemplo 500 ml). Descartada porque un tope absoluto sin volumen conocido es igual de ciego —500 ml es poco para 20 L y mucho para 1 L— y porque tapa el síntoma: el problema no es el número, es que **el sistema decide sobre una maceta que no conoce**. La consecuencia de diseño (no el parche) es que volumen y caudal sean precondición de `tiene_actuador_riego`, del mismo modo que los umbrales son precondición del diagnóstico (16.38 es el mismo argumento para `parametro_etapa`).

**Cómo ejercerlo:** poner `caudal_bomba_ml_s = NULL` en el dispositivo de prueba y mandar una sequía; verificar en `evento_riego` que `dosis_ml` y `duracion_segundos` se calcularon con 50 ml/s. Limpiar después.

### 16.52 — 🌱ʰ El Motor decide sobre el valor crudo; la normalización que evita `'' → 0` vive un nodo más abajo

**Dónde.** `Motor de Inferencia` (WF1): `if (sensor.humedad !== undefined && sensor.humedad !== null) { if (sensor.humedad < reglas.humedad_min) { … haySequiaFlag = true` — compara `sensor.humedad` **tal como llegó**. La función `num()` que convierte `''`/`null`/no-numérico en `null` está en `Consolidar datos`, **aguas abajo** del Motor, y solo alimenta la RPC de telemetría. La regla 11 del contexto ("la ausencia se decide antes de convertir") está aplicada al registro y no a la decisión.

**Qué pasa, por semántica de JavaScript (esto no es hipótesis):** `'' < 50` es `true` porque `''` se convierte en `0`; `'' !== null && '' !== undefined` es `true`, así que la guarda no lo frena. Una humedad que llega como cadena vacía produce `hay_sequia = true`, `Dispara WF5` abre, y en `Calcular Dosis` `deficitPct = 57,5 − ''` es `57,5`: **la dosis de un déficit total**, hasta el tope. La telemetría se guarda con `p_humedad: null` (porque `num('')` sí lo detecta), así que la base dirá que no hubo lectura de humedad y `evento_riego` dirá que se regó por 0 %. Una fila que miente, con agua real detrás.

Segundo caso, mismo origen: la rama B detecta sensor desconectado con `v === 0` estricto. Cinco `"0"` **como strings** no la activan, y `"0" < 50` es `true` → sequía → riego. La rama que existe para no regar con un sensor desconectado se salta si el firmware serializa números como texto.

**Lo que es hipótesis:** que el productor pueda mandar `''` o strings. El ESP32 no existe; el contrato del webhook no está escrito; el simulador PowerShell manda números. Es una hipótesis sobre el **borde**, no sobre el runtime, y por eso lo pongo 🌱ʰ y no 🌱. Pero es la clase de cosa que el firmware va a hacer el primer día (`String(analogRead)`, un campo vacío cuando la sonda falla).

**Cómo ejercerlo:** dos POST al webhook de telemetría, uno con `"humedad": ""` y otro con las cinco métricas como `"0"`, y verificar **en `evento_riego`** (no en el verde del nodo) si aparecieron filas. Limpiar después. Si aparecen, el hallazgo sube a 🌱.

**Alternativa que descarté:** defender en WF5 (`Calcular Dosis` validando `typeof humedadActual === 'number'`). Descartada porque sería el quinto consumidor defendiéndose del mismo dato (el contexto cita 16.12, v23, Bug 4, 16.35 como las cuatro apariciones anteriores del patrón); la definición tiene que vivir donde entra el dato, antes del Motor. Sí anoto que hoy `Calcular Dosis` deja pasar `NaN` (`NaN <= 0` es `false`) y que el pedido falla **por accidente** más abajo, porque `NaN` en el body interpolado da JSON inválido. Un fallo fuerte por casualidad no es una defensa.

### 16.53 — 📉 WF5 no cuenta lo que no hace: cooldown, fallos y recortes terminan en silencio, y WF1 nunca se entera

**Dónde.** Tres lugares, un mismo defecto.

1. `Cooldown Activo` salida `true` **no está conectada a nada** (conexiones de `WF5.json`: solo `[out 1] → Calcular Dosis`). `minutos_restantes` se calcula y se tira.
2. El `Webhook` de WF5 no tiene `responseMode`, o sea que responde en cuanto recibe (default). `Trigger WF5` en WF1 tiene `onError: continueRegularOutput` y `retryOnFail: true`. Resultado: **WF1 recibe 200 antes de que WF5 haga nada**, y cualquier falla posterior —`Calcular Dosis` abortando por umbrales, la RPC rechazando, Telegram caído— queda como ejecución roja de WF5 y **verde de WF1**. El usuario recibe la alerta de sequía de WF1 y no recibe el mensaje de riego, y nadie le dice por qué.
3. `dosis_recortada` se calcula (`(dosisMl / caudal) > MAX_DURACION_RIEGO_SEG`) y **no llega ni al mensaje ni a la RPC**. Si la planta necesitaba 3 L y recibió 1,2 L, ni el operador ni la base lo saben; el recheck (13.7.1), cuando exista, lo vería como "riego insuficiente" sin poder distinguir "bomba rota" de "dosis recortada por diseño".

**Qué pasa.** El principio del contexto lo dice textual: *"un fallo manejado tiene que seguir siendo contado"*. Hoy el cooldown, que es la **única** protección contra riegos repetidos (REVISION_02), no deja rastro de cuántas veces frenó. Si un sensor clavado pide riego cada 10 minutos, la mitad de las órdenes se descartan en silencio y la otra mitad riega; el operador ve riegos cada 15 minutos y no ve las 30 solicitudes por hora que serían el síntoma del sensor.

Sobre el reintento en WF1: **es seguro por accidente**, no por diseño. Como el webhook responde al recibir, el reintento solo ocurre si el POST no llegó, y si llegó y se cortó la respuesta, el cooldown absorbe el duplicado. Pero esa garantía depende de que nadie cambie el `responseMode` a "cuando termine el workflow" —lo que cualquiera haría para que WF1 se entere de los fallos del punto 2— y en ese momento **el reintento de WF1 se convierte en un segundo riego real** (regla 6). Los dos arreglos naturales del punto 2 y del reintento son mutuamente excluyentes y hay que decidirlos juntos.

**Alternativa que descarté:** hacer que WF5 devuelva el resultado a WF1 y que WF1 notifique. Descartada porque introduce el acoplamiento que la regla 6 prohíbe (reintento sobre operación no idempotente) y porque el que sabe qué pasó es WF5. La señal tiene que salir de WF5, en las tres ramas, y **también** cuando decide no regar.

### 16.54 — 🌱ʰ Dos lecturas de sequía casi simultáneas pasan el cooldown las dos

**Dónde.** `Verificar Cooldown` lee `vista_ultimo_riego` y decide; `Registrar Riego` inserta varios cientos de milisegundos después (una llamada a Gemini no, pero sí un `Code` y un HTTP). Entre la lectura y la escritura no hay ninguna exclusión: la RPC `fn_registrar_riego` **no relee el último riego ni tiene restricción de unicidad por ventana** *(BD, cuerpo de la función)*. n8n ejecuta webhooks concurrentes.

**Qué pasa.** Dos POST de telemetría con sequía separados por menos de la latencia de WF5 (un dispositivo que reintenta porque no recibió respuesta, dos sensores del mismo cultivo, o simplemente el firmware mandando en ráfaga tras reconectar, que es lo que REVISION_02 §5 describe como comportamiento normal de un nodo de campo) → dos ejecuciones de WF5 leen "sin riego reciente" → dos comandos, dos pulsos. Es el mismo defecto que 16.33 (dos cultivos activos) trasladado al tiempo: la base no impide lo que el flujo asume.

**Hipótesis.** No sé si n8n serializa ejecuciones del mismo webhook en modo regular (creo que no; no lo verifiqué). Se ejerce mandando dos POST idénticos en paralelo desde PowerShell (`Start-Job` o dos ventanas) y contando `evento_riego`. Si da 2, es 🌱 y la consecuencia de diseño es que la exclusión viva en la base (la RPC leyendo el último riego dentro de la misma transacción, o una restricción), no en el nodo.

**Alternativa que descarté:** limitar concurrencia en n8n (`N8N_CONCURRENCY_PRODUCTION_LIMIT`). Descartada porque serializa **todo** —cada telemetría de cada cultivo esperaría a la anterior— y porque la garantía quedaría en una variable de entorno que B.13/B.14 ya muestran que no está bajo control.

### 16.55 — 🟠 (📉 hoy, 🌱ʰ con la clave expuesta) WF5 ejecuta lo que le mandan sin verificar nada contra la base

**Dónde.** `Calcular Dosis` toma `cultivo_id`, `dispositivo_id`, `umbrales`, `humedad`, `volumen`, `caudal` **del body del webhook** y la RPC los inserta. No consulta `vista_cultivos_activos`, no comprueba `tiene_actuador_riego` ni `active`, no comprueba que el dispositivo pertenezca al cultivo. La autenticación es la misma `Header Auth` de los otros webhooks; el contexto (§9, punto 9) dice que **esa clave quedó expuesta en un chat** y no se rotó. El compose publica `5678:5678`, que en Docker Desktop es alcanzable desde la LAN.

**Qué pasa.** Con la clave, un POST a `/webhook/control-riego` con `humedad: 0`, `umbrales.humedad {min: 50, max: 65}`, `volumen_maceta_litros: 100`, `caudal_bomba_ml_s: 1` produce un comando de riego de 30 s sobre cualquier `cultivo_id` de la base, repetible cada 15 minutos. No hace falta malicia: un PowerShell con el body equivocado (por ejemplo, el de telemetría) hace lo mismo con valores absurdos, y `deficit <= 0` es la única validación.

**Por qué no es solo "seguridad" (16.1/16.6).** Es también contrato: WF5 es un **actuador** que confía en que su único llamador es WF1 y que WF1 ya validó. Eso es cierto hoy y deja de serlo con el primer cliente que tenga dos dispositivos o con el primer script de prueba. La regla del contexto "verificar contra el estado persistido" vale también para decidir, no solo para comprobar.

**Alternativa que descarté:** quitar la autenticación y confiar en que es tráfico interno (`localhost`). Descartada: el puerto está publicado, y "interno" no es una propiedad del webhook sino de la red donde corre Docker, que el proyecto no controla en la PC de un cliente.

### 16.56 — 📉 `Registrar Riego` arma el body por interpolación de texto: la misma forma que 16.34 corrigió en WF1

**Dónde.** `jsonBody: "={ \"p_cultivo_id\": \"{{ $json.cultivo_id }}\", … \"p_humedad_inicial\": {{ $json.humedad }}, …"`. En WF1 (16.34) y WF3 (16.25) el mismo pedido se arma con `JSON.stringify` de un objeto.

**Qué pasa.** Un campo `undefined`, `NaN` o `''` deja `"p_humedad_inicial": ,` → JSON inválido → el nodo falla. Es el defecto de 16.34 con signo contrario: allí perdía la telemetría entera; acá **aborta el riego**, que es la dirección segura, y por eso lo dejo en 📉 y no más. Pero es seguro por accidente (ver 16.52), el mensaje de error no nombra la causa, y en el momento en que alguien lo "arregle" convirtiendo a objeto sin agregar la validación que 16.52 pide, el `NaN` pasa a la base como `null` y el riego se ordena con `humedad_inicial` nulo.

**Alternativa que descarté:** ninguna, es una inconsistencia de forma entre tres nodos que hacen lo mismo. La anoto porque el proyecto ya decidió cómo se arma un body de RPC y este nodo no lo sigue.

### Revisado en WF5 sin hallazgo

`TIEMPO_ABSORCION_MIN = 15` no tiene origen en ningún artefacto (REVISION_02 ya lo dice). El mensaje de Telegram promete *"Se re-chequeará la humedad en ~15 min"* y eso **no existe** (13.7.1): es 🎨 hoy, pero para un producto es una promesa escrita que el sistema no cumple; lo dejo como nota porque el hallazgo es 13.7.1, no el texto. `humedadObjetivo = (min+max)/2` está bien elegido como Y de histéresis (REVISION_02 §4). El `FACTOR_RETENCION_HIDRICA = 0,25` es una constante agronómica sin procedencia declarada (misma familia que Fase 17); no puedo juzgar su valor.

---

## 3 · WF4 — Análisis Preventivo de Rutina (apagado, nunca auditado)

Está apagado a propósito y **nada de esta sección daña hoy**. Lo audito porque el plan lo tiene como pendiente de reactivar (16.30, 16.45) y porque, cuando se reactive, va a ser el primer workflow programado que lee lecturas, o sea el candidato natural a heredar el latido de 16.44. Conviene que no arrastre esto. 16.3, 16.4 y 16.11 están cerrados y no los repito.

### 16.57 — 📉 WF4 pierde cardinalidad: con N cultivos manda N informes del primero

**Dónde.** `Obtener lecturas y conocimiento`: `const cultivo = $('Obtener Cultivos Activos').first().json; const promedios = $input.first().json;`. `Calcular Diagnostico`: `$('Conocimiento Experto').first()` y `$('Obtener lecturas y conocimiento').first()`. `Parsear Respuesta de Gemini`: tres `.first()` más. **No hay un solo `.item` ni `.all()` en WF4.**

**Qué pasa.** `Consultar Promedios` corre una vez por cultivo (regla 2), así que llegan N ítems; cada nodo Code toma **el primero** y devuelve un ítem; el siguiente nodo HTTP vuelve a correr N veces con el mismo dato. Salida: N mensajes de Telegram idénticos sobre el cultivo 1, y los cultivos 2…N **no se analizan nunca**, en verde. Es 16.16 (WF3, "procesaba un solo cultivo y descartaba el resto en silencio", resuelto el 17/08) sin portar. Con N=1 es invisible, que es la razón por la que el test del 04/08 pasó.

**Alternativa que descarté:** dejarlo para cuando haya más de un cultivo. Descartada porque es exactamente el caso que el proyecto ya aprendió ("N=1 no prueba un sistema que itera") y porque el fix de WF3 ya definió el patrón (`.all()` + emparejar por índice + guarda de desalineación): no es diseño nuevo, es aplicar una decisión tomada.

### 16.58 — 📉 `skip: true` no se rutea: sigue corriendo con `planta = undefined` y muere en verde dos nodos después

**Dónde.** `Obtener lecturas y conocimiento` devuelve `{ skip: true }` si no hay promedios. El siguiente nodo, `Conocimiento Experto`, consulta `planta=eq.undefined` → cero filas → el HTTP sin `alwaysOutputData` corta la rama. **No existe un IF sobre `skip`** (compará con `Hay cultivos a evaluar?` en WF3). Además, `!promedios.humedad_promedio` trata una humedad promedio de `0` como ausencia.

**Qué pasa.** Cada corrida de WF4 sin telemetría de las últimas 6 h termina verde, sin mensaje y sin fila. Es el silencio que el 16.44 del plan describe ("convierte 'no hay datos' en 'nada que hacer'"), pero la mecánica es peor de lo que ese hallazgo dice: no es que WF4 *decide* callarse; es que **se corta por un `undefined` en una query**. Y un cultivo en etapa sin umbrales (16.37) muere en el mismo nodo por la misma razón (INNER JOIN de la vista), sin la guarda que WF1 sí tiene.

**Alternativa que descarté:** agregarle `alwaysOutputData` a `Conocimiento Experto` como en WF1. Descartada porque es la lección 1 del contexto: convierte el corte en un `{}` que `Calcular Diagnostico` evaluaría contra `undefined` → `evaluarRango(x, undefined, undefined)` → `x >= undefined` es `false` → **todo 'seria'** con `desviacion_pct: NaN`, y saldría un informe alarmante sobre nada. La solución de forma es el IF explícito sobre `skip`, que ya está decidido en WF3.

### 16.59 — 📉 Si Gemini falla, WF4 informa "Tendencia: estable": el `catch` que avisaría es inalcanzable

**Dónde.** `Parsear Respuesta de Gemini`: `const rawText = geminiResponse.candidates?.[0]?.content?.parts?.[0]?.text || '{}'; … textoGemini = JSON.parse(cleaned);`. `Request a Gemini` tiene `onError: continueRegularOutput`, así que un 503 llega como `{ error: … }` sin `candidates`.

**Qué pasa.** Sin `candidates`, `rawText` es `'{}'`, que **parsea bien**. `textoGemini = {}`, el `catch` (que construye el mensaje "No se pudo generar el detalle (falla de IA)…") **no se ejecuta nunca por esa vía**; solo lo haría con un JSON roto. Después: `tendencia: textoGemini.tendencia || 'estable'` y `mensaje_agricultor: ''`. El Telegram sale con "📈 Tendencia: estable" y sin recomendaciones. Es 16.14 (WF2 guardaba el error como diagnóstico) en versión "lo manda por Telegram como diagnóstico": una fila que miente, sin fila. WF2 y WF3 ya tienen la validación positiva de forma (`if (!rawText)`); WF4 tiene un default que la anula.

Mismo nodo, mismo signo: si las cinco métricas dan `sin_dato` (ideal nulo, promedio nulo), `estado_optimo` es `true` y no se manda nada. "No sé nada" y "todo está bien" son indistinguibles.

**Alternativa que descarté:** confiar en `responseMimeType: application/json` para que la respuesta siempre sea JSON válido. Descartada porque el caso que importa no es un JSON malo sino la **ausencia** de respuesta, y el default `'{}'` está diseñado justamente para tragarse esa ausencia.

### 16.60 — 🎨 (con lente de producto, más) WF1 y WF4 no coinciden en qué es una desviación

**Dónde.** `Motor de Inferencia`: `NPK_TOLERANCIA = 0.30`, y para humedad/pH cualquier valor fuera de `[min, max]` es alerta. `Calcular Diagnostico` (16.11): NPK `|actual − ideal| / ideal`, corte `leve ≤ 10 % < seria`; humedad/pH: dentro del rango óptimo, fuera del rango `distancia / ancho`, corte 10 %.

**Qué pasa.** N = 36 con ideal 30 (Floración): WF1 dice **OK** (dentro de ±30 %), WF4 dice **desviación seria** (20 %). Humedad 48 con rango 50–65: WF1 dice **SEQUÍA** y riega; WF4 dice **leve** (13 % del ancho… no: 2/15 = 13 % → *seria*; con 49 sería 6,7 % → *leve*). El productor recibe, el mismo día, una alerta roja de un workflow y "leve" del otro, o "todo OK" de uno y "seria" del otro. 16.11 eligió el 10 % "por continuidad con el prompt original" sin reconciliarlo con el Motor. Es el principio "la definición vive en el productor" violado **entre workflows**: dos consumidores del mismo umbral con criterio propio.

**Por qué importa más que un 🎨.** Es una tesis: el marco teórico va a tener que explicar por qué hay dos motores de reglas con dos tolerancias sobre la misma base de conocimiento. Y para el producto, dos mensajes contradictorios en el mismo canal es la forma más rápida de perder la confianza en los dos.

**Alternativa que descarté:** que WF4 use la tolerancia del Motor y listo. Descartada como "solución" porque la pregunta real es si WF4 debe **re-evaluar** en absoluto o **consumir** el estado que WF1 ya calculó y persistió (que hoy no persiste: `estado` vive solo en el mensaje). Eso conecta con B.17 (capa de tendencia) y no se decide en este nodo.

### Revisado en WF4 sin hallazgo nuevo

`Hay recomendacion?` usa `notEquals true` con strict sobre un booleano real: bien. `desviaciones_leves.join('\n• ')` deja el primer ítem sin viñeta y el nombre del campo incluye las "serias": 🎨, no lo numero. WF4 **no persiste nada** (ningún nodo escribe en la base): no sé si es decisión de diseño o carencia; lo señalo como pregunta, no como hallazgo. 16.30 (modelo 2.5) y 16.45 (tendencia inventada) siguen como están.

---

## 4 · WF1, WF2 y WF3 — solo lo que no está cerrado

Auditoría reciente en WF1 y WF3; no repito 16.31, 16.33–16.39, 16.15, 16.21, B.10, B.11, ni el 16.42/16.43 del plan. Recorrí los tres nodo por nodo contra el estado persistido.

### 16.61 — 📉 En WF3, una etapa con `duracion_estimada_dias` nulo o una `etapa_actual_id` nula desactivan la evaluación en silencio y para siempre

**Dónde.** `Calcular Dias en Etapa`: `ventanaEvaluacion = cultivo.duracion_estimada_dias * 0.8` → con `null` es `0`, no `NaN` (`null * 0.8 === 0`), así que **la ventana se abre el día 0** y el cultivo se evalúa en cada corrida desde el primer día, gastando Gemini contra cada foto nueva; con `undefined` (columna ausente) sí es `NaN` y `>= NaN` es `false` → nunca. *(BD)* `etapas_especie.duracion_estimada_dias` es `integer NULL` sin default; `cultivo.etapa_actual_id` es `integer NULL`, y la vista hace `LEFT JOIN tipo_etapa`, así que `etapa_actual` puede llegar `null` → `findIndex` da `-1` → `continue` (B.2, que el plan tiene en 🟢 como "caso raro").

**Qué pasa.** Ninguno de los dos casos es raro en un alta manual: son dos columnas nulables sin default que el usuario puede dejar vacías. El primero produce llamadas a Gemini desde el día 0 (costo, y un avance prematuro si el modelo confirma algo); el segundo, un cultivo que WF3 no mira nunca, en verde. 16.38 pide restricciones para `parametro_etapa`; estas dos columnas están en la misma situación y no están en ese hallazgo.

**Alternativa que descarté:** tratarlo como parte de B.2. Descartada porque B.2 está calificado como 🟢 "caso raro" y la evidencia del esquema dice que no es raro: es el default.

### 16.62 — 📉 hoy, 🌱ʰ mañana: nada distingue "el planificador no tuvo nada que hacer" de "el planificador no corrió"

**Dónde.** WF3 y WF4 terminan en silencio por diseño en su caso normal (`skip`); no escriben ningún registro de "corrí a las X y evalué N cultivos". n8n no manda nada cuando un trigger deja de disparar. No hay ninguna pieza fuera de n8n que sepa cuándo debería haber corrido WF3. Evidencia: la anomalía de §1 lleva **21 días** sin que ningún componente la detectara; la detectó una persona mirando una tabla.

**Qué pasa.** Hoy cuesta una evaluación fenológica atrasada (📉). Cuando exista el latido del dispositivo (16.44 del plan) y el recheck de riego (13.7.1) —los dos programados por naturaleza— **heredan esta falla**: un latido que no late no avisa que no late. Es la precondición de los dos, y por eso es 🌱ʰ: no daña hoy, pero cualquier defensa programada que se construya encima nace con este agujero.

**Es distinto de B.13 y B.14** (respaldo y versión) porque esos son causas posibles del silencio; éste es la ausencia de detección, que sobrevive a que se arreglen las causas.

**Alternativa que descarté:** que el propio WF3 escriba un "último latido" en `cultivo`. Descartada porque el que no corre no escribe: la detección de ausencia tiene que vivir en el lado que sigue vivo (mismo argumento que el plan usa en 16.44 para el sensor). El lado que sigue vivo acá es Supabase, que no tiene `pg_cron` (REVISION_02 lo verificó), o un proceso fuera de la PC del cliente. Es decisión de arquitectura, la misma que decide dónde corre el orquestador de un producto vendido.

### Revisado en WF1 / WF2 / WF3 sin hallazgo nuevo

- **WF3 `Cambio de etapa?` lee `$json.avanzo`** de la respuesta de la RPC. Era mi hipótesis principal de bug (campo inexistente → IF siempre falso → nunca notifica). *(BD)* `fn_registrar_evaluacion_fenologica` devuelve `jsonb` con `avanzo` en los dos caminos. **Refutada.** La anoto porque ilustra la regla del proyecto: dos minutos de consulta contra la base valieron más que la deducción.
- **WF3, cola tras la RPC:** `Notificar` → `Generar URL Firmada` → `Mandar foto` corren después del `COMMIT`; si Telegram o el firmado fallan, la ejecución queda roja con la evaluación **ya persistida y correcta**. 🎨, y con la salvedad de que un rojo ahí puede leerse como "no avanzó" cuando sí avanzó. No lo numero.
- **WF3 `Parsear y decidir`:** si Gemini devuelve un JSON válido que no es objeto (un array, un número), `diagnosis.diagnostico_fallido = false` sobre un primitivo se ignora o lanza según el modo del sandbox; no lo sé y no lo ejercí. Marginal.
- **WF2 prompt:** `${$json.body?.humedad || $json.humedad}` con humedad `0` legítima imprime `undefined%` (el `||` trata 0 como ausencia). Le miente a Gemini en el caso extremo. 🎨.
- **WF1:** todo lo que vi está en 16.33–16.39 o en 16.52 de este documento. `Trigger a WF2` con `retryOnFail` es seguro porque WF2 no es idempotente **pero** su webhook también responde al recibir; misma dependencia frágil que describo en 16.53.

---

## 5 · Diferidos nuevos

### B.22 — 🟢 El contrato del webhook de telemetría no está escrito

No hay JSON Schema ni documento que diga qué tipos manda el dispositivo (número vs. string, `null` vs. ausente, unidades). 16.52 y el 16.42/16.43 de REVISION_02 (timestamp, temperatura) son tres consecuencias del mismo vacío. Se difiere porque depende del firmware, pero conviene escribirlo **antes** del firmware, no después: hoy el contrato de facto es "lo que el simulador PowerShell manda", y el Motor lo asume.

### B.23 — 🟢 Los tres webhooks comparten una credencial y un mismo puerto publicado

Anotación de 16.55 que no es de WF5: la rotación pendiente de la clave (§9.9 del contexto) no cambia que telemetría (lectura) y riego (actuación) autentiquen igual. Diferido hasta decidir dónde corre el orquestador en producto.

---

## 6 · Tabla de hallazgos de esta revisión

| # | Sev | Dónde | Qué | Estado |
|---|---|---|---|---|
| **16.51** | 🌱 | WF5 `Calcular Dosis` | Volumen y caudal faltantes se inventan (10 L, 50 ml/s); el tope de 30 s hereda el invento. Columnas nulables sin default | Observado en JSON + esquema |
| **16.52** | 🌱ʰ | WF1 `Motor` → WF5 | El Motor compara el valor crudo; `''` es sequía y riega el déficit total; `"0"` esquiva la rama B. `num()` vive aguas abajo | Semántica JS cierta; que el borde lo mande es hipótesis. Ejercer con dos POST |
| **16.53** | 📉 | WF5 topología · WF1 `Trigger WF5` | Cooldown, fallos y recorte terminan en silencio; WF1 recibe 200 antes de que pase nada | Observado |
| **16.54** | 🌱ʰ | WF5 `Verificar Cooldown` · RPC | Dos sequías casi simultáneas pasan el cooldown; la base no excluye | Hipótesis; ejercer con dos POST paralelos |
| **16.55** | 🟠 | WF5 `Webhook`/`Calcular Dosis` | Actúa sobre el body sin verificar contra la base; misma clave que telemetría, expuesta; puerto publicado | Observado |
| **16.56** | 📉 | WF5 `Registrar Riego` | Body por interpolación de texto (forma de 16.34); falla seguro por accidente | Observado |
| **16.57** | 📉 | WF4 todos los Code | Pierde cardinalidad: N informes del primer cultivo (16.16 sin portar) | Observado |
| **16.58** | 📉 | WF4 `Obtener lecturas…` → `Conocimiento Experto` | `skip` no se rutea; muere en verde con `planta=undefined`; etapa sin umbrales igual | Observado |
| **16.59** | 📉 | WF4 `Parsear Respuesta de Gemini` | Fallo de Gemini → "Tendencia: estable"; el `catch` es inalcanzable por `\|\| '{}'` | Observado |
| **16.60** | 🎨+ | WF1 vs WF4 | Dos tolerancias para el mismo umbral (±30 % vs 10 %): mensajes contradictorios | Observado |
| **16.61** | 📉 | WF3 `Calcular Dias en Etapa` · esquema | `duracion_estimada_dias` nulo abre la ventana el día 0; `etapa_actual_id` nulo apaga la evaluación. Nulables sin default | Observado en JSON + esquema |
| **16.62** | 📉 → 🌱ʰ | Arquitectura | Sin latido del planificador; 21 días de anomalía sin detección automática. Precondición de 16.44 y 13.7.1 | Observado (la anomalía es la evidencia) |
| **B.22** | 🟢 | Contrato | El contrato del webhook no está escrito | Diferido |
| **B.23** | 🟢 | Infra | Una credencial y un puerto para leer y para actuar | Diferido |

**Refutado por evidencia:** `Cambio de etapa?` sobre `avanzo` (la RPC lo devuelve); ambigüedad de zona horaria en el cooldown (`fecha_inicio` es `timestamptz`).

**Sobre la anomalía (§1):** acotada a cuatro causas, con la observación que las separa (modo de ejecución + `docker ps`), y con una cota nueva: el silencio ya existía el 31/08 con foto válida y ventana abierta. Se cierra con dos minutos de Agustín en la lista de ejecuciones; lo que no se cierra ahí es 16.62.

**Lo que no sé:** si n8n serializa ejecuciones de un mismo webhook (16.54); cuándo se hizo la observación "última ejecución 28/08" (§1.4); si WF4 debe persistir; de dónde salen 15 min y 0,25 (constantes sin procedencia). No completé ninguno de los cuatro.

**Orden sugerido, para cuando toque priorizar** (no es un plan, es una lectura de severidad): 16.51 y 16.52 antes de conectar cualquier bomba, junto con 13.7.1 y el "sin tope" de REVISION_02; 16.53 y 16.54 en la misma sesión que 16.51, porque tocan el mismo nodo; §0 (numeración) antes de la próxima sesión de plan, porque cada sesión que pasa lo empeora.
