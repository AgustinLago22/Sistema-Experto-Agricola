-- ============================================================================
-- Sesión 13 · Cargar Fructificación y los umbrales de Cosecha
--
-- Cierra: B.1 (falta la etapa) · 16.41 (Cosecha sin umbrales) · 16.37 (la
-- guarda de "etapa sin umbrales" pasa a ser alcanzable y testeable)
-- Desbloquea: el cultivo a1327127, varado en `etapa_no_coincide` (16.31)
--
-- NO EJECUTAR TODAVÍA. Leer primero.
-- Escrito el 23/09/2026 contra el estado verificado ese día.
-- Versión 2: valores derivados de fuentes citadas (ver FUNDAMENTACIÓN).
-- ============================================================================


-- ============================================================================
-- FUNDAMENTACIÓN DE LOS VALORES
--
-- ADVERTENCIA DE MÉTODO, léase antes que los números:
-- Las columnas `humedad_*` e `ideal_n/p/k` de `parametro_etapa` NO tienen
-- unidad documentada en ningún lado del proyecto. La literatura reporta
-- humedad como % de capacidad de campo o como tensión (kPa), y nutrientes
-- como ppm en solución o kg/ha. Ninguna de esas escalas coincide con la que
-- ya está cargada (Floración: humedad 50-65, N 30, P 50, K 60).
--
-- Por lo tanto los valores de abajo NO se copiaron de las fuentes. Se derivó
-- de las fuentes la DIRECCIÓN y la MAGNITUD RELATIVA del cambio entre etapas,
-- y se aplicó sobre la escala que el proyecto ya venía usando. Las relaciones
-- entre etapas son defendibles; los valores absolutos siguen siendo internos
-- al sistema hasta que se documente la unidad y se calibre el sensor.
-- Eso último es un pendiente aparte y hay que anotarlo.
--
-- ----------------------------------------------------------------------------
-- HUMEDAD
--
-- [1] FAO, Irrigation and Drainage Paper 56, Tabla 22: el tomate tiene
--     fracción de agotamiento p = 0.40, o sea que tolera perder hasta el 40 %
--     del agua disponible antes de entrar en estrés. Es el piso teórico.
--     https://www.fao.org/4/x0490e/x0490e0e.htm
--
-- [2] Wang et al. (2019), PLOS ONE 14(3): e0213643. Ensayo con tres niveles
--     de humedad por etapa. En desarrollo del fruto y maduración lo óptimo
--     fue 80-90 % de capacidad de campo; 60-70 % produjo estrés justo en esas
--     etapas. O sea: la fructificación es la etapa de MAYOR demanda hídrica,
--     no menor.
--     https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0213643
--
-- [3] University of Minnesota Extension: "Consistent soil moisture levels
--     will help produce the best quality fruit. When soil moisture levels
--     fluctuate during fruit growth, blossom-end rot can develop."
--     https://extension.umn.edu/vegetables/growing-tomatoes
--
-- [4] UC IPM, Irrigation of Processing Tomatoes: cerca de cosecha se aplica
--     déficit a propósito — corte de riego 3 a 4 semanas antes — para subir
--     sólidos solubles con pérdida mínima de rendimiento.
--     https://ipm.ucanr.edu/agriculture/tomato/irrigation-of-processing-tomatoes/
--
-- CONCLUSIÓN: la humedad SUBE en Fructificación y BAJA en Cosecha. Esto
-- rompe el descenso monótono que traía la tabla, y lo rompe con fundamento:
-- el descenso venía siendo correcto hasta Floración, y [2] muestra que se
-- invierte en el llenado del fruto. Para Fructificación se reusa la banda
-- 60-75 que el proyecto ya tenía en Vegetativo, la más alta después de las
-- etapas de establecimiento.
--
-- ----------------------------------------------------------------------------
-- NPK
--
-- [5] e-GRO Alert E809, "N and K for Tomato Production": la relación K:N es
--     el determinante principal de la calidad del fruto, y sube por etapa —
--     1:1 antes de la primera flor, 1.4:1 del primer al cuarto racimo,
--     1.7:1 del cuarto racimo en adelante. "Potassium slows vegetative
--     growth and redirects sugars to the fruit."
--     https://e-gro.org/pdf/E809.pdf
--
-- [6] Yara, Role of Nutrients by Tomato Growth Stage: en maduración el N se
--     requiere en cantidad REDUCIDA, solo para sostener el llenado, mientras
--     el K llega a su momento crítico.
--     https://www.yara.us/crop-nutrition/tomato/role-of-nutrients-growth-stage/
--
-- [7] Wang et al. (2019), mismo trabajo que [2]: "excess of K fertilization
--     during FM stage should be avoided to maintain tomato yield". O sea que
--     el K no sube indefinidamente: se sostiene y después afloja.
--
-- [8] Efectos de distintas relaciones NPK en tomate cherry en cultivo sin
--     suelo (Technology in Horticulture, 2026): el K₂O fue el factor de mayor
--     efecto sobre rendimiento Y sobre sólidos solubles, con interacción
--     P × K significativa — el P no rinde si el K no acompaña.
--     https://www.maxapress.com/article/doi/10.48130/tihort-0026-0009
--
-- CONCLUSIÓN: N desciende monótono después del pico vegetativo [6].
-- P desciende después del pico de floración. K:N sigue subiendo en
-- fructificación [5] y afloja en cosecha [7].
-- Lo ya cargado da K:N = 0.6 en Vegetativo y 2.0 en Floración. Se continúa
-- esa curva: 2.4 en Fructificación, 2.25 en Cosecha.
--
-- ----------------------------------------------------------------------------
-- pH
--
-- [3] UMN Extension da 5.5-7.0 para tomate. El proyecto ya venía usando
--     6.0-6.8, que cae adentro y es el rango de máxima disponibilidad de
--     nutrientes. Se mantiene por coherencia interna; no hay motivo para
--     cambiarlo por etapa.
--
-- ----------------------------------------------------------------------------
-- DURACIÓN DE FRUCTIFICACIÓN: 40 días
--
-- [9] Quinet et al. (2019), "Tomato Fruit Development and Metabolism",
--     Frontiers in Plant Science 10:1554. El desarrollo del fruto tiene tres
--     fases: división celular hasta ~10 días después de antesis, expansión
--     celular de 10 a 40 días —que termina en verde maduro—, y maduración
--     a partir de ~40 días.
--     https://www.frontiersin.org/articles/10.3389/fpls.2019.01554/full
--
-- Fructificación = de cuaje a verde maduro ≈ 40 días. Cosecha se deja en los
-- 30 días que ya tenía: en un cherry indeterminado la cosecha es una ventana
-- larga, no la maduración de un fruto.
--
-- OJO CON EL EFECTO LATERAL: WF3 abre su ventana de evaluación al 80 % de la
-- duración. Con 40 días, un cultivo que entre a Fructificación no vuelve a
-- ser evaluado hasta el día 32. Es mucho silencio. Se anota como pendiente.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- PASO 0 · Estado ANTES. Correr solo esto primero y guardar el resultado.
--          Sin una foto del antes no hay forma de revertir con precisión.
-- ----------------------------------------------------------------------------

