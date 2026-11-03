# Contrato de telemetría — versión 1

> **Estado:** escrito el 13/10/2026 (B.22). **Pasos 1 y 2 de la sección 9 aplicados y verificados en vivo el 20/10/2026 (sesión 17):** el arranque lo da WF7 y la puerta de WF1 hace cumplir este contrato. **Desde el 20/10, el formato anterior se rechaza con `400`.** **Pasos 5 y 4 aplicados y verificados en vivo el 03/11/2026 (sesión 21):** temperatura y conductividad se guardan, y cada lectura se guarda con su DNI y su hora (un reintento no se guarda dos veces). Falta el paso 3: hasta entonces, un reintento recibe `"aceptada"` en vez de `"duplicada"`. Detalle en `implementation_plan.md`, Fase 18.
>
> **Para qué existe.** Es la definición de qué manda el nodo sensor y de qué hace el sistema con lo que recibe. Hasta hoy el formato era "lo que manda el script de PowerShell", y esa falta de definición causó 16.52 (un `""` leído como humedad 0 %), 16.47 (sin hora de medición) y 16.48 (temperatura y conductividad descartadas). Se escribe **antes** de que exista el firmware, porque después cambiarlo obliga a actualizar cada placa instalada.

El contrato tiene **dos pedidos**: uno al arrancar la placa, y uno por cada lectura.

---

## 1 · Al arrancar: pedir el número de arranque

```
POST http://<orquestador>:5678/webhook/arranque
Content-Type: application/json
X-Device-Key: <clave del dispositivo>

{ "v": 1, "dispositivo_mac": "24:0A:C4:A1:B2:C3", "fw": "1.0.0" }
```

Respuesta: `200` · `{ "arranque_id": 1234 }`

| Campo | Tipo | Qué es |
|---|---|---|
| `v` | entero | Versión del contrato. Hoy vale `1`. |
| `dispositivo_mac` | texto | MAC del ESP32, formato `AA:BB:CC:DD:EE:FF`. |
| `fw` | texto, 1 a 20 caracteres | Versión del firmware. Va acá y no en cada lectura porque solo puede cambiar al reiniciar. Se guarda **en el arranque**; el firmware vigente de cada placa se deriva del último arranque (`vista_ultimo_arranque`). |

**Por qué lo asigna el servidor.** Cada lectura necesita una identidad que **no se repita nunca** (sección 3). Si la placa contara sus propios arranques, un borrado de su memoria haría volver el contador a 0 y repetiría números viejos; si los sorteara, habría una chance chica pero real de repetir. En cambio, la base saca el número de un contador propio que solo sube, y **no puede entregar dos veces el mismo, por construcción**. Es la regla de 16.25: *un identificador único no se garantiza con una convención, se garantiza con un registro que lo asigne.*

**Reglas del arranque:**

1. La placa pide el número **una vez por encendido**, antes de mandar ninguna lectura, y lo usa para todas las lecturas hasta el próximo reinicio.
2. Si no hay conexión al arrancar, la placa **mide igual** y guarda las lecturas en memoria hasta conseguir el número. Igual no podría mandarlas sin conexión.
3. Si la respuesta se pierde y la placa pide otra vez, recibe **otro** número. El primero queda sin usar: es un hueco, nunca una repetición.
4. Cada arranque queda registrado en la base con su fecha y su firmware. **De paso, el sistema sabe cuándo y cada cuánto se reinicia cada placa**, que es una señal de problemas eléctricos o de firmware.
5. MAC desconocida: `404`. La placa no puede mandar lecturas.
6. Pedido mal formado (falta `v`, `dispositivo_mac` o `fw`, o tienen otro tipo): `400` · `{"estado":"rechazado","errores":[...]}`.

> **Cambio del 19/10 (sesión 17):** la versión original decía que `fw` se guardaba en `dispositivo.version_firmware`. Con la tabla de arranques, ese dato se puede **derivar** del último arranque, y mantenerlo también en `dispositivo` era sostener dos fuentes de la misma verdad. Decisión del autor: la columna se borra. No cambia nada para la placa, así que `v` sigue en 1.

---

## 2 · Cada lectura

```
POST http://<orquestador>:5678/webhook/telemetria
Content-Type: application/json
X-Device-Key: <clave del dispositivo>
```

