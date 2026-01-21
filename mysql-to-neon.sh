#!/bin/bash
#
# Migrazione completa MySQL -> Neon PostgreSQL
# Include: migrazione dati, fix tipi colonne, creazione FK, verifica finale
#
# Uso: ./mysql-to-neon.sh <dump.sql> <neon-connection-string>
#
# Esempio:
#   ./mysql-to-neon.sh dump.sql "postgresql://user:pass@neon.tech/mydb?sslmode=require"
#

set -e

DUMP_FILE="$1"
NEON_CONN="$2"

if [ -z "$DUMP_FILE" ] || [ -z "$NEON_CONN" ]; then
    echo "Uso: $0 <dump.sql> <neon-connection-string>"
    echo ""
    echo "Esempio:"
    echo "  $0 dump.sql \"postgresql://user:pass@neon.tech/mydb?sslmode=require\""
    exit 1
fi

if [ ! -f "$DUMP_FILE" ]; then
    echo "Errore: file non trovato: $DUMP_FILE"
    exit 1
fi

echo "============================================"
echo "  MIGRAZIONE COMPLETA MySQL -> Neon"
echo "============================================"
echo ""
echo "Dump:   $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
echo "Neon:   ${NEON_CONN%%:*}://***@${NEON_CONN#*@}"
echo ""

# ============================================
# STEP 1: Pulisci database Neon
# ============================================
echo "[1/5] Pulizia database Neon..."
psql "$NEON_CONN" -q << 'EOF'
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
    FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public'
    LOOP
        EXECUTE 'DROP SEQUENCE IF EXISTS public.' || quote_ident(r.sequencename) || ' CASCADE';
    END LOOP;
END $$;
EOF
echo "    Database pulito"

# ============================================
# STEP 2: Migrazione MySQL -> PostgreSQL
# ============================================
echo ""
echo "[2/5] Migrazione MySQL -> PostgreSQL..."

# Cleanup Docker preventivo
docker rm -f mig-maria mig-pg 2>/dev/null || true
docker network rm mignet 2>/dev/null || true

echo "    Avvio containers Docker..."
docker network create mignet >/dev/null
docker run -d --name mig-maria --network mignet -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=src mariadb:10.11 >/dev/null
docker run -d --name mig-pg --network mignet -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=dst postgres:15 >/dev/null

echo "    Attesa avvio database..."
sleep 10
until docker exec mig-maria mariadb -uroot -proot -e "SELECT 1" &>/dev/null; do sleep 2; done
until docker exec mig-pg pg_isready -U postgres &>/dev/null; do sleep 2; done

echo "    Import dump in MariaDB..."
docker exec -i mig-maria mariadb --binary-mode -uroot -proot src < "$DUMP_FILE"

echo "    Conversione con pgloader..."
docker run --rm --network mignet dimitri/pgloader \
    pgloader mysql://root:root@mig-maria/src postgresql://postgres:postgres@mig-pg/dst 2>&1 | grep -E "^[0-9]{4}|Total import time" | tail -5

# pgloader crea uno schema 'src', rinominalo in 'public'
docker exec mig-pg psql -U postgres -d dst -q -c "
DROP SCHEMA IF EXISTS public CASCADE;
ALTER SCHEMA src RENAME TO public;
"

echo "    Export da PostgreSQL locale..."
PG_DUMP_FILE="/tmp/neon_import_$$.sql"
docker exec mig-pg pg_dump -U postgres --no-owner --no-privileges dst > "$PG_DUMP_FILE"
echo "    Export: $(du -h "$PG_DUMP_FILE" | cut -f1)"

echo "    Upload su Neon..."
psql "$NEON_CONN" -q -f "$PG_DUMP_FILE" 2>&1 | grep -E "^CREATE|^ERROR" | head -10 || true

# Cleanup Docker
docker rm -f mig-maria mig-pg >/dev/null
docker network rm mignet >/dev/null
rm -f "$PG_DUMP_FILE"

echo "    Migrazione dati completata"

# ============================================
# STEP 3: Fix tipi colonne (numeric -> bigint)
# ============================================
echo ""
echo "[3/5] Conversione colonne numeric -> bigint..."

