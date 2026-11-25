-- ============================================================================
-- Sesión 25 · 16.44 (parte) — un riego sin control no queda "pendiente"
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 25/11/2026 contra el estado verificado ese día por MCP.
--
-- EL PROBLEMA
--   Si no llega una lectura dentro de la hora del riego, nadie cierra el
--   control: el evento queda "pendiente" para siempre y /estado dice
--   "esperando el control" aunque ya no pueda llegar (riego 33, del 15/11).
--
-- QUÉ HACE
--   1. vista_ultimo_riego devuelve resultado = 'sin_control' cuando el riego
--      sigue 'pendiente' y pasó la hora del control. Se calcula al leer, como
--      absorcion_completa y recheck_vencido: guardarlo necesitaría algo que
--      corra justo cuando la placa no manda nada.
--   2. Comentarios en evento_riego.resultado y comando_dispositivo.estado:
--      qué quiere decir "pendiente" en la tabla.
--
-- QUÉ NO CAMBIA
--   Las tablas y sus datos. Las columnas de la vista (mismos nombres, tipos y
--   orden), sus permisos y vista_estado_cultivo. El Motor de WF1 decide igual:
--   con el plazo vencido ya no hacía el control, y el freno solo mira
--   'fallo_sistema'. WF5 solo mira absorcion_completa. La orden no cambia: la
--   entrega ya ignora las de más de 10 minutos (fn_tomar_ordenes).
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: el último riego (evento 33) en 'pendiente' con recheck_vencido
-- true; sin comentarios en las dos columnas.
-- ============================================================================
select cultivo_id, evento_id, resultado, comando_estado, recheck_vencido
from public.vista_ultimo_riego;

select a.attrelid::regclass as tabla, a.attname, col_description(a.attrelid, a.attnum) as comentario
from pg_attribute a
where (a.attrelid, a.attname) in (('public.evento_riego'::regclass, 'resultado'),
                                  ('public.comando_dispositivo'::regclass, 'estado'));


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

create or replace view public.vista_ultimo_riego as
select distinct on (e.cultivo_id)
       e.cultivo_id,
       e.fecha_inicio,
       -- 16.44: pasada la hora, el control ya no puede llegar.
       case when e.resultado = 'pendiente' and t.recheck_vencido
            then 'sin_control' else e.resultado end as resultado,
       e.humedad_inicial,
       e.humedad_objetivo,
       e.duracion_segundos,
       e.id as evento_id,
       e.fecha_recheck,
       e.humedad_recheck,
       c.estado as comando_estado,
       (now() - e.fecha_inicio) >= interval '15 minutes' as absorcion_completa,
       t.recheck_vencido,
       (select max(l.valor)
          from public.lectura_sensores l
         where l.cultivo_id = e.cultivo_id
           and l.metrica_id = 1
           and l.fecha_hora > e.fecha_recheck) as humedad_max_posterior
from public.evento_riego e
left join public.comando_dispositivo c on c.id = e.comando_id
cross join lateral (select (now() - e.fecha_inicio) > interval '1 hour' as recheck_vencido) t
order by e.cultivo_id, e.fecha_inicio desc, e.id desc;

comment on column public.evento_riego.resultado is
  'Conclusión del control del riego. "pendiente" = sin conclusión registrada. Si pasó la hora sin una lectura, vista_ultimo_riego lo devuelve como "sin_control" (16.44). Sesión 25.';
comment on column public.comando_dispositivo.estado is
  'Estado de la orden. Una "pendiente" de más de 10 minutos ya no se entrega (fn_tomar_ordenes), aunque acá siga diciendo "pendiente". Sesión 25.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: evento 33 en 'sin_control'; /estado lo ve igual; la tabla sigue
-- en 'pendiente'; los dos comentarios.
-- ============================================================================
select cultivo_id, evento_id, resultado, comando_estado, absorcion_completa, recheck_vencido
from public.vista_ultimo_riego;

select riego_resultado, riego_comando_estado from public.vista_estado_cultivo;

select id, resultado from public.evento_riego where id = 33;

select a.attrelid::regclass as tabla, a.attname, col_description(a.attrelid, a.attnum) as comentario
from pg_attribute a
where (a.attrelid, a.attname) in (('public.evento_riego'::regclass, 'resultado'),
                                  ('public.comando_dispositivo'::regclass, 'estado'));


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el diseño.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- ANTES del BLOQUE 1 tiene que dar TEST FALLÓ con 4 de 8 bien
-- (fallan c1, c4, c6 y c7).
-- ============================================================================
do $$
declare
  ok     int  := 0;
  fallas text := '';
  v_cult uuid;
  v_ev   bigint;
  v_res  text;
  v_txt  text;
