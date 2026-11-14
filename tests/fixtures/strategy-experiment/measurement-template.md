# Registro manual de una corrida

Copiar esta hoja para cada corrida y una adicional para preparación compartida.
No escribir datos privados ni transcripciones completas; conservar rutas de evidencia en almacenamiento autorizado.
Cuando falte un dato, escribir `desconocido` y el motivo; cero exige evidencia.

- Caso / variante / brazo anónimo para el juez:
- Orden y registro previo / fecha UTC / operadores:
- Repositorio y commit base / versión de fixture y contratos:
- Pedido literal y entorno aislado:
- Herramientas, arneses, modelos, esfuerzo, versión Spec Kit:
- Capacidad, carga concurrente y estado inicial de caché:
- Política de relevo, umbrales, cuota inicial/final y concurrencia que limite atribución:
- Reloj UTC: solicitud, inicio, fin, aceptación; esperas humanas y de infraestructura:
- Tiempo real / suma de actividad / camino crítico / explicación de esperas:
- Resultado: aceptado, rechazado o inconcluso; razón y límites:
- Evidencia del recorrido, prueba contra base, check, revisión independiente e instalación aislada:

## Sesiones y funciones

Añadir una fila por sesión o por tramo medible; si una sesión mezcla funciones sin deltas, marcarla `mixta` y contarla una sola vez.
Las funciones son coordinación, análisis, planificación, revisión del plan, implementación, revisión/pruebas, integración y aceptación.

| Tarea | Sesión o referencia | Arnés | Modelo | Esfuerzo | Función/tramo | Inicio/fin UTC | Evidencia y completitud |
|---|---|---|---|---|---|---|---|
| | | | | | | |

| Sesión/tramo | Entrada total | Entrada nueva | Lectura caché | Escritura caché | Salida | Fuente y faltantes |
|---|---|---|---|---|---|---|
| | | | | | | |

Entrada nueva = entrada total menos lectura de caché solo cuando ambas son contadores compatibles; confirmar si la escritura de caché ya está incluida según el proveedor.
Salida de razonamiento es parte de salida cuando así la define el proveedor, no una suma extra.
No estimar un reparto por función desde el tiempo ni tratar la salida de `measure-task` como medición de Claude.

## Estimación a precio de lista

| Modelo | Moneda | Fecha y fuente de tarifa | Tarifa entrada nueva | Tarifa lectura caché | Tarifa escritura caché | Tarifa salida | Tokens correspondientes | Subtotal o desconocido |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | |

- Unidad de tarifa y cálculo verificable / conversión de moneda y fuente si aplica:
- Antigüedad de la tarifa y aviso de precio viejo:
- Total por función y total de preparación compartida, coordinación, workers, revisión e integración:
- Total completo o parcial con razón; esto es **estimación a precio de lista**, no factura:

## Contexto, calidad y personas

| Sesión | Pico / ventana | Compactaciones | Relevos | Relecturas observables | Fuente / dato desconocido |
|---|---|---|---|---|---|
| | | | | | |

| Defecto único | Severidad | Primer intento | Reparaciones | Resultado final | Evidencia |
|---|---|---|---|---|---|
| | | | | |

| Intervención humana | Motivo | Minutos | Steering ordinario o rescate | Evidencia |
|---|---|---|---|---|
| | | | |

- Primera aceptación / aceptación final / diff final y check:
- Limitaciones de cegamiento y diferencias entre brazos:
- Razones emparejadas de costo y reloj frente a V para la misma muestra; sin mezclar clases:
