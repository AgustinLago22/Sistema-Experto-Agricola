-- ############################################################################
-- ##  DESCARTADO el 05/10/2026 (plan v56). NO APLICAR.                       ##
-- ##  Se conserva como registro de lo que se evaluó y por qué se rechazó.    ##
-- ##                                                                         ##
-- ##  Motivo: el defecto solo es alcanzable por intervención manual, y el    ##
-- ##  fix agregaba código para defender una redundancia. La marca            ##
-- ##  ultima_foto_evaluada_path es un caché de "¿existe una evaluación no    ##
-- ##  fallida para esta foto?". La solución de fondo es derivarla y quitar   ##
-- ##  la columna (una sola fuente de verdad), no mantenerla sincronizada.    ##
-- ##  Regla vigente: para reevaluar, foto nueva; la marca no se toca a mano. ##
-- ##  Verificado al descartar: la función conserva el md5 58e3d114… .        ##
-- ############################################################################
-- ============================================================================
-- Sesión 14 · Fix: el camino `duplicado` de fn_registrar_evaluacion_fenologica
--             afirma `foto_marcada: true` sin marcar la foto
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 01/10/2026 contra la función vigente
--   (md5 de pg_get_functiondef = 58e3d114c35af00df40d3ca2cb616d41).
-- Hallazgo SIN NÚMERO (lo asigna el registro). Detalle en el plan, al final de
-- Fase 16, y en el changelog v53.
--
-- EL DEFECTO
--   Si ya existe una evaluación con la misma (cultivo_id, path_foto), la
--   función devuelve temprano con `foto_marcada: true` pero NO ejecuta ningún
--   UPDATE. Si `cultivo.ultima_foto_evaluada_path` quedó desincronizada (hoy
--   solo por intervención manual, como el 23/09), WF3 vuelve a mandar la misma
--   foto a Gemini cada 8 h y recibe siempre `duplicado`, sin señal.
--   El contrato se cumple en FORMA (7 claves) y se rompe en CONTENIDO.
--
-- EL FIX
--   El camino `duplicado` hace lo que dice: re-marca la foto, pero SOLO si
--   sigue siendo la última del cultivo (si entre la descarga y la RPC llegó una
--   foto nueva por WF1, marcar la vieja sería pisar el cursor hacia atrás).
--   `foto_marcada` pasa a informar el ESTADO REAL al volver: true solo si
--   `ultima_foto_evaluada_path = p_path_foto`. Un valor fijo era una afirmación;
--   ahora es una lectura.
--   El resto de la función queda idéntico.
--
-- ORDEN
--   BLOQUE 1 (ejercer el defecto ANTES del fix: un fix aplicado antes del test
--   convierte al test en una tautología) → BLOQUE 2 (fix) → BLOQUE 3 (test
--   después del fix, dos casos) → BLOQUE 4 (verificar estado final).
--   Correr de a un bloque. Si algo no da lo esperado, parar y avisar.
-- ============================================================================


-- ============================================================================
-- BLOQUE 1 — Ejercer el defecto con la función VIEJA
-- ============================================================================
-- Reproduce la condición del 23/09: la foto actual ya fue evaluada (evaluación
-- 13) pero la marca está limpia.
update cultivo set ultima_foto_evaluada_path = null
 where id = 'a1327127-1570-474a-a49e-6d506b300759';

select public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id => 'a1327127-1570-474a-a49e-6d506b300759'::uuid,
  p_path_foto  => 'a1327127-1570-474a-a49e-6d506b300759/1790896237301.jpg',
  p_resultado  => 'no_avanza'
) as respuesta,
(select ultima_foto_evaluada_path from cultivo
  where id = 'a1327127-1570-474a-a49e-6d506b300759') as marca_despues;
-- Esperado (DEFECTO): respuesta con "resultado": "duplicado" y
-- "foto_marcada": true, pero marca_despues = NULL. Ahí está la mentira.
-- La marca se deja en NULL a propósito: el BLOQUE 3 verifica que el fix la repone.