Un pedido = **una lectura completa** (las 7 mediciones del mismo instante, y opcionalmente una foto).

| Campo | Tipo | Obligatorio | Qué es |
|---|---|---|---|
| `v` | entero | sí | Versión del contrato. Hoy vale `1`. |
| `dispositivo_mac` | texto | sí | MAC del ESP32. El sistema deduce el cultivo a partir de ella. |
| `arranque_id` | entero | sí | El número que el servidor le dio a la placa al arrancar (sección 1). |
| `seq` | entero ≥ 0 | sí | Número de lectura dentro de este arranque. Empieza en 0 y sube de a 1 por cada lectura. |
| `ts` | entero o `null` | sí | **Hora de la medición**, en segundos desde 1970 (Unix, UTC). `null` si la placa no tiene hora confiable (por ejemplo, no pudo sincronizar por NTP). |
| `motivo` | texto | sí | `"programada"` (lectura del ciclo normal) o `"recheck"` (lectura extra después de regar, para confirmar que el riego funcionó — ver 13.7). |
| `humedad` | número o `null` | sí | Humedad del suelo, **%**. |
| `temperatura` | número o `null` | sí | Temperatura del suelo, **°C**. |
| `ph` | número o `null` | sí | **pH**. |
| `conductividad` | número o `null` | sí | Conductividad eléctrica del suelo, **mS/cm**. |
| `n` | número o `null` | sí | Nitrógeno, **mg/kg**. |
| `p` | número o `null` | sí | Fósforo, **mg/kg**. |
| `k` | número o `null` | sí | Potasio, **mg/kg**. |
| `foto_base64` | texto | no | Foto JPEG en base64, sin el prefijo `data:`. Si no hay foto, el campo **no se manda**. |

Las unidades son las que ya declara `tipos_metricas` en la base.

---

## 3 · Las reglas

1. **Las 7 mediciones van siempre.** Cada una es un **número o `null`**. `null` significa "el sensor no pudo medir esta variable". **Nunca** se manda `""`, texto, ni se omite el campo. *(Ataca la causa de 16.52: la ausencia se declara en el origen, no se adivina en el destino.)*
2. **Un valor fuera del rango físico del sensor se manda como `null`**, no como el número raro. Rangos físicos de referencia: humedad 0–100 · temperatura −40–80 · pH 0–14 · conductividad 0–20 · N, P, K 0–2000. Son límites de lo **posible**, no de lo **sano**: lo sano lo deciden los umbrales de cada etapa.
3. **La identidad de una lectura es `(arranque_id, seq)`**: su "DNI". Como el servidor nunca repite un `arranque_id` y la placa nunca repite un `seq` dentro de un arranque, **dos lecturas distintas no pueden tener el mismo DNI**. Sirve para descartar reintentos, para detectar lecturas perdidas (un salto en `seq`) y para que un riego señale la lectura exacta que lo disparó (B.20).
4. **Una lectura reintentada se manda idéntica**: mismo `arranque_id`, mismo `seq`, mismo `ts`, mismos valores.
5. **No se manda `planta`** ni ningún dato del cultivo. El dispositivo informa lo que mide; qué planta es lo sabe el sistema por la MAC. *(La definición vive en un solo lugar.)*
6. **Campos que el contrato no conoce se ignoran.** No producen error. Esto permite que un firmware más nuevo conviva con un servidor más viejo.

---

## 4 · Qué hace el sistema con cada lectura

| Caso | Respuesta | Qué pasa |
|---|---|---|
| Cumple el contrato | `200` · `{"estado":"aceptada"}` | Se procesa como hoy: se guarda y se evalúa contra los umbrales de la etapa. |
| DNI ya recibido | `200` · `{"estado":"duplicada"}` | Es un reintento. No se guarda de nuevo ni se evalúa. Responde 200 para que el dispositivo **deje de reintentar**. |
| `arranque_id` que no se le dio a esa MAC | `400` · con `errores` | Se rechaza: el número no es de esa placa. También si la MAC no está registrada. |
| Versión `v` desconocida | `400` | Se rechaza: el sistema no sabe leer ese formato. |
| No cumple el contrato | `400` · `{"estado":"rechazada","errores":[...]}` | **Se rechaza entera** y se informa cada campo con problema. No se procesa a medias: una lectura mal formada no puede disparar un riego. El rechazo queda registrado en la tabla `lectura_rechazada` (el cuerpo, sin la foto). |
| Clave incorrecta | `403` | No se procesa. *(La versión original decía `401`; `403` es lo que responde n8n con Header Auth, verificado en su código el 19/10. Se corrige el documento, no la placa: no hay placas en campo.)* |
| Falla del servidor | `5xx` o sin respuesta | El dispositivo guarda la lectura y **reintenta más tarde, idéntica** (regla 4). |