begin
  -- El último riego de un cultivo activo (c6 lo busca en /estado).
  select r.cultivo_id, r.evento_id into v_cult, v_ev
    from public.vista_ultimo_riego r
    join public.vista_estado_cultivo s on s.cultivo_id = r.cultivo_id
   limit 1;
  if v_ev is null then
    raise exception 'TEST NO CORRIÓ: ningún cultivo activo tiene riegos.';
  end if;

  -- c1: pendiente y vencido (2 h) → sin_control
  begin
    update public.evento_riego set resultado = 'pendiente', fecha_inicio = now() - interval '2 hours' where id = v_ev;
    select resultado into v_res from public.vista_ultimo_riego where cultivo_id = v_cult and evento_id = v_ev;
    if v_res = 'sin_control' then ok := ok + 1; else fallas := fallas || format(' [c1: pendiente de 2 h dio %s]', v_res); end if;
    raise exception 'DESHACER';
  exception when others then
    if sqlerrm <> 'DESHACER' then fallas := fallas || ' [c1: ' || sqlerrm || ']'; end if;
  end;

  -- c2: pendiente dentro de la hora (59 min) → sigue pendiente
  begin
    update public.evento_riego set resultado = 'pendiente', fecha_inicio = now() - interval '59 minutes' where id = v_ev;
    select resultado into v_res from public.vista_ultimo_riego where cultivo_id = v_cult and evento_id = v_ev;
    if v_res = 'pendiente' then ok := ok + 1; else fallas := fallas || format(' [c2: pendiente de 59 min dio %s]', v_res); end if;
    raise exception 'DESHACER';
  exception when others then
    if sqlerrm <> 'DESHACER' then fallas := fallas || ' [c2: ' || sqlerrm || ']'; end if;
  end;

  -- c3: un resultado ya escrito no se toca, aunque sea viejo
  begin
    update public.evento_riego set resultado = 'fallo_sistema', fecha_inicio = now() - interval '2 hours' where id = v_ev;
    select resultado into v_res from public.vista_ultimo_riego where cultivo_id = v_cult and evento_id = v_ev;
    if v_res = 'fallo_sistema' then ok := ok + 1; else fallas := fallas || format(' [c3: fallo_sistema viejo dio %s]', v_res); end if;
    raise exception 'DESHACER';
  exception when others then
    if sqlerrm <> 'DESHACER' then fallas := fallas || ' [c3: ' || sqlerrm || ']'; end if;
  end;

  -- c4: con los datos reales, ningún riego vencido sale como pendiente
  if not exists (select 1 from public.vista_ultimo_riego where resultado = 'pendiente' and recheck_vencido) then
    ok := ok + 1;
  else
    fallas := fallas || ' [c4: hay riegos vencidos que siguen en pendiente]';
  end if;

  -- c5: la vista tiene las mismas 13 columnas, con sus tipos y en orden
  select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) into v_txt
    from information_schema.columns where table_schema = 'public' and table_name = 'vista_ultimo_riego';
  if v_txt = 'cultivo_id:uuid,fecha_inicio:timestamp with time zone,resultado:text,humedad_inicial:numeric,'
          || 'humedad_objetivo:numeric,duracion_segundos:integer,evento_id:bigint,fecha_recheck:timestamp with time zone,'
          || 'humedad_recheck:numeric,comando_estado:text,absorcion_completa:boolean,recheck_vencido:boolean,'
          || 'humedad_max_posterior:double precision' then
    ok := ok + 1;
  else
    fallas := fallas || ' [c5: columnas distintas: ' || coalesce(v_txt, 'ninguna') || ']';
  end if;

  -- c6: /estado (vista_estado_cultivo) ve sin_control
  begin
    update public.evento_riego set resultado = 'pendiente', fecha_inicio = now() - interval '2 hours' where id = v_ev;
    select riego_resultado into v_res from public.vista_estado_cultivo where cultivo_id = v_cult;
    if v_res = 'sin_control' then ok := ok + 1; else fallas := fallas || format(' [c6: vista_estado_cultivo dio %s]', coalesce(v_res, 'nada')); end if;
    raise exception 'DESHACER';
  exception when others then
    if sqlerrm <> 'DESHACER' then fallas := fallas || ' [c6: ' || sqlerrm || ']'; end if;
  end;

  -- c7: los dos comentarios
  if col_description('public.evento_riego'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.evento_riego'::regclass and attname = 'resultado')) like '%sin_control%'
     and col_description('public.comando_dispositivo'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.comando_dispositivo'::regclass and attname = 'estado')) like '%10 minutos%' then
    ok := ok + 1;
  else
    fallas := fallas || ' [c7: falta un comentario]';
  end if;

  -- c8: los permisos de la vista siguen
  if has_table_privilege('service_role', 'public.vista_ultimo_riego', 'select')
     and has_table_privilege('authenticated', 'public.vista_ultimo_riego', 'select')
     and has_table_privilege('anon', 'public.vista_ultimo_riego', 'select') then
    ok := ok + 1;
  else
    fallas := fallas || ' [c8: cambiaron los permisos de la vista]';
  end if;

  if ok = 8 then
    raise exception 'TEST OK: % de 8', ok;
  else
    raise exception 'TEST FALLÓ: % de 8 bien.%', ok, fallas;
  end if;
end $$;


-- ============================================================================
-- BLOQUE R — Reverso (no correr salvo que haya que deshacer).
-- ============================================================================
-- begin;
-- create or replace view public.vista_ultimo_riego as
-- select distinct on (e.cultivo_id)
--        e.cultivo_id, e.fecha_inicio, e.resultado, e.humedad_inicial, e.humedad_objetivo,
--        e.duracion_segundos, e.id as evento_id, e.fecha_recheck, e.humedad_recheck,
--        c.estado as comando_estado,
--        (now() - e.fecha_inicio) >= interval '15 minutes' as absorcion_completa,
--        (now() - e.fecha_inicio) > interval '1 hour' as recheck_vencido,
--        (select max(l.valor) from public.lectura_sensores l
--          where l.cultivo_id = e.cultivo_id and l.metrica_id = 1
--            and l.fecha_hora > e.fecha_recheck) as humedad_max_posterior
-- from public.evento_riego e
-- left join public.comando_dispositivo c on c.id = e.comando_id
-- order by e.cultivo_id, e.fecha_inicio desc, e.id desc;
-- comment on column public.evento_riego.resultado is null;
-- comment on column public.comando_dispositivo.estado is null;
-- commit;
-- notify pgrst, 'reload schema';
