-- ============================================================================
-- SESIÓN 9 — Limpieza de los residuos del test de inyección de fallos (16.32)
-- Fecha: 24/08/2026
-- ============================================================================
-- El test que refutó 16.32 corrió a las 16:39:14 UTC del 24/08 y dejó CINCO
-- rastros, de los cuales el plan solo documentó dos. Este script los revierte.
--
-- ORDEN OBLIGATORIO: evento_riego antes que comando_dispositivo, por la FK
-- evento_riego_comando_id_fkey (evento_riego.comando_id -> comando_dispositivo.id).
--
-- El objeto de Storage se borra APARTE y DESPUÉS (ver nota al final): borrarlo
-- antes de revertir el puntero deja una ventana donde cultivo.ultima_foto_path
-- apunta a un objeto inexistente, que es exactamente el escenario de B.10.
-- ============================================================================

BEGIN;

-- Verificación previa: si esto no devuelve exactamente lo esperado, abortar.
-- (Ejecutar el SELECT solo, mirar el resultado, y recién entonces el resto.)
--   select id, resultado, fecha_inicio from evento_riego where id = 11;
--   -- esperado: 1 fila, resultado='pendiente', fecha_inicio=2026-08-24 16:39:16 UTC

-- 1) Riego disparado por el test. Ambas filas son #9 en su tabla, id = 11.
DELETE FROM public.evento_riego        WHERE id = 11;
DELETE FROM public.comando_dispositivo WHERE id = 11;

-- 2) Diagnóstico que WF2 escribió sobre la foto del test (16:40:30 UTC).
--    Este residuo NO estaba documentado: el plan se grabó a las 16:48 diciendo
--    "24 filas" cuando la 25 ya existía desde las 16:40.
DELETE FROM public.seguimiento_fenologico
WHERE id = '29c109c9-c5d8-4499-9688-a276adfb391d';

-- 3) Telemetría que disparó todo. lectura_sensores es formato largo:
--    una fila por métrica, así que una sola lectura son 5 filas (ids 271-275).
DELETE FROM public.lectura_sensores WHERE id BETWEEN 271 AND 275;

-- 4) Revertir el puntero de la foto a la última foto real previa (20/08).
--    Este es el residuo con consecuencia futura: WF3 está activo, la ventana de
--    evaluación se abre ~28/08 y ultima_foto_evaluada_path sigue en null, así que
--    la dedup de 16.21 no filtraría nada y el sistema evaluaría la foto de un test
--    como si fuera una observación real del cultivo.
UPDATE public.cultivo
SET ultima_foto_path = 'a1327127-1570-474a-a49e-6d506b300759/1787251621094.jpg'
WHERE id = 'a1327127-1570-474a-a49e-6d506b300759';

COMMIT;

-- ============================================================================
-- VERIFICACIÓN CONTRA EL ESTADO PERSISTIDO (regla 4)
-- Esperado tras la limpieza: 8 / 8 / 24 / 0 / 220 / y el path del 20/08.
-- ============================================================================
SELECT 'evento_riego'           AS tabla, count(*)::text AS v FROM public.evento_riego
UNION ALL SELECT 'comando_dispositivo',   count(*)::text FROM public.comando_dispositivo
UNION ALL SELECT 'seguimiento_fenologico',count(*)::text FROM public.seguimiento_fenologico
UNION ALL SELECT 'evaluacion_fenologica', count(*)::text FROM public.evaluacion_fenologica
UNION ALL SELECT 'lectura_sensores',      count(*)::text FROM public.lectura_sensores
UNION ALL SELECT 'evento_riego_no_pendiente',
                 count(*)::text FROM public.evento_riego WHERE resultado <> 'pendiente'
UNION ALL SELECT 'ultima_foto_path',
                 ultima_foto_path FROM public.cultivo;

-- ============================================================================
-- PASO MANUAL, DESPUÉS del COMMIT (no va por SQL)
-- ----------------------------------------------------------------------------
-- Borrar el objeto de Storage:
--   fotos-cultivos / a1327127-1570-474a-a49e-6d506b300759/1787589552279.jpg
-- desde el dashboard de Supabase (Storage -> fotos-cultivos).
--
-- Por qué no por SQL: `delete from storage.objects` borra la fila de metadatos,
-- no el archivo del backend de almacenamiento. Queda un objeto huérfano que ya
-- no se puede listar ni borrar por la API. Se borra por la interfaz o por la
-- API de Storage, nunca por la tabla.
--
-- Es cosmético (67 KB, sin referrer una vez borrada la fila de
-- seguimiento_fenologico). Si se deja, no rompe nada — pero solo porque el
-- puntero ya fue revertido en el paso 4.
-- ============================================================================
