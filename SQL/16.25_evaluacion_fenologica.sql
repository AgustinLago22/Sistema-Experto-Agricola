-- ============================================================================
-- 16.25 · Registro de evaluaciones fenológicas + escritura atómica de WF3
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Fecha: 21/08/2026 — sesión 8
--
-- QUÉ RESUELVE
--   16.25  la marca "esta foto ya la miré" se escribía sin garantía de que el
--          avance de etapa se hubiera guardado. Si fallaba, la evidencia
--          quedaba consumida y el avance se perdía para siempre.
--   16.23  UPDATE cultivo + INSERT seguimiento_fenologico eran dos llamadas
--          independientes que debían ocurrir juntas.
--   16.19  seguimiento_fenologico.diagnostico_ia recibía un string concatenado
--          desde WF3 y un objeto desde WF2, en la misma columna jsonb.
--   16.28  etapa_detectada se calculaba y se descartaba.
--   16.21  la deduplicación por foto no cubría el camino del error.
--   16.27  no había ninguna política de terminación para fallos repetidos.
--
-- QUÉ NO TOCA
--   No modifica ni borra ninguna tabla, columna, política ni fila existente.
--   seguimiento_fenologico y cultivo quedan intactos: solo se les escribe
--   desde la función nueva, con la misma forma de siempre.
--
-- CÓMO CORRERLO
--   Pegá el BLOQUE 1, verificá con el BLOQUE 3 (parte A), después el BLOQUE 2
--   y verificá con el BLOQUE 3 (parte B). Si algo falla, no sigas al siguiente.
-- ============================================================================


-- ============================================================================
-- BLOQUE 1 — Tabla, índices y permisos
-- ============================================================================

create table public.evaluacion_fenologica (
  id                         bigint generated always as identity primary key,
  cultivo_id                 uuid        not null references public.cultivo(id) on delete cascade,
  path_foto                  text        not null,
  resultado                  text        not null
    check (resultado in ('avanza','no_avanza','etapa_no_coincide','diagnostico_fallido','agotada')),
  etapas_especie_id_origen   integer     references public.etapas_especie(id),
  etapas_especie_id_destino  integer     references public.etapas_especie(id),
  etapa_detectada            text,
  confianza                  numeric,
  diagnostico                jsonb,
  fecha                      timestamptz not null default now()
);

comment on table public.evaluacion_fenologica is
  'Una fila por cada vez que WF3 evaluó una foto, haya habido cambio de etapa o no. '
  'seguimiento_fenologico sigue siendo la historia clínica (solo transiciones reales); '
  'esta tabla es el registro de intentos, y es lo que permite deduplicar por foto (16.21) '
  'y cortar los reintentos sobre una foto que falla siempre (16.27).';

-- Soporta el conteo de intentos fallidos por foto.
create index ix_evaluacion_cultivo_foto
  on public.evaluacion_fenologica (cultivo_id, path_foto);

-- Clave de idempotencia: una sola evaluación CONCLUYENTE por (cultivo, foto).
-- Los 'diagnostico_fallido' quedan fuera del índice a propósito: son intentos,
-- no conclusiones, y tienen que poder repetirse para poder contarse.
create unique index uq_evaluacion_conclusiva
  on public.evaluacion_fenologica (cultivo_id, path_foto)
  where resultado <> 'diagnostico_fallido';

-- Defensa en profundidad (16.13): RLS activo sin políticas, MÁS el REVOKE
-- explícito, porque las default privileges de Supabase le dan ALL a
-- anon/authenticated sobre toda tabla nueva de public.
alter table public.evaluacion_fenologica enable row level security;
revoke all on table public.evaluacion_fenologica from public, anon, authenticated;
grant  all on table public.evaluacion_fenologica to service_role;