-- ============================================================================
-- BLOQUE 2 — El fix (CREATE OR REPLACE conserva los privilegios; igual se
-- reaplican REVOKE y GRANT, que son idempotentes)
-- ============================================================================
create or replace function public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id                uuid,
  p_path_foto                 text,
  p_resultado                 text,
  p_etapas_especie_id_origen  integer default null,
  p_etapas_especie_id_destino integer default null,
  p_etapa_destino_id          integer default null,
  p_etapa_detectada           text    default null,
  p_confianza                 numeric default null,
  p_diagnostico               jsonb   default null,
  p_max_intentos              integer default 3
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  v_evaluacion_id  bigint;
  v_seguimiento_id uuid;
  v_existente      bigint;
  v_fallidos       integer := 0;
  v_resultado      text    := p_resultado;
  v_avanzo         boolean := false;
  v_marca_foto     boolean;
BEGIN
  -- Precondiciones. Fallar fuerte es preferible a escribir una fila que miente.
  IF p_cultivo_id IS NULL OR coalesce(p_path_foto, '') = '' THEN
    RAISE EXCEPTION 'fn_registrar_evaluacion_fenologica: cultivo_id y path_foto son obligatorios';
  END IF;

  IF v_resultado NOT IN ('avanza','no_avanza','etapa_no_coincide','diagnostico_fallido') THEN
    RAISE EXCEPTION 'fn_registrar_evaluacion_fenologica: resultado invalido (%)', v_resultado;
  END IF;

  IF v_resultado = 'avanza'
     AND (p_etapa_destino_id IS NULL OR p_etapas_especie_id_destino IS NULL) THEN
    RAISE EXCEPTION 'fn_registrar_evaluacion_fenologica: avanzar exige etapa destino completa';
  END IF;

  -- Idempotencia por clave natural (cultivo_id, path_foto).
  SELECT id INTO v_existente
  FROM public.evaluacion_fenologica
  WHERE cultivo_id = p_cultivo_id
    AND path_foto  = p_path_foto
    AND resultado <> 'diagnostico_fallido'
  LIMIT 1;

  IF v_existente IS NOT NULL THEN
    -- Fix (sesión 14): la foto ya tiene una conclusión, así que corresponde
    -- que esté marcada. Se re-marca solo si sigue siendo la última foto del
    -- cultivo: si llegó una más nueva, marcar ésta movería el cursor hacia atrás.
    UPDATE public.cultivo
       SET ultima_foto_evaluada_path = p_path_foto
     WHERE id = p_cultivo_id
       AND ultima_foto_path = p_path_foto
       AND ultima_foto_evaluada_path IS DISTINCT FROM p_path_foto;

    -- `foto_marcada` informa el estado real al volver, no una constante.
    SELECT coalesce(ultima_foto_evaluada_path = p_path_foto, false)
      INTO v_marca_foto
      FROM public.cultivo
     WHERE id = p_cultivo_id;

    -- Contrato de salida uniforme: las MISMAS 7 claves que el camino normal.
    RETURN jsonb_build_object(
      'ya_evaluada',       true,
      'evaluacion_id',     v_existente,
      'seguimiento_id',    null::uuid,
      'avanzo',            false,
      'foto_marcada',      coalesce(v_marca_foto, false),
      'resultado',         'duplicado',
      'intentos_fallidos', null::integer
    );
  END IF;

  -- Política de terminación (16.27): fallos repetidos sobre LA MISMA foto.
  IF v_resultado = 'diagnostico_fallido' THEN
    SELECT count(*) INTO v_fallidos
    FROM public.evaluacion_fenologica
    WHERE cultivo_id = p_cultivo_id
      AND path_foto  = p_path_foto
      AND resultado  = 'diagnostico_fallido';

    IF v_fallidos + 1 >= p_max_intentos THEN
      v_resultado := 'agotada';
    END IF;
  END IF;

  v_marca_foto := (v_resultado <> 'diagnostico_fallido');

  INSERT INTO public.evaluacion_fenologica (
    cultivo_id, path_foto, resultado,
    etapas_especie_id_origen, etapas_especie_id_destino,
    etapa_detectada, confianza, diagnostico
  ) VALUES (
    p_cultivo_id, p_path_foto, v_resultado,
    p_etapas_especie_id_origen, p_etapas_especie_id_destino,
    p_etapa_detectada, p_confianza, p_diagnostico
  )
  RETURNING id INTO v_evaluacion_id;

  IF v_resultado = 'avanza' THEN

    UPDATE public.cultivo
       SET etapa_actual_id           = p_etapa_destino_id,
           fecha_inicio_etapa        = now(),
           ultima_foto_evaluada_path = p_path_foto
     WHERE id = p_cultivo_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_registrar_evaluacion_fenologica: cultivo % inexistente', p_cultivo_id;
    END IF;

    INSERT INTO public.seguimiento_fenologico (
      cultivo_id, path_foto, diagnostico_ia, confianza_ia, etapas_especie_id
    ) VALUES (
      p_cultivo_id, p_path_foto, p_diagnostico,
      p_confianza::double precision, p_etapas_especie_id_destino
    )
    RETURNING id INTO v_seguimiento_id;

    v_avanzo := true;

  ELSIF v_marca_foto THEN

    UPDATE public.cultivo
       SET ultima_foto_evaluada_path = p_path_foto
     WHERE id = p_cultivo_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_registrar_evaluacion_fenologica: cultivo % inexistente', p_cultivo_id;
    END IF;

  END IF;

  RETURN jsonb_build_object(
    'ya_evaluada',       false,
    'evaluacion_id',     v_evaluacion_id,
    'seguimiento_id',    v_seguimiento_id,
    'avanzo',            v_avanzo,
    'foto_marcada',      v_marca_foto,
    'resultado',         v_resultado,
    'intentos_fallidos', v_fallidos + CASE WHEN v_resultado IN ('diagnostico_fallido','agotada') THEN 1 ELSE 0 END
  );