select ee.id as etapas_especie_id, ee.especie_id, ee.orden,
       te.nombre_etapa, ee.duracion_estimada_dias,
       pe.id as parametro_id, pe.humedad_min, pe.humedad_max,
       pe.ph_min, pe.ph_max, pe.ideal_n, pe.ideal_p, pe.ideal_k
from etapas_especie ee
join tipo_etapa te on te.id = ee.etapa_id
left join parametro_etapa pe on pe.etapa_especie_id = ee.id
order by ee.especie_id, ee.orden;

-- Esperado hoy: 8 filas. Especie 3 (Tomate) con órdenes 1..5 y Cosecha (id 8)
-- sin fila en parametro_etapa. Especie 4 con dos etapas sin umbrales — fuera
-- del alcance de este script, queda anotado.


-- ----------------------------------------------------------------------------
-- PASO 1 · La transacción. Todo o nada.
--
-- Por qué en una sola transacción y no en tres scripts: cargar Fructificación
-- sin cargar los umbrales de Cosecha deja al cultivo pudiendo avanzar a una
-- etapa sin umbrales. Es exactamente la advertencia de 16.42. Las tres
-- escrituras tienen que ser un solo hecho.
-- ----------------------------------------------------------------------------

begin;

-- 1.1 · Guarda de idempotencia. Si la etapa ya existe, este script ya corrió.
--       Falla fuerte en vez de duplicar el catálogo (16.24: un catálogo
--       duplicado no da error, hace que el índice de la etapa actual resuelva
--       mal y el cultivo deje de evaluarse en silencio).
do $$
begin
  if exists (select 1 from tipo_etapa where nombre_etapa = 'Fructificación') then
    raise exception 'Fructificación ya existe en tipo_etapa. Este script ya se aplicó.';
  end if;
