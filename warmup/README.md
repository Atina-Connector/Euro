# Calentamiento de JP55MULE validateSalesOrder

Kit para que el primer pedido después de un deploy (o de un reinicio) no pague el arranque de las sesiones JDE.
Requiere **StdWebService 1.0.7** o posterior y `JP55MULE_ORDER_VALIDATION_WORKER_CONNECTION=POOLED`.

## Archivos de esta carpeta

`docs/europastry-poc/solution/warmup/` (en el repo `JDEAtinaStdWebServiceWorkspace`):

| Archivo | Para qué | Dónde queda en el servidor |
|---|---|---|
| `warmup.sh` | Hace el login en Atina y manda el pedido de calentamiento | `/opt/jp55mule/warmup.sh` |
| `install-warmup.sh` | Instala todo, pide las credenciales y hace una prueba | (se ejecuta desde la carpeta copiada) |
| `jp55mule-warmup.cron` | Corrida cada 10 minutos | `/etc/cron.d/jp55mule-warmup` |
| `jp55mule-warmup.logrotate` | Rotación semanal del log | `/etc/logrotate.d/jp55mule-warmup` |
| (lo crea el instalador) | URL y credenciales, permisos 600 | `/etc/jp55mule-warmup.env` |
| (lo crea el instalador) | Una línea por corrida | `/var/log/jp55mule-warmup.log` |

## Instalación (servidor Linux)

El script usa la API REST de Atina, que entra por el **gateway REST (puerto 8086)**. El **8077**
(`JDE_MICROSERVER_PORT`) es el gRPC directo del microservicio y no sirve para el script. El cron puede correr en
**cualquier servidor Linux que llegue al gateway 8086**, no necesariamente donde está el contenedor del
microservicio: en ese caso la URL lleva la IP del gateway (por ejemplo `http://192.168.252.63:8086`) en lugar de
`localhost`.

1. Copiar la carpeta al servidor (desde la máquina con el repo, con la VPN activa):

   ```sh
   scp -r docs/europastry-poc/solution/warmup TU_USUARIO@192.168.252.63:/tmp/jp55mule-warmup
   ```

2. Entrar al servidor y ejecutar el instalador como root:

   ```sh
   ssh TU_USUARIO@192.168.252.63
   sudo bash /tmp/jp55mule-warmup/install-warmup.sh
   ```

   El instalador:
   - verifica `curl` (7.55 o superior), `flock` (aviso si falta) y que cron esté instalado y activo;
   - copia `warmup.sh` a `/opt/jp55mule/`;
   - **la primera vez** pide los datos y crea `/etc/jp55mule-warmup.env` (600, root). Enter deja el valor entre
     corchetes; la contraseña no se muestra:

     ```
     Atina REST gateway URL (port 8086, not the gRPC port 8077) [http://localhost:8086]:
                                                 la URL del gateway REST (8086); localhost solo si el
                                                 gateway corre en este servidor. Con :8077 avisa y pide confirmar
     JDE user (the one MuleSoft uses) [ATINAD]:
     JDE environment [JUAT920]:
     JDE role [*ALL]:
     JDE password:
     ```

     En una reinstalación conserva el archivo existente (para cambiar credenciales: editarlo, o `--uninstall` e
     instalar de nuevo);
   - instala el cron y el logrotate;
   - **hace un calentamiento de prueba** y muestra el resultado.

3. Resultado esperado de la prueba (con la 1.0.7 desplegada):

   ```
   ... jp55mule-warmup OK http=200 seconds=18 WARMUP correlationId=WARMUP-... requestSession=OK ... poolFull=Y ... kernels=9/10 totalMs=...
   ```

4. Seguir las corridas (una línea cada 10 minutos):

   ```sh
   tail -f /var/log/jp55mule-warmup.log
   ```

5. Opcional, para no esperar al cron después de un arranque: al final del `start-docker.sh` del servidor, después del
   `docker-compose ... start`:

   ```sh
   ( . /etc/jp55mule-warmup.env && /opt/jp55mule/warmup.sh >> /var/log/jp55mule-warmup.log 2>&1 ) &
   ```

   `warmup.sh` reintenta el login cada 10 s durante 5 minutos mientras el microservicio arranca, y `flock` evita que
   se superponga con una corrida del cron.

Otros comandos:

```sh
sudo bash /tmp/jp55mule-warmup/install-warmup.sh --test        # solo un calentamiento con lo instalado
sudo bash /tmp/jp55mule-warmup/install-warmup.sh --uninstall   # quita todo (conserva el log)
```

El instalador es para Linux (`/etc/cron.d`). En otro sistema (macOS) hay que instalar el cron a mano.

## Qué hace el calentamiento

`warmup.sh` hace el login en Atina (`/v1/session/login`) y llama a `validateSalesOrder` con un `correlationId` que
empieza con `WARMUP` y **sin `detail`**. No se procesa ningún pedido ni se escribe nada en JDE (sin cabecera EDI, sin
F5542012, sin consulta, sin totales). El servicio:

1. Ejecuta `GetCurrentUTime` en la sesión de Atina (S0), la que usan la cabecera, la consulta y los totales.
2. Con `POOLED`, crea el pool de sesiones del usuario/entorno/rol y espera a que esté completo (cada sesión nueva
   ejecuta `GetCurrentUTime`), como máximo `JP55MULE_ORDER_VALIDATION_WARMUP_TIMEOUT_SECONDS` (120 s por defecto). Si
   el pool ya está completo responde enseguida.
