# Preparación del experimento de estrategias

Estos materiales preparan casos y medición; no son resultados, no instalan cambios y no autorizan iniciar ensayos.
El protocolo completo y la revisión independiente se conservan en `data/plan-reportes-mac-b-20261114/report.md` y `data/revision-plan-mac-b-20261114/report.md` del home que encargó el trabajo.
Los datos de `input/` son sintéticos salvo las anotaciones anonimizadas de C; `judge/` y las soluciones históricas no se entregan a los participantes.
El juez recibe los resultados sin etiqueta de brazo y registra cualquier pista que revele el proceso.

## Pasos manuales antes de cada ensayo

1. Leer una muestra pequeña de cada repo, fuente y servicio necesario, incluido acceso anónimo donde aplique; registrar ausencias antes de iniciar.
2. Congelar el manifiesto de abajo con las revisiones, pedido literal, fixture, versión de herramientas, modelos/esfuerzos, capacidad y política de relevo; no reutilizar el chat ni los resultados de otro brazo.
3. Preparar copias aisladas del repositorio, del fixture de entrada y de los contratos de productor; el juez conserva `judge/` fuera de la copia del participante.
4. Registrar el orden rotado V/D/S y la caché inicial conocida o desconocida; no ejecutar brazos distintos simultáneamente en recursos compartidos.
5. Correr el brazo en su copia; dentro de B, D/S permiten hasta tres implementadores según capacidad y deben registrar coordinación e integración.
6. Recoger sesiones y datos por función, sin repartir artificialmente sesiones mixtas; registrar tiempos, cuota, contexto, defectos, intervenciones y resultado en `measurement-template.md`.
7. Hacer evaluar el resultado por un juez independiente contra la misma aceptación y registrar límites, fallos, reparaciones e incompletos.
8. Conservar los resultados y comparaciones por par; no fusionar ni publicar candidatos de ensayo.

Para V usar un solo worker Codex con Terra high en A/C o Sol high en B y aceptación SDLC independiente.
D y S usan Astra high en análisis/plan y Opus 5.5 high para revisión independiente del plan; implementación y validación usan la misma clase Codex que V.
S usa el core de Spec Kit ya existente, no un framework nuevo; coordinación tiene el mismo perfil Sol para los brazos.
Todo ensayo que opere panes requiere un brief propio con `--herdr-lab`; este material no lo autoriza.
La comprobación del vínculo de sesión no cuenta como corrida.

## Manifiesto preparado: completar y verificar antes de congelar

| Campo | Valor preparado o pendiente |
|---|---|
| A, Firstmate, base anterior a P10 | `d073a554aec803ecc18e22709d21afec3281cfa9`; regresión histórica en commit `0a2f942ff3cfe4565b264e45915200f2e66ed520`, reservada al juez. |
| B, Deck, base anterior a P13 | `3f70a3187dba5e0fb38e46ec652585439ebb511f`, confirmar que sigue siendo anterior a P13 y que reproduce el contrato antes de congelar. |
| C, fuente | `data/reportes-mac-20261114b/x/issues.md` y `x/attachments/`; copiar fuentes y adjuntos al fixture aislado, sin incluir `judge/c-reference.json`. |
| Core S | Spec Kit 1.2.4, `43486672fe826d230d884815be7cc2026469a6ba`; verificar el pin y versión efectiva al preparar cada brazo. |
| Contratos B | `input/b-board.json` congela un ejemplo semántico, no el formato de producción; P15a está en `ab7705fdc7ba1aeeb3cb32b35c2410e79684ae74`; conectar y fijar ejemplos reales de P12 y de resultado/revisión antes del ensayo. |
| P02 / precio | Verificar vínculo real y tarifas oficiales o P08 antes del piloto, con moneda, fuente y fecha; nunca inferir el costo faltante como cero. |
| Versiones de herramientas / carga / caché | Pendientes de medición inmediatamente antes de ejecutar. |
| Relevo y capacidad | Misma política en todos los brazos; registrar parámetros y capacidad disponible. |
| Orden y límites | Registrar secuencia rotada antes de ver resultados; piloto 2 h por corrida y dos reparaciones, calibrar después un límite común de 1,5–4 h por muestra. |
| Presupuesto | Plan orientativo: 150–300 USD equivalentes a precio de lista y hasta 10 puntos semanales de Codex; recalibrar con el piloto y cuota observada sin reinicios ni créditos. |
| Estado | **Preparado parcialmente: P12/P15a, tarifas y condiciones de ejecución aún no están congelados; no empezar el ensayo con este manifiesto.** |