end $$;


-- 1.2 · La etapa nueva en el catálogo global de etapas.
insert into tipo_etapa (nombre_etapa) values ('Fructificación');


-- 1.3 · Correr Cosecha un lugar hacia abajo para hacerle lugar.
--       Se cambia el ORDEN, no el id. El id 8 sigue siendo Cosecha, así que
--       las filas históricas de evaluacion_fenologica y seguimiento_fenologico
--       que apuntan a 8 siguen significando lo mismo.
update etapas_especie
set orden = 6
where especie_id = 3
  and etapa_id = (select id from tipo_etapa where nombre_etapa = 'Cosecha');


-- 1.4 · Fructificación en la secuencia del Tomate Cherry, en el lugar 5.
--       40 días: fase de expansión celular, de cuaje a verde maduro [9].
insert into etapas_especie (especie_id, etapa_id, orden, duracion_estimada_dias)
values (
  3,
  (select id from tipo_etapa where nombre_etapa = 'Fructificación'),
  5,
  40
);


-- 1.5 · Umbrales de Fructificación.
insert into parametro_etapa (etapa_especie_id, humedad_min, humedad_max, ph_min, ph_max, ideal_n, ideal_p, ideal_k)
values (
  (select ee.id from etapas_especie ee
   join tipo_etapa te on te.id = ee.etapa_id
   where ee.especie_id = 3 and te.nombre_etapa = 'Fructificación'),
  60, 75,      -- SUBE respecto de Floración [2][3]. Misma banda que Vegetativo
  6.0, 6.8,    -- [3]
  25,          -- N sigue bajando tras el pico vegetativo [6]
  40,          -- P baja desde el pico de Floración
  60           -- K:N = 2.4, continúa la curva ascendente [5][8]
);


-- 1.6 · Umbrales de Cosecha. Esto es 16.41.
insert into parametro_etapa (etapa_especie_id, humedad_min, humedad_max, ph_min, ph_max, ideal_n, ideal_p, ideal_k)
values (
  (select ee.id from etapas_especie ee
   join tipo_etapa te on te.id = ee.etapa_id
   where ee.especie_id = 3 and te.nombre_etapa = 'Cosecha'),
  45, 60,      -- déficit controlado, sube sólidos solubles [4]
  6.0, 6.8,    -- [3]
  20,          -- N reducido, solo sostén del llenado [6]
  30,
  45           -- K afloja: el exceso en maduración perjudica [7]
);


-- 1.7 · Verificación DENTRO de la transacción, antes de confirmar.
--       Si algo no cuadra, el rollback del paso 2 deja todo como estaba.
select ee.orden, te.nombre_etapa, ee.duracion_estimada_dias,
       pe.humedad_min, pe.humedad_max, pe.ideal_n, pe.ideal_p, pe.ideal_k,
       round((pe.ideal_k / nullif(pe.ideal_n, 0))::numeric, 2) as relacion_k_n
