-- ============================================================================
-- Sesión 16 · Cierre del lazo de riego: recheck (13.7.1) + tope duro (16.46)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 16/10/2026 contra el estado verificado ese día.
--
-- QUÉ CAMBIA (no toca ninguna tabla ni ningún dato)
--   1. `vista_ultimo_riego` agrega 7 columnas AL FINAL (las 6 actuales quedan
--      iguales, así que WF1 y WF5 viejos siguen andando):
--        evento_id, fecha_recheck, humedad_recheck, comando_estado,
--        absorcion_completa (>= 15 min), recheck_vencido (> 60 min),
--        humedad_max_posterior (máxima humedad leída después del recheck).
--      Los dos tiempos viven ACÁ y en ningún otro lado: el cooldown de WF5 y el
--      recheck del Motor leen la misma definición.
--   2. `fn_registrar_riego` gana el TOPE DURO (16.46): no más de 4 riegos
--      automáticos por cultivo en 6 h. Si se alcanza, NO crea comando ni evento
--      y devuelve `registrado = false, motivo = 'tope_alcanzado'`.
--      Bloquea la fila del cultivo (FOR UPDATE): dos ejecuciones simultáneas de
--      WF5 no pueden pasar las dos el conteo.
--      Cambia el tipo de retorno → hace falta DROP + CREATE (mismos parámetros).
--   3. `fn_registrar_recheck_riego` (nueva): guarda la conclusión del recheck
--      que calculó el Motor. Solo cierra un evento `pendiente` del mismo cultivo
--      → es idempotente y se puede reintentar.
--
-- POR QUÉ EL TOPE VA EN LA BASE Y NO EN WF5
--   Es la última barrera antes de que exista la orden. No depende de n8n, ni de
--   que lleguen lecturas, ni del recheck: es un interlock, no realimentación.
--   Mismo argumento que el CHECK (duracion_segundos <= 30) de 13.1 y que 16.25:
--   lo que tiene que valer siempre se garantiza en la base, no con un IF.
--
-- NÚMEROS SIN PROCEDENCIA (Fase 17): 4 riegos / 6 h, 15 min de absorción y
-- 60 min de vencimiento del recheck. Salen del piloto con hardware (B3).
--
-- ORDEN DE APLICACIÓN (cada paso deja el sistema andando)
--   BLOQUE 1 (este script) → WF5 → WF1. Ver docs/implementation_plan.md, 13.7.2.
--   BLOQUE 2 verifica. BLOQUE 3 es un test que se deshace solo.
--   BLOQUE R es el reverso: solo si hay que volver atrás (primero revertir n8n).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo, registrado el 16/10 (no hace falta correrlo)
-- ============================================================================
-- evento_riego 8 filas (ids 3–10), las 8 'pendiente', la última del 20/08.
-- comando_dispositivo 8 filas (ids 3–10), las 8 'pendiente'.
-- lectura_sensores 230 filas (max id 289), última 01/10 23:10 UTC.
-- CHECK evento_riego.resultado IN ('exitoso','insuficiente','pendiente','fallo_sistema')
--   → ya acepta los tres resultados del recheck. No hace falta tocar la tabla.
-- cultivo a1327127: volumen_maceta_litros 20 · dispositivo 3581a79d:
--   tiene_actuador_riego true, caudal_bomba_ml_s 40.
--
-- Definición previa de la vista (para el reverso):
--   SELECT DISTINCT ON (cultivo_id) cultivo_id, fecha_inicio, resultado,
--          humedad_inicial, humedad_objetivo, duracion_segundos
--     FROM evento_riego ORDER BY cultivo_id, fecha_inicio DESC;
-- Definición previa de fn_registrar_riego: la de 13.5.3 (está copiada en el BLOQUE R).
-- ACL previa: postgres=X, service_role=X. Sin SECURITY DEFINER.


-- ============================================================================
-- BLOQUE 1 — Aplicar (todo o nada)
-- ============================================================================
begin;

