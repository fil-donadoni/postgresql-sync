#!/bin/bash

# Script di sincronizzazione PostgreSQL con gestione FK e sequence
# Uso: ./postgresql-sync.sh [opzioni]
#
# Opzioni:
#   --source-type <remote|local>  Tipo sorgente: remote=database remoto, local=file dump locale
#   --source-file <path>          Path del file dump locale
#   --source-conn <string>        Stringa connessione sorgente (postgresql://user:pass@host:port/db)
#   --source-host <host>          Host sorgente
#   --source-port <port>          Porta sorgente
#   --source-db <database>        Database sorgente
#   --source-user <username>      Username sorgente
#   --source-password <password>  Password sorgente
#   --dest-conn <string>          Stringa connessione destinazione
#   --dest-host <host>            Host destinazione
#   --dest-port <port>            Porta destinazione
#   --dest-db <database>          Database destinazione
#   --dest-user <username>        Username destinazione
#   --dest-password <password>    Password destinazione
#   --skip-confirm                Salta conferma finale
#   --help                        Mostra questo help
#
# Esempi:
#   # Modalità interattiva (default)
#   ./postgresql-sync.sh
#
#   # Da database remoto a database remoto (connection string)
#   ./postgresql-sync.sh \
#     --source-conn "postgresql://user:pass@source.host.com:5432/sourcedb" \
#     --dest-conn "postgresql://user:pass@dest.host.com:5432/destdb" \
#     --skip-confirm
#
#   # Da database remoto a database remoto (parametri separati)
#   ./postgresql-sync.sh \
#     --source-type remote \
#     --source-host source.host.com \
#     --source-port 5432 \
#     --source-db sourcedb \
#     --source-user myuser \
#     --source-password mypass \
#     --dest-host dest.host.com \
#     --dest-port 5432 \
#     --dest-db destdb \
#     --dest-user myuser \
#     --dest-password mypass \
#     --skip-confirm
#
#   # Da file dump locale a database remoto
#   ./postgresql-sync.sh \
#     --source-type local \
#     --source-file /path/to/dump.sql \
#     --dest-conn "postgresql://user:pass@dest.host.com:5432/destdb" \
#     --skip-confirm

set -e  # Esce in caso di errore

# ============================================
# PARAMETRI DA LINEA DI COMANDO
# ============================================

CLI_SOURCE_TYPE=""
CLI_SOURCE_FILE=""
CLI_SOURCE_CONN=""
CLI_SOURCE_HOST=""
CLI_SOURCE_PORT=""
CLI_SOURCE_DB=""
CLI_SOURCE_USER=""
CLI_SOURCE_PASSWORD=""
CLI_DEST_CONN=""
CLI_DEST_HOST=""
CLI_DEST_PORT=""
CLI_DEST_DB=""
CLI_DEST_USER=""
CLI_DEST_PASSWORD=""
CLI_SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-type)
            CLI_SOURCE_TYPE="$2"
            shift 2
            ;;
        --source-file)
            CLI_SOURCE_FILE="$2"
            shift 2
            ;;
        --source-conn)
            CLI_SOURCE_CONN="$2"
            shift 2
            ;;
        --source-host)
            CLI_SOURCE_HOST="$2"
            shift 2
            ;;
        --source-port)
            CLI_SOURCE_PORT="$2"
            shift 2
            ;;
        --source-db)
            CLI_SOURCE_DB="$2"
            shift 2
            ;;
        --source-user)
            CLI_SOURCE_USER="$2"
            shift 2
            ;;
        --source-password)
            CLI_SOURCE_PASSWORD="$2"
            shift 2
            ;;
        --dest-conn)
            CLI_DEST_CONN="$2"
            shift 2
            ;;
        --dest-host)
            CLI_DEST_HOST="$2"
            shift 2
            ;;
        --dest-port)
            CLI_DEST_PORT="$2"
            shift 2
            ;;
        --dest-db)
            CLI_DEST_DB="$2"
            shift 2
            ;;
        --dest-user)
            CLI_DEST_USER="$2"
            shift 2
            ;;
        --dest-password)
            CLI_DEST_PASSWORD="$2"
            shift 2
            ;;
        --skip-confirm)
            CLI_SKIP_CONFIRM=true
            shift
            ;;
        --help)
            grep "^#" "$0" | grep -E "^# (Uso:|Opzioni:|  --)" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Opzione sconosciuta: $1" >&2
            echo "Usa --help per vedere le opzioni disponibili" >&2
            exit 1
            ;;
    esac
