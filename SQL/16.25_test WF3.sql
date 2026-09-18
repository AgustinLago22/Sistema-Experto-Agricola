-- ============================================================================
-- 16.25 · Test en vivo de WF3 con la escritura transaccional
-- Fecha: 23/08/2026 — sesión 8
--
-- ORDEN: BLOQUE 0 → BLOQUE 1 → correr WF3 a mano → BLOQUE 2 →
--        correr WF3 otra vez → BLOQUE 3 → BLOQUE 4 (restaurar)
--
-- NO SALTEAR EL BLOQUE 4. Los datos que un test crea son parte del test.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Foto del estado ANTES. Guardá esta salida.
-- ============================================================================
select
  (select fecha_inicio_etapa        from cultivo) as fecha_inicio_etapa,
  (select etapa_actual_id           from cultivo) as etapa_actual_id,
  (select ultima_foto_path          from cultivo) as ultima_foto_path,
  (select ultima_foto_evaluada_path from cultivo) as ultima_foto_evaluada_path,
  (select count(*) from seguimiento_fenologico)   as filas_seguimiento,
  (select count(*) from evaluacion_fenologica)    as filas_evaluacion,
  (select max(fecha_registro) from seguimiento_fenologico) as ultimo_seguimiento;

-- Esperado antes de empezar:
--   fecha_inicio_etapa = 2026-08-12 19:39:05.008+00
--   etapa_actual_id = 4  ·  ultima_foto_evaluada_path = null
--   filas_seguimiento = 24  ·  filas_evaluacion = 0


-- ============================================================================
-- BLOQUE 1 — Abrir la ventana de evaluación (ÚNICA escritura previa al test)
--
-- Hoy el cultivo lleva 11 días en Floración y la ventana es 16 (0.8 × 20), así
-- que `Calcular Dias en Etapa` devuelve {skip:true} y la corrida se corta en
-- `Hay cultivos a evaluar?`. Sin esto, el test daría verde sin ejercer nada.
-- ============================================================================
update cultivo
   set fecha_inicio_etapa = now() - interval '17 days';

-- Verificación: dias_en_etapa debe dar 17 y ser >= ventana_dias (16).
select planta, etapa_actual, duracion_estimada_dias,
       floor(extract(epoch from (now() - fecha_inicio_etapa))/86400) as dias_en_etapa,
       round(duracion_estimada_dias * 0.8) as ventana_dias
from vista_cultivos_activos;


-- ============================================================================
-- >>> ACÁ: en n8n, "Test workflow" sobre WF3. NO lo actives.
-- ============================================================================


-- ============================================================================
-- BLOQUE 2 — Verificación de la PRIMERA corrida
-- ============================================================================

-- 2.1 · La evaluación quedó registrada.
select id, resultado, etapa_detectada, confianza,
       etapas_especie_id_origen, etapas_especie_id_destino,
       jsonb_pretty(diagnostico) as diagnostico, fecha
from evaluacion_fenologica
order by id desc;

-- 2.2 · El estado del cultivo.
select etapa_actual_id, fecha_inicio_etapa,
       ultima_foto_path, ultima_foto_evaluada_path
from cultivo;

-- 2.3 · La historia clínica NO debe tener filas de más.
--       Si aparecen DOS filas nuevas para la misma transición, revivió el nodo viejo.
select count(*) as filas_seguimiento,
       max(fecha_registro) as ultima
from seguimiento_fenologico;