-- ============================================================================
-- BLOQUE 2 — Función transaccional
--
-- Todo lo que escribe WF3 pasa por acá, en UNA sola llamada. Una función
-- plpgsql corre dentro de una transacción implícita: o se aplican todas las
-- escrituras, o no se aplica ninguna. Ese es el punto de 16.25.
--
-- Tabla de decisión:
--   resultado             | evaluación | marca foto | avanza etapa | historia clínica
--   ----------------------|------------|------------|--------------|------------------
--   avanza                |     sí     |     sí     |      sí      |        sí
--   no_avanza             |     sí     |     sí     |      no      |        no
--   etapa_no_coincide     |     sí     |     sí     |      no      |        no
--   diagnostico_fallido   |     sí     |     NO     |      no      |        no
--   agotada (interno)     |     sí     |     sí     |      no      |        no
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

  -- Idempotencia por clave natural (cultivo_id, path_foto). Si esta foto ya
  -- tuvo una evaluación concluyente, la llamada no escribe nada y lo informa.
  -- El índice único parcial es la garantía real ante concurrencia; este SELECT
  -- solo evita el error en el caso normal.
  SELECT id INTO v_existente
  FROM public.evaluacion_fenologica
  WHERE cultivo_id = p_cultivo_id
    AND path_foto  = p_path_foto
    AND resultado <> 'diagnostico_fallido'
  LIMIT 1;

  IF v_existente IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ya_evaluada',   true,
      'evaluacion_id', v_existente,
      'avanzo',        false,
      'foto_marcada',  true,
      'resultado',     'duplicado'
    );
  END IF;

  -- Política de terminación (16.27): fallos repetidos sobre LA MISMA foto.
  -- Un reintento sin tope no es resiliencia, es un bucle. El contador vive acá
  -- porque es el único lugar del sistema que recuerda los intentos.
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

  -- La foto se marca como consumida en todos los casos MENOS mientras se
  -- siga reintentando: un 503 pasajero de Gemini no es culpa de la foto.
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

    -- Historia clínica: el OBJETO completo de diagnóstico, no la prosa
    -- concatenada que WF3 venía guardando (16.19 / 16.28). Con esto vuelve
    -- etapa_detectada, que es la evidencia que B.1 necesita acumular.
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

comment on function public.fn_registrar_evaluacion_fenologica(uuid,text,text,integer,integer,integer,text,numeric,jsonb,integer) is
  'Escritura atómica de una evaluación fenológica de WF3 (16.25). Registra el intento, '
  'marca la foto como evaluada y avanza la etapa, según corresponda, en una sola transacción. '
  'Retry On Fail debe quedar APAGADO en el nodo que la llame: es idempotente para los '
  'resultados concluyentes pero NO para diagnostico_fallido, donde cada reintento consume '
  'presupuesto de intentos.';

-- Mismos criterios de seguridad que fn_registrar_riego (13.5.2 / v30), NO los
-- de fn_registrar_telemetria (B.9): sin SECURITY DEFINER, porque n8n llama con
-- la Secret key (service_role) que ya pasa por encima del RLS; y REVOKE
-- explícito, porque Postgres otorga EXECUTE a PUBLIC por defecto.
revoke all on function public.fn_registrar_evaluacion_fenologica(
  uuid, text, text, integer, integer, integer, text, numeric, jsonb, integer
) from public, anon, authenticated;

grant execute on function public.fn_registrar_evaluacion_fenologica(
  uuid, text, text, integer, integer, integer, text, numeric, jsonb, integer
) to service_role;


-- ============================================================================
-- BLOQUE 3 — Verificación (no modifica nada, se puede correr las veces que sea)
-- ============================================================================

-- ---- Parte A: después del BLOQUE 1 ----------------------------------------
-- Esperado: rls = true, policies = 0, y en relacl NO deben aparecer
-- anon ni authenticated (solo postgres y service_role).
select c.relname,
       c.relrowsecurity as rls,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as policies,
       c.relacl::text
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'evaluacion_fenologica';

-- Esperado: los 2 índices + la PK.
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'evaluacion_fenologica'
order by indexname;


-- ---- Parte B: después del BLOQUE 2 ----------------------------------------
-- Esperado: prosecdef = false  y  proacl = {postgres=X/postgres,service_role=X/postgres}
-- Si aparece "=X/postgres" suelto (que significa PUBLIC), el REVOKE no corrió.
select p.proname,
       p.prosecdef,
       p.proacl::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'fn_registrar_evaluacion_fenologica';