-- 1a · La vista ------------------------------------------------------------
create or replace view public.vista_ultimo_riego as
select distinct on (e.cultivo_id)
       -- las 6 columnas de siempre, en el mismo orden
       e.cultivo_id,
       e.fecha_inicio,
       e.resultado,
       e.humedad_inicial,
       e.humedad_objetivo,
       e.duracion_segundos,
       -- nuevas (al final: CREATE OR REPLACE VIEW solo permite agregar al final)
       e.id                                              as evento_id,
       e.fecha_recheck,
       e.humedad_recheck,
       c.estado                                          as comando_estado,
       (now() - e.fecha_inicio) >= interval '15 minutes' as absorcion_completa,
       (now() - e.fecha_inicio) >  interval '60 minutes' as recheck_vencido,
       (select max(l.valor)
          from public.lectura_sensores l
         where l.cultivo_id = e.cultivo_id
           and l.metrica_id = 1                -- Humedad
           and l.fecha_hora > e.fecha_recheck) as humedad_max_posterior
  from public.evento_riego e
  left join public.comando_dispositivo c on c.id = e.comando_id
 order by e.cultivo_id, e.fecha_inicio desc, e.id desc;

comment on view public.vista_ultimo_riego is
  'Último riego por cultivo. absorcion_completa (15 min) y recheck_vencido (60 min) son la ÚNICA definición de esos tiempos: la leen el cooldown de WF5 y el recheck del Motor de WF1 (13.7.2). humedad_max_posterior sirve para el rearme por evidencia del freno.';

-- 1b · fn_registrar_riego con tope duro -----------------------------------
drop function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric);

create function public.fn_registrar_riego(
  p_cultivo_id        uuid,
  p_dispositivo_id    uuid,
  p_duracion_segundos integer,
  p_humedad_inicial   numeric,
  p_humedad_objetivo  numeric,
  p_dosis_ml          numeric
)
returns table (
  comando_id        bigint,
  evento_id         bigint,
  registrado        boolean,
  motivo            text,
  riegos_en_ventana integer,
  max_riegos        integer,
  ventana_horas     integer   -- horas enteras: es para el mensaje de Telegram
)
language plpgsql
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  -- 16.46 · tope duro. Sin procedencia todavía: sale del piloto con hardware (B3).
  c_max_riegos constant integer  := 4;
  c_ventana    constant interval := interval '6 hours';
  v_recientes  integer;
  v_comando_id bigint;
  v_evento_id  bigint;
begin
  -- Serializa los riegos de UN cultivo: si dos ejecuciones de WF5 llegan a la
  -- vez, la segunda espera acá y después cuenta el riego de la primera.
  perform 1 from public.cultivo where id = p_cultivo_id for update;
  if not found then
    raise exception 'fn_registrar_riego: el cultivo % no existe', p_cultivo_id;
  end if;

  -- Se cuentan TODOS los riegos automáticos de la ventana, sin mirar su
  -- resultado: el tope tiene que cortar aunque el recheck no haya ocurrido.
  select count(*) into v_recientes
    from public.evento_riego e
   where e.cultivo_id    = p_cultivo_id
     and e.disparado_por = 'automatico'
     and e.fecha_inicio  > now() - c_ventana;

  if v_recientes >= c_max_riegos then
    return query select null::bigint, null::bigint, false, 'tope_alcanzado'::text,
                        v_recientes, c_max_riegos,
                        (extract(epoch from c_ventana) / 3600)::integer;
    return;
  end if;

  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos)
  values (p_dispositivo_id, 'ACTIVAR_RIEGO', p_duracion_segundos)
  returning id into v_comando_id;

  insert into public.evento_riego (
    cultivo_id, dispositivo_id, comando_id,
    humedad_inicial, humedad_objetivo, dosis_ml, duracion_segundos
  )
  values (
    p_cultivo_id, p_dispositivo_id, v_comando_id,
    p_humedad_inicial, p_humedad_objetivo, p_dosis_ml, p_duracion_segundos
  )
  returning id into v_evento_id;

  return query select v_comando_id, v_evento_id, true, 'registrado'::text,
                      v_recientes + 1, c_max_riegos,
                      (extract(epoch from c_ventana) / 3600)::integer;
end;
$$;

-- Postgres le da EXECUTE a PUBLIC al crear cualquier función: hay que revocarlo.
revoke all on function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric)
  from public, anon, authenticated;
