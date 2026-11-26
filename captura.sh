#!/usr/bin/env bash
# uso: bash captura.sh <contenedor de Atina>
C=${1:?uso: bash captura.sh <contenedor>}
D=~/captura-$(date +%Y%m%d-%H%M%S); mkdir -p "$D"; cd "$D" || exit 1
echo "Grabando 4 minutos en $D"
{ date; nproc; lscpu; free -h
  docker inspect "$C" --format 'NanoCpus={{.HostConfig.NanoCpus}} CpuQuota={{.HostConfig.CpuQuota}} Cpuset={{.HostConfig.CpusetCpus}}'
  echo "nproc en el contenedor: $(docker exec "$C" nproc)"; } > sistema.txt 2>&1
JPID=$(docker exec "$C" sh -c 'for p in /proc/[0-9]*; do grep -q java $p/cmdline 2>/dev/null && basename $p && break; done')
echo "PID de Java en el contenedor: $JPID" >> sistema.txt
top -b -d 2 -n 120 > top.txt 2>&1 &
( for i in $(seq 80); do date +%T; docker stats --no-stream "$C"; done ) > stats.txt 2>&1 &
for n in 1 2 3; do
  sleep 60
  echo "volcado $n $(date +%T)"
  { date +%T; docker exec "$C" jcmd "$JPID" Thread.print; } > threads-$n.txt 2>&1 \
    || docker exec "$C" kill -3 "$JPID"
done
wait
docker logs --since 10m "$C" > docker-logs.txt 2>&1
echo "Listo. Archivos en $D:"; ls -la "$D"