from etapas_especie ee
join tipo_etapa te on te.id = ee.etapa_id
left join parametro_etapa pe on pe.etapa_especie_id = ee.id
where ee.especie_id = 3
order by ee.orden;

-- Esperado: 6 filas, órdenes 1 a 6 sin huecos ni repetidos, NINGUNA con los
-- umbrales en null, y la relación K:N creciendo 0.20 · 0.75 · 0.60 · 2.00 ·
-- 2.40 · 2.25. El salto de Vegetativo a Floración es el viraje reproductivo.


-- ----------------------------------------------------------------------------
-- PASO 2 · Elegir una de las dos líneas siguientes.
-- ----------------------------------------------------------------------------

-- rollback;   -- si el paso 1.7 no dio lo esperado
-- commit;     -- si dio lo esperado


-- ============================================================================
-- PASO 3 · APARTE, y con su propia confirmación: destrabar el cultivo.
--
-- Cargar el catálogo NO alcanza para que la planta avance.
--
-- El 19/09 WF3 evaluó la foto y, al terminar, marcó
-- `cultivo.ultima_foto_evaluada_path` con esa foto. Esa marca es la
-- deduplicación de 16.21: impide volver a analizar la misma imagen. Funciona
-- bien, pero significa que la única foto disponible ya fue consumida —
-- con el catálogo viejo, que no tenía Fructificación.
--
-- O sea: aunque ahora la etapa exista, WF3 va a filtrar esa foto y el cultivo
-- se queda en Floración igual. Es el problema que 16.25 describe: la evidencia
-- se consume aunque la decisión que se tomó con ella haya quedado mal.
--
-- Hay dos caminos:
--
--   a) Sacar una foto nueva de la planta y mandarla por el webhook. Es lo
--      correcto si la planta existe: la foto del 18/08 tiene más de un mes.
--
--   b) Limpiar la marca para que WF3 reevalúe la foto vieja. Con el catálogo
--      nuevo, la respuesta ya registrada ("Fructificación", 0.95) coincidiría
--      con la etapa esperada y el cultivo avanzaría. Sirve para ejercer el
--      camino `avanza` en producción, que nunca se ejerció.
--      Costo: avanza con evidencia de hace un mes, y `fecha_inicio_etapa`
--      arranca hoy.
--
-- Si elegís (b), esta es la línea. Requiere confirmación aparte.
-- ============================================================================

-- update cultivo
-- set ultima_foto_evaluada_path = null
-- where id = 'a1327127-1570-474a-a49e-6d506b300759';

-- Para revertir el paso 3:
-- update cultivo
-- set ultima_foto_evaluada_path = 'a1327127-1570-474a-a49e-6d506b300759/1787251621094.jpg'
-- where id = 'a1327127-1570-474a-a49e-6d506b300759';


-- ============================================================================
-- CÓMO REVERTIR EL PASO 1, si ya se hizo commit
-- ============================================================================

-- begin;
-- delete from parametro_etapa
--  where etapa_especie_id in (
--    select ee.id from etapas_especie ee
--    join tipo_etapa te on te.id = ee.etapa_id
--    where ee.especie_id = 3 and te.nombre_etapa in ('Fructificación','Cosecha'));
-- delete from etapas_especie
--  where especie_id = 3
--    and etapa_id = (select id from tipo_etapa where nombre_etapa = 'Fructificación');
-- update etapas_especie set orden = 5
--  where especie_id = 3
--    and etapa_id = (select id from tipo_etapa where nombre_etapa = 'Cosecha');
-- delete from tipo_etapa where nombre_etapa = 'Fructificación';
-- commit;

-- Ojo: esto solo es limpio mientras ningún cultivo haya entrado a
-- Fructificación. Si alguno avanzó, hay filas en seguimiento_fenologico y
-- evaluacion_fenologica apuntando a esa etapas_especie_id, y el delete
-- las arrastra por ON DELETE CASCADE.
