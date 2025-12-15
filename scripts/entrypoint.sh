#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
BACKUP_DIR="/opt/trinitycore/etc-backup"
SQL_DIR="/opt/trinitycore/sql"
DATA_DIR="/opt/trinitycore/data"

# DB credentials
DB_HOST=${DB_HOST:-"db"}
DB_USER=${DB_USER:-"root"}
DB_PASS=${DB_PASS:-"trinity"}

echo ">>> TrinityCore MASTER Entrypoint started <<<"

# --- 1. SSL CERTIFICATES (FIX FOR OSSL ERROR) ---
# Bnetserver needs certs. If missing, generate them.
if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ] || [ ! -f "$ETC_DIR/bnetserver.key.pem" ]; then
    echo "Generating SSL certificates for Bnetserver..."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" \
        -keyout "$ETC_DIR/bnetserver.key.pem" \
        -out "$ETC_DIR/bnetserver.cert.pem" \
        2>/dev/null
    
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"
    chmod 600 "$ETC_DIR/bnetserver.key.pem"
    
    # Symlink to bin dir just in case the server looks there
    ln -sf "$ETC_DIR/bnetserver.cert.pem" "$BIN_DIR/bnetserver.cert.pem"
    ln -sf "$ETC_DIR/bnetserver.key.pem" "$BIN_DIR/bnetserver.key.pem"
    echo "SSL Certificates generated."
fi

# --- 2. CONFIG RESTORE ---
if [ -d "$BACKUP_DIR" ]; then
    if [ ! -f "$ETC_DIR/bnetserver.conf.dist" ]; then
        echo "Volume mount detected. Restoring config files..."
        cp -r "$BACKUP_DIR/." "$ETC_DIR/"
    fi
fi

# --- 3. CONFIG HELPER FUNCTIONS (FIX FOR BAD VALUE ERROR) ---

# Use this for text/connection strings (Adds quotes "")
set_config_string() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "s|^$key\s*=\s*.*|$key = \"$value\"|g" "$file"
    fi
}

# Use this for numbers/booleans (NO quotes)
set_config_int() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "s|^$key\s*=\s*.*|$key = $value|g" "$file"
    fi
}

# --- 4. CONFIG SETUP ---
if [ ! -f "$ETC_DIR/bnetserver.conf" ] && [ -f "$ETC_DIR/bnetserver.conf.dist" ]; then
    cp "$ETC_DIR/bnetserver.conf.dist" "$ETC_DIR/bnetserver.conf"
fi
if [ ! -f "$ETC_DIR/worldserver.conf" ] && [ -f "$ETC_DIR/worldserver.conf.dist" ]; then
    cp "$ETC_DIR/worldserver.conf.dist" "$ETC_DIR/worldserver.conf"
fi

echo "Configuring server settings..."

# Bnetserver Config
set_config_string "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"

# Worldserver Config
# Strings (Connection info needs quotes)
set_config_string "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"
set_config_string "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;world"
set_config_string "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;characters"
set_config_string "$ETC_DIR/worldserver.conf" "DataDir"               "$DATA_DIR"

# Integers (NO QUOTES allowed here!)
set_config_int    "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int    "$ETC_DIR/worldserver.conf" "Updates.AutoSetup"       "1"

# --- 5. WAIT FOR DATABASE ---
echo "Waiting for database connection..."
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent; do
    sleep 2
done
echo "Database is reachable."

# --- 6. AUTO INSTALLATION ---
if ! mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "USE auth; SELECT 1 FROM realmlist LIMIT 1;" 2>/dev/null; then
    echo ">>> Database empty. Starting initial setup... <<<"

    if [ -d "$SQL_DIR" ]; then
        echo "Creating DB structure..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" < "$SQL_DIR/create/create_mysql.sql" || true

        echo "Importing base SQLs..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth < "$(find $SQL_DIR/base -name 'auth_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" characters < "$(find $SQL_DIR/base -name 'characters_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find $SQL_DIR/base -name 'world_database.sql')"

        echo "Searching for TDB..."
        API_RESPONSE=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest)
        
        if echo "$API_RESPONSE" | jq -e . >/dev/null 2>&1; then
             LATEST_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | startswith("TDB_full_") and (.name | contains("335") | not)) | .browser_download_url')
        else
             LATEST_URL=""
             echo "WARNING: GitHub API limit reached. Skipping TDB download."
        fi
        
        if [ -n "$LATEST_URL" ] && [ "$LATEST_URL" != "null" ]; then
            echo "Found TDB: $LATEST_URL"
            curl -L -o /tmp/tdb.7z "$LATEST_URL"
            7z e /tmp/tdb.7z -o/tmp/tdb_extracted -y
            mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find /tmp/tdb_extracted -name '*.sql' | head -n 1)"
            rm -rf /tmp/tdb.7z /tmp/tdb_extracted
            echo "TDB Import completed."
        fi
    fi
fi

# --- 7. REALM IP ---
if [ ! -z "$TRINITY_REALM_IP" ] && [ "$1" = "bnetserver" ]; then
    echo "Setting Realmlist IP: $TRINITY_REALM_IP"
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "UPDATE realmlist SET address = '$TRINITY_REALM_IP', name = 'Trinity Master Docker' WHERE id = 1;" 2>/dev/null || true
fi

# --- 8. START SERVER ---
if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then
    exec "$BIN_DIR/worldserver"
else
    exec "$@"
fi
