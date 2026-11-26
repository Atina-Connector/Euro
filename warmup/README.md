# Calentamiento de JP55MULE validateSalesOrder

`warmup.sh` le manda al microservicio un **pedido de calentamiento**: `validateSalesOrder` con `correlationId` que
empieza con `WARMUP` y **sin `detail`**. No se procesa ningún pedido ni se escribe nada en JDE (sin cabecera EDI, sin
F5542012, sin consulta, sin totales).

El servicio:

1. Ejecuta `GetCurrentUTime` en la sesión de Atina (S0), la que usan la cabecera, la consulta y los totales.
2. Con `JP55MULE_ORDER_VALIDATION_WORKER_CONNECTION=POOLED`, crea el pool de sesiones del usuario/entorno/rol y espera
   a que esté completo (cada sesión nueva ejecuta `GetCurrentUTime`), como máximo
   `JP55MULE_ORDER_VALIDATION_WARMUP_TIMEOUT_SECONDS` (120 s por defecto). Si el pool ya está completo responde enseguida.
3. Responde sin líneas, con un mensaje y una línea de log `ORDER_VALIDATION_WARMUP`:

```
WARMUP correlationId=WARMUP-host-20261126190000 requestSession=OK requestSessionMs=35 workerConnection=POOLED
maxConcurrency=10 globalMaxConcurrency=20 poolFull=Y poolWaitMs=18400 pool=ATINAD|JUAT920|*ALL target=10 open=10
idle=10 created=10 keepAliveSec=600 kernels=8/10 totalMs=18460
```

Un pedido **con** líneas siempre es un pedido normal, aunque su `correlationId` empiece con `WARMUP`. Un pedido sin
líneas y sin el prefijo sigue siendo inválido, como antes.

## Concurrencia y tamaño del pool

- `JP55MULE_ORDER_VALIDATION_MAX_CONCURRENCY`: líneas de un pedido que se procesan a la vez (una sesión por línea).
- `JP55MULE_ORDER_VALIDATION_SESSION_POOL_SIZE`: sesiones del pool. **Si no se define, toma el valor de
  `MAX_CONCURRENCY`**. Si es menor, las líneas que no encuentran sesión libre van por DEDICATED (más lentas, en el
  kernel de S0); el resumen del calentamiento lo avisa con `note=pool smaller than maxConcurrency`.
- Atina serializa las llamadas a servicios web (`JDEWSDriver.callJDEWS` es `synchronized`), así que hoy no hay dos
  pedidos a la vez: alcanza con un pool del tamaño de `MAX_CONCURRENCY`.
- Si el pool es más grande que los kernels CallObject disponibles, varias sesiones caen en el mismo kernel (ver
  `kernels=8/10`).

## Configuración del script

Variables de entorno (las credenciales nunca se escriben en el script ni en el crontab):

| Variable | Default | |
|---|---|---|
| `WARMUP_ATINA_URL` | `http://localhost:8086` | URL REST de Atina |
| `WARMUP_JDE_USER` / `WARMUP_JDE_PASSWORD` | (obligatorias) | el mismo usuario que usa Mule (el pool es por usuario/entorno/rol) |
| `WARMUP_JDE_ENVIRONMENT` / `WARMUP_JDE_ROLE` | `JUAT920` / `*ALL` | |
| `WARMUP_WAIT_SECONDS` | 300 | reintenta el login cada 10 s mientras el microservicio arranca |
| `WARMUP_CALL_TIMEOUT_SECONDS` | 300 | timeout HTTP de la llamada (mayor que la espera del servicio) |
| `WARMUP_LOCK_FILE` | `/tmp/jp55mule-warmup.lock` | evita corridas superpuestas (`flock`, Linux) |

Salida: una línea por corrida (`OK ...` con el resumen, o `ERROR ...`). Códigos: 0 OK (o corrida saltada porque otra
está en curso), 1 configuración, 2 login, 3 llamada. La contraseña va por stdin y el token a un archivo temporal
privado: no aparecen en la lista de procesos ni en la salida.

## Cron

Recomendado: **cron cada 10 minutos + una corrida al arrancar el contenedor**.

```cron
# /etc/cron.d/jp55mule-warmup  (archivo de entorno con permisos 600, dueño el usuario del cron)
*/10 * * * * jdeatina . /etc/jp55mule-warmup.env && /opt/jp55mule/warmup.sh >> /var/log/jp55mule-warmup.log 2>&1
```

`/etc/jp55mule-warmup.env` (600):

```sh
export WARMUP_ATINA_URL=http://localhost:8086
export WARMUP_JDE_USER=...
export WARMUP_JDE_PASSWORD=...
export WARMUP_JDE_ENVIRONMENT=JUAT920
export WARMUP_JDE_ROLE='*ALL'
```

Por qué el cron es bueno:

- **Cubre todos los arranques**, no solo el deploy: reinicio del contenedor, del microservicio o del Enterprise
  Server de JDE. A lo sumo 10 minutos después, el pool vuelve a estar completo.
- **Renueva el token del pool**: las sesiones nuevas se abren con el token del último pedido. Después de un reinicio
  de JDE el token viejo puede no servir; el login del cron trae uno nuevo.
- **Es barato con el pool lleno**: el login reutiliza la sesión de Atina (S0, no crea sesiones), `GetCurrentUTime`
  tarda milisegundos y `awaitFull` responde enseguida.
- **No se superpone**: `flock` salta la corrida si la anterior sigue en curso.

A tener en cuenta:

- Entre un reinicio y la próxima corrida del cron, los primeros pedidos pagan el arranque. Por eso conviene además
  una corrida al arrancar (al final de `start-docker.sh`, en segundo plano: `warmup.sh &`); `WARMUP_WAIT_SECONDS`
  espera a que el microservicio responda.
- Cada login de Atina escribe unas 50 líneas en el log del microservicio (recarga ws.json/vo.json): con 10 minutos
  son unas 7.000 líneas por día. Con un intervalo menor crece en proporción.
- El keepalive del pool (`JP55MULE_ORDER_VALIDATION_SESSION_POOL_KEEPALIVE_SECONDS`, 600) sigue siendo el que mantiene
  vivas las sesiones entre corridas; el cron repone lo que el keepalive no puede (pool vacío, token vencido).

## Qué calienta y qué no

| Parte | |
|---|---|
| Primer login de la JVM (conector, JDBJ, seguridad: ~9 s) | Sí (login del script) |
| Sesión de Atina (S0) y su kernel | Sí (`GetCurrentUTime`) |
| Pool completo, sesiones con kernel asignado | Sí |
| Especificaciones de B5542025 (cabecera), N5542011 (líneas), V554202E (consulta) | No: las carga el primer pedido real |
