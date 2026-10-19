-- ============================================================================
-- Sesión 16 · Test EN VIVO del lazo de riego (13.7.2: recheck + freno + tope)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 16/10/2026. Se corre DESPUÉS de aplicar sesion16_lazo_riego.sql,
-- WF5 y WF1 (en ese orden).
--
-- QUÉ PRUEBA, Y CÓMO PUEDE FALLAR (regla: un test que no puede fallar no prueba nada)
--   A · Tope duro (16.46): una dosis que nunca alcanza → 4 riegos y el 5º se frena.
--       Falla si: aparece un 5º riego (no hay tope) · un riego queda 'pendiente'
--       (el recheck no se guarda) · se frena antes del 5º (el freno confunde
--       'insuficiente' con 'fallo_sistema', que era el problema 2 del diseño viejo).
--   B · Freno (13.7.1): el riego no tiene efecto → freno EN ESA MISMA lectura.
--       Falla si: aparece un riego nuevo en B2 o B3 (es justo el problema 1 del
--       diseño viejo: el freno mira un riego que todavía no se cerró).
--   C · Rearme y recheck exitoso, y el cooldown leído de la vista.
--       Falla si: después de ver la maceta húmeda no vuelve a regar (problema 3,
--       freno sin rearme) · riega dentro de los 15 min (cooldown roto).
--
-- POR QUÉ HAY QUE "ATRASAR" (regla: que el workflow LLEGUE a los nodos)
--   El recheck y el cooldown esperan 15 min de absorción. En vez de esperar,
--   se corre el bloque ATRASAR, que mueve 20 min hacia atrás el último riego.
--   Sin eso, cada lectura caería en el cooldown y el test daría verde sin
--   probar el recheck.
--
-- PREPARAR LA TERMINAL (PowerShell, una sola línea; reemplazá LA_CLAVE)
--   function T($h){ $body = @{dispositivo_mac="24:0A:C4:A1:B2:C3"; planta="Tomate Cherry"; humedad=$h; ph=6.4; n=25; p=40; k=60} | ConvertTo-Json; Invoke-RestMethod -Uri "http://localhost:5678/webhook/telemetria" -Method POST -ContentType "application/json" -Headers @{ "X-Device-Key" = "LA_CLAVE" } -Body $body }
-- Después, cada lectura es:  T 40
--
-- ⚠️ NO correr el archivo entero. Se corre bloque por bloque (VER, ATRASAR,
--    B4, LIMPIEZA), en el orden de los escenarios.
--
-- Umbrales vigentes (Fructificación): humedad 60–75. Debajo de 60 = Sequía.
-- Después de cada T, esperá ~5 s (WF5 corre aparte) y corré VER.
-- ============================================================================


-- ============================================================================
-- ESTADO PREVIO (16/10): evento_riego max id 10 · comando_dispositivo max id 10
-- · lectura_sensores max id 289 (230 filas). La LIMPIEZA borra lo que pase de ahí.
-- ============================================================================


-- ============================================================================
-- VER — correr después de cada paso
-- ============================================================================
select e.id, e.fecha_inicio, e.humedad_inicial as h_ini, e.resultado,
       e.humedad_recheck as h_recheck, e.fecha_recheck,
       c.id as cmd, c.estado as cmd_estado
  from evento_riego e
  join comando_dispositivo c on c.id = e.comando_id
 where e.id > 10
 order by e.id;


-- ============================================================================
-- ATRASAR — simula que pasaron 20 min desde el último riego
-- ============================================================================
update evento_riego
   set fecha_inicio = fecha_inicio - interval '20 minutes'
 where id = (select max(id) from evento_riego where id > 10);


