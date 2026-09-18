-- ============================================================================
-- SESIÓN 10 — Limpieza de los residuos del test del batch de WF1
-- Fecha: 31/08/2026
-- ============================================================================
-- El test verificó 16.34 (lectura parcial sin pH) y de paso ejercitó el camino
-- completo de la foto, porque se mandó `foto_base64`. Dejó CUATRO rastros.
--
-- No hay evento_riego ni comando_dispositivo que borrar: humedad 55 está dentro
-- del rango 50-65, así que `hay_sequia` quedó en false y WF5 nunca se disparó.
-- Verificado: evento_riego sigue en 8 filas, todas 'pendiente'.
--
-- ORDEN: el puntero de la foto se revierte ANTES de borrar el objeto de Storage
-- (paso manual al final). Al revés queda una ventana donde ultima_foto_path
-- apunta a un objeto inexistente, que es el escenario de B.10.
-- ============================================================================

BEGIN;

-- 1) Diagnóstico que escribió WF2 sobre la foto del test (20:24:45 UTC).
DELETE FROM public.seguimiento_fenologico
WHERE id = '3d6b5fab-a161-40f9-8621-e3f45d8e558f';

-- 2) Telemetría del test. lectura_sensores es formato largo: una fila por
--    métrica. Acá son CUATRO y no cinco, y esa es justamente la evidencia de
--    que 16.34 quedó cerrado — el pH ausente ya no rompe el pedido entero,
--    simplemente no genera fila.
DELETE FROM public.lectura_sensores WHERE id BETWEEN 276 AND 279;

-- 3) Revertir el puntero de la foto a la última foto real previa (20/08).
UPDATE public.cultivo
SET ultima_foto_path = 'a1327127-1570-474a-a49e-6d506b300759/1787251621094.jpg'
WHERE id = 'a1327127-1570-474a-a49e-6d506b300759';

COMMIT;

-- ============================================================================
-- VERIFICACIÓN CONTRA EL ESTADO PERSISTIDO (regla 4)
-- Esperado tras la limpieza: 8 / 8 / 24 / 0 / 220 / y el path del 20/08.
-- ============================================================================
SELECT 'evento_riego'            AS tabla, count(*)::text AS v FROM public.evento_riego
UNION ALL SELECT 'comando_dispositivo',    count(*)::text FROM public.comando_dispositivo
UNION ALL SELECT 'seguimiento_fenologico', count(*)::text FROM public.seguimiento_fenologico
UNION ALL SELECT 'evaluacion_fenologica',  count(*)::text FROM public.evaluacion_fenologica
UNION ALL SELECT 'lectura_sensores',       count(*)::text FROM public.lectura_sensores
UNION ALL SELECT 'evento_riego_no_pendiente',
                 count(*)::text FROM public.evento_riego WHERE resultado <> 'pendiente'
UNION ALL SELECT 'ultima_foto_path',       ultima_foto_path FROM public.cultivo;

-- ============================================================================
-- PASO MANUAL, DESPUÉS del COMMIT (no va por SQL)
-- ----------------------------------------------------------------------------
-- Borrar el objeto de Storage:
--   fotos-cultivos / a1327127-1570-474a-a49e-6d506b300759/1788207853114.jpg
-- desde el dashboard de Supabase (Storage -> fotos-cultivos).
--
-- Por qué no por SQL: `delete from storage.objects` borra la fila de metadatos,
-- no el archivo del backend. Queda un objeto huérfano que ya no se puede listar
-- ni borrar por la API. (Criterio heredado de sesion9_limpieza_residuos.sql.)
-- ============================================================================