grant execute on function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric)
  to service_role;

comment on function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric) is
  'Comando + evento de riego en una transacción (13.5.3), con tope duro de 4 riegos automáticos por cultivo en 6 h (16.46). Si se alcanza el tope no escribe nada y devuelve registrado=false.';

-- 1c · fn_registrar_recheck_riego (nueva) -----------------------------------
create function public.fn_registrar_recheck_riego(
  p_cultivo_id uuid,
  p_evento_id  bigint,
  p_humedad    numeric,
  p_resultado  text
)
returns table (cerrado boolean, motivo text)
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- WF1 llama en CADA lectura. Sin recheck en esta lectura, no hace nada.
  if p_evento_id is null then
    return query select false, 'sin_recheck'::text;
    return;
  end if;

  if p_resultado is null or p_resultado not in ('exitoso', 'insuficiente', 'fallo_sistema') then
    raise exception 'fn_registrar_recheck_riego: resultado inválido (%)', p_resultado;
  end if;
  if p_humedad is null then
    raise exception 'fn_registrar_recheck_riego: falta la humedad del recheck (evento %)', p_evento_id;
  end if;

  -- Solo se cierra un evento PENDIENTE del MISMO cultivo. Eso lo hace idempotente:
  -- un reintento no pisa una conclusión ya escrita.
  update public.evento_riego
     set resultado       = p_resultado,
         humedad_recheck = p_humedad,
         fecha_recheck   = now()
   where id         = p_evento_id
     and cultivo_id = p_cultivo_id
     and resultado  = 'pendiente';

  if found then
    return query select true, 'cerrado'::text;
    return;
  end if;

  if exists (select 1 from public.evento_riego where id = p_evento_id and cultivo_id = p_cultivo_id) then
    -- Ya tenía conclusión (reintento). Se informa la verdad: no se cerró ahora.
    return query select false, 'ya_cerrado'::text;
    return;
  end if;

  raise exception 'fn_registrar_recheck_riego: el evento % no existe o no es del cultivo %',
    p_evento_id, p_cultivo_id;
end;
$$;

revoke all on function public.fn_registrar_recheck_riego(uuid, bigint, numeric, text)
  from public, anon, authenticated;
grant execute on function public.fn_registrar_recheck_riego(uuid, bigint, numeric, text)
  to service_role;

comment on function public.fn_registrar_recheck_riego(uuid, bigint, numeric, text) is
  'Guarda la conclusión del recheck de riego que calcula el Motor de WF1 (13.7.2). Solo cierra eventos pendientes del mismo cultivo: idempotente.';

commit;


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura)
-- ============================================================================
-- Esperado: dos filas, prosecdef = false, ACL = {postgres=X/postgres,service_role=X/postgres}
select p.proname, pg_get_function_result(p.oid) as retorno, p.prosecdef, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('fn_registrar_riego', 'fn_registrar_recheck_riego');

-- Esperado: la fila del cultivo con evento_id 10, resultado 'pendiente',
-- comando_estado 'pendiente', absorcion_completa true, recheck_vencido true,
-- humedad_max_posterior null. Y los conteos sin cambios: 8 · 8 · 230.
select v.*,
       (select count(*) from evento_riego)        as eventos,
       (select count(*) from comando_dispositivo) as comandos,
       (select count(*) from lectura_sensores)    as lecturas
  from vista_ultimo_riego v;


-- ============================================================================
-- BLOQUE 3 — Test en la base. SE DESHACE SOLO.
-- ============================================================================
-- Termina SIEMPRE con un error, a propósito: el error deshace todo lo que el
-- test escribió. Leé el TEXTO del error:
--   'TEST OK: ...'     → pasó.
--   'TEST FALLÓ: ...'  → no pasó, y dice qué.
--   'PRECONDICIÓN: ...'→ no se pudo probar (hay riegos reales en la ventana).
-- Después de correrlo, el BLOQUE 2 tiene que seguir dando 8 · 8 · 230.
-- ============================================================================
do $$
declare
  v_cultivo   constant uuid := 'a1327127-1570-474a-a49e-6d506b300759';
  v_disp      constant uuid := '3581a79d-75a0-4116-b924-13444b4bdb85';
  v_max_antes bigint;
  v_cmds      integer;
  v_ev        bigint;
  v_falla     boolean;
  r           record;
  v           record;
  i           integer;
