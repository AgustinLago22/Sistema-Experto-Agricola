-- ============================================================================
-- Sesión 18 · 16.38 — Reglas en la base de conocimiento (catálogo de etapas y umbrales)
-- Proyecto: Tesis Cultivos (xypqsthwquegftcnoqyi)
-- Escrito el 20/10/2026 contra el estado verificado ese día por MCP.
-- ✅ APLICADO por Agustín (SQL Editor) el 20/10/2026, y verificado por MCP:
--    BLOQUE 0 (por MCP): todo 0.
--    BLOQUE 3 ANTES del cambio: "TEST FALLÓ: la base ACEPTÓ [update public.etapas_especie
--      set etapa_id = 6 where id = 8]" → el test puede fallar (ejercer antes de arreglar).
--    BLOQUE 1: sin error.
--    BLOQUE 3 DESPUÉS: "TEST OK: 13 de 13 errores frenados, cada uno por la regla esperada;
--      los 2 cambios válidos pasaron."
--    BLOQUE 2 (por MCP): 10 restricciones, 0 columnas anulables. El test no dejó nada:
--      órdenes 1–6, humedad_min de Fructificación 60, 1 especie, nombres de etapa intactos,
--      la vista sigue devolviendo 6 filas.
--
-- QUÉ RESUELVE
--   16.38  `etapas_especie` y `parametro_etapa` tenían SOLO la clave primaria.
--          La base aceptaba sin quejarse, por ejemplo, una segunda fila de
--          umbrales para la misma etapa: `vista_conocimiento_experto` devolvía
--          dos filas, `Conocimiento Experto` tomaba la primera que llegara (orden
--          no definido) y el Motor podía evaluar con los umbrales equivocados,
--          con todas las ejecuciones en verde. 16.17 (catálogo duplicado) habría
--          sido imposible con estas reglas.
--          Un IF se puede romper en silencio; una restricción de la base no. Y el
--          error aparece AL CARGAR, frente a quien se equivocó, no semanas
--          después en una maceta que no se regó.
--
-- LAS REGLAS
--   Sin duplicados:
--     etapas_especie   (especie_id, etapa_id)  una vez cada etapa por especie
--     etapas_especie   (especie_id, orden)     un orden por especie (ver NOTA 1)
--     parametro_etapa  (etapa_especie_id)      una fila de umbrales por etapa
--     especie_planta   (nombre_comun)          ┐ `Conocimiento Experto` busca en la
--     tipo_etapa       (nombre_etapa)          ┘ vista POR NOMBRE: el nombre es la
--                                                clave de búsqueda, tiene que ser único
--   Sin vacíos (NOT NULL):
--     etapas_especie   especie_id, etapa_id, duracion_estimada_dias (WF3 la usa
--                      para la ventana de evaluación)
--     parametro_etapa  etapa_especie_id y los 7 umbrales
--   Valores con sentido (CHECK):
--     orden > 0 · duración > 0
--     0 <= humedad_min < humedad_max <= 100
--     0 <= ph_min < ph_max <= 14
--     ideal_n, ideal_p, ideal_k > 0
--
-- NOTA 1 — el único de (especie_id, orden) es DEFERRABLE INITIALLY IMMEDIATE.
--   Un único común se controla fila por fila: `update ... set orden = orden + 1`
--   (correr las etapas para insertar una en el medio, como en B.1) chocaría
--   consigo mismo a mitad del UPDATE. Deferrable en modo inmediato se controla al
--   final de cada sentencia: el corrimiento pasa y un duplicado real se rechaza
--   igual. El BLOQUE 3 lo prueba.
--
-- LO QUE QUEDA AFUERA, A PROPÓSITO
--   "Una etapa sin ninguna fila de umbrales" (16.37) no se puede impedir con una
--   regla simple: son dos tablas que se cargan en dos pasos, y la base no
--   distingue "todavía no" de "me olvidé". Hoy lo cubre la guarda del Motor
--   (avisa "Configuración Incompleta"). El arreglo de fondo es juntar las dos
--   tablas en una (la relación es 1 a 1), y eso toca la vista que leen WF1, WF3
--   y WF4: trabajo futuro, no antes del 27/10.
--
-- QUIÉN ESCRIBE EN ESTAS TABLAS (verificado 20/10): nadie de forma automática.
--   Ninguna función ni workflow inserta o modifica el catálogo; se carga a mano.
--   `fn_registrar_evaluacion_fenologica` solo nombra columnas `etapas_especie_id`
--   de otras tablas. Las reglas no pueden romper ningún flujo en marcha.
--
-- ORDEN: BLOQUE 0 (estado previo) → BLOQUE 1 (cambio) → BLOQUE 2 (verificar)
--        → BLOQUE 3 (test que se deshace solo).
-- ============================================================================


