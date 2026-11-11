#!/usr/bin/env bash

JDE_HOST="192.168.252.158"
JDE_PORT="6017"
PING_COUNT="50"
TCP_TESTS="10"
REPORT_FILE="latencia_jde_$(date +%Y%m%d_%H%M%S).txt"

{
  printf '\n============================================================\n'
  printf ' PRUEBA DE CONECTIVIDAD ATINA -> JDE\n'
  printf '============================================================\n'
  printf 'Fecha          : %s\n' "$(date)"
  printf 'Servidor origen: %s\n' "$(hostname)"
  printf 'Destino JDE    : %s:%s\n' "$JDE_HOST" "$JDE_PORT"

  printf '\n=== SISTEMA ORIGEN ===\n'
  hostnamectl 2>/dev/null || uname -a

  printf '\n=== INTERFACES DE RED ===\n'
  ip -br address

  printf '\n=== TABLA DE RUTAS ===\n'
  ip route

  printf '\n=== RUTA UTILIZADA HACIA JDE ===\n'
  ip route get "$JDE_HOST"

  printf '\n=== PING A JDE (%s PAQUETES) ===\n' "$PING_COUNT"
  ping -c "$PING_COUNT" "$JDE_HOST"

  printf '\n=== PRUEBA DEL PUERTO JDE %s ===\n' "$JDE_PORT"
  nc -vz -w 5 "$JDE_HOST" "$JDE_PORT"

  printf '\n=== TIEMPOS DE CONEXION TCP ===\n'

  for intento in $(seq 1 "$TCP_TESTS"); do
    printf '\nIntento %02d: ' "$intento"

    if command -v /usr/bin/time >/dev/null 2>&1; then
      /usr/bin/time -f 'tiempo=%e segundos' \
        nc -z -w 5 "$JDE_HOST" "$JDE_PORT"
    else
      time nc -z -w 5 "$JDE_HOST" "$JDE_PORT"
    fi

    sleep 1
  done

  printf '\n=== RECORRIDO DE RED ===\n'

  if command -v tracepath >/dev/null 2>&1; then
    tracepath -n "$JDE_HOST"
  elif command -v traceroute >/dev/null 2>&1; then
    traceroute -n "$JDE_HOST"
  else
    printf 'tracepath/traceroute no está instalado.\n'
  fi

  printf '\n=== RESULTADO FINAL DEL PUERTO ===\n'

  if nc -z -w 5 "$JDE_HOST" "$JDE_PORT"; then
    printf 'RESULTADO: JDE %s:%s ES ACCESIBLE DESDE ATINA\n' \
      "$JDE_HOST" "$JDE_PORT"
  else
    printf 'RESULTADO: NO SE PUDO CONECTAR A JDE %s:%s\n' \
      "$JDE_HOST" "$JDE_PORT"
  fi

  printf '\n============================================================\n'
  printf ' FIN DE LA PRUEBA\n'
  printf '============================================================\n'

} 2>&1 | tee "$REPORT_FILE"

printf '\nInforme guardado en: %s\n' "$REPORT_FILE"