-- ============================================================================
-- Sesión 21 · Contrato v1, paso 5 (16.48) — Guardar temperatura y conductividad
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 03/11/2026 contra el estado verificado ese día por MCP.
--
-- QUÉ RESUELVE (la parte de la base)
--   El contrato (sección 5) dice "temperatura y conductividad se guardan, no
--   deciden". Hoy llegan y la puerta de WF1 las valida, pero se pierden:
--   `fn_registrar_telemetria` solo recibe humedad, pH, N, P y K. Al 03/11 hay
--   0 filas de las métricas 2 (Temperatura) y 7 (Conductividad) en
--   `lectura_sensores`, sobre 347 filas.
--
-- LO QUE HACE
--   La función pasa a recibir dos parámetros más, `p_temperatura` y
--   `p_conductividad`, los dos con DEFAULT NULL como los otros cinco. Igual que
--   hoy, un valor en null no se guarda (es "el sensor no pudo medir"), y un 0 sí.
--
-- POR QUÉ DROP + CREATE Y NO CREATE OR REPLACE
--   Con parámetros nuevos, CREATE OR REPLACE no reemplaza: crea una SEGUNDA
--   función con el mismo nombre. Con dos, la API de Supabase no sabe a cuál
--   llamar y WF1 dejaría de guardar. Se borra la vieja y se crea la nueva en la
--   misma transacción: no hay ningún momento sin función. Nada depende de ella
--   en la base (verificado: 0 dependencias, 1 sola versión).
--
-- QUÉ NO CAMBIA (a propósito, una cosa por vez)
--   - SECURITY DEFINER y los permisos (anon y authenticated pueden ejecutarla):
--     se reponen tal como estaban. Eso es B.9, aparte.
--   - Ninguna vista ni workflow lee las métricas 2 y 7 (verificado): las dos
--     vistas que leen `lectura_sensores` filtran por métrica.
--
-- ORDEN (la base primero)
--   La función nueva acepta también la llamada de hoy (7 parámetros), así que
--   WF1 sigue guardando como siempre hasta que se le agreguen los dos campos.
--   Al revés no: si WF1 mandara los dos campos antes, la base no reconocería la
--   llamada y se perdería la lectura entera.
--
--   BLOQUE 0 (lo corre el agente por MCP) → BLOQUE 3 ANTES (tiene que FALLAR)
--   → BLOQUE 1 → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP).
--   Después, el cambio en `Consolidar datos` de WF1 (instrucción aparte).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: 1 versión de la función, con 7 parámetros; 0 filas de las métricas
-- 2 y 7; las métricas 2 y 7 se llaman 'Temperatura' y 'Conductividad'.
-- Verificado por MCP el 03/11: 1 versión, 0 filas, nombres correctos.
-- ============================================================================
select p.oid::regprocedure as firma, p.prosecdef, p.proacl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_registrar_telemetria';

select id, nombre, unidad,
       (select count(*) from public.lectura_sensores l where l.metrica_id = tm.id) as filas
from public.tipos_metricas tm
where id in (2, 7);


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

drop function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
                                             double precision, double precision, double precision);

create function public.fn_registrar_telemetria(
  p_cultivo_id      uuid,
  p_dispositivo_id  uuid,
  p_humedad         double precision default null,
  p_ph              double precision default null,
  p_n               double precision default null,
  p_p               double precision default null,
  p_k               double precision default null,
  p_temperatura     double precision default null,
  p_conductividad   double precision default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.lectura_sensores (cultivo_id, dispositivo_id, metrica_id, valor)
  select p_cultivo_id, p_dispositivo_id, tm.id, v.valor
  from (values
    ('Humedad',       p_humedad),
    ('Temperatura',   p_temperatura),
    ('pH',            p_ph),
    ('Conductividad', p_conductividad),
    ('Nitrógeno',     p_n),
    ('Fósforo',       p_p),
    ('Potasio',       p_k)
  ) as v(nombre, valor)
  join public.tipos_metricas tm on tm.nombre = v.nombre
  where v.valor is not null;
end;
$function$;

-- Los mismos permisos que tenía (PUBLIC lo recibe solo al crearla).
grant execute on function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
  double precision, double precision, double precision, double precision, double precision)
  to anon, authenticated, service_role;

comment on function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
  double precision, double precision, double precision, double precision, double precision) is
  'Guarda una lectura: una fila por métrica con valor. Null = el sensor no midió (no se guarda). '
  'Temperatura y conductividad desde el 03/11/2026 (contrato v1, paso 5, 16.48): se guardan, no deciden.';

commit;

-- Que la API de Supabase vea la función nueva ya (normalmente lo hace sola).
notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: 1 sola versión, con 9 parámetros, SECURITY DEFINER y los mismos
-- permisos que en el BLOQUE 0.
-- ============================================================================
select p.oid::regprocedure as firma, p.prosecdef, p.proacl, p.proconfig,
       obj_description(p.oid, 'pg_proc') as comentario
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_registrar_telemetria';


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Llama a la función 4 veces sobre el cultivo de demo y cuenta las filas que
-- escribió cada llamada. Termina SIEMPRE con un error a propósito, que revierte
-- todo lo que escribió:
--   "TEST OK: ..."     → la función guarda bien.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (1 bien), porque solo
-- la llamada de hoy funciona. Si da OK, el test no prueba nada.
-- Deja un hueco de unos 20 números en los id de `lectura_sensores` (el
-- contador no vuelve atrás): es inocuo.
-- ============================================================================
do $$
declare
  v_disp    uuid;
  v_cultivo uuid;
  v_antes   bigint;
  v_filas   int;
  v_t       double precision;
  v_c       double precision;
  v_fallas  text[] := '{}';
  v_ok      int := 0;