**Sobre la hora (`ts`).** El sistema guarda dos horas: la de **medición** (`ts`) y la de **recepción** (la del servidor). Si `ts` es `null`, o está más de 5 minutos en el futuro respecto del servidor, la lectura **se acepta** igual, pero se marca como "hora no confiable" y para decidir se usa la de recepción. No se rechaza por eso: el dato medido sigue siendo válido aunque el reloj no lo sea.

---

## 5 · Temperatura y conductividad: se guardan, no deciden

Las dos están en el catálogo (`tipos_metricas` 2 y 7), el sensor 7 en 1 las mide, y hasta el 03/11/2026 el sistema las descartaba: **0 lecturas guardadas** hasta esa fecha (16.48). **Desde el 03/11 se guardan** (paso 5 de la sección 9).

**Un sensor que no mide alguna de las dos** la manda igual, en `null` (regla 1): se acepta, no se guarda esa fila y no produce ningún aviso, porque no decide. El campo no se omite: un campo ausente no distingue "este sensor no lo mide" de "el firmware se olvidó de mandarlo" (decisión del autor, 03/11).

Con este contrato **se registran, pero no intervienen en el diagnóstico**: no tienen umbrales por etapa ni disparan alertas. Usarlas para decidir exige cargar umbrales con fuentes, como se hizo con humedad y NPK (Fase 17), y eso queda como trabajo futuro. Guardarlas desde ahora es lo que va a permitir analizarlas cuando llegue ese momento: lo que no se guarda hoy no se recupera después.

**Nota para la tesis.** En la mayoría de los sensores 7 en 1 de bajo costo, N, P y K **no se miden directamente**: se calculan a partir de la conductividad con una fórmula de fábrica. Si la hoja de datos del sensor elegido lo confirma, la conductividad es el dato de origen y el NPK es un dato derivado, lo que limita cuánto se puede confiar en él. Verificarlo antes de comprar el sensor.

---

## 6 · Cadencia

El contrato **no fija** cada cuánto se mide (B.19): ese número sale de un piloto, midiendo la velocidad de secado real y el ruido del sensor. Sí fija dos cosas:

- las lecturas `"programada"` tienen un intervalo **regular** y conocido;
- después de un riego, el dispositivo manda una lectura extra con `motivo: "recheck"` a los 15 minutos (13.6, paso 4).

---

## 7 · Ejemplos

**Lectura normal, con todo:**

```json
{
  "v": 1,
  "dispositivo_mac": "24:0A:C4:A1:B2:C3",
  "arranque_id": 1234,
  "seq": 1842,
  "ts": 1791320400,
  "motivo": "programada",
  "humedad": 68.0,
  "temperatura": 22.5,
  "ph": 6.4,
  "conductividad": 1.2,
  "n": 25,
  "p": 40,
  "k": 60
}
```

**El sensor de pH no respondió y la placa no tiene hora** — válida, se acepta:

```json
{ "v": 1, "dispositivo_mac": "24:0A:C4:A1:B2:C3", "arranque_id": 1235, "seq": 0,
  "ts": null, "motivo": "programada",
  "humedad": 66.1, "temperatura": 21.9, "ph": null, "conductividad": 1.1,
  "n": 24, "p": 41, "k": 59 }
```

**Inválida — se rechaza entera:**

```json
{ "v": 1, "dispositivo_mac": "24:0A:C4:A1:B2:C3", "planta": "Tomate Cherry",
  "humedad": "", "ph": 6.4, "n": 25, "p": 40, "k": 60 }
```