begin
  if exists (select 1 from evento_riego
              where cultivo_id = v_cultivo and fecha_inicio > now() - interval '6 hours') then
    raise exception 'PRECONDICIÓN: hay riegos en las últimas 6 h; el test del tope no sería concluyente';
  end if;
  select coalesce(max(id), 0) into v_max_antes from comando_dispositivo;

  -- T1 · El tope: los riegos 1 a 4 pasan, el 5º no, y el 5º no deja comando.
  for i in 1..5 loop
    select * into r from fn_registrar_riego(v_cultivo, v_disp, 10, 50, 67.5, 400);
    if i <= 4 and (r.registrado is not true or r.comando_id is null or r.riegos_en_ventana <> i) then
      raise exception 'TEST FALLÓ (T1): el riego % debía registrarse → %', i, to_json(r);
    end if;
    if i = 5 and (r.registrado is not false or r.motivo <> 'tope_alcanzado'
                  or r.comando_id is not null or r.riegos_en_ventana <> 4) then
      raise exception 'TEST FALLÓ (T1): el 5º riego debía frenarse → %', to_json(r);
    end if;
  end loop;
  select count(*) into v_cmds from comando_dispositivo where id > v_max_antes;
  if v_cmds <> 4 then
    raise exception 'TEST FALLÓ (T1): se esperaban 4 comandos nuevos y hay %', v_cmds;
  end if;

  -- T2 · La ventana se desliza: con los 4 riegos movidos 7 h atrás, vuelve a regar.
  update evento_riego set fecha_inicio = fecha_inicio - interval '7 hours'
   where cultivo_id = v_cultivo and comando_id > v_max_antes;
  select * into r from fn_registrar_riego(v_cultivo, v_disp, 10, 50, 67.5, 400);
  if r.registrado is not true or r.riegos_en_ventana <> 1 then
    raise exception 'TEST FALLÓ (T2): fuera de la ventana debía registrar → %', to_json(r);
  end if;
  v_ev := r.evento_id;

  -- T3 · La vista: recién regado → sin absorción; a 20 min → absorción sin vencer;
  --      a 70 min → vencido. Son los dos tiempos que leen WF5 y el Motor.
  select * into v from vista_ultimo_riego where cultivo_id = v_cultivo;
  if v.evento_id <> v_ev or v.resultado <> 'pendiente' or v.comando_estado <> 'pendiente'
     or v.absorcion_completa is not false or v.recheck_vencido is not false then
    raise exception 'TEST FALLÓ (T3): vista recién regado → %', to_json(v);
  end if;
  update evento_riego set fecha_inicio = now() - interval '70 minutes' where id = v_ev;
  select * into v from vista_ultimo_riego where cultivo_id = v_cultivo;
  if v.absorcion_completa is not true or v.recheck_vencido is not true then
    raise exception 'TEST FALLÓ (T3): vista a 70 min → %', to_json(v);
  end if;
  update evento_riego set fecha_inicio = now() - interval '20 minutes' where id = v_ev;
  select * into v from vista_ultimo_riego where cultivo_id = v_cultivo;
  if v.absorcion_completa is not true or v.recheck_vencido is not false then
    raise exception 'TEST FALLÓ (T3): vista a 20 min → %', to_json(v);
  end if;

  -- T4 · El recheck: sin evento no hace nada; cierra un pendiente una sola vez.
  select * into r from fn_registrar_recheck_riego(v_cultivo, null, null, null);
  if r.cerrado is not false or r.motivo <> 'sin_recheck' then
    raise exception 'TEST FALLÓ (T4): sin evento debía ser no-op → %', to_json(r);
  end if;
  select * into r from fn_registrar_recheck_riego(v_cultivo, v_ev, 51, 'fallo_sistema');
  if r.cerrado is not true then
    raise exception 'TEST FALLÓ (T4): debía cerrar el evento → %', to_json(r);
  end if;
  select * into r from fn_registrar_recheck_riego(v_cultivo, v_ev, 70, 'exitoso');
  if r.cerrado is not false or r.motivo <> 'ya_cerrado' then
    raise exception 'TEST FALLÓ (T4): el reintento no debía pisar la conclusión → %', to_json(r);
  end if;
  select * into v from vista_ultimo_riego where cultivo_id = v_cultivo;
  if v.resultado <> 'fallo_sistema' or v.humedad_recheck <> 51 or v.fecha_recheck is null then
    raise exception 'TEST FALLÓ (T4): la vista no muestra la conclusión → %', to_json(v);
  end if;

  -- T5 · Lo que tiene que fallar, falla: otro cultivo y resultado inválido.
  v_falla := false;
  begin
    perform fn_registrar_recheck_riego(gen_random_uuid(), v_ev, 60, 'exitoso');
  exception when others then v_falla := true;
  end;
  if not v_falla then raise exception 'TEST FALLÓ (T5): aceptó cerrar un evento de otro cultivo'; end if;
  v_falla := false;
  begin
    perform fn_registrar_recheck_riego(v_cultivo, v_ev, 60, 'pendiente');
  exception when others then v_falla := true;
  end;
  if not v_falla then raise exception 'TEST FALLÓ (T5): aceptó un resultado inválido'; end if;

  -- T6 · Rearme por evidencia: una lectura húmeda POSTERIOR al recheck aparece en la vista.
  if v.humedad_max_posterior is not null then
    raise exception 'TEST FALLÓ (T6): antes de la lectura húmeda debía ser null → %', to_json(v);
  end if;
  insert into lectura_sensores (dispositivo_id, metrica_id, valor, fecha_hora, cultivo_id)
  values (v_disp, 1, 70, now() + interval '1 second', v_cultivo);
  select * into v from vista_ultimo_riego where cultivo_id = v_cultivo;
  if v.humedad_max_posterior is distinct from 70 then
    raise exception 'TEST FALLÓ (T6): humedad_max_posterior debía ser 70 → %', to_json(v);
  end if;

  raise exception 'TEST OK: tope (4/6 h, ventana deslizante), vista, recheck idempotente y rearme. Este error es A PROPÓSITO: deshace todos los datos de prueba.';
