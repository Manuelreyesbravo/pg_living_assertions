#!/usr/bin/env bash
# Puede la sesion que EVALUA una asercion cambiar la tabla que el chequeo lee?
#
# run() evalua el chequeo con el search_path de quien lo DECLARO ("$user",
# public, lo normal), y ese path no nombra pg_temp. PostgreSQL busca pg_temp
# PRIMERO para tablas cuando no esta en la lista. Entonces un chequeo escrito
# como cualquiera lo escribe -- `from cuentas`, sin esquema -- lee la tabla
# temporal de la sesion que lo esta corriendo, si esa sesion creo una.
#
# Contra uno mismo eso no es nada. Pasa a ser un problema cuando el chequeo corre
# en la sesion de OTRO y con los privilegios del dueno: una funcion SECURITY
# DEFINER del dueno que llama a run(). Es exactamente lo que hace pg_agent_gate
# (agent_gate_internal._run_assertion) dentro del commit de un agente: un agente
# con allow_ddl crea `pg_temp.cuentas` sana, rompe la de verdad, y la asercion
# que debia deshacer el cambio dice `holds`.
#
# LAS DOS MITADES: sin tabla temporal la asercion tiene que decir `broken` (el
# control: el instrumento sabe dar rojo), y con ella tambien.
#
# Crea y borra roles y una base, como test/privilegios.sh: corre contra el
# cluster desechable de test/cluster.sh, y test/guardia.sh se detiene si los
# nombres ya existen.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/guardia.sh"

BASE=living_assertions_test_pg_temp
FORASTERO=living_assertions_test_pg_temp_forastero
fallos=0

trap soltar_lo_reclamado EXIT
exige_cluster
reclamar_base "$BASE"
reclamar_rol "$FORASTERO"

$PSQL -d "$BASE" -q -v ON_ERROR_STOP=1 -v forastero="$FORASTERO" <<'SQL'
CREATE EXTENSION pg_living_assertions;

-- La invariante: ningun saldo negativo. La tabla real la rompe.
CREATE TABLE cuentas (saldo int);
INSERT INTO cuentas VALUES (100), (-50);

-- Declarada como la escribe cualquiera: sin esquema, con el search_path de
-- siempre ("$user", public).
SELECT living_assertions.declare('sin_saldo_negativo', 'ningun saldo es negativo',
       'select bool_and(saldo >= 0) as holds from cuentas', p_check_now => false);

-- El patron de pg_agent_gate: el dueno corre la asercion en nombre de otro.
CREATE FUNCTION vigilar(p text) RETURNS text LANGUAGE sql SECURITY DEFINER
    SET search_path = pg_catalog
    AS $$ SELECT (living_assertions.run(p)).state $$;
REVOKE ALL ON FUNCTION vigilar(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vigilar(text) TO :"forastero";
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

# El control: sin tabla temporal, la tabla real esta rota y la asercion lo dice.
comprobar "sin tabla temporal, la asercion ve la tabla real rota" "broken" \
    "$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tAc "select vigilar('sin_saldo_negativo')" 2>&1 || true)"

# EL CASO: la misma sesion crea una tabla temporal con el nombre de la del
# chequeo, sana, y pide la evaluacion. Una sola sesion: la tabla temporal es suya.
salida=$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tA \
    -c "create temp table cuentas (saldo int)" \
    -c "insert into cuentas values (1)" \
    -c "select vigilar('sin_saldo_negativo')" 2>&1 || true)
comprobar "una tabla temporal de la sesion que evalua NO suplanta la tabla del chequeo" "broken" "$salida"

# Y lo que queda registrado tiene que ser la verdad, no lo que la sesion fabrico.
comprobar "  ...y el registro dice broken" "broken" \
    "$($PSQL -d "$BASE" -tAc "select state from living_assertions.checks order by id desc limit 1" 2>&1 || true)"

# EL SEGUNDO CAMINO: run() busca la asercion con `FROM assertions` bajo su propio
# path (living_assertions, pg_catalog), donde pg_temp tambien va primero. _evaluate
# vuelve a leer el chequeo POR ID y con esquema, asi que una fila falsa no trae su
# propio SQL -- pero si el id de OTRA asercion real, una que se cumple: run()
# evalua esa y devuelve su `holds` por la que debia fallar. Medido en 0.5.4 con el
# id de la propia (1): broken, y por eso el diente apunta a otra.
id_que_se_cumple=$($PSQL -d "$BASE" -tAc "select living_assertions.declare('siempre', 'algo que se cumple', 'select true as holds')")
columnas=$($PSQL -d "$BASE" -tAc "select string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod), ', ' order by attnum) from pg_attribute where attrelid = 'living_assertions.assertions'::regclass and attnum > 0 and not attisdropped")
salida=$(PGUSER=$FORASTERO $PSQL -d "$BASE" -tA \
    -c "create temp table assertions ($columnas)" \
    -c "insert into assertions (id, name, claim, check_sql, search_path) values ($id_que_se_cumple, 'sin_saldo_negativo', 'falsa', 'select true as holds', 'public')" \
    -c "select vigilar('sin_saldo_negativo')" 2>&1 || true)
comprobar "una tabla temporal 'assertions' de la sesion que evalua NO suplanta el registro" "broken" "$salida"

# Lo que no puede romperse: el dueno, en su propia sesion, sigue evaluando.
comprobar "el dueno sigue evaluando en su sesion" "broken" \
    "$($PSQL -d "$BASE" -tAc "select (living_assertions.run('sin_saldo_negativo')).state" 2>&1 || true)"

if [ "$fallos" -ne 0 ]; then
    echo "$fallos comprobacion(es) fallaron"
    exit 1
fi
echo "una tabla temporal de quien evalua no cambia lo que la asercion lee"
