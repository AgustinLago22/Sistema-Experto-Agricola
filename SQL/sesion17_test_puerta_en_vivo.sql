-- ============================================================================
-- Sesión 17 · Test EN VIVO del contrato v1, pasos 1 y 2 (arranque + puerta de WF1)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 19/10/2026.
--
-- ⚠️ NO correr el archivo entero. Se corre bloque por bloque, en este orden:
--   PARTE 0 (T0) ANTES de tocar nada · aplicar · PARTE 1 (arranque) ·
--   PARTE 2 (puerta) · PARTE 3 (riego corto) · LIMPIEZA.
--
-- QUÉ PRUEBA, Y CÓMO PUEDE FALLAR (un test que no puede fallar no prueba nada)
--   T0 · 16.52 ANTES del fix: un fix aplicado antes del test lo vuelve una
--        tautología. Hipótesis, leyendo el código: con humedad "" el Motor dice
--        SEQUÍA (en JS `"" < 60` es true), avisa por Telegram y dispara WF5; y
--        WF5 probablemente SE ROMPE al armar el cuerpo de `Registrar Riego` por
--        interpolación (16.56: queda `"p_humedad_inicial": ,`, JSON inválido).
--        Si se confirma, hoy un bug tapa al otro. Falla (la hipótesis) si: el
--        Motor no dice Sequía · o WF5 SÍ crea un riego (sería peor: 16.52
--        regaría de verdad, y hay que anotarlo así).
--   P · Cada rechazo tiene un error DISTINTO, para que no se puedan confundir
--        (P2 humedad "", P3 fuera de rango, P4 arranque ajeno). Falla si: una
--        lectura inválida devuelve 200 · deja filas en lectura_sensores · no
--        deja fila en lectura_rechazada · una válida devuelve 400.
--   R · Riego corto con el simulador nuevo: que el Motor siga leyendo bien la
--        humedad desde la puerta, también en el control del riego.
--
-- Umbrales vigentes (Fructificación): humedad 60–75. Debajo de 60 = Sequía.
-- Después de cada pedido esperá ~5 s (WF2 y WF5 corren aparte) y corré VER.
-- ============================================================================


-- ============================================================================
-- ESTADO PREVIO (19/10): evento_riego max id 10 · comando_dispositivo max id 10
-- · lectura_sensores max id 289 (230 filas). La LIMPIEZA borra lo que pase de ahí.
-- ============================================================================


-- ============================================================================
-- VER — correr después de cada paso
-- ============================================================================
select (select count(*) from lectura_sensores where id > 289) as lecturas_nuevas,
       (select string_agg(metrica_id::text || '=' || valor::text, ' ' order by id)
          from lectura_sensores where id > 289)                as ultimas_metricas,
       (select count(*) from evento_riego where id > 10)        as riegos_nuevos,
       (select count(*) from comando_dispositivo where id > 10) as comandos_nuevos;


-- ============================================================================
-- PARTE 0 — T0: ejercer 16.52 ANTES del fix (WF1 sin tocar, SQL sin aplicar)
-- ============================================================================
-- PowerShell (una línea; reemplazá LA_CLAVE). Es la `T` de la sesión 16:
--   function T($h){ $body = @{dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry"; humedad=$h; ph=6.4; n=25; p=40; k=60} | ConvertTo-Json; Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body $body }
-- Mandar:   T ""
-- Mirar y anotar:
--   · Telegram: ¿llega "DIAGNÓSTICO: Sequía" con "Humedad del suelo = %"?
--   · n8n → Executions de "Control de Riego" (WF5): ¿corrió?, ¿falló en
--     `Registrar Riego`? Copiar el mensaje de error.
--   · VER: lo esperado es lecturas_nuevas = 4 (pH, N, P y K: la humedad no se
--     guarda porque `Consolidar datos` sí la normaliza) y riegos_nuevos = 0.
-- Después: LIMPIEZA (abajo) antes de aplicar nada.


-- ============================================================================
-- APLICAR (en este orden)
--   1. SQL/sesion17_contrato_pasos_1_y_2.sql: BLOQUE 1, BLOQUE 2, BLOQUE 3.
--   2. WF7: importar WORKFLOWS/WF7.json, revisar credenciales, activar.
--   3. WF1: los cambios de la puerta (ver docs/implementation_plan.md, 18.2).
-- ============================================================================


-- ============================================================================
-- SIMULADOR NUEVO — pegar en PowerShell, UNA LÍNEA POR VEZ (reemplazá LA_CLAVE)
-- ============================================================================
--   $K = "LA_CLAVE"; $U = "http://localhost:5678/webhook"; $MAC = "24:0A:C4:A1:B2:C3"
--   function Pedir($ruta, $obj){ try { Invoke-RestMethod -Uri "$U/$ruta" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = $K } -Body ($obj | ConvertTo-Json -Compress) } catch { "HTTP " + [int]$_.Exception.Response.StatusCode + " " + $_.ErrorDetails.Message } }
--   function A($fw = "sim"){ $r = Pedir "arranque" @{v=1; dispositivo_mac=$MAC; fw=$fw}; if ($r.arranque_id) { $global:a = $r.arranque_id; $global:s = 0 }; $r }
--   function L($h = 68.0, $arr = $global:a){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$arr; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$h; temperatura=22.5; ph=6.4; conductividad=1.2; n=25; p=40; k=60}; $global:s++; Pedir "telemetria" $b }
--   function N(){ $b = @{v=1; dispositivo_mac=$MAC; arranque_id=$global:a; seq=$global:s; ts=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); motivo="programada"; humedad=$null; temperatura=$null; ph=$null; conductividad=$null; n=$null; p=$null; k=$null}; $global:s++; Pedir "telemetria" $b }
--
-- Qué es cada uno:
--   A        → la placa "enciende": pide su arranque_id y lo guarda en $a. seq vuelve a 0.
--   L 68     → una lectura con humedad 68 (el resto, sano). Sube seq solo.
--   L ""     → humedad como texto vacío (el caso de 16.52).
--   L 68 999999 → una lectura con un arranque_id que no es de esta placa.
--   N        → una lectura con las 7 mediciones en null.
--   Un error se ve como "HTTP 400 {...}". Un 403 es la clave mal puesta.