3. Responde sin líneas, con un mensaje y una línea `ORDER_VALIDATION_WARMUP` en el log del microservicio:

   ```
   WARMUP correlationId=WARMUP-host-20261126190000 requestSession=OK requestSessionMs=35 workerConnection=POOLED
   maxConcurrency=10 globalMaxConcurrency=20 poolFull=Y poolWaitMs=18400 pool=ATINAD|JUAT920|*ALL target=10 open=10
   idle=10 created=10 keepAliveSec=600 kernels=8/10 totalMs=18460
   ```

Un pedido **con** líneas siempre es un pedido normal, aunque su `correlationId` empiece con `WARMUP`. Un pedido sin
líneas y sin el prefijo sigue siendo inválido, como antes.

| Parte | ¿Queda caliente? |
|---|---|
| Primer login de la JVM (conector, JDBJ, seguridad: ~9 s) | Sí (login del script) |
| Sesión de Atina (S0) y su kernel | Sí |
| Pool completo, cada sesión con su kernel asignado | Sí |
| Especificaciones de B5542025 (cabecera), N5542011 (líneas), V554202E (consulta) | No: las carga el primer pedido real |

## Por qué un cron cada 10 minutos

- **Cubre cualquier arranque**, no solo el deploy: reinicio del contenedor, del microservicio o del Enterprise Server
  de JDE. A lo sumo 10 minutos después el pool vuelve a estar completo.
- **Renueva el token del pool**: las sesiones nuevas se abren con el token del último pedido; después de un reinicio de
  JDE el token viejo puede no servir y el login del cron trae uno nuevo.
- **Mantiene viva la sesión de Atina (S0)**: el `SessionsCleanerTask` de Atina desconecta cada
  `SESSION_EXPIRATION_TIME` minutos (60 en el `.env`) las sesiones sin uso. El login del cron reutiliza S0 y la usa,
  así que S0 no vence. **El intervalo del cron tiene que ser menor que `SESSION_EXPIRATION_TIME`**: si lo bajan, bajar
  también el cron (`jp55mule-warmup.cron`). Las sesiones del pool no están registradas en Atina: a esas las mantiene
  el keepalive (`JP55MULE_ORDER_VALIDATION_SESSION_POOL_KEEPALIVE_SECONDS`).
- **Es barato con el pool lleno**: el login reutiliza S0 (no crea sesiones), `GetCurrentUTime` tarda milisegundos y la
  espera del pool termina enseguida.
- Costo: cada login de Atina escribe unas 50 líneas en el log del microservicio (recarga ws.json/vo.json): unas 7.000
  líneas por día con 10 minutos.

## Concurrencia y tamaño del pool

- `JP55MULE_ORDER_VALIDATION_MAX_CONCURRENCY`: líneas de un pedido que se procesan a la vez (una sesión por línea).
- `JP55MULE_ORDER_VALIDATION_SESSION_POOL_SIZE`: sesiones del pool. **Si no se define, toma el valor de
  `MAX_CONCURRENCY`**. Si es menor, las líneas sin sesión libre van por DEDICATED (más lentas, en el kernel de S0); el
  resumen lo avisa con `note=pool smaller than maxConcurrency`.
- Atina serializa las llamadas a servicios web (`JDEWSDriver.callJDEWS` es `synchronized`): hoy no hay dos pedidos a la
  vez, alcanza con un pool del tamaño de `MAX_CONCURRENCY`.
- Si el pool es más grande que los kernels CallObject disponibles, varias sesiones caen en el mismo kernel
  (`kernels=8/10`).

## Referencia de warmup.sh

Variables de entorno (las define `/etc/jp55mule-warmup.env`; nunca se escriben en el script ni en el crontab):

| Variable | Default | |
|---|---|---|
| `WARMUP_ATINA_URL` | `http://localhost:8086` | URL del gateway REST de Atina (8086), no el gRPC del microservicio (8077) |
| `WARMUP_JDE_USER` / `WARMUP_JDE_PASSWORD` | (obligatorias) | el mismo usuario que usa Mule (el pool es por usuario/entorno/rol) |
| `WARMUP_JDE_ENVIRONMENT` / `WARMUP_JDE_ROLE` | `JUAT920` / `*ALL` | |
| `WARMUP_WAIT_SECONDS` | 300 | reintenta el login cada 10 s mientras el microservicio arranca |
| `WARMUP_CALL_TIMEOUT_SECONDS` | 300 | timeout HTTP de la llamada (mayor que la espera del servicio) |
| `WARMUP_LOCK_FILE` | `/tmp/jp55mule-warmup.lock` | evita corridas superpuestas (`flock`) |

La contraseña va por stdin y el token a un archivo temporal privado: no aparecen en la lista de procesos ni en la
salida.

Códigos de salida y qué revisar:

| Código | Significado | Revisar |
|---|---|---|
| 0 | OK, o corrida saltada porque otra está en curso | |
| 1 | Configuración | variables de `/etc/jp55mule-warmup.env` |
| 2 | Login fallido | que la URL sea la del gateway REST 8086 (no el gRPC 8077), que el gateway y el microservicio estén arriba, usuario y contraseña |
| 3 | La llamada de calentamiento falló | versión desplegada: con la 1.0.6 o anterior responde http 500 `Required field missing: customer` (no conoce el pedido WARMUP); log del microservicio |

Si la respuesta es OK pero sin resumen, el script lo indica y remite a la línea `ORDER_VALIDATION_WARMUP` del log del
microservicio.
