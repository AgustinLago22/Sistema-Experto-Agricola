# Sistema Experto Agrícola — Monitoreo y Riego en Lazo Cerrado

Sistema de monitoreo agronómico y riego automático para cultivos en maceta, construido sobre una arquitectura de orquestación de eventos. Un nodo sensor reporta humedad de sustrato, pH y NPK; el sistema contrasta cada lectura contra umbrales agronómicos parametrizados por especie y etapa fenológica, persiste el resultado, notifica las desviaciones y, ante déficit hídrico, ordena un riego dosificado.

Proyecto de tesis de grado.

---

## Arquitectura

```
Nodo sensor ──POST──► Orquestador ──► Motor de inferencia ──► Base de datos
                          │                    │
                          │                    ├──► Notificación (desvío)
                          │                    └──► Orden de riego (déficit)
                          │
                          └──► Visión artificial ──► Validación fenológica
```

| Componente | Implementación |
|---|---|
| Orquestación | n8n autoalojado (Docker) — cinco workflows |
| Persistencia | PostgreSQL gestionado (Supabase), 12 tablas y 4 vistas |
| Inferencia de umbrales | Determinística, en código, contra `parametro_etapa` |
| Visión artificial | Modelo multimodal, acotado a clasificación fenológica |
| Notificación | Bot de mensajería |
| Atomicidad | Funciones transaccionales en la base (`fn_registrar_*`) |

## Los cinco workflows

| # | Nombre | Disparador | Función |
|---|---|---|---|
| WF1 | Orquestación | Webhook | Recibe telemetría, evalúa contra umbrales, persiste y decide |
| WF2 | Diagnóstico de emergencia | Llamado por WF1 | Análisis de imagen ante una alerta de umbral |
| WF3 | Validación fenológica | Programado, 8 h | Confirma por imagen el avance de etapa del cultivo |
| WF4 | Análisis preventivo | Programado | Informe periódico de tendencia (inactivo por decisión) |
| WF5 | Control de riego | Llamado por WF1 | Calcula la dosis y emite la orden al actuador |

Los cinco están exportados en `WORKFLOWS/` con nombre estable, de modo que cada cambio sea legible como diferencia entre versiones.

## Estructura del repositorio

| Ruta | Contenido |
|---|---|
| `docs/implementation_plan.md` | **Documento de referencia del proyecto.** Diseño nodo por nodo, registro de hallazgos, decisiones y su fundamentación |
| `docs/CONTEXTO_AGENTE.md` | Resumen operativo del estado del sistema |
| `docs/revisiones/` | Auditorías técnicas: cobertura del ciclo, instrumentación, workflows y hoja de ruta |
| `SQL/` | Esquema, funciones transaccionales y guiones de prueba |
| `WORKFLOWS/` | Definiciones de los cinco workflows |
| `test/` | Escenarios de prueba y material de demostración |
| `docker-compose.yaml` | Despliegue del orquestador |

## Criterios de diseño

El sistema está construido sobre un conjunto de principios que el documento de referencia desarrolla con su fundamentación teórica. Los centrales:

- **Validación positiva.** Confirmar que una respuesta contiene lo que se espera, en lugar de asumir que la ausencia de error equivale a un resultado válido.
- **Rutear por hechos de dominio.** Las decisiones se toman sobre valores booleanos con significado agronómico, nunca sobre cadenas de presentación.
- **Atomicidad donde hay escritura múltiple.** Toda operación que modifica más de una tabla se resuelve en una función transaccional; no existe el dual-write.
- **Fallar de forma audible.** Una degradación silenciosa es peor que un error: un sistema que afirma estar funcionando sin hacerlo no admite corrección.
- **Verificar contra el estado persistido**, no contra el resultado intermedio de un nodo.

## Estado

Los cinco workflows están implementados. Cuatro operan en producción; el análisis preventivo permanece inactivo de forma deliberada. El lazo de control se encuentra cerrado en su rama de decisión y abierto en la de confirmación física, a la espera del nodo sensor.

El registro de hallazgos del documento de referencia lleva la cuenta de lo verificado, lo pendiente y lo diferido con su justificación.

## Alcance y limitaciones

El trabajo verifica **el comportamiento del sistema de control**: la corrección de las decisiones del motor de inferencia, el aislamiento de fallos, la atomicidad de las escrituras y el comportamiento de las rutas de error bajo inyección de fallos.

La **validación agronómica de los umbrales queda fuera del alcance.** Los valores de `parametro_etapa` son umbrales operativos de decisión, derivados de curvas de absorción y rangos de suficiencia publicados, y documentados con su procedencia. No fueron contrastados contra un ensayo de campo.
