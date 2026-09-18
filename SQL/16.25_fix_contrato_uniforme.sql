-- ============================================================================
-- 16.25 · Fix de contrato de salida uniforme en fn_registrar_evaluacion_fenologica
-- Fecha: 23/08/2026 — sesión 8
--
-- QUÉ CORRIGE
--   El RETURN temprano de la rama "ya evaluada" devolvía 5 claves mientras el
--   camino normal devuelve 7: faltaban `seguimiento_id` e `intentos_fallidos`.
--   Detectado al ejecutar la prueba de idempotencia del BLOQUE 3.
--
--   Es el mismo defecto que 13.3.3 Bug 4: un return temprano que no emite
--   todos los campos del contrato, en la rama menos transitada. Un consumidor
--   que lea una clave ausente recibe `undefined`, y con typeValidation: strict
--   eso es un error de tipo justo en el caso raro.
--
--   `null` en vez de 0 para intentos_fallidos es deliberado: en este camino no
--   se contó nada, y 0 afirmaría "cero fallos", que no es lo mismo que "no
--   corresponde". Un valor por defecto plausible es peor que un nulo honesto.
--
-- CÓMO CORRERLO
--   Es un CREATE OR REPLACE: reemplaza la función completa y preserva los
--   permisos. Igual se vuelven a aplicar el REVOKE y el GRANT al final, que
--   son idempotentes. No toca la tabla ni ningún dato.
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
set search_path = public
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
    -- Contrato de salida uniforme: las MISMAS 7 claves que el camino normal.
    RETURN jsonb_build_object(
      'ya_evaluada',       true,
      'evaluacion_id',     v_existente,
      'seguimiento_id',    null::uuid,
      'avanzo',            false,
      'foto_marcada',      true,
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
-- Verificación: el camino "duplicado" ahora tiene que devolver 7 claves.
-- Correr ANTES del BLOQUE 4 del test, mientras la fila id=1 todavía existe.
-- ============================================================================
select
  jsonb_object_keys_count.cant as claves,
  r as respuesta
from (
  select public.fn_registrar_evaluacion_fenologica(
    p_cultivo_id => 'a1327127-1570-474a-a49e-6d506b300759'::uuid,
    p_path_foto  => 'a1327127-1570-474a-a49e-6d506b300759/1787251621094.jpg',
    p_resultado  => 'no_avanza'
  ) as r
) t,
lateral (select count(*) as cant from jsonb_object_keys(t.r)) jsonb_object_keys_count;

-- Esperado: claves = 7, y en la respuesta seguimiento_id e intentos_fallidos
-- presentes con valor null.