-- ============================================================================
-- BLOQUE 0 — Estado previo, verificado por MCP el 20/10 (para poder revertir)
-- ============================================================================
-- Restricciones existentes:
--   etapas_especie:  PK (id) · FK especie_id, etapa_id (ON DELETE CASCADE)
--                    · CHECK etapas_especie_criterio_visual_no_vacio
--   parametro_etapa: PK (id) · FK etapa_especie_id (ON DELETE CASCADE)
--   especie_planta:  PK (id) · tipo_etapa: PK (id)
-- Columnas anulables que pasan a NOT NULL:
--   etapas_especie.especie_id, etapa_id, duracion_estimada_dias
--   parametro_etapa.etapa_especie_id, humedad_min, humedad_max, ph_min, ph_max,
--                   ideal_n, ideal_p, ideal_k
-- Datos: 1 especie (Tomate Cherry), 6 tipos de etapa, 6 etapas_especie, 6
--   parametro_etapa. 0 duplicados, 0 nulos, 0 mínimos mayores que el máximo,
--   0 etapas sin umbrales. Ninguna fila viola las reglas nuevas.
--
-- Detección (correrla antes de aplicar; tiene que dar todo 0):
select
  (select count(*) from (select especie_id, etapa_id from public.etapas_especie group by 1,2 having count(*) > 1) x) dup_especie_etapa,
  (select count(*) from (select especie_id, orden    from public.etapas_especie group by 1,2 having count(*) > 1) x) dup_especie_orden,
  (select count(*) from (select etapa_especie_id     from public.parametro_etapa group by 1   having count(*) > 1) x) dup_umbrales,
  (select count(*) from (select nombre_comun         from public.especie_planta  group by 1   having count(*) > 1) x) dup_especie_nombre,
  (select count(*) from (select nombre_etapa         from public.tipo_etapa      group by 1   having count(*) > 1) x) dup_etapa_nombre,
  (select count(*) from public.etapas_especie
     where especie_id is null or etapa_id is null or duracion_estimada_dias is null
        or orden <= 0 or duracion_estimada_dias <= 0) etapas_invalidas,
  (select count(*) from public.parametro_etapa
     where etapa_especie_id is null
        or humedad_min is null or humedad_max is null or ph_min is null or ph_max is null
        or ideal_n is null or ideal_p is null or ideal_k is null
        or not (humedad_min >= 0 and humedad_max <= 100 and humedad_min < humedad_max)
        or not (ph_min >= 0 and ph_max <= 14 and ph_min < ph_max)
        or not (ideal_n > 0 and ideal_p > 0 and ideal_k > 0)) umbrales_invalidos;

-- Reverso, si hiciera falta (deja la base exactamente como estaba):
--   begin;
--   alter table public.etapas_especie
--     drop constraint etapas_especie_especie_etapa_unica,
--     drop constraint etapas_especie_especie_orden_unico,
--     drop constraint etapas_especie_orden_positivo,
--     drop constraint etapas_especie_duracion_positiva,
--     alter column especie_id drop not null,
--     alter column etapa_id drop not null,
--     alter column duracion_estimada_dias drop not null;
--   alter table public.parametro_etapa
--     drop constraint parametro_etapa_una_por_etapa,
--     drop constraint parametro_etapa_humedad_rango,
--     drop constraint parametro_etapa_ph_rango,
--     drop constraint parametro_etapa_npk_positivo,
--     alter column etapa_especie_id drop not null,
--     alter column humedad_min drop not null, alter column humedad_max drop not null,
--     alter column ph_min drop not null,      alter column ph_max drop not null,
--     alter column ideal_n drop not null,     alter column ideal_p drop not null,
--     alter column ideal_k drop not null;
--   alter table public.especie_planta drop constraint especie_planta_nombre_unico;
--   alter table public.tipo_etapa     drop constraint tipo_etapa_nombre_unico;
--   commit;


