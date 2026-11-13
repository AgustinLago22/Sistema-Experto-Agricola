# Sistema Experto Agrícola — Paquete de contexto para un agente

> **Regenerado el 20/10/2026** (plan v62, cierre de la sesión 17). **Actualizado el 26/10 con las sesiones 18 y 19, el 29/10 con el cierre de la 20, el 03/11 con su commit y la sesión 21, el 10/11 con la sesión 22 (16.63, la entrega de órdenes), el 11/11 con la sesión 23 (16.33) y el 12/11 con el backlog en GitHub y el diseño de WF6: ver los bloques ▶ de abajo, antes del §0.** El plan (`implementation_plan.md`, **v74**) ya las registra. Estado verificado contra Supabase y contra los JSON exportados, no contra lo que afirma la documentación.
>
> Este archivo existe para que un agente pueda trabajar **sin leer `docs/implementation_plan.md`**, que tiene ~6.600 líneas y ~740 KB. Acá está comprimido lo que hace falta para operar; el plan queda como referencia para profundizar en un punto concreto (mapa al final de este archivo).
>
> **Este archivo es una foto, y envejece.** Fue escrito después de una ronda de cuatro revisiones externas que corrieron en paralelo leyendo la versión anterior. Tres de ellas numeraron hallazgos nuevos usando el "último número" que este archivo declaraba, y chocaron entre sí. La lección quedó registrada como regla, abajo: **no asignes números de hallazgo.**

---

## ▶ Sesión 23, continuación (12/11): backlog en GitHub, alcance según la propuesta y diseño de WF6