Errores que devolvería: `humedad` es `""` (tiene que ser número o `null`); faltan `arranque_id`, `seq`, `ts`, `motivo`, `temperatura` y `conductividad`. `planta` se ignora (regla 6).

**Simulador en PowerShell** (una línea cada uno, como las pruebas actuales). Primero el arranque, que guarda el número en `$a`:

```powershell
$a = (Invoke-RestMethod -Uri "http://localhost:5678/webhook/arranque" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body (@{v=1; dispositivo_mac="24:0A:C4:A1:B2:C3"; fw="sim"} | ConvertTo-Json)).arranque_id
```

Después, cada lectura, subiendo `seq` de a 1:

```powershell
$body = @{v=1; dispositivo_mac="24:0A:C4:A1:B2:C3"; arranque_id=$a; seq=0; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=68.0; temperatura=22.5; ph=6.4; conductividad=1.2; n=25; p=40; k=60} | ConvertTo-Json; Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body $body
```

Para probar un reintento, mandar dos veces la misma lectura: la segunda tiene que volver `duplicada`.

---

## 8 · Cómo cambia este contrato

- **Agregar un campo opcional** no cambia `v`: los dispositivos viejos siguen siendo válidos (regla 6).
- **Cualquier otro cambio** (agregar un campo obligatorio, cambiar un tipo, una unidad o el significado de un campo) sube `v`. Durante la transición, el sistema acepta la versión nueva y la anterior.
- Cada cambio se registra en el changelog de `implementation_plan.md`.

---

## 9 · Qué falta para que el sistema lo cumpla

Este documento es el primer paso. Cada uno de los siguientes es una tarea propia, con su prueba; los cambios en la base van como script en `SQL/`, que ejecuta el usuario.

1. **Base y n8n — el arranque.** Una tabla de arranques (con un número que solo sube, la placa, la fecha y el firmware), una función que la registre y devuelva el número, y el webhook `/arranque` que la llame. *Aplicado el 20/10: `SQL/sesion17_contrato_pasos_1_y_2.sql` y `WORKFLOWS/WF7.json`. El firmware vigente se deriva del último arranque (ver sección 1).*
2. **WF1 — revisión en la puerta.** Un nodo al principio, antes de `Resolver Cultivo`, que valide el contrato y responda `400` con los errores. Normaliza una sola vez, antes del primer nodo que decide (**cierra 16.52**). *Aplicado el 20/10: `Validar Contrato` + `Verificar Arranque` + respuestas `200`/`400` + registro del rechazo (Fase 18.2 del plan).*
3. **WF1 — respuestas.** Hoy el webhook responde apenas recibe el pedido, sin decir si la lectura sirvió. Hay que responder con los códigos de la sección 4.
4. **Base — hora y DNI de la lectura.** Guardar `ts`, la hora de recepción, `arranque_id` y `seq`, con una restricción de unicidad sobre `(arranque_id, seq)` que haga imposible el duplicado (**16.47**, y la pieza que necesita **B.20**). *Aplicado el 03/11: `SQL/sesion21_contrato_paso4_dni_lectura.sql` (tabla `lectura`; las mediciones apuntan a ella con `lectura_id`) y WF1, que registra la lectura antes de subir la foto. Un DNI repetido lo rechaza la base y WF1 se detiene sin avisar ni regar. "Hora no confiable" no se guarda: se deriva de `ts` y de la hora de recepción.*
5. **Base y WF1 — temperatura y conductividad.** Que `fn_registrar_telemetria` las reciba y las guarde como métricas 2 y 7 (**16.48**). *Aplicado el 03/11: `SQL/sesion21_contrato_paso5_temp_cond.sql` y `Consolidar datos` de WF1, que las toma de la lectura de `Validar Contrato`.*
6. **Simulador.** Actualizar los comandos de prueba del plan al formato nuevo. *Escrito el 19/10 en `SQL/sesion17_test_puerta_en_vivo.sql` (funciones `A`, `L` y `N` de PowerShell); falta pasarlo a la sección "Cómo probar" del plan cuando la puerta esté aplicada.*

**Transición.** Mientras los pasos 1 a 5 no estén hechos, WF1 sigue aceptando el formato viejo. Cuando el paso 2 entre en vigencia, el formato viejo pasa a rechazarse: no hay dispositivos reales en campo que migrar, solo el simulador.