COLUMNS=$(psql "$NEON_CONN" -t -A -c "
SELECT table_name || '.' || column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (column_name LIKE '%_id' OR column_name = 'created_by')
  AND data_type = 'numeric'
ORDER BY table_name, column_name;
")

COUNT=0
for col in $COLUMNS; do
    TABLE=$(echo "$col" | cut -d'.' -f1)
    COLUMN=$(echo "$col" | cut -d'.' -f2)
    psql "$NEON_CONN" -q -c "ALTER TABLE public.\"$TABLE\" ALTER COLUMN \"$COLUMN\" TYPE bigint;" 2>/dev/null || true
    COUNT=$((COUNT + 1))
done
echo "    $COUNT colonne convertite"

# ============================================
# STEP 4: Creazione Foreign Keys
# ============================================
echo ""
echo "[4/5] Creazione foreign keys..."

FK_TEMP="/tmp/fk_commands_$$.sql"
> "$FK_TEMP"

CURRENT_TABLE=""
while IFS= read -r line; do
    # Cerca CREATE TABLE
    if echo "$line" | grep -q "CREATE TABLE \`"; then
        CURRENT_TABLE=$(echo "$line" | sed -n 's/.*CREATE TABLE `\([^`]*\)`.*/\1/p')
    fi

    # Cerca FOREIGN KEY
    if echo "$line" | grep -qi "CONSTRAINT.*FOREIGN KEY"; then
        CONSTRAINT=$(echo "$line" | sed -n 's/.*CONSTRAINT `\([^`]*\)`.*/\1/p')
        FK_COLUMN=$(echo "$line" | sed -n 's/.*FOREIGN KEY (`\([^`]*\)`).*/\1/p')
        REF_TABLE=$(echo "$line" | sed -n 's/.*REFERENCES `\([^`]*\)`.*/\1/p')
        REF_COLUMN=$(echo "$line" | sed -n 's/.*REFERENCES `[^`]*` (`\([^`]*\)`).*/\1/p')

        # ON DELETE action
        ON_DELETE=""
        if echo "$line" | grep -q "ON DELETE CASCADE"; then
            ON_DELETE="ON DELETE CASCADE"
        elif echo "$line" | grep -q "ON DELETE SET NULL"; then
            ON_DELETE="ON DELETE SET NULL"
        elif echo "$line" | grep -q "ON DELETE RESTRICT"; then
            ON_DELETE="ON DELETE RESTRICT"
        fi

        if [ -n "$CURRENT_TABLE" ] && [ -n "$CONSTRAINT" ] && [ -n "$FK_COLUMN" ] && [ -n "$REF_TABLE" ]; then
            echo "ALTER TABLE public.$CURRENT_TABLE ADD CONSTRAINT $CONSTRAINT FOREIGN KEY ($FK_COLUMN) REFERENCES public.$REF_TABLE($REF_COLUMN) $ON_DELETE;" >> "$FK_TEMP"
        fi
    fi
done < "$DUMP_FILE"

while IFS= read -r sql; do
    if [ -n "$sql" ]; then
        psql "$NEON_CONN" -q -c "$sql" 2>/dev/null || true
    fi
done < "$FK_TEMP"

rm -f "$FK_TEMP"

CREATED_FKS=$(psql "$NEON_CONN" -t -A -c "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public';")
echo "    $CREATED_FKS foreign keys create"

# ============================================
# STEP 5: Verifica finale
# ============================================
echo ""
echo "[5/5] Verifica finale..."

TABLES=$(psql "$NEON_CONN" -t -A -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';")
ROWS=$(psql "$NEON_CONN" -t -A -c "SELECT COALESCE(SUM(n_live_tup), 0) FROM pg_stat_user_tables WHERE schemaname = 'public';")
FKS=$(psql "$NEON_CONN" -t -A -c "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public';")
MYSQL_FKS=$(grep -c "FOREIGN KEY" "$DUMP_FILE" || echo "0")

# FK mancanti
grep -i "FOREIGN KEY" "$DUMP_FILE" | sed 's/.*CONSTRAINT `\([^`]*\)`.*/\1/' | sort > /tmp/mysql_fks_check.txt
psql "$NEON_CONN" -t -A -c "SELECT constraint_name FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public' ORDER BY constraint_name;" | sort > /tmp/neon_fks_check.txt
MISSING_FKS=$(comm -23 /tmp/mysql_fks_check.txt /tmp/neon_fks_check.txt)

# Colonne ancora numeric
REMAINING_NUMERIC=$(psql "$NEON_CONN" -t -A -c "
SELECT COUNT(*) FROM information_schema.columns
WHERE table_schema = 'public'
  AND (column_name LIKE '%_id' OR column_name = 'created_by')
  AND data_type = 'numeric';
")

echo ""
echo "============================================"
echo "  RISULTATO MIGRAZIONE"
echo "============================================"
echo ""
echo "  DATI:"
echo "    Tabelle:        $TABLES"
echo "    Righe totali:   $ROWS"
echo ""
echo "  INTEGRITÀ:"
echo "    Foreign Keys:   $FKS / $MYSQL_FKS"
if [ "$REMAINING_NUMERIC" -gt 0 ]; then
    echo "    Colonne numeric: $REMAINING_NUMERIC (da verificare)"
else
    echo "    Tipi colonne:   OK"
fi
echo ""

if [ -n "$MISSING_FKS" ]; then
    echo "  ⚠️  FK MANCANTI:"
    echo "$MISSING_FKS" | while read -r fk; do
        [ -n "$fk" ] && echo "      - $fk"
    done
    echo ""
else
    echo "  ✓ Tutte le FK sono state create"
    echo ""
fi

echo "  TOP 10 TABELLE:"
psql "$NEON_CONN" -t -c "
SELECT '    ' || rpad(relname, 30) || n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC
LIMIT 10;"

echo ""
echo "  FOREIGN KEYS:"
psql "$NEON_CONN" -t -c "
SELECT '    ' || tc.table_name || '.' || kcu.column_name || ' -> ' || ccu.table_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
ORDER BY tc.table_name;"

echo ""
echo "============================================"

rm -f /tmp/mysql_fks_check.txt /tmp/neon_fks_check.txt