-- ============================================================================
-- BLOQUE 1 — El cambio, en una sola transacción
-- Si alguna fila violara una regla, el ALTER falla y no queda nada a medias.
-- ============================================================================
begin;

alter table public.etapas_especie
  alter column especie_id set not null,
  alter column etapa_id set not null,
  alter column duracion_estimada_dias set not null,
  add constraint etapas_especie_especie_etapa_unica unique (especie_id, etapa_id),
  add constraint etapas_especie_especie_orden_unico unique (especie_id, orden)
    deferrable initially immediate,   -- NOTA 1
  add constraint etapas_especie_orden_positivo    check (orden > 0),
  add constraint etapas_especie_duracion_positiva check (duracion_estimada_dias > 0);

alter table public.parametro_etapa
  alter column etapa_especie_id set not null,
  alter column humedad_min set not null,
  alter column humedad_max set not null,
  alter column ph_min set not null,
  alter column ph_max set not null,
  alter column ideal_n set not null,
  alter column ideal_p set not null,
  alter column ideal_k set not null,
  add constraint parametro_etapa_una_por_etapa unique (etapa_especie_id),
  add constraint parametro_etapa_humedad_rango
    check (humedad_min >= 0 and humedad_max <= 100 and humedad_min < humedad_max),
  add constraint parametro_etapa_ph_rango
    check (ph_min >= 0 and ph_max <= 14 and ph_min < ph_max),
  add constraint parametro_etapa_npk_positivo
    check (ideal_n > 0 and ideal_p > 0 and ideal_k > 0);

-- `Conocimiento Experto` busca en la vista por nombre de planta y de etapa.
alter table public.especie_planta add constraint especie_planta_nombre_unico unique (nombre_comun);
alter table public.tipo_etapa     add constraint tipo_etapa_nombre_unico     unique (nombre_etapa);

commit;


-- ============================================================================
-- BLOQUE 2 — Verificación contra el estado persistido
-- Esperado: 10 filas (las 10 restricciones nuevas) y 0 columnas anulables.
-- ============================================================================
select conrelid::regclass as tabla, conname, pg_get_constraintdef(oid) as definicion
from pg_constraint
where conname in (
  'etapas_especie_especie_etapa_unica', 'etapas_especie_especie_orden_unico',
  'etapas_especie_orden_positivo', 'etapas_especie_duracion_positiva',
  'parametro_etapa_una_por_etapa', 'parametro_etapa_humedad_rango',
  'parametro_etapa_ph_rango', 'parametro_etapa_npk_positivo',
  'especie_planta_nombre_unico', 'tipo_etapa_nombre_unico')
order by 1, 2;

select table_name, column_name, is_nullable
from information_schema.columns
where table_schema = 'public'
  and ((table_name = 'etapas_especie'  and column_name in ('especie_id', 'etapa_id', 'duracion_estimada_dias'))
    or (table_name = 'parametro_etapa' and column_name in ('etapa_especie_id', 'humedad_min', 'humedad_max',
                                                           'ph_min', 'ph_max', 'ideal_n', 'ideal_p', 'ideal_k')))
  and is_nullable = 'YES';


