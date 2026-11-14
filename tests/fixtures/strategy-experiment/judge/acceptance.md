# Aceptación común reservada al juez

Evaluar sin etiqueta del brazo, usando el mismo reloj, datos, versión y lista; registrar pistas que rompan el cegamiento.
Cada fallo lleva identidad, severidad, primera aparición, reparación y resultado final; no contar el mismo defecto dos veces.
Un skip, falta de fixture o tiempo agotado es inconcluso, no aprobado.

## A

- La publicación cubre los estados presentes en el checkpoint tanto si se captura primero como si se aplica después del estado cubierto, incluido el retraso de 11 segundos; se mantienen fase y 1 de 3 pasos.
- Una actualización posterior realmente no cubierta vuelve obsoleto el checkpoint; reaplicar eventos viejos no lo revive.
- Una resolución no declarativa y los duplicados no inventan cambio de avance; un checkpoint ya inválido por otra causa no se vuelve vigente.
- Usar la regresión de `tests/fm-work-activity.test.sh` introducida por `0a2f942ff3cfe4565b264e45915200f2e66ed520` como referencia sin aplicar su código de producto a la base.

## B

- Listo, dependencia, capacidad, respuesta y estacionado se distinguen con razón; desconocido no se convierte en cero.
- Secciones vacías siguen visibles con cero y los totales explican preguntas, acciones, reportes y aprobaciones sin duplicar identidades.
- Los dos reportes se muestran en la sección de revisión con enlace y resultado; el más reciente primero, sin confundir lectura con aprobación de merge.
- Se preserva la ventana de 24 h y el acceso explícito al historial; no se reactivan revisiones antiguas al transcurrir el tiempo.
- Tres proyectos plegados y un proyecto sin registrar son explicables; las tareas de una misma solicitud siguen separadas.
- En confirmación de espera, distinguir sesión activa y archivada; en confirmación de gasto, mostrar razón del costo desconocido y comprobar estabilidad de filas.
- Ejecutar aceptación visual y por teclado y checks del proyecto con el mismo fixture y límites en los tres brazos.

## C

- Las 24 anotaciones tienen id, elemento/localizador, solicitud, repositorio y aceptación trazable; comparar con `c-reference.json`, que no se entrega al participante.
- Separar hechos, hipótesis y desconocidos; señalar selectores posicionales como históricos y no atribuir causas o accesos sin prueba.
- La propuesta distingue tareas y dependencias por repositorio y no reabre L1–L23 sin evidencia posterior al pull.
- Adjuntar enlaces o rutas de evidencia y declarar ausentes workbook/tickets no suministrados.
