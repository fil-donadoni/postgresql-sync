# PostgreSQL Sync

Script Bash per sincronizzare database PostgreSQL con gestione automatica di foreign keys e sequences.

## Cosa fa

Questo script ti permette di:

- **Copiare** un database PostgreSQL da una sorgente a una destinazione
- **Sincronizzare** dati tra database remoti o da file dump locali
- **Gestire automaticamente** foreign keys e sequences (auto-increment)
- **Validare** i file dump prima dell'importazione
- **Ottimizzare** l'importazione per velocizzare il processo

Lo script supporta due modalità:
1. **Database remoto → Database remoto**: esegue il dump dalla sorgente e lo importa nella destinazione
2. **File dump locale → Database remoto**: usa un file .sql esistente e lo importa nel database di destinazione

## Requisiti

- Bash (preinstallato su Linux/macOS)
- PostgreSQL client tools (`pg_dump`, `psql`)
- Accesso ai database sorgente e destinazione

### Installazione PostgreSQL client su macOS

```bash
brew install postgresql
```

### Installazione PostgreSQL client su Ubuntu/Debian

```bash
sudo apt-get install postgresql-client
```

## Utilizzo

### Modalità 1: Interattiva (consigliata per principianti)

Lancia semplicemente lo script senza parametri:

```bash
chmod +x postgresql-sync.sh
./postgresql-sync.sh
```

Lo script ti guiderà passo passo chiedendoti:
1. Tipo di sorgente (database remoto o file locale)
2. Credenziali del database sorgente (o percorso file dump)
3. Credenziali del database destinazione
4. Conferma finale prima di procedere

### Modalità 2: Con parametri CLI (per automazione)

#### Da database remoto a database remoto (connection string)

```bash
./postgresql-sync.sh \
  --source-conn "postgresql://user:password@source.example.com:5432/sourcedb" \
  --dest-conn "postgresql://user:password@dest.example.com:5432/destdb" \
  --skip-confirm
```

#### Da database remoto a database remoto (parametri separati)

```bash
./postgresql-sync.sh \
  --source-type remote \
  --source-host source.example.com \
  --source-port 5432 \
  --source-db sourcedb \
  --source-user myuser \
  --source-password mypassword \
  --dest-host dest.example.com \
  --dest-port 5432 \
  --dest-db destdb \
  --dest-user myuser \
  --dest-password mypassword \
  --skip-confirm
```

#### Da file dump locale a database remoto

```bash
./postgresql-sync.sh \
  --source-type local \
  --source-file /path/to/backup.sql \
  --dest-conn "postgresql://user:password@dest.example.com:5432/destdb" \
  --skip-confirm
```

## Parametri disponibili

| Parametro | Descrizione | Esempio |
|-----------|-------------|---------|
| `--source-type` | Tipo sorgente: `remote` o `local` | `--source-type remote` |
| `--source-file` | Path del file dump locale | `--source-file /tmp/dump.sql` |
| `--source-conn` | Stringa connessione sorgente | `--source-conn "postgresql://..."` |
| `--source-host` | Host sorgente | `--source-host db.example.com` |
| `--source-port` | Porta sorgente | `--source-port 5432` |
| `--source-db` | Database sorgente | `--source-db mydb` |
| `--source-user` | Username sorgente | `--source-user postgres` |
| `--source-password` | Password sorgente | `--source-password secret` |
| `--dest-conn` | Stringa connessione destinazione | `--dest-conn "postgresql://..."` |
| `--dest-host` | Host destinazione | `--dest-host localhost` |
| `--dest-port` | Porta destinazione | `--dest-port 5432` |
| `--dest-db` | Database destinazione | `--dest-db mydb_copy` |
| `--dest-user` | Username destinazione | `--dest-user postgres` |
| `--dest-password` | Password destinazione | `--dest-password secret` |
| `--skip-confirm` | Salta conferma finale | `--skip-confirm` |
| `--help` | Mostra help | `--help` |

