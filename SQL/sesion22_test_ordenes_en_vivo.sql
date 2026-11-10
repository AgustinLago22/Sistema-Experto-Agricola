-- ============================================================================
-- Sesión 22 · Test EN VIVO de 16.63: la placa recibe sus órdenes (WF8)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 09/11/2026.
--
-- ⚠️ NO correr el archivo entero. Bloque por bloque, en este orden:
--   PARTE 0 ANTES de aplicar nada · aplicar (SQL + WF8) · PARTE 1 · PARTE 2 ·
--   PARTE 3. Sin limpieza: los datos de prueba se dejan, como en la sesión 21.
--
-- QUÉ PRUEBA, Y CÓMO PUEDE FALLAR
--   P0 · Antes: nadie atiende /webhook/ordenes (404). Falla si contesta otra
--        cosa: habría algo corriendo que el plan no conoce.
--   P1 · Las 10 órdenes viejas (8 de agosto, de 30 s, y las 27 y 28 del 04/11)
--        NO se entregan. Es el caso que importa: un consumidor ingenuo regaría
--        10 veces seguidas apenas se conecte. Falla si llega alguna, o si
--        alguna deja de estar 'pendiente'.
--   P2 · Una sequía crea una orden; la placa la recibe UNA vez; al regar avisa
--        'ejecutado'; repetir el aviso da 'duplicado'; un aviso contradictorio
--        se rechaza. Falla si la orden llega dos veces, si la base no guarda
--        las horas, o si el aviso repetido cambia algo.
--   P3 · El control del riego (13.7.2) ve la orden 'ejecutado': la vista lo
--        refleja, así que una falla de riego diría "revisar tanque, bomba,
--        fuga o sensor" y no "revisar la conexión".
--
-- Umbrales vigentes (Fructificación): humedad 60–75. Debajo de 60 = Sequía,
-- dispara WF5 y cuenta para el tope de 4 riegos en 6 horas.
-- ============================================================================


-- ============================================================================
-- ESTADO PREVIO — correr ANTES de empezar y anotar los números.
-- Esperado el 09/11: comando_dispositivo max id 28, 10 en 'pendiente'.
-- ============================================================================
select (select max(id) from comando_dispositivo) as max_comando,
       (select max(id) from evento_riego)        as max_riego,
       (select max(id) from lectura)             as max_lectura,
       (select count(*) from comando_dispositivo where estado = 'pendiente') as pendientes;


-- ============================================================================
-- VER — correr después de cada paso
-- ============================================================================
select id, tipo_comando, duracion_segundos, estado,
       creado_en    at time zone 'America/Argentina/Buenos_Aires' as creada,
       entregado_en at time zone 'America/Argentina/Buenos_Aires' as entregada,
       ejecutado_en at time zone 'America/Argentina/Buenos_Aires' as ejecutada
from comando_dispositivo
order by id desc
limit 5;


-- ============================================================================
-- PowerShell — pegar una vez por ventana, una línea por vez (reemplazá LA_CLAVE).
-- Las tres primeras son las de siempre (sección "Cómo probar"); O y E son nuevas.
-- ============================================================================
-- $K = "LA_CLAVE"; $U = "http://localhost:5678/webhook"; $MAC = "24:0A:C4:A1:B2:C3"
-- function Pedir($ruta, $obj){ try { Invoke-RestMethod -Uri "$U/$ruta" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = $K } -Body ($obj | ConvertTo-Json -Compress) } catch { "HTTP " + [int]$_.Exception.Response.StatusCode + " " + $_.ErrorDetails.Message } }
-- function A($fw = "sim"){ $r = Pedir "arranque" @{v=1; dispositivo_mac=$MAC; fw=$fw}; if ($r.arranque_id) { $global:a = $r.arranque_id; $global:s = 0 }; $r }
-- function L($h = 68.0, $arr = $global:a){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$arr; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=6.4; conductividad=1.2; n=25; p=40; k=60}; $global:s++; Pedir "telemetria" $b }
-- function O(){ $r = Pedir "ordenes" @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a}; $r | ConvertTo-Json -Depth 5 }
-- function E($id, $res = "ejecutado"){ Pedir "orden-acuse" @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; comando_id=$id; resultado=$res} }
--
-- O       → pide las órdenes de la placa (las muestra en JSON).
-- E 29    → avisa que la orden 29 se ejecutó.  E 29 "error" → que falló.
-- La página test/simulador.html hace lo mismo en el paso 3, "Recibir órdenes".


-- ============================================================================
-- PARTE 0 — ANTES de aplicar nada (sin el SQL y sin WF8)
-- ============================================================================
-- A        → un arranque nuevo (anotalo).
-- O        → esperado: HTTP 404 (no existe el webhook). Si contesta otra cosa, parar.


-- ============================================================================
-- Aplicar: SQL/sesion22_16.63_entrega_ordenes.sql (BLOQUE 3 antes, BLOQUE 1,
-- BLOQUE 3 después) → importar WF8 → activarlo y publicarlo.
-- ============================================================================


-- ============================================================================
-- PARTE 1 — Las órdenes viejas no se entregan
-- ============================================================================
-- O        → esperado: {"estado":"ok","ordenes":[]}
-- VER      → las 10 viejas siguen 'pendiente', sin hora de entrega.
select count(*) filter (where estado = 'pendiente' and entregado_en is null) as viejas_intactas
from comando_dispositivo
where id <= 28;   -- esperado: 10


-- ============================================================================
-- PARTE 2 — Una orden nueva, de punta a punta
-- ============================================================================
-- L 55     → sequía: Telegram de alerta y de riego; WF5 crea la orden (16 s).
--            Esperá ~10 s.
-- VER      → una orden nueva (anotá su id, N), 'pendiente'.
-- O        → esperado: la orden N, con "duracion_segundos": 16.
-- O        → otra vez: esperado "ordenes": [] (se entrega una sola vez).
-- VER      → la orden N 'entregado', con hora de entrega.
-- E N      → esperado: {"estado":"aceptado","comando_id":N,"estado_orden":"ejecutado"}
-- E N      → otra vez: esperado "duplicado".
-- E N "error" → esperado: HTTP 400, "ya figura \"ejecutado\"".
-- VER      → la orden N 'ejecutado', con las tres horas.


-- ============================================================================
-- PARTE 3 — El control del riego ve la orden ejecutada
-- ============================================================================
select evento_id, resultado, comando_estado
from vista_ultimo_riego;   -- esperado: comando_estado = 'ejecutado'