END;
$function$;

revoke all on function public.fn_registrar_evaluacion_fenologica(
  uuid, text, text, integer, integer, integer, text, numeric, jsonb, integer
) from public, anon, authenticated;

grant execute on function public.fn_registrar_evaluacion_fenologica(
  uuid, text, text, integer, integer, integer, text, numeric, jsonb, integer
) to service_role;


-- ============================================================================
-- BLOQUE 3 — Test DESPUÉS del fix (dos casos que pueden fallar)
-- ============================================================================
-- Caso A · la foto duplicada ES la última → se re-marca.
select public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id => 'a1327127-1570-474a-a49e-6d506b300759'::uuid,
  p_path_foto  => 'a1327127-1570-474a-a49e-6d506b300759/1790896237301.jpg',
  p_resultado  => 'no_avanza'
) as respuesta,
(select ultima_foto_evaluada_path from cultivo
  where id = 'a1327127-1570-474a-a49e-6d506b300759') as marca_despues;
-- Esperado: "duplicado", "foto_marcada": true, evaluacion_id 13,
-- y marca_despues = '…/1790896237301.jpg' (YA NO NULL).

-- Caso B · la foto duplicada es VIEJA (la del 23/09, evaluación 12) → NO se
-- re-marca, y la respuesta lo dice.
select public.fn_registrar_evaluacion_fenologica(
  p_cultivo_id => 'a1327127-1570-474a-a49e-6d506b300759'::uuid,
  p_path_foto  => 'a1327127-1570-474a-a49e-6d506b300759/1790205442303.jpg',
  p_resultado  => 'no_avanza'
) as respuesta,
(select ultima_foto_evaluada_path from cultivo
  where id = 'a1327127-1570-474a-a49e-6d506b300759') as marca_despues;
-- Esperado: "duplicado", "foto_marcada": false, evaluacion_id 12,
-- y marca_despues SIGUE en '…/1790896237301.jpg' (el cursor no retrocedió).


-- ============================================================================
-- BLOQUE 4 — Estado final (tiene que quedar igual que antes del test)
-- ============================================================================
select ultima_foto_path = ultima_foto_evaluada_path as foto_marcada,   -- true
       etapa_actual_id,                                                -- 6
       fecha_inicio_etapa,                              -- 2026-09-23 23:18:15.868662+00
       (select count(*) from evaluacion_fenologica)  as evaluaciones,  -- 3 (sin filas nuevas)
       (select count(*) from seguimiento_fenologico) as seguimientos   -- 25
from cultivo where id = 'a1327127-1570-474a-a49e-6d506b300759';

-- Si el caso A falló y la marca quedó en NULL, restaurarla a mano:
--   update cultivo set ultima_foto_evaluada_path = ultima_foto_path
--    where id = 'a1327127-1570-474a-a49e-6d506b300759';
