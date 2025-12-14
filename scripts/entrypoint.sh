#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
BACKUP_DIR="/opt/trinitycore/etc-backup"
SQL_DIR="/opt/trinitycore/sql"
DATA_DIR="/opt/trinitycore/data"

# DB credentials (dynamic with defaults)
DB_HOST=${DB_HOST:-"db"}
DB_USER=${DB_USER:-"root"}
DB_PASS=${DB_PASS:-"trinity"}

echo ">>> TrinityCore MASTER Entrypoint started <<<"

# --- 1. CONFIG RESTORE ---
if [ -d "$BACKUP_DIR" ]; then
    # Check for bnetserver.conf.dist (Master uses bnetserver)
    if [ ! -f "$ETC_DIR/bnetserver.conf.dist" ]; then
        echo "Volume mount detected (etc dir is empty). Restoring config files from backup..."
        cp -r "$BACKUP_DIR/." "$ETC_DIR/"
        echo "Restore complete."
    fi
fi

# Config Helper
set_config() {
    local file=$1
    local key=$2
    local value=$3
    if [ -f "$file" ]; then
        sed -i "s|^$key\s*=\s*.*|$key = \"$value\"|g" "$file"
    fi
}

# --- 2. CONFIG SETUP ---
# Master Branch uses 'bnetserver'
if [ ! -f "$ETC_DIR/bnetserver.conf" ] && [ -f "$ETC_DIR/bnetserver.conf.dist" ]; then
    cp "$ETC_DIR/bnetserver.conf.dist" "$ETC_DIR/bnetserver.conf"
fi
if [ ! -f "$ETC_DIR/worldserver.conf" ] && [ -f "$ETC_DIR/worldserver.conf.dist" ]; then
    cp "$ETC_DIR/worldserver.conf.dist" "$ETC_DIR/worldserver.conf"
fi

echo "Configuring server settings..."
set_config "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"
set_config "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"
set_config "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;world"
set_config "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;characters"
set_config "$ETC_DIR/worldserver.conf" "DataDir"               "$DATA_DIR"
set_config "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config "$ETC_DIR/worldserver.conf" "Updates.AutoSetup"       "1"

# --- 3. WAIT FOR DATABASE ---
echo "Waiting for database connection..."
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent; do
    sleep 2
done
echo "Database is reachable."

# --- 4. AUTO INSTALLATION (If DB empty) ---
if ! mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "USE auth; SELECT 1 FROM realmlist LIMIT 1;" 2>/dev/null; then
    echo ">>> Database empty. Starting initial setup for MASTER... <<<"

    if [ -d "$SQL_DIR" ]; then
        # A. Create structure
        # Allow failure (|| true) in case user 'trinity' already exists from a previous run
        echo "Creating DB structure..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" < "$SQL_DIR/create/create_mysql.sql" || true

        # B. Import base SQLs
        echo "Importing base SQLs..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth < "$(find $SQL_DIR/base -name 'auth_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" characters < "$(find $SQL_DIR/base -name 'characters_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find $SQL_DIR/base -name 'world_database.sql')"

        # C. TDB Download & Import
        echo "Searching for latest TDB for MASTER on GitHub..."
        
        # Check API response first to avoid jq crashes on rate limits
        API_RESPONSE=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest)
        
        # Validate if response is valid JSON
        if echo "$API_RESPONSE" | jq -e . >/dev/null 2>&1; then
             LATEST_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | startswith("TDB_full_") and (.name | contains("335") | not)) | .browser_download_url')
        else
             LATEST_URL=""
             echo "WARNING: GitHub API returned invalid JSON (Rate limit exceeded?). Skipping TDB download."
        fi
        
        if [ -n "$LATEST_URL" ] && [ "$LATEST_URL" != "null" ]; then
            echo "Found TDB: $LATEST_URL"
            curl -L -o /tmp/tdb.7z "$LATEST_URL"
            7z e /tmp/tdb.7z -o/tmp/tdb_extracted -y
            mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find /tmp/tdb_extracted -name '*.sql' | head -n 1)"
            rm -rf /tmp/tdb.7z /tmp/tdb_extracted
            echo "TDB Import completed."
        else
            echo "WARNING: TDB URL not found. Server starts with empty world."
        fi
    fi
fi

# --- 5. REALM IP ---
if [ ! -z "$TRINITY_REALM_IP" ] && [ "$1" = "bnetserver" ]; then
    echo "Setting Realmlist IP: $TRINITY_REALM_IP"
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "UPDATE realmlist SET address = '$TRINITY_REALM_IP', name = 'Trinity Master Docker' WHERE id = 1;" 2>/dev/null || true
fi

# --- 6. START SERVER ---
if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then
    echo "Starting Bnetserver..."
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then
    echo "Starting Worldserver..."
    exec "$BIN_DIR/worldserver"
else
    exec "$@"
fi