begin
  select dispositivo_id, cultivo_id into v_disp, v_cultivo
  from public.vista_cultivos_activos
  where dispositivo_mac = '24:0A:C4:A1:B2:C3';
  if v_cultivo is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de demo en la vista.';
  end if;

  -- Caso 1 — las 7 mediciones: 7 filas, con temperatura 22.5 y conductividad 1.2
  select coalesce(max(id), 0) into v_antes from public.lectura_sensores;
  begin
    perform public.fn_registrar_telemetria(
      p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp,
      p_humedad => 68, p_temperatura => 22.5, p_ph => 6.4, p_conductividad => 1.2,
      p_n => 25, p_p => 40, p_k => 60);
    select count(*), max(valor) filter (where metrica_id = 2), max(valor) filter (where metrica_id = 7)
      into v_filas, v_t, v_c
    from public.lectura_sensores where id > v_antes and fecha_hora = now();
    if v_filas = 7 and v_t = 22.5 and v_c = 1.2 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "las 7": %s filas, temperatura %s, conductividad %s (esperaba 7, 22.5 y 1.2)',
        v_filas, coalesce(v_t::text, 'no guardada'), coalesce(v_c::text, 'no guardada')));
    end if;
  exception when undefined_function then
    v_fallas := array_append(v_fallas, 'caso "las 7": la función no acepta temperatura ni conductividad');
  end;

  -- Caso 2 — temperatura y conductividad en null: 5 filas, ninguna de la 2 ni de la 7
  select coalesce(max(id), 0) into v_antes from public.lectura_sensores;
  begin
    perform public.fn_registrar_telemetria(
      p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp,
      p_humedad => 68, p_temperatura => null, p_ph => 6.4, p_conductividad => null,
      p_n => 25, p_p => 40, p_k => 60);
    select count(*), count(*) filter (where metrica_id in (2, 7))
      into v_filas, v_t
    from public.lectura_sensores where id > v_antes and fecha_hora = now();
    if v_filas = 5 and v_t = 0 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "sin temperatura ni conductividad": %s filas, %s de la 2 o la 7 (esperaba 5 y 0)', v_filas, v_t));
    end if;
  exception when undefined_function then
    v_fallas := array_append(v_fallas, 'caso "sin temperatura ni conductividad": la función no acepta los parámetros nuevos');
  end;

  -- Caso 3 — solo la conductividad, y en 0: 1 fila de la métrica 7 con valor 0
  -- (el 0 es un dato, no una falta)
  select coalesce(max(id), 0) into v_antes from public.lectura_sensores;
  begin
    perform public.fn_registrar_telemetria(
      p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp, p_conductividad => 0);
    select count(*), max(valor) filter (where metrica_id = 7)
      into v_filas, v_c
    from public.lectura_sensores where id > v_antes and fecha_hora = now();
    if v_filas = 1 and v_c = 0 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "conductividad 0": %s filas, conductividad %s (esperaba 1 y 0)',
        v_filas, coalesce(v_c::text, 'no guardada')));
    end if;
  exception when undefined_function then
    v_fallas := array_append(v_fallas, 'caso "conductividad 0": la función no acepta la conductividad');
  end;

  -- Caso 4 — la llamada de hoy (WF1 sin cambiar): 5 filas, como siempre
  select coalesce(max(id), 0) into v_antes from public.lectura_sensores;
  begin
    perform public.fn_registrar_telemetria(
      p_cultivo_id => v_cultivo, p_dispositivo_id => v_disp,
      p_humedad => 68, p_ph => 6.4, p_n => 25, p_p => 40, p_k => 60);
    select count(*) into v_filas
    from public.lectura_sensores where id > v_antes and fecha_hora = now();
    if v_filas = 5 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format('caso "llamada de hoy": %s filas (esperaba 5)', v_filas));
    end if;
  exception when undefined_function then
    v_fallas := array_append(v_fallas, 'caso "llamada de hoy": la función ya no acepta la llamada de WF1');
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 4. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- OJO: antes de revertir, `Consolidar datos` (WF1) tiene que dejar de mandar
-- p_temperatura y p_conductividad; si no, se pierden las lecturas.
-- Las filas de las métricas 2 y 7 que se hayan guardado quedan (no molestan).
-- ============================================================================
-- begin;
-- drop function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
--   double precision, double precision, double precision, double precision, double precision);
-- create function public.fn_registrar_telemetria(p_cultivo_id uuid, p_dispositivo_id uuid,
--   p_humedad double precision default null, p_ph double precision default null,
--   p_n double precision default null, p_p double precision default null, p_k double precision default null)
-- returns void language plpgsql security definer set search_path to 'public'
-- as $function$
-- begin
--   insert into public.lectura_sensores (cultivo_id, dispositivo_id, metrica_id, valor)
--   select p_cultivo_id, p_dispositivo_id, tm.id, v.valor
--   from (values ('Humedad', p_humedad), ('pH', p_ph), ('Nitrógeno', p_n),
--                ('Fósforo', p_p), ('Potasio', p_k)) as v(nombre, valor)
--   join public.tipos_metricas tm on tm.nombre = v.nombre
--   where v.valor is not null;
-- end;
-- $function$;
-- grant execute on function public.fn_registrar_telemetria(uuid, uuid, double precision, double precision,
--   double precision, double precision, double precision) to anon, authenticated, service_role;
-- commit;
-- notify pgrst, 'reload schema';