done

# ============================================
# FUNZIONI
# ============================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

parse_connection_string() {
    local conn_str="$1"
    local host port db user password

    # Rimuovi il prefisso postgresql:// o postgres://
    conn_str=${conn_str#postgresql://}
    conn_str=${conn_str#postgres://}

    # Rimuovi query string se presente (tutto dopo ?)
    conn_str="${conn_str%%\?*}"

    # Pattern con user:password@host:port/database
    if [[ "$conn_str" =~ ^([^:]+):([^@]+)@([^/:]+):([0-9]+)/(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        password="${BASH_REMATCH[2]}"
        host="${BASH_REMATCH[3]}"
        port="${BASH_REMATCH[4]}"
        db="${BASH_REMATCH[5]}"
    # Pattern con user:password@host/database (porta default 5432)
    elif [[ "$conn_str" =~ ^([^:]+):([^@]+)@([^/:]+)/(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        password="${BASH_REMATCH[2]}"
        host="${BASH_REMATCH[3]}"
        port="5432"
        db="${BASH_REMATCH[4]}"
    # Pattern con user@host:port/database (password richiesta dopo)
    elif [[ "$conn_str" =~ ^([^@]+)@([^/:]+):([0-9]+)/(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        host="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[3]}"
        db="${BASH_REMATCH[4]}"
        password=""
    # Pattern con user@host/database (porta default, password richiesta dopo)
    elif [[ "$conn_str" =~ ^([^@]+)@([^/:]+)/(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        host="${BASH_REMATCH[2]}"
        port="5432"
        db="${BASH_REMATCH[3]}"
        password=""
    else
        return 1
    fi

    echo "$host|$port|$db|$user|$password"
}

read_connection_string() {
    local db_type="$1"
    echo "" >&2
    echo "==========================================" >&2
    echo "  STRINGA DI CONNESSIONE $db_type" >&2
    echo "==========================================" >&2
    echo "Formato: postgresql://user:password@host:port/database" >&2
    echo "Esempio: postgresql://postgres:mypass@localhost:5432/mydb" >&2
    echo "" >&2

    read -p "Stringa di connessione $db_type: " conn_str
    [ -z "$conn_str" ] && error "Stringa di connessione obbligatoria"

    local parsed
    parsed=$(parse_connection_string "$conn_str")

    if [ $? -ne 0 ] || [ -z "$parsed" ]; then
        error "Formato stringa di connessione non valido"
    fi

    # Se la password non è nella stringa, chiedila (opzionale)
    IFS='|' read -r host port db user password <<< "$parsed"
    if [ -z "$password" ]; then
        read -sp "Password $db_type (premi Invio se non richiesta): " password
        echo "" >&2
    fi

    echo "$host|$port|$db|$user|$password"
}

read_credentials_manual() {
    local db_type="$1"
    echo "" >&2
    echo "==========================================" >&2
    echo "  CONFIGURAZIONE DATABASE $db_type" >&2
    echo "==========================================" >&2
    read -p "Host $db_type [$2]: " host
    host=${host:-$2}

    read -p "Porta $db_type [$3]: " port
    port=${port:-$3}

    read -p "Nome database $db_type: " db
    [ -z "$db" ] && error "Nome database obbligatorio"

    read -p "Username $db_type [$4]: " user
    user=${user:-$4}

    read -sp "Password $db_type (premi Invio se non richiesta): " password
    echo "" >&2

    echo "$host|$port|$db|$user|$password"
}

read_credentials() {
    local db_type="$1"
    local default_host="$2"
    local default_port="$3"
    local default_user="$4"

    echo "" >&2
    echo "==========================================" >&2
    echo "  METODO DI CONNESSIONE $db_type" >&2
    echo "==========================================" >&2
    echo "1) Stringa di connessione (consigliato)" >&2
    echo "2) Credenziali separate" >&2
    echo "" >&2
    read -p "Scegli il metodo [1]: " method
    method=${method:-1}

    if [ "$method" = "1" ]; then
        read_connection_string "$db_type"
    else
        read_credentials_manual "$db_type" "$default_host" "$default_port" "$default_user"
    fi
}

validate_dump_file() {
    local dump_file="$1"
    local has_create_table=false
    local has_foreign_keys=false
    local has_sequences=false
    local has_data=false
    local has_drop_commands=false
    local warnings=()
    local errors=()

    log "Validazione del file dump in corso..."

    # Controlla il contenuto del file
    if grep -q "CREATE TABLE" "$dump_file"; then
        has_create_table=true
    fi

    if grep -qE "(FOREIGN KEY|REFERENCES|ADD CONSTRAINT.*FOREIGN)" "$dump_file"; then
        has_foreign_keys=true
    fi

    if grep -q "CREATE SEQUENCE" "$dump_file"; then
        has_sequences=true
    fi

    if grep -qE "(^INSERT INTO|^COPY)" "$dump_file"; then
        has_data=true
    fi

    if grep -qE "(DROP TABLE|DROP SEQUENCE|DROP SCHEMA)" "$dump_file"; then
        has_drop_commands=true
    fi

    # Analizza i risultati
    echo "" >&2
    echo "=========================================="
    echo "  RISULTATI VALIDAZIONE DUMP"
    echo "=========================================="

    if [ "$has_create_table" = true ]; then
        echo "✓ Struttura tabelle: PRESENTE"
    else
        echo "✗ Struttura tabelle: ASSENTE"
        errors+=("Il dump non contiene la struttura delle tabelle (CREATE TABLE)")
    fi

    if [ "$has_foreign_keys" = true ]; then
        echo "✓ Foreign Keys: PRESENTI"
    else
        echo "⚠ Foreign Keys: ASSENTI"
        warnings+=("Il dump non contiene foreign keys. Le relazioni tra tabelle potrebbero non essere preservate.")
    fi

    if [ "$has_sequences" = true ]; then
        echo "✓ Sequences: PRESENTI"
    else
        echo "⚠ Sequences: ASSENTI (verranno ricreate automaticamente)"
        warnings+=("Il dump non contiene sequences, ma verranno ricalcolate automaticamente dopo l'import.")
    fi

    if [ "$has_data" = true ]; then
        echo "✓ Dati: PRESENTI"
    else
        echo "✗ Dati: ASSENTI"
        errors+=("Il dump non contiene dati (INSERT/COPY). Verrà importata solo la struttura.")
    fi

    if [ "$has_drop_commands" = true ]; then
        echo "✓ Comandi DROP: PRESENTI (pulizia automatica)"
    else
        echo "⚠ Comandi DROP: ASSENTI"
        warnings+=("Il dump non contiene comandi DROP. Potrebbero verificarsi conflitti con oggetti esistenti.")
    fi

    echo "=========================================="
    echo ""

    # Mostra errori critici
    if [ ${#errors[@]} -gt 0 ]; then
        echo "❌ ERRORI CRITICI:"
        for err in "${errors[@]}"; do
            echo "   • $err"
        done
        echo ""
    fi

    # Mostra warning
    if [ ${#warnings[@]} -gt 0 ]; then
        echo "⚠️  AVVISI:"
        for warn in "${warnings[@]}"; do
            echo "   • $warn"
        done
        echo ""
    fi

    # Se ci sono errori critici, chiedi conferma
    if [ ${#errors[@]} -gt 0 ]; then
        echo "Il dump potrebbe non essere completo o compatibile."
        echo ""
        echo "Per creare un dump compatibile, usa:"
        echo "  pg_dump --no-owner --no-privileges -f dump.sql"
        echo ""
        read -p "Continuare comunque con questo dump? (si/no): " continue_validation
        if [ "$continue_validation" != "si" ] && [ "$continue_validation" != "SI" ] && [ "$continue_validation" != "s" ] && [ "$continue_validation" != "S" ]; then
            error "Validazione dump fallita. Operazione annullata."
        fi
    elif [ ${#warnings[@]} -gt 0 ]; then
        # Se ci sono solo warning, chiedi comunque conferma
        read -p "Continuare con questo dump? (si/no) [si]: " continue_validation
        continue_validation=${continue_validation:-si}
        if [ "$continue_validation" != "si" ] && [ "$continue_validation" != "SI" ] && [ "$continue_validation" != "s" ] && [ "$continue_validation" != "S" ]; then
            error "Operazione annullata dall'utente."
        fi
    else
        log "✓ Validazione completata: dump compatibile"
    fi

    echo ""
}

# ============================================
# RACCOLTA CREDENZIALI
# ============================================

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  SINCRONIZZAZIONE DATABASE POSTGRESQL  ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Scelta tipo di sorgente
if [ -n "$CLI_SOURCE_TYPE" ]; then
    source_type="$CLI_SOURCE_TYPE"
    # Validazione
    if [ "$source_type" != "remote" ] && [ "$source_type" != "local" ]; then
        error "Valore non valido per --source-type: $source_type (usa 'remote' o 'local')"
    fi
    log "Tipo sorgente da CLI: $source_type"
else
    echo "=========================================="
    echo "  TIPO DI SORGENTE"
    echo "=========================================="
    echo "1) Database remoto (effettua dump)"
    echo "2) File dump locale (.sql)"
    echo ""
    read -p "Scegli il tipo di sorgente [1]: " source_type_choice
    source_type_choice=${source_type_choice:-1}

    # Converti da numero a stringa
    if [ "$source_type_choice" = "1" ]; then
        source_type="remote"
    elif [ "$source_type_choice" = "2" ]; then
        source_type="local"
    else
        source_type="$source_type_choice"  # Accetta anche "remote" o "local" diretto
    fi
fi

# File per il dump
DUMP_FILE="/tmp/pg_sync_$(date +%Y%m%d_%H%M%S).sql"
USE_LOCAL_FILE=false

if [ "$source_type" = "local" ]; then
    # File locale
    if [ -n "$CLI_SOURCE_FILE" ]; then
        LOCAL_DUMP_FILE="$CLI_SOURCE_FILE"
        log "File dump da CLI: $LOCAL_DUMP_FILE"
    else
        echo ""
        echo "=========================================="
        echo "  FILE DUMP LOCALE"
        echo "=========================================="
        read -p "Percorso del file dump .sql: " LOCAL_DUMP_FILE
    fi

    # Verifica esistenza file
    if [ ! -f "$LOCAL_DUMP_FILE" ]; then
        error "File non trovato: $LOCAL_DUMP_FILE"
    fi

    # Verifica estensione .sql
    if [[ ! "$LOCAL_DUMP_FILE" =~ \.sql$ ]]; then
        echo "⚠️  Attenzione: il file non ha estensione .sql"
        if [ "$CLI_SKIP_CONFIRM" = false ]; then
            read -p "Continuare comunque? (si/no): " continue_anyway
            if [ "$continue_anyway" != "si" ] && [ "$continue_anyway" != "SI" ] && [ "$continue_anyway" != "s" ] && [ "$continue_anyway" != "S" ]; then
                error "Operazione annullata"
            fi
        fi
    fi

    DUMP_FILE="$LOCAL_DUMP_FILE"
    USE_LOCAL_FILE=true
    log "Usando file dump locale: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"

    # Valida il contenuto del dump
    validate_dump_file "$DUMP_FILE"
else
    # Database remoto - usa parametri CLI se disponibili
    if [ -n "$CLI_SOURCE_CONN" ]; then
        SOURCE_CREDS=$(parse_connection_string "$CLI_SOURCE_CONN")
        if [ $? -ne 0 ] || [ -z "$SOURCE_CREDS" ]; then
            error "Formato stringa di connessione sorgente non valido"
        fi
        IFS='|' read -r SOURCE_HOST SOURCE_PORT SOURCE_DB SOURCE_USER SOURCE_PASSWORD <<< "$SOURCE_CREDS"
        log "Credenziali sorgente da CLI (connection string)"
    elif [ -n "$CLI_SOURCE_HOST" ] && [ -n "$CLI_SOURCE_DB" ] && [ -n "$CLI_SOURCE_USER" ]; then
        SOURCE_HOST="${CLI_SOURCE_HOST}"
        SOURCE_PORT="${CLI_SOURCE_PORT:-5432}"
        SOURCE_DB="${CLI_SOURCE_DB}"
        SOURCE_USER="${CLI_SOURCE_USER}"
        SOURCE_PASSWORD="${CLI_SOURCE_PASSWORD}"
        log "Credenziali sorgente da CLI (parametri separati)"
    else
        SOURCE_CREDS=$(read_credentials "SORGENTE" "localhost" "5432" "postgres")
        IFS='|' read -r SOURCE_HOST SOURCE_PORT SOURCE_DB SOURCE_USER SOURCE_PASSWORD <<< "$SOURCE_CREDS"
    fi
fi

echo ""

# Leggi credenziali DESTINAZIONE - usa parametri CLI se disponibili
if [ -n "$CLI_DEST_CONN" ]; then
    DEST_CREDS=$(parse_connection_string "$CLI_DEST_CONN")
    if [ $? -ne 0 ] || [ -z "$DEST_CREDS" ]; then
        error "Formato stringa di connessione destinazione non valido"
    fi
    IFS='|' read -r DEST_HOST DEST_PORT DEST_DB DEST_USER DEST_PASSWORD <<< "$DEST_CREDS"
    log "Credenziali destinazione da CLI (connection string)"
elif [ -n "$CLI_DEST_HOST" ] && [ -n "$CLI_DEST_DB" ] && [ -n "$CLI_DEST_USER" ]; then
    DEST_HOST="${CLI_DEST_HOST}"
    DEST_PORT="${CLI_DEST_PORT:-5432}"
    DEST_DB="${CLI_DEST_DB}"
    DEST_USER="${CLI_DEST_USER}"
    DEST_PASSWORD="${CLI_DEST_PASSWORD}"
    log "Credenziali destinazione da CLI (parametri separati)"
else
    DEST_CREDS=$(read_credentials "DESTINAZIONE" "localhost" "5432" "postgres")
    IFS='|' read -r DEST_HOST DEST_PORT DEST_DB DEST_USER DEST_PASSWORD <<< "$DEST_CREDS"
fi

# ============================================
# CONFERMA
# ============================================

echo ""
echo "=========================================="
echo "  RIEPILOGO SINCRONIZZAZIONE"
echo "=========================================="
echo ""
if [ "$USE_LOCAL_FILE" = true ]; then
    echo "📤 SORGENTE:"
    echo "   Tipo:     File dump locale"
    echo "   File:     $DUMP_FILE"
    echo "   Dimensione: $(du -h "$DUMP_FILE" | cut -f1)"
else
    echo "📤 DATABASE SORGENTE (da cui copiare):"
    echo "   Host:     $SOURCE_HOST"
    echo "   Porta:    $SOURCE_PORT"
    echo "   Database: $SOURCE_DB"
    echo "   Username: $SOURCE_USER"
    echo "   Password: ********"
fi
echo ""
echo "📥 DATABASE DESTINAZIONE (da sovrascrivere):"
echo "   Host:     $DEST_HOST"
echo "   Porta:    $DEST_PORT"
echo "   Database: $DEST_DB"
echo "   Username: $DEST_USER"
echo "   Password: ********"
echo ""
echo "⚠️  ATTENZIONE: Tutti i dati in '$DEST_DB' verranno sovrascritti!"
echo ""

if [ "$CLI_SKIP_CONFIRM" = false ]; then
    read -p "Procedere con la sincronizzazione? (si/no): " confirm
    if [ "$confirm" != "si" ] && [ "$confirm" != "SI" ] && [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        log "Sincronizzazione annullata dall'utente"
        exit 0
    fi
else
    log "Conferma saltata (--skip-confirm)"
fi

# ============================================
# SCRIPT PRINCIPALE
# ============================================

log "Inizio sincronizzazione database"

# 1. EXPORT dalla sorgente (solo se non è un file locale)
if [ "$USE_LOCAL_FILE" = true ]; then
    log "Usando file dump esistente ($(du -h "$DUMP_FILE" | cut -f1))"
else
    log "Export dal database sorgente (struttura + dati)..."
    PGPASSWORD="$SOURCE_PASSWORD" pg_dump \
        -h "$SOURCE_HOST" \
        -p "$SOURCE_PORT" \
        -U "$SOURCE_USER" \
        -d "$SOURCE_DB" \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        -f "$DUMP_FILE" || error "Errore durante export"

    log "Export completato: $(du -h $DUMP_FILE | cut -f1)"
fi

# 2. IMPORT nella destinazione
log "Import dei dati nella destinazione..."
log "Applicazione ottimizzazioni temporanee..."

IMPORT_START=$(date +%s)

PGPASSWORD="$DEST_PASSWORD" psql \
    -h "$DEST_HOST" \
    -p "$DEST_PORT" \
    -U "$DEST_USER" \
    -d "$DEST_DB" \
    << EOF || error "Errore durante import"
-- Ottimizzazioni temporanee per velocizzare l'import
SET maintenance_work_mem = '512MB';
SET work_mem = '64MB';
SET synchronous_commit = OFF;

\echo 'Ottimizzazioni applicate. Inizio import...'
\echo 'Nota: eventuali errori di permessi su DROP verranno ignorati'

-- Esegue il dump (ignora errori di permessi ma mostra i messaggi)
\i $DUMP_FILE

-- Ripristina impostazioni normali
RESET maintenance_work_mem;
RESET work_mem;
RESET synchronous_commit;

\echo 'Import completato'
EOF

IMPORT_END=$(date +%s)
IMPORT_DURATION=$((IMPORT_END - IMPORT_START))

log "Import completato in ${IMPORT_DURATION}s"

# 3. STATISTICHE POST-IMPORT
log "Raccolta statistiche database..."

PGPASSWORD="$DEST_PASSWORD" psql \
    -h "$DEST_HOST" \
    -p "$DEST_PORT" \
    -U "$DEST_USER" \
    -d "$DEST_DB" \
    -t \
    << 'EOF' || log "Avviso: impossibile raccogliere statistiche"
SELECT
    schemaname || '.' || tablename as tabella,
    n_live_tup as righe
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC
LIMIT 10;
EOF

# 4. FIX delle SEQUENCE
log "Aggiornamento delle sequence (auto increment)..."

PGPASSWORD="$DEST_PASSWORD" psql \
    -h "$DEST_HOST" \
    -p "$DEST_PORT" \
    -U "$DEST_USER" \
    -d "$DEST_DB" \
    -v ON_ERROR_STOP=1 \
    << 'EOF' || error "Errore durante fix sequence"
DO $$
DECLARE
    seq_record RECORD;
    max_val BIGINT;
    updated_count INTEGER := 0;
BEGIN
    -- Per ogni sequence nel database con la sua tabella e colonna associata
    FOR seq_record IN
        SELECT
            s.schemaname,
            s.sequencename,
            t.relname as tablename,
            a.attname as column_name
        FROM pg_sequences s
        JOIN pg_class c ON c.relname = s.sequencename AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = s.schemaname)
        JOIN pg_depend d ON d.objid = c.oid
        JOIN pg_class t ON t.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        WHERE s.schemaname = 'public'
        AND d.deptype = 'a'
    LOOP
        -- Ottiene il max valore dalla colonna
        EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %I.%I',
                      seq_record.column_name,
                      seq_record.schemaname,
                      seq_record.tablename)
        INTO max_val;

        -- Aggiorna la sequence
        EXECUTE format('SELECT setval(%L, %s, true)',
                      seq_record.schemaname || '.' || seq_record.sequencename,
                      GREATEST(max_val, 1));

        updated_count := updated_count + 1;
        RAISE NOTICE '✓ Sequence %.% (tabella %.%, colonna %) → %',
                    seq_record.schemaname,
                    seq_record.sequencename,
                    seq_record.schemaname,
                    seq_record.tablename,
                    seq_record.column_name,
                    GREATEST(max_val, 1);
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE 'Totale sequence aggiornate: %', updated_count;
END $$;
EOF

log "Sequence aggiornate"

# 5. PULIZIA
if [ "$USE_LOCAL_FILE" = true ]; then
    log "File dump locale conservato: $DUMP_FILE"
else
    log "Rimozione file temporaneo..."
    rm -f "$DUMP_FILE"
fi

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  ✅ SINCRONIZZAZIONE COMPLETATA!      ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "⏱️  Tempo import: ${IMPORT_DURATION}s"
echo "📊 Database: $DEST_DB su $DEST_HOST:$DEST_PORT"
echo ""

exit 0