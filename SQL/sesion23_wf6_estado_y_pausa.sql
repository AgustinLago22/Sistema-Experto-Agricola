-- ============================================================================
-- Sesión 23 · WF6 — Lo que necesitan /estado, /diagnostico, /pausar y /reanudar
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 12/11/2026 contra el estado verificado ese día por MCP.
-- BLOQUE 0 verificado por MCP el 12/11: ni la vista ni la función existen;
-- un cultivo, activo y sin pausa.
-- APLICADO el 13/11/2026 por Agustín: BLOQUE 3 antes → TEST FALLÓ (0 bien);
-- BLOQUE 1; BLOQUE 3 después → TEST OK: 11 de 11. BLOQUE 2 verificado por MCP
-- (vista con security_invoker y permisos solo de postgres y service_role;
-- función sin SECURITY DEFINER, EXECUTE solo postgres y service_role; una
-- fila, con la lectura 30; sin pausa; el test no dejó filas). El advisor de
-- seguridad no muestra hallazgos nuevos.
--
-- QUÉ RESUELVE (la parte de la base de WF6, diseño en 13.13.4)
--   1. vista_estado_cultivo: una fila por cultivo activo con todo lo que
--      muestran /estado y /diagnostico. WF6 hace UNA consulta y no seis.
--        · El cultivo: nombre, planta, etapa, días en la etapa, la pausa, si
--          tiene riego automático y la MAC de su placa.
--        · La última lectura (la más reciente de `lectura`, por la hora en que
--          llegó) con sus siete valores de `lectura_sensores`.
--        · Los rangos de la etapa (`parametro_etapa`).
--        · El último riego (`vista_ultimo_riego`, no se repite la regla).
--        · La última foto: la ruta y la hora REAL en que se subió (de
--          storage.objects, la versión vigente del archivo).
--        · La hora del último diagnóstico (`seguimiento_fenologico`), para el
--          límite de un /diagnostico cada 10 minutos.
--
--   2. fn_pausar_cultivo(p_cultivo_id, p_minutos): el modo mantenimiento.
--        · De 1 a 1440 minutos: mantenimiento_hasta = ahora + esos minutos.
--        · 0: reanudar (mantenimiento_hasta = null).
--        · Rechaza un valor fuera de rango y un cultivo inexistente o inactivo,
--          con el motivo, y no cambia nada.
--      Devuelve SIEMPRE una fila: (valido, mantenimiento_hasta,
--      estaba_en_pausa, errores). Mismo estilo que fn_tomar_ordenes: un nodo
--      de n8n que recibe un error de la base no siempre lo muestra bien, una
--      fila con `valido` sí. `estaba_en_pausa` es para contestar "No estaba en
--      pausa" a un /reanudar sin pausa; se calcula en el mismo momento del
--      cambio, no con la lectura de la vista de antes.
--
-- CAMBIO RESPECTO DEL DISEÑO (13.13.4 decía `returns timestamptz`)
--   Una función que devuelve solo la hora no puede decir "no estaba en pausa"
--   ni rechazar sin tirar un error. Se pasó a la fila de cuatro columnas.
--
-- POR QUÉ ASÍ
--   · El tope de 24 h vive acá y en ningún otro lado (WF6 valida el formato
--     del texto, pero el que decide es la base). Durante la pausa no se riega
--     ni se avisa; una maceta chica puede secarse en un día de calor.
--   · La vista se apoya en vista_cultivos_activos y vista_ultimo_riego: el
--     "cultivo activo", el "riego automático disponible" y el "último riego"
--     tienen una sola definición. Consecuencia: un cultivo activo sin placa o
--     sin especie no aparece (igual que en WF1).
--   · El "freno" del riego NO se calcula acá (lo decide el Motor de WF1;
--     copiarlo crearía una segunda definición, ver 13.13.4).
--   · Sin SECURITY DEFINER y solo para service_role, como fn_tomar_ordenes y
--     vista_ultimo_arranque. Supabase da permisos a anon y authenticated en
--     cada vista y función nueva (pg_default_acl, verificado el 12/11): por
--     eso los REVOKE explícitos. La vista es security_invoker: lee con los
--     permisos de quien consulta, no con los del dueño.
--
-- QUÉ NO CAMBIA
--   Ninguna tabla, columna, restricción, política ni dato. Sin WF6 nadie usa
--   la vista ni la función, así que crearlas no cambia nada de lo que corre.
--
-- ORDEN
--   BLOQUE 0 (MCP) → BLOQUE 3 ANTES (tiene que FALLAR) → BLOQUE 1
--   → BLOQUE 3 DESPUÉS (tiene que dar TEST OK) → BLOQUE 2 (MCP) → WF6.
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo (solo lectura).
-- Esperado: ni la vista ni la función existen; un cultivo activo, sin pausa.
-- ============================================================================
select c.relname as objeto, c.relkind
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_estado_cultivo'
union all
select p.oid::regprocedure::text, 'f'
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_pausar_cultivo';