-- ============================================================================
-- PARTE 1 — Arranque (WF7)
-- ============================================================================
-- A1 · A                → 200 con arranque_id (no va a ser 1: el BLOQUE 3 del
--                          script consumió números. Es un hueco, y es inocuo).
-- A2 · Pedir "arranque" @{v=1; dispositivo_mac="AA:BB:CC:DD:EE:FF"; fw="sim"}
--                        → HTTP 404, "dispositivo_mac: no corresponde a ningún dispositivo registrado".
-- A3 · Pedir "arranque" @{v=1; dispositivo_mac=$MAC}
--                        → HTTP 400, "fw: falta".
-- Esperado acá: 1 sola fila (A2 y A3 no crean nada), firmware 'sim'.
select * from arranque_dispositivo order by id;
select * from vista_ultimo_arranque;


-- ============================================================================
-- PARTE 2 — La puerta de WF1
-- ============================================================================
-- P1 · T 68         (formato viejo) → HTTP 400 con 7 errores: v, arranque_id,
--                                     seq, ts, motivo, temperatura y conductividad.
-- P2 · L ""         → HTTP 400, 'humedad: "" no es un número ni null'.
--                     ES 16.52: comparar con T0. Ni Telegram ni WF5.
-- P3 · L 150        → HTTP 400, 'humedad: 150 está fuera del rango físico...'.
-- P4 · L 68 999999  → HTTP 400, 'arranque_id: no fue asignado a este dispositivo...'.
-- VER después de P1–P4: lecturas_nuevas = 0, riegos_nuevos = 0.
-- Y acá: 4 filas, en orden P1–P4, con esos errores. P1 tiene `planta` en el
-- cuerpo (se guarda tal como llegó; la puerta lo ignora pero no lo borra).
select id, fecha_hora, dispositivo_mac, errores, cuerpo
  from lectura_rechazada order by id;

-- P5 · L 68  → 200 {"estado":"aceptada"}. Sin Telegram.
--             VER: lecturas_nuevas = 5 (temperatura y conductividad todavía
--             NO se guardan: es el paso 5 del contrato).
-- P6 · N     → 200 {"estado":"aceptada"}. Telegram con "Lectura Sin Datos -
--             Revisar Sensor". VER: lecturas_nuevas sigue en 5, riegos_nuevos = 0.
--             (Antes de este cambio, esta lectura salía 'OK' sin evaluar nada.)


-- ============================================================================
-- PARTE 3 — Riego corto con el simulador nuevo (13.7.2 sigue andando)
-- ============================================================================
-- R1 · L 55  → 200. Telegram de Sequía y de riego. VER: riegos_nuevos = 1.
-- R2 · correr ATRASAR (abajo) y después  L 62  → 200, sin alerta.
--      Esperado acá: el riego con humedad_inicial 55, resultado 'exitoso',
--      humedad_recheck 62. Falla si queda 'pendiente' (el Motor no leyó la
--      humedad desde la puerta) o si aparece un segundo riego.
select e.id, e.fecha_inicio, e.humedad_inicial, e.resultado, e.humedad_recheck, e.fecha_recheck,
       c.estado as comando_estado
  from evento_riego e join comando_dispositivo c on c.id = e.comando_id
 where e.id > 10 order by e.id;

-- ATRASAR — simula que pasaron 20 min desde el último riego
update evento_riego
   set fecha_inicio = fecha_inicio - interval '20 minutes'
 where id = (select max(id) from evento_riego where id > 10);


-- ============================================================================
-- LIMPIEZA T0 — después de la PARTE 0 (las tablas nuevas todavía no existen)
-- ============================================================================
-- El orden importa (evento → comando).
begin;
delete from evento_riego        where id > 10;
delete from comando_dispositivo where id > 10;
delete from lectura_sensores    where id > 289;
commit;
-- Esperado: 8 · 8 · 230
select (select count(*) from evento_riego)        as eventos,
       (select count(*) from comando_dispositivo) as comandos,
       (select count(*) from lectura_sensores)    as lecturas;


-- ============================================================================
-- LIMPIEZA FINAL — los datos que crea un test son parte del test
-- ============================================================================
-- Los arranques y los rechazos del test también se borran: la demo hace su
-- propio arranque con A.
begin;
delete from evento_riego        where id > 10;
delete from comando_dispositivo where id > 10;
delete from lectura_sensores    where id > 289;
delete from lectura_rechazada;
delete from arranque_dispositivo;
commit;

-- Esperado: 8 · 8 · 230 · 0 · 0
select (select count(*) from evento_riego)         as eventos,
       (select count(*) from comando_dispositivo)  as comandos,
       (select count(*) from lectura_sensores)     as lecturas,
       (select count(*) from lectura_rechazada)    as rechazos,
       (select count(*) from arranque_dispositivo) as arranques;
