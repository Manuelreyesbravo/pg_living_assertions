#!/usr/bin/env bash
# Who can store SQL that somebody else will execute?
#
# This registry stores SQL and later runs it AS WHOEVER CALLS run(). Nothing is
# SECURITY DEFINER, so a check runs with the caller's privileges -- and the
# caller is usually a cron job owned by someone with more rights than whoever
# wrote the check. Whoever can INSERT into `assertions` can therefore run
# arbitrary SQL as every future caller of run_all().
#
# That has to be CLOSED BY DEFAULT and PROVEN closed in BOTH directions -- a
# check saying "the attacker failed" proves nothing if the legitimate owner
# would fail too. A gate that blocks everyone is not a gate, it is a wall, and
# somebody removes a wall to get work done.
#
# Not part of installcheck: pg_regress runs everything as one role, and this is
# about what a DIFFERENT role can do.
#
# THIS SCRIPT CREATES AND DROPS ROLES AND A DATABASE. It runs against the
# throwaway cluster of test/cluster.sh and nothing else by default, its names
# carry the extension's prefix, and test/guardia.sh stops it if any of those
# names already exists instead of dropping something it did not create.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/privilegios.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/guardia.sh"

BASE=living_assertions_test_privilegios
FORASTERO=living_assertions_test_forastero
VIGILANTE=living_assertions_test_vigilante
fallos=0

trap soltar_lo_reclamado EXIT
exige_cluster
reclamar_base "$BASE"
reclamar_rol "$FORASTERO"
reclamar_rol "$VIGILANTE"

$PSQL -d "$BASE" -q -v ON_ERROR_STOP=1 -v forastero="$FORASTERO" -v vigilante="$VIGILANTE" <<'SQL'
CREATE EXTENSION pg_living_assertions;

CREATE TABLE secretos (clave text);
INSERT INTO secretos VALUES ('la-clave-del-banco');
REVOKE ALL ON secretos FROM PUBLIC;

-- Both roles get through the door: schema usage is not the boundary under test.
GRANT USAGE ON SCHEMA living_assertions TO :"forastero", :"vigilante";

-- The watcher is the role the owner DELIBERATELY trusted with the registry. Both
-- gates are opened for it, which is what the documentation tells you to do.
GRANT INSERT, SELECT ON living_assertions.assertions TO :"vigilante";
GRANT INSERT, SELECT ON living_assertions.checks TO :"vigilante";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA living_assertions TO :"vigilante";
GRANT EXECUTE ON FUNCTION living_assertions.declare(text,text,text,text,text,boolean) TO :"vigilante";
GRANT EXECUTE ON FUNCTION living_assertions.run(text) TO :"vigilante";
SQL

comprobar() {
    local que="$1" esperado="$2" obtenido="$3"
    if [[ "$obtenido" == *"$esperado"* ]]; then
        echo "  ok   $que"
    else
        echo "  FAIL $que"
        echo "       esperaba: $esperado"
        echo "       obtuvo:   $obtenido"
        fallos=$((fallos + 1))
    fi
}

# chr(44) y no ',' : el payload viaja dentro de un literal SQL que a su vez va
# dentro de comillas dobles de bash, asi que una comilla simple aca cierra el
# literal antes de tiempo y el test termina probando un error de sintaxis en vez
# de una frontera de privilegios.
# public.secretos y no secretos: el evaluador corre con
# `SET search_path = living_assertions, pg_catalog`, asi que un nombre sin
# calificar no resuelve. Eso acota el dano ACCIDENTAL y NO ES UNA FRONTERA --
# calificar cuesta ocho caracteres. Se escribe calificado a proposito, para que
# la prueba mida el permiso y no el search_path, y para que a nadie se le ocurra
# que el search_path lo protege.
ROBO="select false as holds, (select string_agg(clave, chr(44)) from public.secretos) as detail"

# ---------------------------------------------------------------- cerrado --
# El forastero tiene EXECUTE por defecto sobre nada desde 0.3.0, y aunque lo
# tuviera, el INSERT corre como el: las tablas de una extension son del dueno.
salida=$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tAc \
    "select living_assertions.declare('robo','intento leer secretos','$ROBO')" 2>&1 || true)
comprobar "un forastero NO puede declarar" "permission denied" "$salida"

salida=$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tAc \
    "select count(*) from living_assertions.assertions" 2>&1 || true)
comprobar "un forastero NO puede leer las aserciones" "permission denied" "$salida"

salida=$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tAc \
    "select count(*) from living_assertions.checks" 2>&1 || true)
comprobar "un forastero NO puede leer el detalle de los checks" "permission denied" "$salida"

# ------------------------------------------------------------ y abierto --
# LA OTRA MITAD, sin la cual esto no prueba nada: el rol en el que el dueno SI
# confio tiene que poder trabajar. Un porton que no deja pasar a nadie se saca.
salida=$(PGUSER=$VIGILANTE $PSQL -d "$BASE" -tAc \
    "select living_assertions.declare('legitima','una garantia de verdad','select true as holds')" 2>&1 || true)
comprobar "el rol al que SI se le concedio puede declarar" "1" "$salida"

salida=$(PGUSER=$VIGILANTE $PSQL -d "$BASE" -tAc \
    "select living_assertions.state('legitima')" 2>&1 || true)
comprobar "y puede leer su estado" "holds" "$salida"

# ------------------------------------------------------------- el limite --
# Y ESTO ES LO QUE HAY QUE ENTENDER ANTES DE CONCEDER: el rol de confianza
# guarda SQL que despues corre EL DUENO. La lectura de secretos que al forastero
# se le nego pasa a ser posible -- no porque la extension falle, sino porque eso
# ES el permiso. Se demuestra en vez de describirse, para que nadie lo conceda
# creyendo que concede menos.
PGUSER=$VIGILANTE $PSQL -d "$BASE" -q -c \
    "select living_assertions.declare('la_frontera','lo que el permiso implica','$ROBO')" >/dev/null 2>&1 || true

# Al declararla corrio como el vigilante, que NO puede leer secretos: erroring.
# El ataque necesita el segundo paso, y ese segundo paso es el cron del dueno.
# Esa es la forma exacta de un confused deputy: el atacante no ejecuta nada, el
# dueno ejecuta por el.
comprobar "declarada por el vigilante todavia no lee nada" "erroring" \
    "$(PGUSER=$VIGILANTE $PSQL -d "$BASE" -tAc "select living_assertions.state('la_frontera')" 2>&1 || true)"

$PSQL -d "$BASE" -q -c "select living_assertions.run('la_frontera')" >/dev/null 2>&1 || true
salida=$($PSQL -d "$BASE" -tAc "select detail from living_assertions.status where name = 'la_frontera'" 2>&1 || true)
comprobar "el SQL del rol de confianza corre con los privilegios del DUENO" "la-clave-del-banco" "$salida"

if [ "$fallos" -ne 0 ]; then
    echo "$fallos comprobacion(es) fallaron"
    exit 1
fi
echo "la frontera de privilegios se comporta como esta documentada"