select id, nombre_personalizado, active, mantenimiento_hasta
from public.cultivo order by id;


-- ============================================================================
-- BLOQUE 1 — El cambio. Se pega entero, una sola vez.
-- ============================================================================
begin;

-- 1. Todo lo que muestra /estado, en una fila por cultivo activo.
create view public.vista_estado_cultivo
with (security_invoker = true) as
select
  v.cultivo_id,
  coalesce(nullif(btrim(c.nombre_personalizado), ''), v.planta) as nombre,
  v.planta,
  v.etapa_actual                                                  as etapa,
  v.etapas_especie_id,
  floor(extract(epoch from now() - v.fecha_inicio_etapa) / 86400)::int as dias_en_etapa,
  v.duracion_estimada_dias,
  v.mantenimiento_hasta,
  v.riego_automatico_disponible,
  v.dispositivo_mac,
  -- La última lectura y sus valores
  l.fecha_recepcion                                               as ultima_lectura_fecha,
  l.humedad, l.temperatura, l.ph, l.n, l.p, l.k, l.conductividad,
  -- Los rangos de la etapa
  pe.humedad_min, pe.humedad_max, pe.ph_min, pe.ph_max,
  pe.ideal_n, pe.ideal_p, pe.ideal_k,
  -- El último riego
  r.fecha_inicio                                                  as riego_fecha,
  r.resultado                                                     as riego_resultado,
  r.comando_estado                                                as riego_comando_estado,
  -- La última foto y el último diagnóstico
  v.ultima_foto_path,
  f.created_at                                                    as ultima_foto_fecha,
  d.ultimo_diagnostico_fecha
from public.vista_cultivos_activos v
join public.cultivo c on c.id = v.cultivo_id
-- La más reciente por la hora en que llegó; el id solo desempata.
left join lateral (
  select ul.fecha_recepcion,
         max(ls.valor) filter (where ls.metrica_id = 1) as humedad,
         max(ls.valor) filter (where ls.metrica_id = 2) as temperatura,
         max(ls.valor) filter (where ls.metrica_id = 3) as ph,
         max(ls.valor) filter (where ls.metrica_id = 4) as n,
         max(ls.valor) filter (where ls.metrica_id = 5) as p,
         max(ls.valor) filter (where ls.metrica_id = 6) as k,
         max(ls.valor) filter (where ls.metrica_id = 7) as conductividad
    from (select le.id, le.fecha_recepcion
            from public.lectura le
           where le.cultivo_id = v.cultivo_id
           order by le.fecha_recepcion desc, le.id desc
           limit 1) ul
    left join public.lectura_sensores ls on ls.lectura_id = ul.id
   group by ul.id, ul.fecha_recepcion
) l on true
left join public.parametro_etapa pe on pe.etapa_especie_id = v.etapas_especie_id
left join public.vista_ultimo_riego r on r.cultivo_id = v.cultivo_id
-- La versión vigente del archivo (Storage puede guardar versiones viejas).
left join storage.objects f
       on f.bucket_id = 'fotos-cultivos'
      and f.name = v.ultima_foto_path
      and f.archived_at is null
      and f.is_delete_marker is not true
