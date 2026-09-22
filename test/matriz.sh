#!/usr/bin/env bash
# LA TABLA DE «TESTED ON», REPRODUCIBLE. Corre `make installcheck` dentro de un contenedor de
# la imagen oficial de cada PostgreSQL y escribe una tabla con el resultado real.
#
# POR QUÉ EXISTE: la tabla del README se midió a mano el 2026-09-16 y la receta quedó sólo en
# el mensaje del commit. Cuando hizo falta repetirla para 0.5.0, hubo que reinventarla — y el
# primer intento falló por tres cosas que este script ya resuelve:
#
#   1. Un bind mount del repo no se lee dentro del contenedor: SELinux (Fedora) y los permisos
#      700 del directorio. Acá el repo se COPIA con `podman cp`, que no depende de ninguna de
#      las dos.
#   2. La imagen oficial NO trae PGXS ni pg_regress: vienen en `postgresql-server-dev-N`, que
#      hay que instalar adentro. Sin eso `make install` falla aunque la extensión sea SQL puro.
#   3. `make installcheck` escribe en `test/`, así que el repo copiado tiene que ser del
#      usuario `postgres`.
#
# EL CONTROL: PostgreSQL 10 TIENE que fallar. Los triggers se crean con `EXECUTE FUNCTION`,
# que 10 no acepta, y el README lo declara no soportado. Si 10 pasara, esta prueba no estaría
# midiendo lo que dice medir (cicatriz 3).
#
#   bash test/matriz.sh              # 10 (control) y 11..18
#   bash test/matriz.sh 15 16        # sólo esas
set -uo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
VERSIONES=("${@:-}")
[ -z "${VERSIONES[0]:-}" ] && VERSIONES=(10 11 12 13 14 15 16 17 18)

declare -A RESULTADO
for v in "${VERSIONES[@]}"; do
    caja="matriz-pg-living-$v"
    podman rm -f "$caja" >/dev/null 2>&1
    echo "── PostgreSQL $v ─────────────────────────────────────────"
    if ! podman run -d --name "$caja" -e POSTGRES_HOST_AUTH_METHOD=trust \
                    "docker.io/library/postgres:$v" >/dev/null 2>&1; then
        RESULTADO[$v]="sin imagen"; continue
    fi

    listo=no
    for _ in $(seq 60); do
        if podman exec "$caja" pg_isready -U postgres -q 2>/dev/null; then listo=si; break; fi
        sleep 1
    done
    if [ "$listo" != si ]; then
        RESULTADO[$v]="no arrancó"; podman rm -f "$caja" >/dev/null 2>&1; continue
    fi

    podman cp "$RAIZ/." "$caja:/ext" >/dev/null 2>&1
    podman exec "$caja" bash -c "chown -R postgres:postgres /ext && rm -rf /ext/.testcluster" >/dev/null 2>&1

    # El `-dev` trae PGXS y pg_regress. En silencio salvo que falle: su salida es apt, no la prueba.
    if ! podman exec "$caja" bash -c \
        "apt-get update -qq && apt-get install -y -qq make postgresql-server-dev-$v" >/dev/null 2>&1; then
        RESULTADO[$v]="sin postgresql-server-dev-$v"; podman rm -f "$caja" >/dev/null 2>&1; continue
    fi

    salida=$(podman exec "$caja" bash -c \
        "cd /ext && make install >/tmp/install.log 2>&1 && \
         su postgres -c 'cd /ext && PGHOST=/var/run/postgresql make installcheck' 2>&1 || \
         { echo '--- make install ---'; tail -5 /tmp/install.log; }")
    if grep -q "All .* tests passed" <<<"$salida"; then
        RESULTADO[$v]="pasa"
    else
        RESULTADO[$v]="FALLA"
        echo "$salida" | grep -E "^(not ok|ok|#|make|--- |.*Error)" | tail -8
    fi
    podman rm -f "$caja" >/dev/null 2>&1
done

echo
echo "── LA TABLA ──────────────────────────────────────────────"
control_ok=si
for v in "${VERSIONES[@]}"; do
    marca="✓"; [ "${RESULTADO[$v]}" = pasa ] || marca="✗"
    nota=""
    if [ "$v" = 10 ]; then
        nota="  ← CONTROL: tiene que fallar (EXECUTE FUNCTION no existe en 10)"
        [ "${RESULTADO[$v]}" = pasa ] && control_ok=no
    fi
    printf "  PG %-3s %s  %s%s\n" "$v" "$marca" "${RESULTADO[$v]}" "$nota"
done

if [ "$control_ok" = no ]; then
    echo
    echo "⚠ EL CONTROL PASÓ: PG 10 no debería poder. Esta corrida NO mide lo que dice medir."
    exit 2
fi