-- ============================================================================
-- BLOQUE 3 — Test que se deshace solo
-- Intenta 13 errores de carga sobre el catálogo real. Cada uno tiene que ser
-- frenado POR LA REGLA ESPERADA (no alcanza con que falle: si lo frena otra
-- regla, el test lo marca). Después, dos cambios válidos tienen que pasar: el
-- corrimiento de orden de la NOTA 1 y un ajuste de umbral normal.
-- Termina SIEMPRE con un error a propósito, que revierte todo lo que hizo:
--   "TEST OK: ..."      → las reglas funcionan. Nada quedó escrito.
--   "TEST FALLÓ: ..."   → dice qué caso pasó o qué regla lo frenó.
-- Efecto colateral aceptado: el caso 13 (INSERT) consume un número de la
-- secuencia de especie_planta aunque se revierta. Un hueco es inocuo.
-- Ids usados (20/10): etapas_especie 8 = Cosecha (orden 6), 14 = Fructificación
-- (orden 5, etapa_id 6); parametro_etapa 6 = Fructificación, 7 = Cosecha.
-- ============================================================================
do $$
declare
  casos text[][] := array[
    -- [sentencia que tiene que fallar, regla que la tiene que frenar]
    ['update public.etapas_especie set etapa_id = 6 where id = 8',               'etapas_especie_especie_etapa_unica'],
    ['update public.etapas_especie set orden = 5 where id = 8',                  'etapas_especie_especie_orden_unico'],
    ['update public.etapas_especie set orden = 0 where id = 8',                  'etapas_especie_orden_positivo'],
    ['update public.etapas_especie set duracion_estimada_dias = 0 where id = 8', 'etapas_especie_duracion_positiva'],
    ['update public.etapas_especie set duracion_estimada_dias = null where id = 8', 'not_null:duracion_estimada_dias'],
    ['update public.parametro_etapa set etapa_especie_id = 14 where id = 7',     'parametro_etapa_una_por_etapa'],
    ['update public.parametro_etapa set humedad_min = 80 where id = 6',          'parametro_etapa_humedad_rango'],
    ['update public.parametro_etapa set humedad_max = 101 where id = 6',         'parametro_etapa_humedad_rango'],
    ['update public.parametro_etapa set ph_max = 15 where id = 6',               'parametro_etapa_ph_rango'],
    ['update public.parametro_etapa set ideal_n = 0 where id = 6',               'parametro_etapa_npk_positivo'],
    ['update public.parametro_etapa set humedad_min = null where id = 6',        'not_null:humedad_min'],
    ['update public.tipo_etapa set nombre_etapa = ''Cosecha'' where nombre_etapa = ''Floración''', 'tipo_etapa_nombre_unico'],
    ['insert into public.especie_planta (nombre_comun) values (''Tomate Cherry'')', 'especie_planta_nombre_unico']
  ];
  i int;
  regla text;
  columna text;
  frenados int := 0;
begin
  for i in 1 .. array_length(casos, 1) loop
    begin
      execute casos[i][1];
      raise exception 'TEST FALLÓ: la base ACEPTÓ [%]', casos[i][1];
    exception when unique_violation or check_violation or not_null_violation then
      get stacked diagnostics regla = constraint_name, columna = column_name;
      if casos[i][2] like 'not_null:%' then
        if columna is distinct from substr(casos[i][2], 10) then
          raise exception 'TEST FALLÓ: [%] lo frenó NOT NULL de % y se esperaba %',
            casos[i][1], coalesce(columna, '(sin columna)'), casos[i][2];
        end if;
      elsif regla is distinct from casos[i][2] then
        raise exception 'TEST FALLÓ: [%] lo frenó % y se esperaba %',
          casos[i][1], coalesce(nullif(regla, ''), '(sin nombre)'), casos[i][2];
      end if;
      frenados := frenados + 1;
    end;
  end loop;

  -- Controles: dos cambios VÁLIDOS tienen que pasar. Si fallan, las reglas son
  -- demasiado estrictas (o la NOTA 1 no funciona) y el error lo dice.
  update public.etapas_especie set orden = orden + 1 where especie_id = 3;  -- NOTA 1
  update public.parametro_etapa set humedad_min = 61 where id = 6;

  raise exception 'TEST OK: % de % errores frenados, cada uno por la regla esperada; los 2 cambios válidos pasaron. Todo revertido: no quedó nada escrito.',
    frenados, array_length(casos, 1);
end $$;