## Formato connection string

Lo script accetta stringhe di connessione PostgreSQL standard:

```
postgresql://username:password@host:port/database
```

Esempi:
```
postgresql://postgres:mypass@localhost:5432/mydb
postgresql://user:pass@db.example.com:5432/production
```

Se la password non è inclusa nella stringa, lo script la richiederà interattivamente.

## Cosa fa lo script internamente

1. **Validazione**: controlla il file dump (se locale) per verificare che contenga struttura, dati, foreign keys
2. **Export** (se da DB remoto): esegue `pg_dump` con opzioni ottimali (`--clean`, `--if-exists`, `--no-owner`, `--no-privileges`)
3. **Ottimizzazione**: applica impostazioni temporanee per velocizzare l'import
4. **Import**: carica il dump nel database destinazione
5. **Fix sequences**: aggiorna automaticamente tutte le sequences (auto-increment) ai valori corretti
6. **Statistiche**: mostra statistiche post-import (tabelle e righe importate)

## Caratteristiche avanzate

### Gestione automatica delle sequences

Lo script aggiorna automaticamente tutte le sequences PostgreSQL dopo l'import, assicurandosi che i prossimi `INSERT` non causino conflitti di chiavi primarie.

### Validazione dump

Quando usi un file dump locale, lo script:
- Verifica la presenza di `CREATE TABLE`
- Controlla la presenza di foreign keys
- Verifica che ci siano dati da importare
- Avvisa se mancano comandi `DROP`

### Ottimizzazioni performance

Durante l'import, lo script applica temporaneamente:
- `maintenance_work_mem = 512MB`
- `work_mem = 64MB`
- `synchronous_commit = OFF`

Questo può velocizzare significativamente grandi import.

## Sicurezza

- Le password non vengono mai stampate nei log
- Le password da linea di comando sono visibili nel process list (usa la modalità interattiva per maggiore sicurezza)
- Lo script chiede sempre conferma prima di sovrascrivere il database destinazione (a meno di `--skip-confirm`)

## Troubleshooting

### Errore: "command not found: pg_dump"

Installa i PostgreSQL client tools (vedi sezione Requisiti).

### Errore: "permission denied"

Verifica che l'utente abbia i permessi corretti sul database:
- Permessi di lettura sul database sorgente
- Permessi di scrittura (DROP, CREATE) sul database destinazione

### Import lento

Per database molto grandi (>1GB), considera:
- Usare un file dump compresso
- Aumentare i parametri di ottimizzazione
- Eseguire l'import su una macchina con più RAM

### Conflitti di foreign keys

Lo script usa `--clean --if-exists` per gestire automaticamente le foreign keys, ma se riscontri problemi:
1. Assicurati che il dump sia stato creato con `pg_dump --clean`
2. Verifica che non ci siano trigger o constraint custom che bloccano il DROP

## Esempi pratici

### Copiare database di produzione in sviluppo

```bash
./postgresql-sync.sh \
  --source-conn "postgresql://prod_user:prod_pass@prod.example.com:5432/production" \
  --dest-conn "postgresql://dev_user:dev_pass@localhost:5432/development"
```

### Ripristinare un backup locale

```bash
./postgresql-sync.sh \
  --source-type local \
  --source-file /backups/production_2025-12-13.sql \
  --dest-conn "postgresql://postgres:postgres@localhost:5432/restored_db"
```

### Sincronizzazione automatica (cron job)

```bash
# Aggiungi a crontab per backup giornaliero alle 2 AM
0 2 * * * /path/to/postgresql-sync.sh \
  --source-conn "postgresql://..." \
  --dest-conn "postgresql://..." \
  --skip-confirm >> /var/log/pg-sync.log 2>&1
```

## Licenza

Questo script è fornito "as is" senza garanzie. Usalo a tuo rischio.

## Contributi

Suggerimenti e miglioramenti sono benvenuti!