end;
$$;


-- ============================================================================
-- BLOQUE R — Reverso. Solo si hay que volver atrás, y DESPUÉS de revertir WF1 y WF5.
-- ============================================================================
-- begin;
-- drop function public.fn_registrar_recheck_riego(uuid, bigint, numeric, text);
-- drop function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric);
-- create function public.fn_registrar_riego(
--   p_cultivo_id uuid, p_dispositivo_id uuid, p_duracion_segundos integer,
--   p_humedad_inicial numeric, p_humedad_objetivo numeric, p_dosis_ml numeric)
-- returns table (comando_id bigint, evento_id bigint)
-- language plpgsql as $$
-- declare v_comando_id bigint; v_evento_id bigint;
-- begin
--   insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos)
--   values (p_dispositivo_id, 'ACTIVAR_RIEGO', p_duracion_segundos) returning id into v_comando_id;
--   insert into public.evento_riego (cultivo_id, dispositivo_id, comando_id,
--     humedad_inicial, humedad_objetivo, dosis_ml, duracion_segundos)
--   values (p_cultivo_id, p_dispositivo_id, v_comando_id,
--     p_humedad_inicial, p_humedad_objetivo, p_dosis_ml, p_duracion_segundos)
--   returning id into v_evento_id;
--   return query select v_comando_id, v_evento_id;
-- end; $$;
-- revoke all on function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric) from public, anon, authenticated;
-- grant execute on function public.fn_registrar_riego(uuid, uuid, integer, numeric, numeric, numeric) to service_role;
-- drop view public.vista_ultimo_riego;   -- CREATE OR REPLACE no puede sacar columnas
-- create view public.vista_ultimo_riego as
--   select distinct on (cultivo_id) cultivo_id, fecha_inicio, resultado,
--          humedad_inicial, humedad_objetivo, duracion_segundos
--     from public.evento_riego order by cultivo_id, fecha_inicio desc;
-- grant all on public.vista_ultimo_riego to anon, authenticated, service_role;  -- era la ACL previa (16.13)
-- commit;