left join lateral (
  select max(s.fecha_registro) as ultimo_diagnostico_fecha
    from public.seguimiento_fenologico s
   where s.cultivo_id = v.cultivo_id
) d on true;

revoke all on public.vista_estado_cultivo from anon, authenticated;

comment on view public.vista_estado_cultivo is
  'Una fila por cultivo activo con lo que muestran /estado y /diagnostico de WF6: etapa, última lectura, '
  'rangos, último riego, última foto y último diagnóstico. 13.13.4. Solo service_role.';

-- 2. Pausar o reanudar.
create function public.fn_pausar_cultivo(p_cultivo_id uuid, p_minutos integer)
returns table (valido boolean, mantenimiento_hasta timestamptz,
               estaba_en_pausa boolean, errores text[])
language plpgsql
set search_path = public, pg_temp
as $function$
declare
  -- Tope de una pausa. Durante la pausa no se riega ni se avisa: una maceta
  -- chica puede secarse en un día de calor. Para más, se vuelve a pausar.
  c_tope_min constant integer := 1440;
  v_activo   boolean;
  v_antes    timestamptz;
  v_hasta    timestamptz;
begin
  if p_cultivo_id is null then
    return query select false, null::timestamptz, null::boolean,
      array['cultivo_id: falta'];
    return;
  end if;

  if p_minutos is null or p_minutos < 0 or p_minutos > c_tope_min then
    return query select false, null::timestamptz, null::boolean,
      array[format('minutos: %s no es válido; tiene que ser de 1 a %s (24 h), o 0 para reanudar',
                   coalesce(p_minutos::text, 'null'), c_tope_min)];
    return;
  end if;

  -- Bloquea el cultivo: dos pedidos a la vez se ordenan y el segundo ve el
  -- resultado del primero.
  select c.active, c.mantenimiento_hasta into v_activo, v_antes
    from public.cultivo c
   where c.id = p_cultivo_id
     for update;

  if not found then
    return query select false, null::timestamptz, null::boolean,
      array[format('cultivo_id: %s no existe', p_cultivo_id)];
    return;
  end if;

  if v_activo is not true then
    return query select false, v_antes, null::boolean,
      array[format('cultivo_id: %s está inactivo', p_cultivo_id)];
    return;
  end if;

  v_hasta := case when p_minutos = 0 then null
                  else now() + make_interval(mins => p_minutos) end;

  update public.cultivo c set mantenimiento_hasta = v_hasta where c.id = p_cultivo_id;

  -- Una pausa ya vencida no cuenta como pausa.
  return query select true, v_hasta, coalesce(v_antes > now(), false), array[]::text[];
end;
$function$;

revoke all on function public.fn_pausar_cultivo(uuid, integer) from public, anon, authenticated;
grant execute on function public.fn_pausar_cultivo(uuid, integer) to service_role;

comment on function public.fn_pausar_cultivo(uuid, integer) is
  'Modo mantenimiento (WF6, /pausar y /reanudar). De 1 a 1440 minutos pausa riego y avisos hasta '
  'ahora + minutos; 0 reanuda. Rechaza cultivo inexistente o inactivo y valores fuera de rango. '
  '13.13.4. Solo service_role.';

commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- BLOQUE 2 — Verificación (solo lectura; la corre el agente por MCP).
-- Esperado: la vista con security_invoker y permisos solo de postgres y
-- service_role; la función sin SECURITY DEFINER, ejecutable solo por postgres
-- y service_role; una fila en la vista, con la lectura 30; el cultivo sin
-- pausa, igual que en el BLOQUE 0.
-- ============================================================================
select c.relname, c.reloptions, c.relacl
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'vista_estado_cultivo';

select p.oid::regprocedure as firma, p.prosecdef, p.proacl, pg_get_function_result(p.oid) as devuelve
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_pausar_cultivo';

select * from public.vista_estado_cultivo;