**Backlog público** (plan v73): Project número 2 de `AgustinLago22`, "Sistema Experto Agrícola · Backlog", enlazado al repo, con 32 issues (#1 a #32, etiqueta `backlog`) y el campo **Status** de GitHub pasado a castellano (Hecho 14, En curso 1, Por hacer 14, Fuera de alcance 3; las opciones se renombraron conservando su id, así la automatización sigue: agregado → Por hacer, cerrado → Hecho; un cierre como "no planeado" también cae en Hecho y se pasa a mano a Fuera de alcance). Verificado con `gh`. **Al cerrar una pieza, cerrar su issue** (o `closes #N` en el commit). Agustín corre lo que escribe en GitHub; el agente lee y verifica. Ojo: PowerShell 5.1 rompe las comillas dobles dentro de un argumento para `gh`, y una función llamada `Gh` tapa a `gh.exe` (no distingue mayúsculas).

**Lo que dice la propuesta (Anexo II).** Fuera de alcance: la placa física y su firmware, el riego físico (sin bomba ni electroválvula), entrenar modelos propios, la validación agronómica experimental, el fertirriego, una interfaz web o móvil y el multiusuario. Promete: comandos de inspección por Telegram (WF6), análisis proactivo y un orquestador "accesible para su evaluación". **El servidor es una decisión abierta de Agustín:** no quiere pagarlo sin placa; se decide cerca de la defensa. Para desarrollar WF6 alcanza con un túnel gratis.

**Orden:** WF6 primero (confirmado por Agustín); después, propuesto: análisis proactivo (16.43) → Fase 17 corta → informe → servidor.

**WF6 diseñado (v74, plan 13.13), sin construir.** Comandos v1: `/estado`, `/diagnostico` (reusa WF2, uno cada 10 min), `/pausar [3h|30m]` (tope 24 h) y `/reanudar` (WF1 ya respeta `mantenimiento_hasta`), `/ayuda`. Solo el chat del autor; más de 10 min de viejo no se ejecuta; como mucho una vez. Entrada por `getUpdates` cada 30 s; la lógica empieza en `Normalizar mensaje` (pasar a webhook cambia solo la entrada). Base aplicada el 13/11 (`SQL/sesion23_wf6_estado_y_pausa.sql`, TEST OK 11 de 11): `vista_estado_cultivo`, una fila por cultivo activo con todo lo de `/estado`, y `fn_pausar_cultivo(cultivo, minutos)`, de 1 a 1440 pausa y 0 reanuda. La función devuelve siempre una fila `(valido, mantenimiento_hasta, estaba_en_pausa, errores)`. Las dos solo para `service_role`. Sigue el JSON de WF6. **Token del bot (13.13.6), opción A de Agustín:** la credencial de Telegram de n8n no sirve para `getUpdates` desde un nodo HTTP, así que el token vive en `.env`, compose lo pasa al contenedor (`TELEGRAM_BOT_TOKEN`, con `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`) y el nodo lo lee con `{{ $env.TELEGRAM_BOT_TOKEN }}`. Probado con `getMe` desde un nodo. Nunca escribir el token en un nodo (el JSON va al repo público). La vista previa del editor dice `[access to env vars denied]` igual: es solo del navegador, ejecutando anda. Datos reales al 12/11: Fructificación día 49 de 40 estimados, última lectura 10/11 (humedad 55, rango 60 a 75), último riego 10/11 `fallo_sistema`, última foto 04/11.

**Ojo antes de commitear:** `SQL/sesion22_test_ordenes_en_vivo.sql` tiene en la copia local la `X-Device-Key` real en lugar de `LA_CLAVE`. No va a ningún commit: `git restore` de ese archivo.

---

## ▶ Sesión 23 — CERRADA (11/11): una placa, un solo cultivo activo (16.33 ✅)

**Decisión de alcance de Agustín (11/11): la tesis NO promete la placa física funcionando.** Se defiende con el simulador. Era la pregunta abierta de `REVISION_04_hoja_de_ruta.md`: el hardware no sube al carril que bloquea la tesis. **Orden que sigue:** las fuentes de los números (Fase 17) y después el informe.

**Base** (`SQL/sesion23_16.33_un_cultivo_activo_por_placa.sql`, aplicado por Agustín, verificado por MCP): `uq_cultivo_activo_por_dispositivo`, índice único parcial sobre `cultivo (dispositivo_id) where active`. El alta de un segundo cultivo activo en la misma placa falla en ese momento (antes, WF1 tomaba uno cualquiera con `limit: 1`). `where active` cubre justo lo que lee la vista (`active = true`) y la MAC ya era única: la vista devuelve a lo sumo una fila por placa. Ningún workflow ni función cambia `active` ni `dispositivo_id`: no cambia nada de lo que corre. Test que se deshace solo (6 casos): corrido antes y después del cambio, OK 6 de 6 después; probado antes en PGlite (falló antes, detectó tres índices mal hechos).

**Ciclo nuevo en la misma maceta, desde ahora:** primero `active = false` en el cultivo viejo, después el alta del nuevo. El resto sigue en B.16. **Visto al pasar, sin tocar:** `cultivo.active` admite vacío. **La base tiene una sola especie** (Tomate Cherry): la Albahaca se dio de baja el 01/10 (v54); las notas viejas del plan que dicen "no borrar Albahaca" son anteriores.

**Sin datos de prueba nuevos.** Los de la sesión 22 siguen ahí, y **el freno sigue puesto** (riego 30 en falla): para probar el paso 3 de la página en vivo, primero una lectura sana (`L 68`).

---

## ▶ Sesión 22 — CERRADA (09/11 → 10/11): la placa recibe sus órdenes (16.63 ✅)

**Qué se hizo.** La placa pide sus órdenes a **WF8** y avisa cómo terminó cada una, con la misma `X-Device-Key` de las lecturas. La Secret key no sale de n8n. **Decisiones de Agustín (09/11):** por n8n; cada orden se entrega **una sola vez** (se prefiere perder un riego a regar dos veces la misma orden); una orden **vence a los 10 minutos**. El informe (Anexo III) quedó en pausa, sin tocar.

**Base** (`SQL/sesion22_16.63_entrega_ordenes.sql`; FALLÓ 1 bien antes, OK 10 de 10 después): `fn_tomar_ordenes(p_mac, p_arranque_id)` valida MAC y arranque, y en un solo `UPDATE … WHERE estado = 'pendiente'` pasa a `entregado` y devuelve las órdenes de esa placa de menos de 10 minutos. `fn_acusar_orden(p_mac, p_arranque_id, p_comando_id, p_resultado)` solo pasa de `entregado` a `ejecutado` (con `ejecutado_en`) o `error`; el mismo acuse otra vez da `duplicado`; uno contradictorio, de una orden ajena o nunca entregada, se rechaza. Las dos sin `SECURITY DEFINER` y solo `service_role` (el `REVOKE` es explícito: Supabase da `EXECUTE` a `anon` y `authenticated` por defecto). **Ninguna tabla cambió:** el vencimiento se deriva de `creado_en` y una orden vencida queda en `pendiente`.

**En vivo (10/11, `SQL/sesion22_test_ordenes_en_vivo.sql`, arranque 22):** las 10 órdenes viejas no se entregaron; la 37 venció (pedida a los 45 min); la 38 llegó una vez, el segundo pedido volvió vacío, `E 38` → `aceptado`, otra vez → `duplicado`, `E 38 "error"` → `400`. **Las dos ramas del diagnóstico de 13.7.2, en vivo por primera vez:** riego 29 (orden sin entregar) → "Revisar primero la conexión de la placa"; riego 30 (orden ejecutada) → "¿hay agua en el tanque?, ¿la bomba funciona?…".

**Página del simulador:** paso 3 nuevo, "Recibir órdenes". **Probada contra un servidor de prueba local, no en vivo.**

**Contradicciones nuevas (filas h e i del plan):** B.9 ya estaba resuelto desde el 03/11 (`fn_registrar_telemetria` sin `SECURITY DEFINER`, solo `service_role`); B.23 decía que telemetría y riego comparten clave, pero WF5 usa `n8n interno`. Lo que sigue valiendo de B.23: **una sola clave para todas las placas**.

**Límites conocidos:** una placa que conozca la MAC y el arranque de otra puede pedir sus órdenes (B.23); la placa tiene que pedir más seguido que cada 10 min (B.19); el recheck cuenta los 15 min desde que se creó la orden.

**Datos de prueba, sin limpiar a propósito:** arranque 22, lecturas 26 a 30, riegos 29 y 30 (`fallo_sistema`), órdenes 37 (`pendiente`, vencida) y 38 (`ejecutado`); 29 a 36 son huecos de los tests. **El freno quedó puesto:** la próxima sequía no riega hasta que una lectura muestre humedad ≥ 60 (`L 68`).

**Lo que sigue:** a definir con Agustín. Detalle: changelog **v71** del plan y **13.6**.

---

## ▶ Sesión 21 — CERRADA (03/11 → 04/11), anotada en el plan (v67 a v70) y commiteada: el contrato, un paso por vez

**Paso 5 ✅ (16.48 cerrado, 03/11):** temperatura y conductividad **se guardan, no deciden**. `fn_registrar_telemetria` recibe `p_temperatura` y `p_conductividad` (`DEFAULT NULL`; script `SQL/sesion21_contrato_paso5_temp_cond.sql`, FALLÓ antes y OK 4 de 4 después). `Consolidar datos` (WF1) las toma de `$('Validar Contrato').first().json.lectura`: el Motor no las emite ni las lee. Export de WF1 comparado: idéntico. En vivo (17:21 de Argentina): lectura sana → 7 filas (520 a 526); con las dos en "sin dato" → 5 (527 a 531). **Decisión de Agustín:** siguen obligatorias con `null` permitido (un sensor que no las mide manda `null`). Detalle: changelog **v67** del plan.

**Corrección de estado:** la foto de la prueba de 16.39 **ya está evaluada**: WF3 corrió solo el 01/11 a las 01:01 de Argentina (evaluación 16, `no_avanza`, 0,95). Datos de prueba nuevos, sin limpiar a propósito: arranque 10, lecturas 520 a 531 (497 a 519 es el hueco que dejó el test).

**Hallazgo nuevo, SIN número (ejercido el 03/11): una falla de Storage se llevaba la lectura entera.** URL de `Subir Foto a Storage` rota a propósito + sequía 55 % con foto → la página recibió `200 "aceptada"`, la ejecución murió en ese nodo (*On Error* por defecto) y no quedó nada: ni lectura, ni Telegram, ni riego. Una placa real no la reintentaría. **El paso 4 lo arregla en parte** (la lectura ya se guarda antes de la foto); **el 04/11 se resolvió el resto** (ver abajo).

**Paso 4 ✅ (16.47 cerrado, 03/11):** cada lectura con su DNI y su hora. **Tabla nueva `lectura`** (una fila por lectura: `arranque_id`, `seq`, `ts_dispositivo` en segundos Unix tal como llega, `fecha_recepcion`, `motivo`; `unique (arranque_id, seq)`; FK `(arranque_id, dispositivo_id)` → `arranque_dispositivo`: el arranque tiene que ser de esa placa; RLS, solo `service_role`). `lectura_sensores.lectura_id` apunta a ella (las 359 filas viejas en `null`; una regla `NOT VALID` lo exige en las nuevas; una medición por métrica por lectura). `fn_registrar_telemetria` (13 parámetros) crea lectura + mediciones en una transacción y devuelve `lectura_id`; sin DNI corta; un DNI repetido corta con "Lectura duplicada" (23505 → la API responde 409). **Ya no es `SECURITY DEFINER` y solo la ejecuta `service_role`** (la credencial "Sup S" de n8n lo es). Script: `SQL/sesion21_contrato_paso4_dni_lectura.sql` (FALLÓ antes, OK 7 de 7 después). **WF1 con orden nuevo (JSON importado):** Motor → `Consolidar datos` (agrega el DNI y decide el nombre de la foto) → `fn_registrar_telemetria` → `Hay foto nueva?` (lee `tiene_foto` del Motor) → `Preparar Foto binaria` (lee de `Consolidar datos`) → Storage → `Actualizar Ultima Foto Cultivo` → `Registrar Recheck de Riego` → lo demás. Al pegar, n8n cambió los `id` internos de los nodos (no importa: se referencian por nombre). En vivo: lecturas 5 y 6 (arranque 15, `seq` 0 y 1) con 7 mediciones cada una; el reintento de `seq` 0 → WF1 en rojo en `fn_registrar_telemetria` con "Lectura duplicada… (lectura 5)", sin mediciones, foto, Telegram ni riego. Detalle: changelog **v68**.

**Limpiezas, desde el paso 4:** sin cascadas, a propósito. Orden: `lectura_sensores` → `lectura` → `arranque_dispositivo`. Los scripts de limpieza viejos (sesiones 16 y 17) no conocen `lectura`: revisarlos antes de usarlos.

**Storage caído ya no frena el resto ✅ (04/11):** `Subir Foto a Storage` tiene *On Error* "Continue (using error output)". `Resultado de la foto` (Code, nuevo) junta los tres caminos (sin foto / guardada / error) y devuelve `foto_guardada` (`null`/`true`/`false`), `aviso_foto` (siempre booleano), `foto_error` y `path_foto_guardada`; cuenta como guardada solo si `Actualizar Ultima Foto Cultivo` devolvió **esa** ruta. Sigue a `Registrar Recheck de Riego` y a `Foto no guardada?` → `Aviso Foto no Guardada` (Telegram aparte, para que avise también con una lectura sana). `Trigger a WF2` manda la ruta solo si se guardó (si no, `null`); la foto le llega igual en el pedido, así que la IA diagnostica. Export idéntico (29 nodos). En vivo: Storage roto → lectura 9 con alerta, aviso "FOTO NO GUARDADA" ("Bucket not found"), riego 27 y seguimiento de WF2 con `path_foto` en `null` (llega ~1 min después si responde el respaldo); Storage sano → lectura 10, foto guardada, ningún Telegram. **Queda fuera a propósito:** si falla `Preparar Foto binaria` (error de programa, 16.39) o `Actualizar Ultima Foto Cultivo` (la base), el workflow se sigue deteniendo. Detalle: changelog **v69**.

**Para probar Storage caído:** cambiar la URL de `Subir Foto a Storage` al bucket `fotos-cultivos-NOEXISTE`, publicar, probar, y reponer `fotos-cultivos`.

**Datos de prueba nuevos, sin limpiar a propósito:** arranques 10 y 15, lecturas 5, 6, 9 y 10, mediciones 520 a 531 y 545 en adelante, el riego 27 (comando 27) y el seguimiento sin foto del 04/11 (los huecos son de los tests: un intento rechazado por duplicado también gasta un número de `lectura`).

**Paso 3 ✅ (04/11):** primero guardar, después contestar. **Base** (`SQL/sesion21_contrato_paso3_respuestas.sql`; FALLÓ 6 de 10 antes, OK 10 de 10 después): `fn_registrar_telemetria` devuelve `lectura_id` y `duplicada` (un DNI repetido ya no es error, no guarda nada y devuelve la lectura existente; los otros errores siguen cortando); `fn_verificar_arranque` rechaza una placa sin cultivo activo (mira `vista_cultivos_activos`, igual que `Resolver Cultivo`). **WF1** (31 nodos, JSON importado, export idéntico): `fn_registrar_telemetria` → `Lectura Duplicada?` → `Responder Duplicada` (termina) o `Responder Aceptada` → `Hay foto nueva?`. **Orden de aplicación:** WF1 primero, porque el WF1 viejo con la función nueva volvería a avisar y a regar en un reintento. **En vivo:** arranque 21, `seq` 0, 1 y 2 (sana, sequía, sana con foto), cada una repetida: los reintentos terminan en `Responder Duplicada`, en verde; el de sequía sin Telegram ni riego, el de la foto sin subir otra. `L 68 999999` sigue dando 400. **La placa sin cultivo solo se probó en el test de la base**, no en vivo.

**Decisión de Agustín (04/11), la opción A:** una falla antes de guardar llega como **`200` vacío**, no como `500` (ver la regla 12 de la semántica de n8n). No se agregó una salida de error por nodo: en los nodos Supabase de n8n, un error sin descripción sale por la salida normal, y en `Obtener Ultimo Riego` eso se confundiría con "no hay riego anterior" y saltearía el freno. En cambio, el contrato ganó la **regla 7: la placa da una lectura por entregada solo si dice `aceptada` o `duplicada`** (con `400` tampoco reintenta). **Límite aceptado:** si algo falla después de `aceptada`, un reintento recibe `duplicada` y no se evalúa de nuevo. Detalle: changelog **v70**.

**Datos de prueba del paso 3, sin limpiar a propósito:** arranques 18 y 21 (16, 17, 19 y 20 son huecos de los tests), lecturas 13, 20, 22 y 24 (cada reintento gasta un número), mediciones 574 en adelante, riego 28 (comando 28), rechazo 10 y la foto `…/1793833455650.jpg`, sin evaluar: WF3 la evalúa en su próximo turno (1 pedido a Gemini).

**Lo que sigue:** a definir con Agustín.

---

## ▶ Sesión 20 — CERRADA (26/10 → 29/10), anotada en el plan (v65 y v66) y commiteada (`c1066d1`, 03/11)

**La simulación de defensa se expuso el 28/10:** 5 minutos (se redujo de 10 ese mismo día), **sin demo en vivo**. La página de la exposición es de claude.ai, privada y fuera del repo; Agustín la conserva por las dudas. **Descartados por él (29/10):** el guion de la demo (se borraron `docs/guion_demo.md` y `SQL/sesion18_demo.sql`) y el PDF de la simulación. No volver a proponerlos. La propuesta original de la tesis (`ANEXO II - Lago .docx`, con DNI, domicilio y teléfono de Agustín) y el logo de la facultad **quedaron fuera del repo**: él los sacó de `docs/` antes del commit (03/11).

**Lo hecho: 16.51 ✅, la dosis entregada ✅, 16.39 ✅ y el Telegram de WF1 más prolijo ✅**, verificados en vivo. Detalle: changelog **v65**, **16.51** y **16.39** del plan.

- **Base** (`SQL/sesion20_16.51_riego_disponible.sql`, aplicado): `caudal_bomba_ml_s > 0` y `volumen_maceta_litros > 0` si están cargados (vacío permitido), y `vista_cultivos_activos.riego_automatico_disponible` = bomba Y volumen > 0 Y caudal > 0, nunca `null`. La vista tiene 18 columnas.
- **WF1:** `Dispara WF5` = `hay_sequia` **y** no `falla_riego_persistente` **y** `riego_automatico_disponible` (ya no `tiene_actuador_riego`). El Motor valida que la columna llegue (si no, corta nombrando el script), la emite en las tres salidas, y con sequía + bomba + dato faltante agrega "⚠️ RIEGO AUTOMÁTICO NO DISPONIBLE".
- **WF5, `Calcular Dosis`:** sin volumen, sin caudal, con 0 o sin humedad, corta con error (antes: `|| 10`, `|| 50`, y con humedad `null` regaba 30 s). `dosis_ml` = **entregada** (pulso × caudal); la calculada viaja como `dosis_calculada_ml` y no se guarda.
- **WF1, 16.39 (27/10):** las dos guardas del Motor (A y B) pasan `foto_base64` y `etapas_especie_id`; `Preparar Foto binaria` corta con un error que nombra la causa si le llega `tiene_foto` sin foto. Ejercido antes (todo en 0 + foto: nada guardado). En vivo después: Telegram "LECTURA SOSPECHOSA", lecturas 482 a 486 en 0, foto subida, sin WF2 ni riego.
- **WF1, Telegram (27/10):** el Motor muestra el pH con un decimal como mínimo (`fmtPh`: "mínimo (6.0)"); `Alerta Telegram` muestra la hora de Argentina (Luxon, zona explícita: el contenedor está en UTC) y alinea las observaciones. En vivo (27/10, 18:24): pH 5.2 sin foto → "pH = 5.2 está por debajo del mínimo (6.0)", "pH: 5.2" y "🕐 27/10/2026 18:24 (hora de Argentina)", la misma hora que guardó la base; sin WF2 ni riego.
- **Exports:** WF1 y WF5 re-exportados el 27/10 y comparados contra el código entregado: idénticos. En WF5, Agustín apagó la firma de n8n en los dos Telegram (`appendAttribution: false`).
- **Datos:** el caudal de demo se repuso en **40**. Riegos de prueba 24 a 26 borrados (quedan los 8 de agosto). Sin limpiar, a propósito: lecturas 462 a 496 y el arranque 9. La foto de la prueba de 16.39 es la `ultima_foto_path`: WF3 la evalúa en su próximo turno (1 pedido a Gemini); al 29/10 **sigue sin evaluar**.
- **Corrección de estado (28/10):** el paso 5 del contrato **no está aplicado**. Temperatura y conductividad llegan y se validan en la puerta, pero no se guardan (16.48 abierto). "Se guardan, no deciden" es el diseño, no el estado.
- **Estado verificado al cierre (29/10):** `lectura_sensores` 347 (max id 496) · `evento_riego` 8 (max id 10, del 20/08) · `comando_dispositivo` 8 · `arranque_dispositivo` 6 a 9 · `lectura_rechazada` 7 a 9 · `evaluacion_fenologica` 11 a 15 · `seguimiento_fenologico` 29. Cultivo en Fructificación.

**Cómo se trabajó y conviene seguir (lo pidió Agustín: "que no se haga un snowball"):** cada paso se chequea antes de entregarlo (el código se corre en local con Node contra casos simulados, el nuevo contra el actual) y se verifica después en la base y **en el export, antes de probar**. Así se atrapó una condición pegada en el lugar equivocado en `Dispara WF5`. **Los `.txt` para un campo de expresión no llevan salto de línea al final** (n8n lo toma como parte del valor).

**Lo que sigue:** a definir con Agustín. Candidatos: la limpieza única de los datos de prueba, WF6, los pasos 3 a 5 del contrato y 16.33. **WF6 quedó para después.** Para cuando se haga: **WF6** (13.13), primero `/pausar` y `/reanudar`. Antes hay que decidir cómo llega Telegram a un n8n en `localhost` (túnel o consulta periódica a `getUpdates`) y agregar que solo acepte el chat 5593622386 (el diseño escrito no lo verifica). `/calibrar` se puede armar, pero no probar de punta a punta sin placa (16.63).

**Cuánto falta para terminar la tesis (estimación del 29/10, a ajustar con Agustín):** del cronograma del Anexo II (8 etapas), las 1 a 6 están hechas en lo sustancial (del contrato faltan los pasos 3 a 5). Faltan la **7** (despliegue en un servidor accesible y documentación técnica: hoy n8n corre en la laptop de Agustín) y la **8** (informe final y defensa), que es lo más grande; el plan y el changelog ya son buena parte del material. Al ritmo de las sesiones 11 a 20 (una cada ~5 días): **lo mínimo** (servidor + informe) entra en noviembre; **con todo el software** (pasos 3 a 5 del contrato, ~2 o 3 sesiones; WF6, ~2; la limpieza, media) llega a mediados de diciembre. **Falta que Agustín diga** el formato del informe que pide la facultad y la fecha de la defensa final.

---

## ▶ Sesión 19 — CERRADA y anotada en el plan

> 21/10 → 26/10/2026. Todo lo de abajo está **probado en vivo y verificado contra la base**, y los workflows tocados están re-exportados (WF2 y WF3, auditados contra lo probado). **Ya está en el plan:** changelog **v64**, Tablero, Hallazgos abiertos, Cierre de sesión y 16.64. **Commiteada y subida** (`1df9f10`, 26/10). La sesión 18 pasó al Historial de sesiones del plan.

**Guion de la demo: descartado (29/10).** La simulación se expuso sin demo y los borradores se borraron.

**Lo hecho, en orden:**

1. **Página del simulador, `test/simulador.html`** (la pidió Agustín; quiso que fuera linda). Se abre con doble clic; la clave se escribe al abrirla y vive solo en memoria. Encender placa, casos de lectura y de rechazo, foto (`test/foto_demo_base64.txt`), avisos antes de mandar, registro de lo enviado y recibido, y una **ficha del cultivo** con la planta dibujada por etapa y la ventana de WF3. **La ficha es una foto de la base del 21/10** (etapa, inicio y umbrales escritos en la página; los días se calculan en vivo): si WF3 cambia la etapa, hay que actualizar `CULTIVO` y `ETAPAS` en el script de la página. Verla en vivo pediría un webhook de solo lectura en n8n (no hecho). **CORS verificado:** el pedido previo da `204` y la respuesta real se lee. Una página publicada en claude.ai **no** puede hablar con `localhost`: la página es local.
2. **WF3 el 25/10 no corrió: Docker estaba apagado** (16.64, tercera vez). Ejecutado a mano el 26/10: evaluación 14, `no_avanza`, 0,98, primera corrida con `gemini-3.8-flash`. **Decisión de Agustín:** Docker a mano cuando trabaja; un VPS si pasa a producto. No proponer automatizar el arranque en la laptop.
3. **El `undefined%` del prompt de WF2, cerrado.** Ejercido antes (`Humedad del suelo: undefined%`), arreglado con `??` y la unidad dentro de la regla, verificado después (`sin dato`; el `0` se respeta).
4. **Respaldo de Gemini en WF2 y WF3** (modelo elegido por Agustín: `gemini-3.5-flash-lite`). El principal sale por la **salida de error** al nodo `IA Vision Gemini Respaldo` / `IA Vision Fenologica Respaldo`, que entrega a `Parsear …`. Tope de 60 s y 2 intentos en los cuatro nodos. Probado forzando un `404` en los dos workflows y con un **`503` real** (3 de 4 llamadas al 3.8 en WF2 fallaron el 26/10).
5. **Rangos de la etapa en el prompt de WF2** (lo planteó Agustín): bloque "RANGOS SANOS PARA ESTA ETAPA", desde el `umbrales` que el Motor ya mandaba.
6. **Rechazos verificados desde la página:** humedad 150, `""` y arranque 999999 → `400`, filas 7 a 9 de `lectura_rechazada`.

**Datos de prueba SIN limpiar, a propósito** (se limpia una sola vez, al final del desarrollo): `lectura_sensores` id > 289, `arranque_dispositivo` 6 a 8, `lectura_rechazada` 7 a 9, `seguimiento_fenologico` 27 a 29. Las evaluaciones 14 y 15 son reales (WF3 sobre la foto de demo). Las fotos de los tests están en Storage (se borran desde el dashboard, nunca por SQL). **Hay una foto sin evaluar** (la de N bajo): WF3 la evalúa en su próximo turno con n8n prendido, o a mano (1 pedido de Gemini).

**Heredado de la sesión 18, sigue valiendo:** una medición que decide, en `null`, avisa ("❓ SIN DATO DE …", estado "Lectura Incompleta" si no hay otro diagnóstico); **opción A** de Agustín: una lectura incompleta con foto dispara WF2 igual. El Telegram de WF1 dice "sin dato"; sus líneas tienen dos espacios adelante (cosmético, decisión de Agustín). 16.38 cerrado. La copia vieja de `implementation_plan.md` en la raíz ya se sacó (commit `1df9f10`). **El "posible secreto" en `test/test_escenarios.txt` está descartado: Agustín confirmó que no es la clave. No volver a plantearlo.**

**Lo que sigue** (Agustín trabaja con el **28/10** como límite; la simulación de defensa es el 27/10; confirmar el orden con él):

1. ~~Telegram de WF1 más prolijo~~ ✅ (27/10).
2. ~~El guion de la demo~~ descartado (29/10).
3. Después del 28/10: ~~16.51~~ ✅ (27/10); respaldo en WF4 al reactivarlo; los nombres de los modelos en un solo lugar; 16.64 con un VPS.

**Para copiar código a n8n:** dejalo también en un `.txt` del scratchpad y decíselo. Copiado desde la terminal, cada renglón le llega con 2 espacios adelante y las líneas largas cortadas.

---

## 0 · Cómo usar este documento

**Leé, en este orden:**

1. Este archivo, entero (~40 KB).
2. `WORKFLOWS/WF1.json` — es el corazón del sistema y donde está casi todo el trabajo abierto.
3. `WORKFLOWS/WF3.json` — el segundo en importancia. Prompt nuevo desde el 01/10 (16.42).
   `WF5.json` se re-exportó el 19/10 (lazo de riego, 13.7.2); `WF7.json` y `WF1.json` el 20/10 (contrato v1, Fase 18, y la sesión 18); `WF2.json` y `WF3.json` **al cierre de la sesión 19** (26/10: respaldo de Gemini y prompt de WF2).
4. WF2, WF4, WF5, WF7 y WF8 **solo si la tarea los toca.** WF4 está apagado a propósito.

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
| n8n | Orquestación. 7 workflows: WF1–WF5, WF7 y WF8 (**WF6 está reservado** para los comandos de Telegram, 13.13, y no existe) | Docker en la PC de Agustín, `localhost:5678`. **Versión fijada `2.19.5`** (B.14), volumen `tesis_n8n_storage` respaldado (B.13) |
| Supabase | Postgres + Storage (bucket `fotos-cultivos`) | Proyecto `xypqsthwquegftcnoqyi`, "Tesis Cultivos" |
| Google Gemini | Visión: diagnóstico de emergencia y validación de etapa | `gemini-3.8-flash` en WF2 y WF3 desde el 20/10 (WF4 quedó en `2.5`). Cupo gratis: 20 pedidos/día por modelo |
| Telegram | Canal de notificación | `chatId` 5593622386, repetido en 5 nodos |

**El ESP32 no está armado y nada depende de él.** La orquestación se construye primero, desacoplada a propósito: el sistema solo habla vía HTTP contra Supabase, nunca al revés.

**Idea central del dominio:** cada especie tiene etapas fenológicas ordenadas (Germinación → Plántula → Vegetativo → Floración → Cosecha), y cada etapa tiene sus propios umbrales de humedad, pH y NPK. El diagnóstico es *lectura contra umbral de la etapa actual*, no contra un valor fijo.

---

## 2 · Flujo, de punta a punta

```
ESP32 (o PowerShell)       Header Auth en los cuatro: X-Device-Key (credencial `ESP32 Telemetra Key`)
   │  al encender:   POST /webhook/arranque     ──► WF7 ──► la base le asigna un arranque_id
   │  sus órdenes:   POST /webhook/ordenes      ──► WF8 ──► las de < 10 min, una sola vez
   │  al terminar:   POST /webhook/orden-acuse  ──► WF8 ──► ejecutado / error
   │  cada lectura:  POST /webhook/telemetria (contrato v1)
   ▼
 WF1 ──► puerta: ¿cumple el contrato? ¿el arranque es suyo? ¿tiene cultivo? ──[no]──► 400 + fila en lectura_rechazada
   ▼
 guarda telemetría ──[ya estaba]──► 200 "duplicada" (termina)
   │ [nueva]
   ▼
 200 "aceptada" ──► ¿requiere alerta? ──┬──► Telegram
   │                                       ├──► WF2 (si hay foto)
   │                                       └──► WF5 (si hay sequía)
   │
   └─ si vino foto: la sube a Storage y actualiza cultivo.ultima_foto_path
      (si Storage falla, sigue igual y avisa por Telegram)

 WF3 (cada 8 h, solo)  ──► mira la última foto ──► Gemini ──► ¿avanzó de etapa?
 WF4 (apagado)         ──► análisis preventivo de rutina
```

---

## 3 · Los 7 workflows

### WF1 — `Orquestacion - Tesis` · 31 nodos · **activo**

Webhook `/telemetria`, con *Respond: Using 'Respond to Webhook' Node*. Es el único que mueve datos en cada lectura.

```
Webhook → Validar Contrato → Contrato Valido? ─[no]─────────────────────────────┐
                               └[sí]→ Verificar Arranque → Arranque Valido? ─[no]─┤
                                                            └[sí]→ Resolver Cultivo
                                          Responder Rechazo (400) ◄─────────────┘ → Registrar Rechazo
Resolver Cultivo → Conocimiento Experto → Obtener Ultimo Riego → Motor de Inferencia
   → Consolidar datos → fn_registrar_telemetria (la lectura con su DNI)
   → Lectura Duplicada? ─[sí]→ Responder Duplicada (200, termina)
                        └[no]→ Responder Aceptada (200)
   → Hay foto nueva?  ─[sí]→ Preparar Foto binaria → Subir Foto a Storage ─[ok]→ Actualizar Ultima Foto Cultivo ─┐
                      │                                                   └[error]───────────────────────────────┤
                      └[no]──────────────────────────────────────────────────────────────────────────────────────┤
   → Resultado de la foto ─┬→ Foto no guardada? ─[sí]→ Aviso Foto no Guardada (Telegram aparte)
                           └→ Registrar Recheck de Riego → Esta en mantenimiento ─[no]→ Requiere Alerta?
        → [3 ramas PARALELAS e INDEPENDIENTES]  Dispara WF 2 · Alerta Telegram · Dispara WF5

(Orden desde el 03/11, paso 4 del contrato: la lectura se registra ANTES de la foto. Desde el 04/11 una falla de Storage no frena el resto: avisa. Desde el 04/11, paso 3: se responde DESPUÉS de guardar.)
```

**La puerta (contrato v1, paso 2, desde el 20/10).** `Validar Contrato` revisa el cuerpo contra `docs/contrato_telemetria.md`: campos presentes, las 7 mediciones como número dentro del rango **físico** o `null`, `v` = 1, MAC con formato. Arma `lectura`, el **único** objeto que leen los nodos de abajo (la MAC va en mayúsculas). `Verificar Arranque` (`fn_verificar_arranque`, siempre devuelve una fila, con reintento) comprueba que el `arranque_id` se le dio a esa placa. Si algo falla: `400` con la lista de errores y una fila en `lectura_rechazada` (el cuerpo sin la foto). Desde el 04/11 (paso 3) rechaza también una placa sin cultivo activo. Si pasa, sigue; `Responder Aceptada` contesta **después de guardar** y el flujo continúa (el nodo Respond deja pasar los ítems). `Resolver Cultivo` toma la MAC de `$('Validar Contrato').first().json.lectura`, porque su entrada no trae el `body`. **El formato viejo (`planta`, sin `v`) se rechaza.**

**`Motor de Inferencia`** (Code, ~350 líneas) es el cerebro. Lee `$('Validar Contrato').first().json.lectura`, nunca el cuerpo crudo del Webhook (eso cerró 16.52). Devuelve **tres ramas** con contrato de salida uniforme (~36 campos):

| Rama | Cuándo | `estado` |
|---|---|---|
| **A · Sin Umbrales** | la etapa no tiene fila en `parametro_etapa` | `Sin Umbrales - Configuracion Incompleta` |
| **B · Lectura Sospechosa** | los 5 que deciden llegan en 0, **o** los 5 en `null` | `Lectura Sospechosa - Revisar Sensor` / `Lectura Sin Datos - Revisar Sensor` |
| **C · normal** | el resto | `OK` / `Sequía` / `Exceso Hídrico` / `Estrés Químico` / `Sequía + Estrés Químico` / `Falla de Riego - Revisar Sistema` / `Lectura Incompleta - Revisar Sensor` |

**Desde el 27/10 (16.39 ✅), las ramas A y B también emiten `foto_base64` y `etapas_especie_id`.** Antes no los emitían, y una lectura con foto que caía en una guarda se perdía entera en `Subir Foto a Storage`. `Preparar Foto binaria` ahora corta con nombre si le llega `tiene_foto` sin foto.

Los IF rutean sobre **booleanos de dominio**, nunca sobre el string `estado`:
`requiere_alerta` · `hay_sequia` · `hay_estres_quimico` · `hay_exceso_hidrico` · `lectura_sospechosa` · `en_mantenimiento` · `falla_riego_persistente` · `tiene_foto` · `tiene_actuador_riego` · `medicion_faltante` (sesión 18; con `mediciones_faltantes`, la lista)

**Medición faltante (sesión 18).** En la rama C, si alguna de las 5 que deciden llega en `null`, el Motor lo dice: una observación "❓ SIN DATO DE …" por cada una, `medicion_faltante = true` (entra en `requiere_alerta`), y `estado` = `Lectura Incompleta - Revisar Sensor` **solo si** no había otro diagnóstico. "OK" quiere decir "evalué todo y está bien", no "no encontré nada malo". El `Alerta Telegram` muestra "sin dato" en vez de la unidad sola.

`Dispara WF5` exige las tres: `hay_sequia = true` **y** `falla_riego_persistente = false` **y** `riego_automatico_disponible = true` (desde el 27/10, 16.51; antes era `tiene_actuador_riego`).

**El control del último riego ("recheck", 13.7.2, desde el 19/10).** Si el último riego está `pendiente`, ya pasó la absorción (15 min) y no venció el control (60 min), **la lectura actual es el control**. El Motor lo evalúa **en la misma lectura, antes de decidir**:
- `exitoso`: la humedad volvió a estar ≥ al mínimo.
- `insuficiente`: subió ≥ 3 puntos pero sigue baja. Puede volver a regar.
- `fallo_sistema`: no subió. Activa el freno (`falla_riego_persistente`).

El freno también lee el resultado guardado de lecturas anteriores, y se suelta **por evidencia**: cuando una lectura posterior a la falla muestra la maceta húmeda (`humedad_max_posterior`). El mensaje de falla distingue, según `comando_estado`, "la placa no tomó la orden" de "la tomó y la humedad no subió".

El Motor emite `recheck_riego` (null si la lectura no es un control) **en las tres ramas**. `Consolidar datos` arma `rpc_recheck`, y `Registrar Recheck de Riego` llama a `fn_registrar_recheck_riego` **en cada lectura**: con `p_evento_id` null no hace nada. Ese nodo tiene *Retry* encendido, porque la RPC es idempotente.

### WF2 — `Diagnostico IA Emergencia` · 8 nodos · **activo**

Webhook `/diagnostico-ia`. Lo dispara WF1 cuando hay alerta **y** foto.

```
Webhook → IA Vision Gemini ─[ok]──────────────────────────→ Parsear Respuesta IA → Diagnostico Valido? ─[sí]→ Persistir Diagnotico → Telegram
              └[error]→ IA Vision Gemini Respaldo ─────────↗                                            └[no]→ Diagnostico Fallido (Stop and Error)
```

**Respaldo (26/10):** `IA Vision Gemini` (`gemini-3.8-flash`) tiene *On Error → Continue (using error output)*; la salida de error va a `IA Vision Gemini Respaldo` (`gemini-3.5-flash-lite`, *On Error → Continue*), que lee los datos de `$('Webhook').first()` porque por la salida de error solo llega el error. Los dos: 2 intentos, 5 s, tope de 60 s. `Parsear Respuesta IA` no cambió: lee `$input` y `$('Webhook')`. **El prompt** dice "sin dato" para un `null` (con `??`, el `0` se respeta) y lleva los **rangos de la etapa** desde `body.umbrales`.

Escribe en `seguimiento_fenologico`. **El nodo se llama `Persistir Diagnotico`, sin la `s`** — `$('...')` resuelve por coincidencia literal, así que el typo es el nombre real.

### WF3 — `Validacion Fenologica` · 18 nodos · **activo** · Schedule cada 8 h

Decide si el cultivo avanzó de etapa, mirando una foto con Gemini.

```
Schedule (8h) → Obtener Cultivos Activos → Obtener Orden Etapas [executeOnce] → Calcular Dias en Etapa
  → Hay cultivos a evaluar? → Validacion de foto → Descargar Foto → Extract from File
  → Convertir a Base64 → Foto Descargada? → IA Vision Fenologica ─[ok]→ Parsear y decidir
                                              └[error]→ IA Vision Fenologica Respaldo ↗
  → Registrar Evaluacion (RPC transaccional) → Cambio de etapa? → Notificar Cambio de Etapa
  → Generar URL Firmada → Mandar foto
```

**Respaldo (26/10):** igual que en WF2 (`gemini-3.5-flash-lite`, tope de 60 s), pero el respaldo lee de `$('Foto Descargada').item` (`.item`, no `.first()`: hay un ítem por cultivo). **Limitación aceptada:** con 2 o más cultivos, si a uno le responde el principal y a otro el respaldo, `Parsear y decidir` corre dos veces con la mitad de los ítems y corta con "Desalineación" (seguro: no guarda nada y reintenta en el próximo turno). Con un solo cultivo no pasa. **Ejecutarlo a mano** (*Execute workflow*) es válido para probar: corre lo mismo que un turno programado.

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

`fn_registrar_riego` escribe `comando_dispositivo` + `evento_riego` en una transacción, y desde el 19/10 aplica el **tope duro** (16.46): no más de 4 riegos automáticos por cultivo en 6 h, con bloqueo por cultivo. Si se llega al tope, no crea nada y devuelve `registrado = false`; WF5 avisa por Telegram con los números que devuelve la base. `Verificar Cooldown` ya no tiene su propio `15`: lee `absorcion_completa` de la vista. Desde el 27/10 (16.51), `Calcular Dosis` corta con error si falta el volumen, el caudal o la humedad, y `dosis_ml` es la entregada (pulso × caudal). Abierto en WF5: **16.55** (ejecuta lo que le mandan sin verificar contra la base), 16.53, 16.54, 16.56, 16.62.

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

### WF8 — `WF8 - Entrega de Ordenes` · 14 nodos · **activo** (desde el 10/11)

Dos webhooks con la credencial de la placa. Diseño completo en el plan, **13.6**; contrato, sección 10.

```
Webhook Ordenes (/ordenes) → Validar Pedido → Pedido Valido? ─[no]→ Responder Pedido Rechazado (400)
   └[sí]→ Tomar Ordenes (fn_tomar_ordenes) → Ordenes Tomadas? ─[sí]→ Responder Ordenes (200 {"estado":"ok","ordenes":[...]})
                                                              └[no]→ Responder Pedido Rechazado (400)
Webhook Acuse (/orden-acuse) → Validar Acuse → Acuse Valido? ─[no]→ Responder Acuse Rechazado (400)
   └[sí]→ Registrar Acuse (fn_acusar_orden) → Acuse Registrado? ─[sí]→ Responder Acuse (200 aceptado/duplicado)
                                                                └[no]→ Responder Acuse Rechazado (400)
```

`Tomar Ordenes` y `Registrar Acuse` usan `Sup S`. Solo `Registrar Acuse` tiene reintento (repetir un acuse es seguro; repetir `Tomar Ordenes` no, porque cada orden se entrega una vez). La placa da el aviso por entregado solo con `aceptado` o `duplicado` (regla 11 del contrato).

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
| `comando_dispositivo` | Órdenes para el ESP32 | `tipo_comando`, `duracion_segundos`, `estado` (`pendiente` → `entregado` → `ejecutado` o `error`), `creado_en`, `entregado_en`, `ejecutado_en`. RLS sin políticas: solo `service_role`. Desde el 10/11 la leen `fn_tomar_ordenes` y `fn_acusar_orden` (WF8) |
| `seguimiento_fenologico` | Historia clínica (la escribe WF2) | `diagnostico_ia jsonb`, `path_foto` |
| `evaluacion_fenologica` | Evaluaciones de etapa (la escribe WF3) | `resultado`, `etapa_detectada`, `diagnostico jsonb` |

**Vistas:** `vista_cultivos_activos` (la que consumen WF1/WF3/WF4; desde el 27/10 trae `riego_automatico_disponible`, y la base exige caudal y volumen > 0 si están cargados), `vista_conocimiento_experto` (umbrales por especie+etapa), `vista_promedios_recientes`, `vista_ultimo_arranque` (firmware vigente por placa, `security_invoker`), `vista_ultimo_riego`. Esta última, desde el 19/10, trae además `evento_id`, `comando_estado`, `absorcion_completa` (≥ 15 min), `recheck_vencido` (> 60 min) y `humedad_max_posterior`. **Los dos tiempos se definen solo ahí**: los leen WF5 y el Motor.

**Tabla `lectura` (desde el 03/11, 16.47):** una fila por lectura, con su DNI `(arranque_id, seq)` único y sus horas; `lectura_sensores.lectura_id` apunta a ella.

**Funciones RPC:** `fn_registrar_telemetria` (desde el 03/11 crea la `lectura` con su DNI, guarda también temperatura y conductividad, métricas 2 y 7, devuelve `lectura_id` y es solo de `service_role`), `fn_registrar_riego` (con tope duro), `fn_registrar_recheck_riego` (solo cierra eventos `pendiente` del mismo cultivo), `fn_registrar_evaluacion_fenologica`, desde el 20/10 `fn_registrar_arranque`, `fn_verificar_arranque` y `fn_registrar_rechazo`, y desde el 10/11 `fn_tomar_ordenes` y `fn_acusar_orden` (todas solo para `service_role`, sin `SECURITY DEFINER`; las tablas nuevas con RLS y sin permisos para `anon`/`authenticated`).

> ⚠️ **`vista_conocimiento_experto` hace INNER JOIN contra `parametro_etapa`.** Una etapa sin umbrales no devuelve nulos: **no devuelve nada**. Es la raíz del hallazgo 16.37.

**Reglas del catálogo en la base (16.38, desde el 20/10).** La base rechaza al cargar: una etapa repetida en una especie, dos etapas con el mismo orden (único *deferrable initially immediate*: un corrimiento `orden = orden + 1` en un solo UPDATE pasa), dos filas de umbrales para una etapa, dos especies o dos tipos de etapa con el mismo nombre (`Conocimiento Experto` busca **por nombre**), ids, duración o umbrales vacíos, orden o duración ≤ 0, humedad fuera de 0–100 o con mín ≥ máx, pH fuera de 0–14 o con mín ≥ máx, y NPK ideal ≤ 0. **Lo único que no impide:** una etapa sin ninguna fila de umbrales (son dos tablas que se cargan en dos pasos). Eso lo cubre la guarda del Motor (16.37); el arreglo de fondo es juntar las dos tablas (relación 1 a 1), trabajo futuro. Script y test: `SQL/sesion18_16.38_restricciones_catalogo.sql`.

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

5. **`typeValidation: strict` en los IF es un detector, no un obstáculo.** Activar "convert types" o agregar `.toBoolean()` para silenciar un error casi siempre esconde una expresión que no está evaluando. **Ojo: `undefined` o `null` no son un error de tipo:** pasan sin aviso, y *is true* da falso (ejercido el 04/11).

6. **`retryOnFail` se habilita según la idempotencia de la operación, no según su importancia.** Reintentar un diagnóstico es seguro; reintentar un INSERT de riego crea un segundo riego real.

7. **`onError: continueRegularOutput` deja pasar el objeto de error como si fuera un dato.** Exige validación positiva aguas abajo.

8. **El `onError` por defecto es "detener workflow".** En un nodo del camino principal, eso convierte el fallo de una rama en un fallo total (16.39).

9. **Fan-out contra una API con límite de tasa requiere batching, no más reintentos:** el reintento compite contra las llamadas que causan la saturación.

10. **`undefined` en un campo binario no es un error de JavaScript.** El nodo Code reporta éxito habiendo producido basura.

11. **Cuidado con la coerción:** `Number(null) === 0` y `Number('') === 0`. Un sensor ausente convertido a 0 no es "falta el dato": es 0 % de humedad, o sea **sequía**, que dispara riego real. La ausencia se decide **antes** de convertir. Y en comparaciones, `"" < 60` es `true` (16.52, confirmado en vivo).

12. **`Respond to Webhook`:** con el Webhook en *Using 'Respond to Webhook' Node*, responde ese nodo, y **deja pasar los ítems**: el flujo sigue después de responder. Si el Webhook queda en *Immediately* con nodos Respond conectados, n8n corta con `500 "Unused Respond to Webhook node found in the workflow"` **antes de ejecutar ningún nodo**. Header Auth con clave incorrecta responde **403** (no 401). **Con el Webhook en ese modo, si la ejecución termina en error sin haber pasado por un nodo Respond, la respuesta es `200` con el cuerpo vacío, no `500`** (ejercido el 04/11: ejecución 422). El código de n8n 2.19.5 tiene una rama que manda `500`, pero antes cierra el pedido con una respuesta vacía. Por el código, lo mismo pasaría si la rama se corta con cero ítems (sin ejercer).

13. **Una salida de error no sirve igual en todos los nodos.** Con *Continue (using error output)*, los nodos Supabase devuelven `{error: error.description}`; si la descripción viene vacía, n8n no lo reconoce como error y lo manda por la salida **normal** (leído en el código de 2.19.5, sin ejercer). Antes de ponerle una salida de error a un nodo Supabase, preguntá qué haría el resto con ese ítem vacío.

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

## 7 · Estado verificado el 26/10/2026

Consultado contra Supabase, no asumido.

| Dato | Valor |
|---|---|
| Cultivos activos | 1 — Tomate Cherry - Demo Tesis, **Fructificación desde el 23/09 23:18 UTC** (avanzó por WF3) |
| Evaluación de etapa | **La ventana está abierta desde el 25/10, 23:18 UTC** (80 % de 40 días, ver 16.65). Evaluada el 26/10 dos veces (`no_avanza`). **Hay foto nueva sin evaluar** (la de N bajo, del 26/10): WF3 la evalúa en su próximo turno **si n8n está prendido** (16.64), o a mano |
| `lectura_sensores` | 312 (max id 461) · las de id > 289 son de los tests de las sesiones 18 y 19 (sin limpiar, a propósito) |
| `evento_riego` | 8. Son los de agosto, en `pendiente`, con el control vencido: no frenan nada. Los de los tests del 19 y 20/10 se limpiaron |
| `arranque_dispositivo` | **3** (ids 6, 7 y 8, de los tests). El próximo será el **9** (los contadores no vuelven atrás) |
| `lectura_rechazada` | 3 (ids 7 a 9, los rechazos de la página del 26/10) |
| `comando_dispositivo` | 8 el 26/10 — ninguno consumido. **Al 10/11: 12** (ids hasta 38), 11 en `pendiente` (las 10 viejas y la 37, vencidas) y la 38 `ejecutado`, entregada por WF8 |
| `evaluacion_fenologica` | **5** — 11 `etapa_no_coincide` (19/09), 12 `avanza` (23/09), 13 `no_avanza` (01/10, test), 14 `no_avanza` (26/10, 3.8), 15 `no_avanza` (26/10, por el respaldo lite) |
| `seguimiento_fenologico` | 29 (26 a 29 son de los tests de WF2) |
| Especies | **1** (la Albahaca se dio de baja el 01/10) |
| Etapas sin umbrales | **0** |
| Claves JWT heredadas de Supabase | **deshabilitadas** (16.40 cerrado) |
| n8n | `n8nio/n8n:2.19.5`, clave de cifrado en `.env` (fuera de git), respaldo en `D:\respaldos_n8n` con simulacro de restauración ✅ |
| Contrato de telemetría | **Vigente desde el 20/10.** Pasos 1 a 5 aplicados y verificados en vivo (el último, el 3, el 04/11) |

**Workflows:** WF1 ✅ (31 nodos, re-exportado 04/11) · WF2 ✅ (8 nodos, con respaldo) · WF3 ✅ (18 nodos, con respaldo, ejercido con `gemini-3.8-flash` el 26/10) — los dos re-exportados el 26/10 · WF4 ⬜ (a propósito) · WF5 ✅ (9 nodos, re-exportado 19/10) · WF7 ✅ (8 nodos, re-exportado 20/10)

**Gemini:** principal `gemini-3.8-flash`, respaldo `gemini-3.5-flash-lite`, en WF2 y WF3. **Cupo gratis: 20 pedidos por día por modelo** (el respaldo tiene el suyo). El 26/10, 3 de 4 llamadas al 3.8 en WF2 dieron `503` ("high demand"): la saturación es la condición normal, no la excepción. WF4 sigue en `gemini-2.5-flash`, sin respaldo.

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

**El registro tiene 64 hallazgos numerados (`16.1`–`16.65`, con `16.50` sin asignar a propósito), 6 hallazgos abiertos todavía sin número (más 3 sin número ya resueltos: la medición en `null` sin aviso y el `Humedad: %` del Telegram en la sesión 18, y el `undefined%` del prompt de WF2 en la 19), y 23 diferidos (`B.1`–`B.23`).** Nomenclatura: `16.x` = hallazgo de auditoría · `B.x` = diferido a propósito.

> [!IMPORTANT]
> **Numeración estable, y NO la asignes vos.** Los números no se reasignan nunca, ni siquiera los que quedan libres — un hueco es inocuo, reusar un número no lo es. **Si encontrás algo nuevo, describilo SIN número** y dejá que se le asigne al integrarlo al plan. Este archivo es una foto y puede estar desactualizado respecto del registro: el último número que ves acá no es necesariamente el último que existe. **El número lo da el registro, no el hallazgo.**

### Los 🔴, en el orden en que importan

| # | Dónde | Qué | Por qué es 🔴 |
|---|---|---|---|
| **16.37** | WF1 | Cultivo en etapa sin umbrales se reporta sano | Guarda aplicada, **nunca ejercida**, y ya **sin datos reales que la ejerzan** (la especie 4 se borró). **16.38 (20/10) no lo vuelve imposible:** la base no puede exigir que cada etapa tenga su fila de umbrales (dos tablas, dos pasos de carga). El fondo es juntar las dos tablas |

> ✅ **Cerrados:** **16.63** (10/11, sesión 22: la entrega por WF8, cada orden una vez, vence a los 10 min; el control del riego ya estaba desde el 19/10; verificado en vivo) · **16.47** (03/11, sesión 21: cada lectura con su DNI y su hora; estaba todavía en la tabla 🟠) · **16.39** (27/10, sesión 20: las guardas del Motor pasan la foto y `Preparar Foto binaria` corta con nombre; verificado en vivo) · **16.51** (27/10, sesión 20: precondición en la base, WF1 y WF5; verificado en vivo. Queda: el tope de 30 s hereda un caudal **mal medido**, lo resuelve `/calibrar`) · **16.38** (20/10, sesión 18: reglas del catálogo en la base, test 13 de 13) · **16.52** (20/10, la puerta del contrato, Fase 18; confirmado antes en vivo con T0) · **16.46** y **13.7.1** (19/10, lazo de riego, 13.7.2, verificado en vivo) · **B.1** y **16.41** (23/09, catálogo completo) · **16.40** (01/10, claves JWT heredadas deshabilitadas) · **16.42** (01/10, criterio visual desde el catálogo, test en vivo) · **B.13** y **B.14** (06/10, respaldo de n8n y versión fijada) · **B.22** (13/10, contrato de telemetría escrito).
>
> ✅ **Resuelto en la sesión 18, SIN número (20/10):** una medición que decide, en `null`, **se salteaba sin aviso** (con solo la humedad en `null` la lectura salía `OK` y no se regaba). Ejercido en vivo antes y después del arreglo (plan, changelog v63). Queda el costo aceptado: avisa en cada lectura mientras el sensor siga sin medir (B.7).
>
> ✅ **Resuelto en la sesión 19, SIN número (26/10):** el prompt de WF2 mandaba `undefined%` con un valor en `null` o en `0` (el `||` trata el 0 como falta). Ejercido antes y después; ahora `??` y "sin dato".
>
> 🟡 **SIN número (20/10, bajó de 🟠 el 26/10):** **un solo modelo de Gemini.** **Respaldo aplicado en WF2 y WF3** (`gemini-3.5-flash-lite`, salida de error, tope de 60 s). **Sigue abierto:** WF4 sin respaldo (apagado), y el nombre de cada modelo escrito en la URL de cada nodo (6 lugares): cuando Google da de baja un modelo, ese nodo pasa a `404` sin aviso. Falta tenerlos en un solo lugar (probar antes qué permite el n8n de Agustín) y revisar las fechas de baja. Para después del 28/10.
>
> 🟢 **SIN número (26/10):** en WF3, con 2 o más cultivos y respuestas mezcladas entre principal y respaldo, `Parsear y decidir` corta con "Desalineación". Seguro e inalcanzable con un cultivo; aceptado a sabiendas.
>
> 🟢 **SIN número (26/10):** el respaldo lite es menos preciso: con pH 5.2 dijo "elevar la acidez" (es al revés) e inventó un síntoma en las hojas que la foto no muestra.
>
> ✅ **SIN número (26/10), resuelto el 27/10:** el Telegram de WF1 mostraba "mínimo (6)" en vez de 6.0, y la hora en UTC ISO.
>
> ✅ **Resueltos en la sesión 20, SIN número (27/10):** `dosis_ml` era la dosis calculada y no la entregada (ahora pulso × caudal: humedad 40 → 1200 ml, antes registraba 1375), y `Calcular Dosis` regaba 30 s con la humedad en `null` (solo alcanzable llamando a WF5 directo; ahora corta).
>
> 🟢 **Hallazgo nuevo, SIN número:** el camino `duplicado` de `fn_registrar_evaluacion_fenologica` devuelve `foto_marcada: true` sin marcar la foto. Solo alcanzable si alguien limpia la marca a mano. **El fix se escribió y se descartó a propósito** (`SQL/sesion14_fix_rpc_duplicado_marca_foto.sql`, marcado DESCARTADO): agregaba código para defender una redundancia. La marca es un caché de "¿existe una evaluación no fallida para esta foto?"; la solución de fondo es **derivarla y quitar la columna**, no programada. **No lo vuelvas a proponer como fix incremental.**

### 🟠 — los que bloquean la venta

| # | Dónde | Qué |
|---|---|---|
| **16.55** | WF5 | Ejecuta lo que le mandan sin verificar contra la base. Compone con B.23 |
| **16.64** | Infra · Producto | **El orquestador apagado es monitoreo apagado.** n8n no recupera corridas perdidas, la pantalla sigue diciendo *Active*, y no hay señal. Es 16.44 un piso más arriba. **Pasó otra vez el 25/10.** Decisión de Agustín (26/10): Docker a mano; un VPS si pasa a producto |
| **16.44** | Todos | El silencio del dispositivo no existe como estado: 34 días sin lecturas y cero avisos |
| **16.43** | WF1 · WF2 | Una foto sin alerta de umbral no la analiza nadie |
| **16.61** | BD | Un `duracion_estimada_dias` o un `etapa_actual_id` nulo cambia la ventana de evaluación de WF3 sin avisar. (16.38, el catálogo, se cerró el 20/10; 16.33, dos cultivos activos por placa, el 11/11) |
| **16.31 · 16.15** | WF3 | `etapa_no_coincide` es estado absorbente · la degradación no deja señal operativa |
| **B.17** | Arquitectura | Falta la capa de tendencia: el sistema ve estados, no procesos. Los datos ya existen, falta quien los lea |
| **B.7** | Producto | Fatiga de alertas: notifica por nivel, no por transición |

### 🟡 · 🟢 — agrupados

- **WF4, no encenderlo:** `16.57` (pérdida de cardinalidad — es 16.16 otra vez), `16.58` (ruteo), `16.59` (el error del modelo guardado como dato — es 16.14 otra vez), `16.49`, `16.60`, `16.45` (el prompt le pide al modelo que invente la tendencia), `16.30` (quedó en `gemini-2.5-flash`).
- **WF5, endurecer:** `16.53`, `16.54`, `16.56` (ya no tapa a 16.52), `16.62`.
- **Seguridad y base:** `16.1` (secretos), `16.6` (mínimo privilegio), `16.13` (`anon`/`authenticated` con `ALL` sobre 18 tablas), ~~`B.9`~~ ✅ (resuelto el 03/11 en el paso 4 y anotado el 10/11), `B.23` (una sola clave para todas las placas; corregido el 10/11: WF5 usa `n8n interno`, así que con la clave de la placa no se ordena un riego).
- **Contrato y datos:** `B.22` ✅ (contrato escrito el 13/10; pasos 1 y 2 vigentes desde el 20/10), ~~`16.48`~~ ✅ (temperatura y conductividad: **se guardan, no deciden**, aplicado el 03/11), `B.19` (cadencia: el contrato no la fija, sale del piloto), `B.20` (trazabilidad: el DNI de la lectura la habilita), `B.21` (retención).
- **Observabilidad de la planta:** `16.65` (la ventana de evaluación es el 80 % de la duración: Fructificación deja **32 días ciegos**), `16.43` (una foto sin alerta no la mira nadie), `B.17` (falta la capa de tendencia). Los tres son lo mismo visto de costado: **el sistema solo observa cuando sospecha, y sospecha por un único criterio.**
- **Resto:** ~~`16.8`~~ ✅ (04/11, paso 3: una MAC desconocida y una placa sin cultivo activo se rechazan y se registran), `16.9`, `16.21`, `16.29`, `B.2`–`B.6`, `B.8`, `B.10`–`B.12`, `B.15`, `B.16`, `B.18`.

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

**El 28/10/2026 Agustín expuso la simulación de defensa de tesis** (5 minutos, sin demo en vivo). **(1) Lazo de riego: ✅ 19/10** (13.7.2). **(2) Contrato, pasos 1 y 2: ✅ 20/10** (Fase 18; cerró 16.52). **(3) Respaldo de Gemini en WF2 y WF3: ✅ 26/10** (sesión 19). **(4) Guion de demo: descartado (29/10).** **Después:** pasos 3 a 5 del contrato ✅ (03/11 y 04/11) la entrega de órdenes a la placa ✅ (10/11, 16.63) y un solo cultivo activo por placa ✅ (11/11, 16.33). **La tesis no promete la placa física (decisión del 11/11): sigue la Fase 17 (las fuentes de los números) y el informe.** **Queda:** los nombres de los modelos en un solo lugar, endurecer WF5 y WF4.

La lista de abajo es el orden general del proyecto, sin la fecha.

`docs/revisiones/REVISION_04_hoja_de_ruta.md` organiza lo que queda en **tres carriles** —lo que bloquea la tesis, lo que bloquea la venta, y la deuda tolerable— y define un **mínimo viable para un primer cliente**. Ese mínimo descansa en tres defensas independientes contra el mismo riesgo (regar de más): el control del riego (13.7.2 ✅), el tope duro por ventana (16.46 ✅) y **la válvula local de 30 segundos en el firmware**, la única que sigue funcionando si n8n, la red o Supabase se caen. Son capas separadas a propósito.

1. **Terminar el contrato** (`docs/contrato_telemetria.md`, sección 9): pasos 1 y 2 ✅ (20/10), pasos 5 y 4 ✅ (03/11, **16.48** y **16.47**), paso 3 ✅ (04/11, cierra **16.8**).
2. ~~**Entrega de órdenes a la placa** (16.63)~~ ✅ 10/11 (sesión 22, WF8). Queda una clave por placa (B.23).
3. ~~16.38~~ ✅ 20/10. Lo que queda del hueco de umbrales (etapa sin fila) se resuelve juntando las dos tablas: trabajo futuro.
4. **Endurecer WF5**: ~~16.51~~ ✅ (27/10), 16.55, 16.53, 16.56 (16.52 se cerró en la puerta de WF1).
5. **No encender WF4** hasta resolver 16.57, 16.58, 16.59, 16.49, 16.60 y 16.30.
6. **Pendientes chicos:** copia de la clave de n8n y del respaldo fuera de la laptop (los hace Agustín); verificar las referencias BBCH antes de citarlas (17.3).

> **La ventana de evaluación de WF3 está abierta desde el 25/10** (16.65). WF3 solo corre si n8n está levantado en un turno (cada 8 h): si no, la corrida no ocurre y no deja rastro (16.64, pasó el 25/10). Para la demo, ejecutarlo a mano.

---

## 10 · Cómo probar

**Desde el 26/10, la forma habitual es la página `test/simulador.html`** (doble clic; la clave se escribe al abrirla y no se guarda). Encender placa primero; los casos cargan todos los valores, así que "sin dato" se tilda **después** de elegir el caso. "Sin dato" manda `null` (válido); la humedad vacía manda `""` (se rechaza). "Arranque ajeno" manda `999999` solo en ese envío. Desde el 27/10 (16.39 ✅) ya no hay aviso ni segunda confirmación para foto + todo sin dato: ese camino funciona. Si la página dice "sin respuesta", n8n está apagado o cambió el CORS. **Para probar el respaldo de Gemini:** cambiar la URL del principal a un modelo inexistente (`gemini-3.8-flash-NOEXISTE`), publicar, probar, **y volver a ponerla**.

**Las funciones de PowerShell siguen sirviendo.** Se simula con PowerShell desde la máquina de Agustín, **con el formato del contrato v1** (desde el 20/10 el formato viejo, con `planta` y sin `v`, se rechaza con `400`). Los webhooks tienen Header Auth (`X-Device-Key`); la clave está en la credencial `ESP32 Telemetra Key`, no en los JSON. Un **403** es la clave mal puesta.

**Simulador** (en `SQL/sesion17_test_puerta_en_vivo.sql`). Se pega una vez por ventana, **una línea por vez** (su terminal no acepta multilínea):

```powershell
$K = "LA_CLAVE"; $U = "http://localhost:5678/webhook"; $MAC = "24:0A:C4:A1:B2:C3"
function Pedir($ruta, $obj){ try { Invoke-RestMethod -Uri "$U/$ruta" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = $K } -Body ($obj | ConvertTo-Json -Compress) } catch { "HTTP " + [int]$_.Exception.Response.StatusCode + " " + $_.ErrorDetails.Message } }
function A($fw = "sim"){ $r = Pedir "arranque" @{v=1; dispositivo_mac=$MAC; fw=$fw}; if ($r.arranque_id) { $global:a = $r.arranque_id; $global:s = 0 }; $r }
function L($h = 68.0, $arr = $global:a){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$arr; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=6.4; conductividad=1.2; n=25; p=40; k=60}; $global:s++; Pedir "telemetria" $b }
function N(){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$null; temperatura=$null; ph=$null; conductividad=$null; n=$null; p=$null; k=$null}; $global:s++; Pedir "telemetria" $b }
```

**Siempre `A` primero** (la placa "enciende" y guarda su arranque en `$a`), también después de cada limpieza, que borra los arranques. Después: `L 68` (sana), `L 55` (sequía), `L ""` o `L 150` (rechazo), `L 68 999999` (arranque ajeno), `N` (todo `null`). `Pedir` muestra los errores como `HTTP 400 {...}` en vez de cortar. **Agregadas en la sesión 18:** `M` (pH elegible, sin foto) y las dos líneas de la foto.

```powershell
function M($h = 68.0, $ph = 6.4){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=$ph; conductividad=1.2; n=25; p=40; k=60}; $global:s++; Pedir "telemetria" $b }
$FOTO = (Get-Content "D:\tesis\test\foto_demo_base64.txt" -Raw).Trim()
function F($h = 68.0, $ph = 6.4){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=$ph; conductividad=1.2; n=25; p=40; k=60; foto_base64=$FOTO}; $global:s++; Pedir "telemetria" $b }
```

`L $null` = solo la humedad en `null` → "Lectura Incompleta" con aviso, sin riego. `M $null 5.2` = humedad `null` + pH ácido → "Estrés Químico" + la observación de la humedad. `L 80` = exceso hídrico (avisa, no riega). `F 68` = sana con foto: sube la foto y actualiza `ultima_foto_path`, sin alerta y sin IA (así se prepara WF3). `F 68 5.2` = pH ácido con foto: alerta + WF2, sin riego. `$FOTO.Length` ≈ 89.800 (comprobarlo antes de usar `F`). *(Hasta el 27/10: no mandar `N` con foto, era el camino de 16.39. Ya está cerrado.)* **Cada `F` con alerta gasta hasta 2 pedidos del cupo diario de Gemini (20).** Después de cambiar un workflow en n8n, **publicarlo**: si no, sigue corriendo la versión vieja (pasó el 20/10).

**Umbrales vigentes (Tomate Cherry / Fructificación):** humedad 60–75 · pH 6.0–6.8 · N ideal 25 (tolerable 17,5–32,5) · P ideal 40 (28–52) · K ideal 60 (42–78). La tolerancia NPK es ±30 %. **Ojo: humedad 55 o 58 ahora es Sequía y dispara WF5.** Lectura sana de referencia: `humedad=68.0; ph=6.4; n=25; p=40; k=60`.

**La función `T` de la sesión 16 ya no sirve** (manda el formato viejo y vuelve `400`). En los guiones viejos, `T 55` se reemplaza por `L 55`. "Execute workflow" no hace falta: WF1 y WF7 activos escuchan en `/webhook/`.

**Probar el lazo de riego:** el guion está en `SQL/sesion16_test_lazo_riego_en_vivo.sql`, con tres escenarios (usa `T`: reemplazarla por `L`, con `A` antes). Para no esperar 15 min reales se usa el **ATRASAR**, que mueve el último riego 20 min hacia atrás. Reglas:
- Anotar los `max(id)` antes de empezar y limpiar por encima de ellos.
- Limpiar **entre escenarios**, porque el tope cuenta los riegos de las últimas 6 h.
- Desde 50, después de regar: subir de 53 a 59 es `insuficiente` (vuelve a regar); subir menos de 3 puntos es `fallo_sistema` (frena).

**Test de la base que se deshace solo:** `SQL/sesion16_lazo_riego.sql`, BLOQUE 3. Termina con un error a propósito, `TEST OK: …`, que revierte todo lo que escribió. Se comprobó que puede fallar: con tres defectos inyectados, los detectó los tres.

**Probar las órdenes (desde el 10/11):** dos funciones más, en `SQL/sesion22_test_ordenes_en_vivo.sql`:

```powershell
function O(){ $r = Pedir "ordenes" @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a}; $r | ConvertTo-Json -Depth 5 }
function E($id, $res = "ejecutado"){ Pedir "orden-acuse" @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; comando_id=$id; resultado=$res} }
```

`L 55` crea una orden (WF5) → `O` la trae (y la marca `entregado`) → `O` otra vez vuelve vacío → `E 38` avisa (`aceptado`; repetido, `duplicado`; `E 38 "error"` después, `400`). **Una orden vence a los 10 minutos de creada:** pedirla después vuelve vacío, y no es un error. Si el último riego quedó en `fallo_sistema`, mandar `L 68` antes de la sequía para levantar el freno. En la página, paso 3, "Recibir órdenes".

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
2. **No toques tablas, columnas, políticas RLS ni datos** sin explicar antes qué y por qué, y esperar confirmación explícita. **Forma de trabajo vigente:** los cambios de esquema o destructivos se escriben como script versionado en `SQL/` (con estado previo, reverso y bloque de verificación), **los ejecuta Agustín en el SQL Editor**, y el agente verifica por MCP en modo lectura. En las sesiones 14 y 18 el control de permisos bloqueó la ejecución directa: **no intentes correr DDL vos**, aunque Agustín lo pida cansado; pasale los bloques listos para pegar, en orden, y verificá después por MCP. Si el script tiene un test que se deshace solo, que lo corra **también antes** del cambio: tiene que fallar.
3. **Verificá el estado real antes de asumir.** El documento y los JSON pueden estar desactualizados respecto de lo que corre en vivo. Ya hubo varios casos de drift.
4. **Verificá contra el estado persistido, no contra el output del nodo.**
5. **No tiene navegador en n8n.** Proponé el cambio exacto —nodo, campo, expresión, código completo para pegar— y él lo aplica y reporta. El código va también en un `.txt` para copiarlo desde ahí. **Si son muchos cambios o es un workflow nuevo, pasale el JSON completo para importar** (chequeado antes, como todo). **Explicá cada nodo en una línea antes de que lo aplique; la explicación larga, solo si es algo nuevo** (le sirve para el informe y la defensa). Regla ajustada por Agustín el 03/11 para avanzar más rápido; las de git, base y verificación siguen igual.
6. **Al terminar algo, actualizá `docs/implementation_plan.md`:** changelog, **Tablero**, **Hallazgos abiertos**, **Cierre de sesión**, y la sección numerada que corresponda. Lo diferido a propósito va al backlog. **Nada queda flotando en la conversación.**
7. **Antes de proponer una tabla, nodo o credencial nueva**, revisá si el backlog ya registra un intento anterior descartado por el mismo motivo.
8. **Decile cuando se equivoque.** Prefiere que discutas una decisión antes de implementarla.
9. **Explicá el razonamiento conceptual detrás de cada decisión**, nombrando el patrón o principio cuando exista. Es material para el marco teórico de la tesis.
10. **El proyecto está versionado con git y publicado en GitHub** (`AgustinLago22/Sistema-Experto-Agricola`). **El repo es un entregable de la tesis**, porque muestra el historial: **los commits y los push los hace Agustín**, y **ningún commit lleva líneas de coautoría ni de sesión del agente** (`Co-Authored-By`, `Claude-Session`). El agente **no corre comandos de git que escriben** (`add`, `commit`): en el entorno viejo la carpeta montada no le dejaba borrar archivos y git dejaba `.git/index.lock` trabado. (En la sesión 18, en el entorno nuevo, el agente sí pudo borrar archivos con permiso de Agustín; la regla de git sigue igual.) Lo que hace el agente: leer con `git --no-optional-locks`, dejar el mensaje del commit en `.git/COMMIT_MSG_<tema>` y pasarle los comandos (`add`, `commit -F`, borrar el archivo del mensaje, `push`). Ritual de cierre: re-exportar los workflows tocados **sobrescribiendo `WORKFLOWS/WFn.json`** (nombre estable, nunca con fecha), actualizar el plan, commit y push. Si `git status` no queda limpio y al día con `origin/main`, hay algo sin documentar.
11. **No inventes números de hallazgo.** Describí lo que encontrás y dejá que el número se asigne al integrarlo al plan. Ver la advertencia de *Hallazgos abiertos*.
12. **Una cosa por vez, y la que él pidió.** Si una tarea viene de un plan escrito ("lo que sigue"), confirmá que sigue siendo la prioridad antes de producir un entregable grande. En la sesión 18 se escribió un guion de demo que él no quería todavía: prefiere desarrollar primero.
13. **No uses el símbolo de sección (§) cuando le hablás.** Nombrá la sección por su título ("la sección Cómo probar"). Este archivo lo usa en sus títulos; en el chat, no.
14. **Explicá con un ejemplo concreto de su propio sistema** (el tomate, la Fructificación, el 55 %) antes que con la teoría. En la sesión 18 la 16.38 no se entendió en abstracto y sí con "una segunda fila de umbrales para Fructificación".

---

## 12 · Mapa del plan, si hace falta profundizar

`docs/implementation_plan.md` (v74, ~6.900 líneas). **Abrí solo la sección que necesites.**

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
| Riego automático | `Fase 13`. El lazo (control, freno, rearme, tope) y su test en vivo están en **`13.7.2`**; `13.7.1` es el diseño viejo con sus tres defectos. **La entrega de órdenes (WF8) está en `13.6`** |
| La RPC transaccional de riego | `13.5.3` (el tope duro se le agregó en `13.7.2`) |
| La RPC transaccional de WF3 | `9.14` |
| Fertirriego (diseñado, sin implementar) | `Fase 15` |
| Trazabilidad de la base de conocimiento y bibliografía (incluye BBCH de los criterios visuales) | `Fase 17` |
| El hallazgo sin número del camino `duplicado` y su fix descartado | Final de `Fase 16`, título **Hallazgo sin número** |
| Lo hecho en las sesiones 19 a 23 | Changelog **v64** a **v74**, y **Cierre de sesión**. Las sesiones 18 (v63) y 17 (v61, v62) están en **Historial de sesiones**; la 17 también en **Fase 18** |
| El contrato aplicado: arranque, WF7, la puerta de WF1, T0 y el test en vivo | **`Fase 18`** (18.1 arranque, 18.2 puerta, 18.3 pruebas, 18.5 lo que queda) |
| El contrato de telemetría (qué manda el ESP32 y qué responde el sistema) | `docs/contrato_telemetria.md` (vigente desde el 20/10; pasos 1 a 5 aplicados el 04/11; órdenes, sección 10, el 10/11) |
| Respaldo, restauración y versión de n8n | `B.13` y `B.14`, en el Backlog |

**Las cuatro revisiones externas** (setiembre 2026, hechas por un agente que leyó este archivo y los workflows pero **no** el plan). Sus conclusiones ya están integradas al plan; los archivos quedan porque tienen el razonamiento completo:

| Archivo | Qué contiene |
|---|---|
| `docs/revisiones/REVISION_01_cobertura.md` | Si el sistema cubre el proceso real de una planta |
| `docs/revisiones/REVISION_02_medicion.md` | Qué se mide, qué falta medir, y la capa de tendencia que no existe |
| `docs/revisiones/REVISION_03_workflows.md` | Los cinco workflows nodo por nodo. Su §1 acota la anomalía de WF3 a cuatro causas |
| `docs/revisiones/REVISION_04_hoja_de_ruta.md` | Los tres carriles y el mínimo viable para un primer cliente |

**Otros archivos del repo:** `SQL/` (esquema y scripts de prueba) · `test/` (fotos y escenarios de prueba) · `WORKFLOWS/` (los 7 JSON: WF1–WF5, WF7 y WF8) · `SQL/sesion18_16.38_restricciones_catalogo.sql` (16.38, aplicado). La propuesta original de la tesis (Anexo II) y el logo de la facultad **no están en el repo** (el Anexo tiene datos personales de Agustín; los sacó él el 03/11).