-- ---------------------------------------------------------------------------
-- CÓMO LEER EL RESULTADO
--
-- Caso A (el más probable) · resultado = 'etapa_no_coincide'
--   Gemini ve una planta con flores y frutos verdes y probablemente diga
--   "Fructificación", que no es "Cosecha". El fix de 16.20 bloquea el avance.
--   Esperado: 1 fila en evaluacion_fenologica · etapa_detectada poblada ·
--   etapa_actual_id SIGUE en 4 · ultima_foto_evaluada_path = la foto actual ·
--   seguimiento_fenologico SIGUE en 24 · sin Telegram.
--   Esto ejerce 16.20 y 16.25 juntos sin tocar la etapa. Es el mejor caso.
--
-- Caso B · resultado = 'avanza'
--   Gemini dijo "Cosecha" con confianza > 0.7.
--   Esperado: etapa_actual_id = 5 · fecha_inicio_etapa = ahora ·
--   UNA sola fila nueva en seguimiento_fenologico, con diagnostico_ia como
--   OBJETO jsonb (no string) · Telegram con foto.
--
-- Caso C · resultado = 'no_avanza'
--   Gemini dijo que no hubo cambio. Foto marcada, nada más.
--
-- Caso D · resultado = 'diagnostico_fallido'
--   Gemini falló. La foto NO debe quedar marcada (ultima_foto_evaluada_path
--   sigue en null), para poder reintentar.
--
-- FALLAS DEL TEST (no de la función):
--   · 0 filas en evaluacion_fenologica  → la RPC no se llamó, o el nodo
--     `Registrar Evaluacion` quedó en rojo. Mirá el error del nodo: si dice
--     "Could not find the function", es un nombre de parámetro que no coincide.
--   · 2 filas nuevas en seguimiento_fenologico → `Persistir Seguimiento
--     Fenologico` volvió a quedar cableado.
--   · resultado concluyente PERO ultima_foto_evaluada_path en null → el UPDATE
--     de la función no corrió.
-- ---------------------------------------------------------------------------


-- ============================================================================
-- >>> ACÁ: correr WF3 a mano OTRA VEZ, sin tocar nada.
-- ============================================================================


-- ============================================================================
-- BLOQUE 3 — Verificación de la deduplicación (16.21)
--
-- Esta segunda corrida NO debe llegar a Gemini: `Validacion de foto` tiene que
-- cortar, porque ultima_foto_path == ultima_foto_evaluada_path.
--
-- OJO: "no pasó nada" y "la dedup funcionó" se ven igual desde afuera. Lo que
-- lo distingue es DÓNDE se cortó la ejecución. En n8n, mirá que la corrida
-- llegue a `Validacion de foto` y muera ahí, sin ítems hacia `Descargar Foto`.
-- ============================================================================

-- Debe seguir habiendo exactamente la misma cantidad de filas que en 2.1.
select count(*) as filas_evaluacion, max(id) as ultimo_id
from evaluacion_fenologica;

-- Prueba directa del índice único parcial + la guarda de idempotencia.
-- Reemplazá <PATH> por el valor de ultima_foto_path.
-- Esperado: {"ya_evaluada": true, "resultado": "duplicado", ...} y NINGUNA
-- fila nueva. Si en cambio inserta, la clave de idempotencia no está actuando.
/*
select public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id => 'a1327127-1570-474a-a49e-6d506b300759'::uuid,
  p_path_foto  => '<PATH>',
  p_resultado  => 'no_avanza'
);
*/


-- ============================================================================
-- BLOQUE 4 — RESTAURAR. No es opcional.
-- ============================================================================

-- 4.1 · Borrar las evaluaciones del test.
delete from evaluacion_fenologica;

-- 4.2 · Si el test avanzó de etapa (Caso B), borrar la fila nueva de la
--       historia clínica. Comparar contra `ultimo_seguimiento` del BLOQUE 0.
--       Descomentar SOLO si hay una fila nueva:
/*
delete from seguimiento_fenologico
 where fecha_registro > '2026-08-20 18:49:08.698461+00';
*/

-- 4.3 · Devolver el cultivo a su estado real.
update cultivo
   set fecha_inicio_etapa        = '2026-08-12 19:39:05.008+00',
       etapa_actual_id           = 4,
       ultima_foto_evaluada_path = null;

-- 4.4 · Confirmar que quedó todo como en el BLOQUE 0.
select
  (select fecha_inicio_etapa        from cultivo) as fecha_inicio_etapa,
  (select etapa_actual_id           from cultivo) as etapa_actual_id,
  (select ultima_foto_evaluada_path from cultivo) as ultima_foto_evaluada_path,
  (select count(*) from seguimiento_fenologico)   as filas_seguimiento,
  (select count(*) from evaluacion_fenologica)    as filas_evaluacion;

-- Esperado: 2026-08-12 19:39:05.008+00 · 4 · null · 24 · 0
