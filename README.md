# Sistema Experto Agrícola — Monitoreo y Riego en Lazo Cerrado

Sistema de monitoreo agronómico y riego automático para cultivos en maceta, construido sobre una arquitectura de orquestación de eventos. Un nodo sensor reporta siete mediciones del suelo (humedad, temperatura, pH, conductividad, N, P y K) y, opcionalmente, una foto. El sistema contrasta cada lectura contra umbrales agronómicos parametrizados por especie y etapa fenológica, persiste el resultado, notifica los desvíos, pide un diagnóstico por imagen cuando hay alerta y, ante déficit hídrico, ordena un riego dosificado y confirma después si funcionó.

Proyecto de tesis de grado.

---

## Arquitectura

```
Nodo sensor ──POST /arranque──► WF7 ──► la base asigna el número de arranque
     │
     ├─────POST /ordenes─────► WF8 ──► las órdenes de riego pendientes, una sola vez
     ├─────POST /orden-acuse─► WF8 ──► la placa avisa si regó
     │
     └─────POST /telemetria──► WF1 ──► ¿cumple el contrato? ──[no]──► 400 + registro del rechazo
                                ▼
                        Motor de inferencia (umbrales de la etapa actual)
                                │
                                ├──► guarda la lectura ──► 200 "aceptada" (o "duplicada" si ya estaba, y termina)
                                ├──► guarda la foto, si vino
                                ├──► Telegram (si hay desvío)
                                ├──► WF2: diagnóstico por imagen (si hay desvío y foto)
                                └──► WF5: orden de riego (si hay déficit hídrico)

WF3 (cada 8 h) ──► última foto ──► visión artificial ──► ¿avanzó de etapa?
```

| Componente | Implementación |
|---|---|
| Orquestación | n8n autoalojado en Docker, versión fijada (`2.19.5`) |
| Persistencia | PostgreSQL gestionado (Supabase): 17 tablas, 5 vistas y 9 funciones transaccionales; Storage para las fotos |
| Inferencia de umbrales | Determinística, en código, contra la base de conocimiento (`parametro_etapa`) |
| Visión artificial | Google Gemini, con un modelo de respaldo cuando el principal falla; acotada a diagnóstico y clasificación fenológica |
| Notificación | Bot de Telegram |
| Atomicidad | Toda escritura en más de una tabla pasa por una función de la base (`fn_registrar_*`) |

## Los workflows

| # | Nombre | Disparador | Función |
|---|---|---|---|
| WF1 | Orquestación | Webhook `/telemetria` | Valida el contrato, evalúa la lectura contra los umbrales, la persiste y decide |
| WF2 | Diagnóstico de emergencia | Llamado por WF1 | Análisis de imagen ante una alerta de umbral |
| WF3 | Validación fenológica | Programado, cada 8 h | Confirma por imagen el avance de etapa del cultivo |
| WF4 | Análisis preventivo | Programado, cada 6 h | Informe periódico de tendencia. **Inactivo por decisión** hasta contar con telemetría real |
| WF5 | Control de riego | Llamado por WF1 | Calcula la dosis con el volumen de la maceta y el caudal de la bomba, y registra la orden |
| WF7 | Registro de arranque | Webhook `/arranque` | Asigna a cada encendido de la placa un número que no se repite |
| WF8 | Entrega de órdenes | Webhooks `/ordenes` y `/orden-acuse` | Entrega a la placa sus órdenes de riego, cada una una sola vez y con vencimiento, y registra cómo terminó |

WF6 está reservado para los comandos por Telegram (pausar, reanudar, calibrar), todavía sin construir.

Los workflows están exportados en `WORKFLOWS/` con nombre estable, de modo que cada cambio se lea como diferencia entre versiones.

## El contrato de telemetría

Lo que manda el nodo sensor y lo que responde el sistema está definido en `docs/contrato_telemetria.md` (versión 1). En resumen:

- **Al encender**, la placa pide un número de arranque. Lo asigna la base, no la placa: así no puede repetirse.
- **Cada lectura** lleva las siete mediciones, el número de arranque, un número de secuencia y la hora de medición. Una medición que el sensor no pudo tomar se manda como `null`, nunca vacía ni omitida.
- **Una lectura que no cumple el contrato se rechaza entera** (`400`, con la lista de errores) y queda registrada. Una lectura mal formada no puede disparar un riego.
- **La placa pide sus órdenes de riego** con la misma clave que usa para las lecturas: nunca tiene una clave de la base. Cada orden se entrega una sola vez y vence a los 10 minutos, para que una placa que estuvo desconectada no riegue con órdenes viejas. Al terminar, la placa avisa si regó.
- **Temperatura y conductividad se guardan, pero no deciden.** Usarlas para diagnosticar requiere umbrales por etapa con fuentes, y queda como trabajo futuro.

## El lazo de riego

El riego tiene tres defensas independientes contra el exceso de agua:

1. **Confirmación por evidencia.** La primera lectura después de que se absorbió el riego lo evalúa: exitoso, insuficiente o falla del sistema. Una falla activa un freno, que se libera cuando una lectura posterior muestra la maceta húmeda. El aviso de falla distingue la causa por el estado de la orden: si la placa no confirmó que regó, hay que revisar la conexión; si confirmó y la humedad no subió, el tanque, la bomba, una fuga o el sensor.
2. **Tope duro en la base.** No más de cuatro riegos automáticos por cultivo en seis horas, aplicado dentro de la transacción que registra la orden.
3. **Válvula local en el firmware** (30 s como máximo), la única que funciona aunque fallen la red, el orquestador o la base. Diseñada; depende del hardware.