select id, nombre_personalizado, active, mantenimiento_hasta
from public.cultivo order by id;


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo. Se pega entero.
-- Crea tres placas falsas con un cultivo cada una (todo se revierte):
--   X  activo, con dos lecturas, un riego, dos diagnósticos y una foto real;
--   Y  activo y vacío: sin lecturas, riegos, foto ni diagnósticos;
--   Z  inactivo.
-- Termina SIEMPRE con un error a propósito:
--   "TEST OK: ..."     → la base cumple el diseño.
--   "TEST FALLÓ: ..."  → la lista de lo que no funcionó.
-- Correrlo ANTES del BLOQUE 1: tiene que dar TEST FALLÓ (0 bien), porque ni
-- la vista ni la función existen. Si da OK, el test no prueba nada.
--
-- Probado el 12/11 en un Postgres 16 local (PGlite) con una copia de las
-- tablas, las dos vistas en que se apoya, storage.objects y los permisos por
-- defecto de Supabase: antes, TEST FALLÓ (0 bien); después, TEST OK 11 de 11,
-- sin dejar filas. Con doce defectos metidos a propósito (última lectura por
-- id, nombre sin recortar, días redondeados para arriba, foto obligatoria,
-- diagnóstico más viejo, vista sin security_invoker, vista o función abiertas
-- a anon, sin tope de 24 h, cultivo inactivo aceptado, pausa vencida contada
-- como pausa, reanudar que no borra) el test detectó los doce.
-- Deja huecos en los id de lectura, lectura_sensores, arranque_dispositivo,
-- comando_dispositivo y evento_riego: son inocuos.
-- ============================================================================
do $$
declare
  v_mac_demo constant text := '24:0A:C4:A1:B2:C3';
  v_demo     record;   -- el cultivo real, para copiar especie y etapa
  v_dx uuid; v_dy uuid; v_dz uuid;   -- placas falsas
  v_x  uuid; v_y  uuid; v_z  uuid;   -- sus cultivos
  v_arr      bigint;
  v_la       bigint;   -- lectura más NUEVA de X (se inserta primero: id menor)
  v_lb       bigint;   -- lectura más VIEJA de X (se inserta después: id mayor)
  v_cmd      bigint;
  v_foto     record;   -- un archivo real del bucket
  v_pe       record;
  e          record;   -- fila de la vista
  r          record;   -- fila de la función
  v_n        int;
  v_m        int;
  v_ts       timestamptz;
  v_fallas   text[] := '{}';
  v_ok       int := 0;
  v_firma    constant text := 'public.fn_pausar_cultivo(uuid, integer)';