## Casos

**A:** `input/a-events.json` fija contenido, dos órdenes y retraso de captura de 11 segundos.
Ejecutar los productores reales con un home desechable, no dormir 11 segundos: asignar o controlar las marcas de tiempo del fixture cuando la interfaz lo permita.
El juez usa la regresión histórica del commit indicado y sus propias condiciones de `judge/acceptance.md`; no dar el parche de la solución al participante.
Una declaración vigente, una actualización no cubierta y la llegada inversa deben evaluarse por separado.

**B:** `input/b-board.json` describe una solicitud multitarea, tres proyectos plegados, un proyecto sin registrar, cinco tipos de estado y dos reportes.
Los archivos `old.html` y `new.html` son informes locales autocontenidos.
El contrato es semántico y deliberadamente independiente del wire format; el ejecutor debe traducirlo al fixture real de Deck usando los ejemplos de P12/P15a congelados antes de iniciar, sin alterar sus significados ni la aceptación.
La base debe conservar las correcciones existentes, incluida la ventana automática de 24 h; fijar reloj del fixture a una hora compatible, sin reactivar revisiones históricas.
Las confirmaciones de `judge/b-confirmation-*.json` se ejecutan solo después de la comparación principal; no mostrar esas variantes al participante antes de fijar los resultados de pantalla.

El residual `sk-pilot-deck-residual` se refería al piloto de accesibilidad del grupo de apariencia en Deck, no a este caso de estados/reportes.
Su brief y la revisión están en `data/sk-pilot-deck/brief-draft.md` y `data/sk-pilot-deck/report.md`; el commit de planificación es `5ead6260142db50f6b40fcf822c8de5ccaa49373`.
Ese caso pedía AC-01–04, localización, teclado, persistencia y fallbacks; B es un **sustituto**, no una repetición ni validación de esos criterios de accesibilidad.
No cerrar el residual ni declarar aceptada la corrección del plan anterior desde este fixture.

**C:** entregar `input/c-annotations.json`, el reporte b y sus adjuntos originales al participante.
Las 24 anotaciones preservan id, selector, tag, texto y solicitud; el juez usa la referencia separada y comprueba atribución, límites, cobertura y ruta por repositorio.
Los selectores posicionales son evidencia histórica, no identidad estable de producción.
El workbook o tickets no incluidos quedan fuera y su acceso no se inventa.

## Medición y decisión

`measurement-template.md` es una hoja manual, no un segundo sistema de registros.
Para Codex se reutiliza `planning/bin/measure-task`; para uso y tarifas se consulta `fm_task_usage.py` cuando corresponda.
La salida de `measure-task` usa el último contador acumulado de cada sesión: entrada de caché es parte de entrada, no se suma otra vez.
Claude se completa manualmente desde evidencia disponible, y un dato ausente se declara desconocido con razón.
El tiempo activo puede incluir espera de herramientas y no sustituye el reloj, el camino crítico o la espera humana.

Se requieren 3 muestras por V/D/S y dos variantes B frente al mejor candidato y V, para 13 corridas solo si el piloto demuestra que caben en cuota y costo.
Antes de comparar costo o tiempo, exigir igual aceptación final, ningún defecto alto/crítico sin resolver y ambas variantes aceptadas.
Calcular razones emparejadas frente a V y mediana por clase, sin mezclar A/C con B: objetivo de costo al menos 25 % menor con tiempo no más de 10 % mayor y ninguna muestra más de 25 % lenta, o tiempo al menos 25 % menor con costo no más de 10 % mayor.
Si faltan evidencia, presupuesto o aceptación, conservar el default y declarar el resultado inconcluso; esta muestra no acredita significancia estadística.