El sistema no riega solo si falta el volumen de la maceta o el caudal de la bomba: avisa por Telegram en lugar de suponer un valor.

## Estructura del repositorio

| Ruta | Contenido |
|---|---|
| `docs/implementation_plan.md` | **Documento de referencia del proyecto.** Diseño nodo por nodo, registro de hallazgos, decisiones y su fundamentación, y el historial de cambios |
| `docs/contrato_telemetria.md` | El contrato entre el nodo sensor y el sistema |
| `docs/CONTEXTO_AGENTE.md` | Resumen operativo del estado del sistema |
| `docs/revisiones/` | Auditorías técnicas: cobertura del ciclo, instrumentación, workflows y hoja de ruta |
| `SQL/` | Scripts de cambios en la base, cada uno con su estado previo, su verificación, su reverso y un test que se deshace solo; y guiones de prueba en vivo |
| `WORKFLOWS/` | Definiciones de los workflows (JSON de n8n) |
| `test/simulador.html` | Página local que simula la placa: encendido, lecturas sanas y con problemas, foto, rechazos y la recepción de órdenes de riego |
| `test/` | Además, escenarios de prueba y la foto de demostración |
| `docker-compose.yaml` | Despliegue del orquestador |

## Puesta en marcha

1. Crear un archivo `.env` junto a `docker-compose.yaml` con `N8N_ENCRYPTION_KEY`, la clave que cifra las credenciales de n8n. Está fuera del repositorio, y sin ella el contenedor no arranca.
2. Levantar el orquestador: `docker compose up -d`. Queda en `http://localhost:5678`.
3. Importar los JSON de `WORKFLOWS/` y crear las credenciales que referencian por nombre: la clave del dispositivo (Header Auth, cabecera `X-Device-Key`), el acceso a Supabase, la clave interna con la que WF1 llama a WF2 y WF5, Telegram y Gemini. Ningún secreto está en el repositorio.
4. Activar WF1, WF2, WF3, WF5, WF7 y WF8. WF4 queda apagado.

Para probar sin hardware, abrir `test/simulador.html` en el navegador, escribir la clave del dispositivo y empezar por "Encender placa".

## Criterios de diseño

El sistema está construido sobre un conjunto de principios que el documento de referencia desarrolla con su fundamentación. Los centrales:

- **Validación positiva.** Confirmar que una respuesta contiene lo que se espera, en lugar de asumir que la ausencia de error equivale a un resultado válido.
- **Normalizar en el borde.** Los datos se validan y se convierten una sola vez, a la entrada, antes del primer nodo que decide.
- **Rutear por hechos de dominio.** Las decisiones se toman sobre valores booleanos con significado agronómico, nunca sobre cadenas de presentación.
- **La definición vive en el productor.** Un concepto que usan varios consumidores se define en un solo lugar (por ejemplo, si un cultivo puede regarse solo se decide en la base).
- **Atomicidad donde hay escritura múltiple.** Toda operación que modifica más de una tabla se resuelve en una función transaccional.
- **Fallar de forma audible.** Una excepción visible es mejor que un dato incorrecto y creíble.
- **Verificar contra el estado persistido**, no contra el resultado intermedio de un nodo, y ejercer un defecto antes de corregirlo.

## Estado

- **Implementado y verificado en vivo** contra la base: la recepción con el contrato (arranque, validación y registro de rechazos), el diagnóstico por umbrales, el aviso de mediciones faltantes, el diagnóstico por imagen con modelo de respaldo, la validación fenológica y el lazo de riego completo con el nodo sensor simulado: la orden, su entrega a la placa, el aviso de que regó y la confirmación por la humedad.
- **Pendiente:** una clave distinta para cada placa (hoy todas comparten la misma).
- **El nodo sensor todavía no existe.** Se simula con el formato del contrato, y nada del sistema depende de él.
- **El orquestador corre en una computadora personal.** Un servidor accesible es el paso siguiente del despliegue.

El registro de hallazgos del documento de referencia lleva la cuenta de lo verificado, lo pendiente y lo diferido con su justificación.

**Backlog:** el [Project del repositorio](https://github.com/users/AgustinLago22/projects/2) muestra de un vistazo lo hecho, lo que falta y lo que queda fuera de alcance, con un issue por fase o pieza de trabajo. El detalle de cada uno sigue en el documento de referencia.

## Alcance y limitaciones

El trabajo verifica **el comportamiento del sistema de control**: la corrección de las decisiones del motor de inferencia, el aislamiento de fallos, la atomicidad de las escrituras y el comportamiento de las rutas de error bajo inyección de fallos.

La **validación agronómica de los umbrales queda fuera del alcance.** Los valores de `parametro_etapa` son umbrales operativos de decisión, derivados de curvas de absorción y rangos de suficiencia publicados, y documentados con su procedencia. No fueron contrastados contra un ensayo de campo. Hoy la base de conocimiento tiene una especie cargada (tomate cherry, seis etapas); agregar otra es cargar conocimiento, no modificar los workflows.