begin
  select * into v_demo from public.vista_cultivos_activos where dispositivo_mac = v_mac_demo;
  if v_demo.cultivo_id is null then
    raise exception 'TEST NO CORRIÓ: no encontré el cultivo de la placa de demo.';
  end if;
  select * into v_pe from public.parametro_etapa where etapa_especie_id = v_demo.etapas_especie_id;
  select o.name, o.created_at into v_foto
    from storage.objects o
   where o.bucket_id = 'fotos-cultivos' and o.name like '%.jpg' and o.archived_at is null
   order by o.created_at desc limit 1;
  if v_foto.name is null then
    raise exception 'TEST NO CORRIÓ: no hay ninguna foto en el bucket fotos-cultivos.';
  end if;

  -- Las tres placas y sus cultivos
  insert into public.dispositivo (mac_address) values ('00:00:00:00:00:0A') returning id into v_dx;
  insert into public.dispositivo (mac_address) values ('00:00:00:00:00:0B') returning id into v_dy;
  insert into public.dispositivo (mac_address) values ('00:00:00:00:00:0C') returning id into v_dz;

  insert into public.cultivo (especie_id, etapa_actual_id, dispositivo_id, active, nombre_personalizado,
                              fecha_inicio_etapa, ultima_foto_path)
  select c.especie_id, c.etapa_actual_id, v_dx, true, '  Prueba X  ',
         now() - interval '10 days 5 hours', v_foto.name
    from public.cultivo c where c.id = v_demo.cultivo_id
  returning id into v_x;
  insert into public.cultivo (especie_id, etapa_actual_id, dispositivo_id, active, nombre_personalizado)
  select c.especie_id, c.etapa_actual_id, v_dy, true, null
    from public.cultivo c where c.id = v_demo.cultivo_id
  returning id into v_y;
  insert into public.cultivo (especie_id, etapa_actual_id, dispositivo_id, active)
  select c.especie_id, c.etapa_actual_id, v_dz, false
    from public.cultivo c where c.id = v_demo.cultivo_id
  returning id into v_z;

  -- Dos lecturas de X. La que se inserta primero (id menor) es la más NUEVA:
  -- una vista que ordene por id en vez de por hora muestra la otra.
  insert into public.arranque_dispositivo (dispositivo_id, version_firmware)
  values (v_dx, 'test-wf6') returning id into v_arr;
  insert into public.lectura (dispositivo_id, cultivo_id, arranque_id, seq, fecha_recepcion, motivo)
  values (v_dx, v_x, v_arr, 2, now() - interval '1 hour', 'programada') returning id into v_la;
  insert into public.lectura (dispositivo_id, cultivo_id, arranque_id, seq, fecha_recepcion, motivo)
  values (v_dx, v_x, v_arr, 1, now() - interval '2 hours', 'programada') returning id into v_lb;
  insert into public.lectura_sensores (dispositivo_id, cultivo_id, lectura_id, metrica_id, valor, fecha_hora)
  values (v_dx, v_x, v_la, 1, 41,   now() - interval '1 hour'),
         (v_dx, v_x, v_la, 2, 23.5, now() - interval '1 hour'),
         (v_dx, v_x, v_la, 3, 6.1,  now() - interval '1 hour'),
         (v_dx, v_x, v_la, 4, 21,   now() - interval '1 hour'),
         (v_dx, v_x, v_la, 5, 31,   now() - interval '1 hour'),
         (v_dx, v_x, v_la, 6, 51,   now() - interval '1 hour'),
         (v_dx, v_x, v_la, 7, 1.7,  now() - interval '1 hour'),
         (v_dx, v_x, v_lb, 1, 99,   now() - interval '2 hours'),
         (v_dx, v_x, v_lb, 3, 9.9,  now() - interval '2 hours');

  -- Un riego de X con su orden ejecutada, y dos diagnósticos.
  insert into public.comando_dispositivo (dispositivo_id, tipo_comando, duracion_segundos, estado)
  values (v_dx, 'ACTIVAR_RIEGO', 10, 'ejecutado') returning id into v_cmd;
  insert into public.evento_riego (cultivo_id, dispositivo_id, comando_id, fecha_inicio, resultado)
  values (v_x, v_dx, v_cmd, now() - interval '30 minutes', 'insuficiente');
  insert into public.seguimiento_fenologico (cultivo_id, fecha_registro)
  values (v_x, now() - interval '3 hours'), (v_x, now() - interval '20 minutes');

  -- Caso 1 — una fila por cultivo activo: X e Y sí, Z no, ninguno repetido,
  -- y tantas filas como cultivos activos con placa.
  begin
    select count(*), count(distinct cultivo_id) into v_n, v_m from public.vista_estado_cultivo;
    if v_n = (select count(*) from public.vista_cultivos_activos) and v_n = v_m
       and exists (select 1 from public.vista_estado_cultivo where cultivo_id = v_x)
       and exists (select 1 from public.vista_estado_cultivo where cultivo_id = v_y)
       and not exists (select 1 from public.vista_estado_cultivo where cultivo_id = v_z) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "una fila por cultivo activo": %s filas, %s cultivos distintos (esperaba %s y %s, con X e Y y sin Z)',
        v_n, v_m, (select count(*) from public.vista_cultivos_activos), v_n));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "una fila por cultivo activo": ' || sqlerrm);
  end;

  -- Caso 2 — la última lectura es la más nueva por hora, con sus 7 valores.
  begin
    select * into e from public.vista_estado_cultivo where cultivo_id = v_x;
    if e.ultima_lectura_fecha = now() - interval '1 hour'
       and e.humedad = 41 and e.temperatura = 23.5 and e.ph = 6.1
       and e.n = 21 and e.p = 31 and e.k = 51 and e.conductividad = 1.7 then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "última lectura": fecha %s, humedad %s, temp %s, pH %s, N %s, P %s, K %s, CE %s (esperaba hace 1 h, 41, 23.5, 6.1, 21, 31, 51, 1.7)',
        e.ultima_lectura_fecha, e.humedad, e.temperatura, e.ph, e.n, e.p, e.k, e.conductividad));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "última lectura": ' || sqlerrm);
  end;

  -- Caso 3 — los datos del cultivo y los rangos de su etapa.
  begin
    select * into e from public.vista_estado_cultivo where cultivo_id = v_x;
    if e.nombre = 'Prueba X' and e.planta = v_demo.planta and e.etapa = v_demo.etapa_actual
       and e.etapas_especie_id = v_demo.etapas_especie_id and e.dias_en_etapa = 10
       and e.duracion_estimada_dias = v_demo.duracion_estimada_dias
       and e.mantenimiento_hasta is null and e.riego_automatico_disponible is false
       and e.dispositivo_mac = '00:00:00:00:00:0A'
       and e.humedad_min = v_pe.humedad_min and e.humedad_max = v_pe.humedad_max
       and e.ph_min = v_pe.ph_min and e.ph_max = v_pe.ph_max
       and e.ideal_n = v_pe.ideal_n and e.ideal_p = v_pe.ideal_p and e.ideal_k = v_pe.ideal_k then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "datos del cultivo": nombre %L, planta %s, etapa %s, días %s, pausa %s, riego %s, mac %s, humedad %s-%s, pH %s-%s',
        e.nombre, e.planta, e.etapa, e.dias_en_etapa, e.mantenimiento_hasta, e.riego_automatico_disponible,
        e.dispositivo_mac, e.humedad_min, e.humedad_max, e.ph_min, e.ph_max));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "datos del cultivo": ' || sqlerrm);
  end;

  -- Caso 4 — último riego, foto y diagnóstico de X.
  begin
    select * into e from public.vista_estado_cultivo where cultivo_id = v_x;
    if e.riego_fecha = now() - interval '30 minutes' and e.riego_resultado = 'insuficiente'
       and e.riego_comando_estado = 'ejecutado'
       and e.ultima_foto_path = v_foto.name and e.ultima_foto_fecha = v_foto.created_at
       and e.ultimo_diagnostico_fecha = now() - interval '20 minutes' then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "riego, foto y diagnóstico": riego %s %s %s, foto %s %s (esperaba %s), diagnóstico %s',
        e.riego_fecha, e.riego_resultado, e.riego_comando_estado, e.ultima_foto_path,
        e.ultima_foto_fecha, v_foto.created_at, e.ultimo_diagnostico_fecha));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "riego, foto y diagnóstico": ' || sqlerrm);
  end;

  -- Caso 5 — un cultivo sin nada: valores vacíos, no un error ni una fila
  -- de menos. El nombre, sin nombre propio, es el de la planta.
  begin
    select * into e from public.vista_estado_cultivo where cultivo_id = v_y;
    if e.cultivo_id = v_y and e.nombre = v_demo.planta
       and e.ultima_lectura_fecha is null and e.humedad is null and e.ph is null
       and e.riego_fecha is null and e.riego_resultado is null
       and e.ultima_foto_path is null and e.ultima_foto_fecha is null
       and e.ultimo_diagnostico_fecha is null and e.humedad_min = v_pe.humedad_min then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "cultivo vacío": fila %s, nombre %L, lectura %s, humedad %s, riego %s, foto %s %s, diagnóstico %s',
        e.cultivo_id, e.nombre, e.ultima_lectura_fecha, e.humedad, e.riego_fecha,
        e.ultima_foto_path, e.ultima_foto_fecha, e.ultimo_diagnostico_fecha));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "cultivo vacío": ' || sqlerrm);
  end;

  -- Caso 6 — pausar 120 minutos: hasta ahora + 2 h, guardado, y antes no
  -- estaba en pausa. La vista lo muestra.
  begin
    select * into r from public.fn_pausar_cultivo(v_x, 120);
    select c.mantenimiento_hasta into v_ts from public.cultivo c where c.id = v_x;
    select * into e from public.vista_estado_cultivo where cultivo_id = v_x;
    if r.valido is true and cardinality(r.errores) = 0
       and r.mantenimiento_hasta = now() + interval '120 minutes'
       and r.estaba_en_pausa is false and v_ts = r.mantenimiento_hasta
       and e.mantenimiento_hasta = v_ts then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "pausar 120": valido %s, hasta %s, estaba %s, errores %s, guardado %s, en la vista %s',
        r.valido, r.mantenimiento_hasta, r.estaba_en_pausa, r.errores, v_ts, e.mantenimiento_hasta));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "pausar 120": ' || sqlerrm);
  end;

  -- Caso 7 — reanudar: null, y avisa que estaba en pausa. Reanudar otra vez:
  -- sigue null y avisa que NO estaba.
  begin
    select * into r from public.fn_pausar_cultivo(v_x, 0);
    select c.mantenimiento_hasta into v_ts from public.cultivo c where c.id = v_x;
    if r.valido is true and r.mantenimiento_hasta is null and r.estaba_en_pausa is true and v_ts is null then
      select * into r from public.fn_pausar_cultivo(v_x, 0);
      if r.valido is true and r.mantenimiento_hasta is null and r.estaba_en_pausa is false then
        v_ok := v_ok + 1;
      else
        v_fallas := array_append(v_fallas, format(
          'caso "reanudar": la segunda vez valido %s, hasta %s, estaba %s (esperaba true, null, false)',
          r.valido, r.mantenimiento_hasta, r.estaba_en_pausa));
      end if;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "reanudar": valido %s, hasta %s, estaba %s, guardado %s (esperaba true, null, true, null)',
        r.valido, r.mantenimiento_hasta, r.estaba_en_pausa, v_ts));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "reanudar": ' || sqlerrm);
  end;

  -- Caso 8 — los bordes: 1 y 1440 se aceptan. Una pausa ya vencida no
  -- cuenta como pausa.
  begin
    select * into r from public.fn_pausar_cultivo(v_x, 1);
    if not (r.valido is true and r.mantenimiento_hasta = now() + interval '1 minute') then
      v_fallas := array_append(v_fallas, format('caso "bordes", 1 minuto: valido %s, hasta %s', r.valido, r.mantenimiento_hasta));
    end if;
    select * into r from public.fn_pausar_cultivo(v_x, 1440);
    if not (r.valido is true and r.mantenimiento_hasta = now() + interval '24 hours' and r.estaba_en_pausa is true) then
      v_fallas := array_append(v_fallas, format('caso "bordes", 1440: valido %s, hasta %s, estaba %s', r.valido, r.mantenimiento_hasta, r.estaba_en_pausa));
    end if;
    update public.cultivo set mantenimiento_hasta = now() - interval '1 minute' where id = v_x;
    select * into r from public.fn_pausar_cultivo(v_x, 0);
    if not (r.valido is true and r.estaba_en_pausa is false) then
      v_fallas := array_append(v_fallas, format('caso "bordes", pausa vencida: valido %s, estaba %s (esperaba false)', r.valido, r.estaba_en_pausa));
    end if;
    if not exists (select 1 from unnest(v_fallas) f where f like 'caso "bordes"%') then
      v_ok := v_ok + 1;
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "bordes": ' || sqlerrm);
  end;

  -- Caso 9 — fuera de rango (-1, 1441, null): rechazado con el motivo y la
  -- pausa que había queda igual.
  begin
    perform public.fn_pausar_cultivo(v_x, 60);
    select c.mantenimiento_hasta into v_ts from public.cultivo c where c.id = v_x;
    v_n := 0;
    for v_m in select unnest(array[-1, 1441]) loop
      select * into r from public.fn_pausar_cultivo(v_x, v_m);
      if r.valido is false and r.errores[1] like 'minutos:%' and r.mantenimiento_hasta is null then
        v_n := v_n + 1;
      end if;
    end loop;
    select * into r from public.fn_pausar_cultivo(v_x, null);
    if r.valido is false and r.errores[1] like 'minutos: null%' then v_n := v_n + 1; end if;
    if v_n = 3 and v_ts = now() + interval '60 minutes'
       and (select c.mantenimiento_hasta from public.cultivo c where c.id = v_x) = v_ts then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "fuera de rango": %s de 3 rechazados; la pausa pasó de %s a %s', v_n, v_ts,
        (select c.mantenimiento_hasta from public.cultivo c where c.id = v_x)));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "fuera de rango": ' || sqlerrm);
  end;

  -- Caso 10 — cultivo inexistente, nulo o inactivo: rechazado y sin cambios.
  begin
    v_n := 0;
    select * into r from public.fn_pausar_cultivo(gen_random_uuid(), 60);
    if r.valido is false and r.errores[1] like '%no existe' then v_n := v_n + 1; end if;
    select * into r from public.fn_pausar_cultivo(null, 60);
    if r.valido is false and r.errores[1] = 'cultivo_id: falta' then v_n := v_n + 1; end if;
    select * into r from public.fn_pausar_cultivo(v_z, 60);
    if r.valido is false and r.errores[1] like '%está inactivo' then v_n := v_n + 1; end if;
    if v_n = 3 and (select c.mantenimiento_hasta from public.cultivo c where c.id = v_z) is null then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas, format(
        'caso "cultivo rechazado": %s de 3 rechazados; Z quedó con pausa %s', v_n,
        (select c.mantenimiento_hasta from public.cultivo c where c.id = v_z)));
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "cultivo rechazado": ' || sqlerrm);
  end;

  -- Caso 11 — permisos: la vista y la función cerradas para anon y
  -- authenticated, abiertas para service_role; la vista con security_invoker
  -- y la función sin SECURITY DEFINER.
  begin
    if not has_table_privilege('anon', 'public.vista_estado_cultivo', 'select')
       and not has_table_privilege('authenticated', 'public.vista_estado_cultivo', 'select')
       and has_table_privilege('service_role', 'public.vista_estado_cultivo', 'select')
       and (select 'security_invoker=true' = any(c.reloptions) from pg_class c
             where c.oid = 'public.vista_estado_cultivo'::regclass)
       and not has_function_privilege('anon', v_firma, 'execute')
       and not has_function_privilege('authenticated', v_firma, 'execute')
       and has_function_privilege('service_role', v_firma, 'execute')
       and not (select p.prosecdef from pg_proc p where p.oid = v_firma::regprocedure) then
      v_ok := v_ok + 1;
    else
      v_fallas := array_append(v_fallas,
        'caso "permisos": anon o authenticated pueden leer o ejecutar, service_role no, falta security_invoker o la función es SECURITY DEFINER');
    end if;
  exception when others then
    v_fallas := array_append(v_fallas, 'caso "permisos": ' || sqlerrm);
  end;

  if array_length(v_fallas, 1) > 0 then
    raise exception 'TEST FALLÓ (% bien): %', v_ok, array_to_string(v_fallas, ' | ');
  end if;
  raise exception 'TEST OK: % de 11. Todo revertido.', v_ok;
end $$;


-- ============================================================================
-- REVERSO — solo si hubiera que deshacer el BLOQUE 1.
-- Desactivar WF6 antes: sin la vista y la función, sus comandos fallan.
-- ============================================================================
-- begin;
-- drop function public.fn_pausar_cultivo(uuid, integer);
-- drop view public.vista_estado_cultivo;
-- commit;
-- notify pgrst, 'reload schema';