-- ============================================================================
-- ESCENARIO A · Tope duro. Cada riego sube la humedad, pero nunca alcanza.
-- ============================================================================
-- A1  T 40  → Telegram: alerta de Sequía + "RIEGO AUTOMÁTICO INICIADO" (riego 1 de 4).
--           VER: 1 fila 'pendiente'.                                   → ATRASAR
-- A2  T 45  → la alerta dice "subió la humedad de 40% a 45%" + riego 2 de 4.
--           VER: la 1ª 'insuficiente' (h_recheck 45), la 2ª 'pendiente'. → ATRASAR
-- A3  T 50  → riego 3 de 4.  VER: 2ª 'insuficiente', 3ª 'pendiente'.    → ATRASAR
-- A4  T 55  → riego 4 de 4.  VER: 3ª 'insuficiente', 4ª 'pendiente'.    → ATRASAR
-- A5  T 59  → Telegram: "RIEGO AUTOMÁTICO FRENADO POR TOPE DE SEGURIDAD" (4 de 4 en 6 h).
--           VER: la 4ª 'insuficiente' y SIGUE HABIENDO 4 FILAS. No hay 5º comando.
-- → LIMPIEZA antes de seguir (si no, el tope sigue lleno y B no prueba nada).


-- ============================================================================
-- ESCENARIO B · El riego no tiene efecto → freno, con diagnóstico
-- ============================================================================
-- B1  T 50  → riego 1 de 4.  VER: 1 fila 'pendiente', cmd 'pendiente'.  → ATRASAR
-- B2  T 51  → Telegram: "FALLA DE RIEGO: se regó con humedad 50% y en el control seguía
--           en 51%. La orden figura "pendiente": ... Revisar primero la conexión de la placa."
--           Estado "Falla de Riego - Revisar Sistema". NO hay "RIEGO AUTOMÁTICO INICIADO".
--           VER: 'fallo_sistema', h_recheck 51, y SIGUE HABIENDO 1 FILA.
-- B3  T 51  → otra vez Falla de Riego (ahora sale de lo guardado, no del recheck). VER: 1 fila.
-- B4  Simular que la placa SÍ ejecutó la orden (lo que haría el simulador de 13.6, 16.63):
update comando_dispositivo
   set estado = 'ejecutado', entregado_en = now(), ejecutado_en = now()
 where id = (select max(comando_id) from evento_riego where id > 10);
--     T 51  → la falla ahora dice "La orden se ejecutó y la humedad no subió. Revisar: ¿hay
--           agua en el tanque?, ¿la bomba funciona?...". VER: 1 fila, cmd 'ejecutado'.


-- ============================================================================
-- ESCENARIO C · Rearme por evidencia, cooldown y recheck exitoso (sigue de B)
-- ============================================================================
-- C1  T 68  → alguien regó a mano: OK, sin alerta. VER: 1 fila.
-- C2  T 55  → Sequía y VUELVE A REGAR (rearmado): riego 2 de 4. VER: 2 filas, la 2ª 'pendiente'.
-- C3  T 55  → enseguida, SIN atrasar: Sequía pero NO riega (cooldown leído de la vista).
--           VER: siguen 2 filas, la 2ª sigue 'pendiente' (sin absorción no hay recheck). → ATRASAR
-- C4  T 68  → OK, sin alerta. VER: la 2ª 'exitoso', h_recheck 68.
-- → LIMPIEZA.


-- ============================================================================
-- LIMPIEZA — los datos del test son parte del test
-- ============================================================================
-- Primero mirar qué se va a borrar:
select 'evento_riego' as tabla, count(*) from evento_riego where id > 10
union all select 'comando_dispositivo', count(*) from comando_dispositivo where id > 10
union all select 'lectura_sensores', count(*) from lectura_sensores where id > 289;

begin;
delete from evento_riego        where id > 10;   -- primero: tiene FK a comando_dispositivo
delete from comando_dispositivo where id > 10;
delete from lectura_sensores    where id > 289;
commit;

-- Esperado al final: 8 · 8 · 230, igual que antes del test.
select (select count(*) from evento_riego)        as eventos,
       (select count(*) from comando_dispositivo) as comandos,
       (select count(*) from lectura_sensores)    as lecturas;
