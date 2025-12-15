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
echo "Target Database Host: $DB_HOST"

# --- 1. SSL CERTIFICATES ---
if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ] || [ ! -f "$ETC_DIR/bnetserver.key.pem" ]; then
    echo "Generating SSL certificates..."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" \
        -keyout "$ETC_DIR/bnetserver.key.pem" \
        -out "$ETC_DIR/bnetserver.cert.pem" \
        2>/dev/null
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"
    chmod 600 "$ETC_DIR/bnetserver.key.pem"
fi

# --- 2. CONFIG RESTORE ---
if [ -d "$BACKUP_DIR" ]; then
    if [ ! -f "$ETC_DIR/bnetserver.conf.dist" ]; then
        echo "Restoring config files from backup..."
        cp -r "$BACKUP_DIR/." "$ETC_DIR/"
    fi
fi

# --- 3. CONFIG HELPER FUNCTIONS (REGEX FIX) ---

# Fix: Added \s* to match leading whitespace
set_config_string() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "s|^\s*$key\s*=.*|$key = \"$value\"|g" "$file"
    fi
}

set_config_int() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "s|^\s*$key\s*=.*|$key = $value|g" "$file"
    fi
}

# --- 4. CONFIG SETUP ---
# Ensure .conf files exist from .dist
for conf in bnetserver worldserver; do
    if [ ! -f "$ETC_DIR/$conf.conf" ] && [ -f "$ETC_DIR/$conf.conf.dist" ]; then
        cp "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"
    fi
done

echo "Configuring server settings..."

# Bnetserver
set_config_string "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"

# Worldserver
set_config_string "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;auth"
set_config_string "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "$DB_HOST;3306;$DB_USER;$DB_PASS;world"
set_config_string "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "$DB_HOST;3306;$DB_USER;$DB_PASS;characters"
set_config_string "$ETC_DIR/worldserver.conf" "DataDir"               "$DATA_DIR"

set_config_int    "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int    "$ETC_DIR/worldserver.conf" "Updates.AutoSetup"       "1"

# --- 5. WAIT FOR DATABASE ---
echo "Waiting for database ($DB_HOST)..."
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent; do
    sleep 2
done
echo "Database reachable."

# --- 6. AUTO INSTALLATION ---
if ! mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "USE auth; SELECT 1 FROM realmlist LIMIT 1;" 2>/dev/null; then
    echo ">>> Database empty. Starting initial setup... <<<"
    if [ -d "$SQL_DIR" ]; then
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" < "$SQL_DIR/create/create_mysql.sql" || true
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth < "$(find $SQL_DIR/base -name 'auth_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" characters < "$(find $SQL_DIR/base -name 'characters_database.sql')"
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find $SQL_DIR/base -name 'world_database.sql')"

        API_RESPONSE=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest)
        if echo "$API_RESPONSE" | jq -e . >/dev/null 2>&1; then
             LATEST_URL=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | startswith("TDB_full_") and (.name | contains("335") | not)) | .browser_download_url')
             if [ -n "$LATEST_URL" ] && [ "$LATEST_URL" != "null" ]; then
                echo "Downloading TDB: $LATEST_URL"
                curl -L -o /tmp/tdb.7z "$LATEST_URL"
                7z e /tmp/tdb.7z -o/tmp/tdb_extracted -y
                mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$(find /tmp/tdb_extracted -name '*.sql' | head -n 1)"
                rm -rf /tmp/tdb.7z /tmp/tdb_extracted
                echo "TDB Import completed."
             fi
        fi
    fi
fi

# --- 7. REALM IP ---
if [ ! -z "$TRINITY_REALM_IP" ] && [ "$1" = "bnetserver" ]; then
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
