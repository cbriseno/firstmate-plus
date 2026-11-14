# Adaptador de B: pendiente de P12

Este documento fija el contrato esperado del caso B a partir de la ficha P12 del plan aprobado.
Todavía no existe un adaptador ejecutable: P12 es una pieza posterior y sus nombres de campos y forma de transporte no se conocen aquí.
El ejemplo `input/b-board.json` es una descripción semántica, no una respuesta real del productor.

## Correspondencia que debe conservar la adaptación

| Entrada del caso | Significado exigido por P12 |
|---|---|
| `ready` | Tarea lista para iniciar; no implica worker presente. |
| `dependency` | Espera una dependencia y explica cuál. |
| `capacity` | Espera capacidad; capacidad no configurada es desconocida, no cero. |
| `answer` | Espera respuesta humana; no es aprobación de merge. |
| `parked` | Tarea estacionada y motivo de espera; el estado de estacionamiento proviene de P03/P12. |
| `review` y `report` | Resultado con revisión pendiente y enlace; P15a conserva resultado/revisión en la declaración existente y el reporte HTML acompaña al Markdown. |
| `projects` y `requests` | Identidades distintas, proyecto no registrado explícito y tres proyectos plegados; no fusionar solicitudes por etiqueta. |
| `attention` | Desglose de preguntas, acciones, reportes y aprobaciones en el mismo cursor, sin duplicar una identidad entre categorías. |
| `clock` y `delivered_at` | Reloj fijo y entregas comparables; preservar la ventana automática de 24 h y el historial explícito previsto en P13. |

P12 debe exponer códigos y razones explícitos, unidad de conteo y liveness con edad/generación, manteniendo separados estado de tarea, presencia del worker y motivo de espera.
Una launch no equivale a una tarjeta y no se clasifica mediante heurísticas sobre prosa.
El contrato de P15a usa la declaración existente; no se supone que el campo canónico de reporte Markdown ya contenga HTML.

## Antes de ejecutar B

1. Obtener el commit y ejemplos reales entregados por P12 y P15a y fijarlos en el manifiesto de la corrida.
2. Traducir cada fila del ejemplo a esos formatos reales dentro de una copia aislada, sin cambiar identidades, estados, razones, reloj ni categorías.
3. Comparar un mismo cursor del productor y del Deck: cinco motivos, pertenencia a proyectos, unidades de conteo y composición de atención.
4. Comprobar que los dos informes abren fuera de línea y que el más reciente aparece primero en la sección de revisión.
5. Si falta un campo o no existe un mapeo fiel, anotar el dato y dejar la ejecución de B inconclusa hasta resolver el contrato; no inventar valores.

Estas comprobaciones son preparación del ensayo futuro; no se han ejecutado aquí y no son una aceptación de P12 ni de P13.
