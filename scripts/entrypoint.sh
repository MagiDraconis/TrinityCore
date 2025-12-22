#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
BACKUP_DIR="/opt/trinitycore/etc-backup"
SQL_DIR="/opt/trinitycore/sql"
DATA_DIR="/opt/trinitycore/data"

# DB credentials - Standard ist "db", aber du kannst es in docker-compose überschreiben
DB_HOST=${DB_HOST:-"db"} 
DB_USER=${DB_USER:-"root"}
DB_PASS=${DB_PASS:-"trinity"}

echo "=========================================="
echo " TrinityCore MASTER Entrypoint (External DB Ready)"
echo "=========================================="
echo "Target Database Host: $DB_HOST" 
echo "Server Mode: $1"

# --- 1. CONFIG RESTORE ---
echo "[1/7] Restoring config..."
if [ -d "$BACKUP_DIR" ]; then
    cp -f "$BACKUP_DIR"/*.conf.dist "$ETC_DIR/" 2>/dev/null || true
fi
for conf in bnetserver worldserver; do
    if [ -f "$ETC_DIR/$conf.conf.dist" ]; then
        cp -f "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"
    fi
done

# --- 2. SSL CERTIFICATES ---
echo "[2/7] Checking SSL..."
if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ] || [ ! -f "$ETC_DIR/bnetserver.key.pem" ]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" \
        -keyout "$ETC_DIR/bnetserver.key.pem" \
        -out "$ETC_DIR/bnetserver.cert.pem" \
        2>/dev/null
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"
    chmod 600 "$ETC_DIR/bnetserver.key.pem"
fi

# --- 3. CONFIGURE SERVERS ---
set_config_string() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
        echo "${key} = \"${value}\"" >> "$file"
    fi
}
set_config_int() {
    local file=$1; local key=$2; local value=$3
    if [ -f "$file" ]; then
        sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
        echo "${key} = ${value}" >> "$file"
    fi
}

echo "[3/7] Configuring connection to external DB..."

# WICHTIG: Hier wird $DB_HOST eingetragen (z.B. "trinitydb")
set_config_string "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"
set_config_string "$ETC_DIR/bnetserver.conf" "BindIP" "0.0.0.0"
set_config_string "$ETC_DIR/bnetserver.conf" "CertificatesFile" "${ETC_DIR}/bnetserver.cert.pem"
set_config_string "$ETC_DIR/bnetserver.conf" "PrivateKeyFile" "${ETC_DIR}/bnetserver.key.pem"

set_config_string "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"
set_config_string "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};world"
set_config_string "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};characters"
set_config_string "$ETC_DIR/worldserver.conf" "HotfixDatabaseInfo"    "${DB_HOST};3306;${DB_USER};${DB_PASS};hotfixes"
set_config_string "$ETC_DIR/worldserver.conf" "DataDir"               "${DATA_DIR}"
set_config_string "$ETC_DIR/worldserver.conf" "SourceDirectory"       "/opt/trinitycore"

# AutoSetup für Master Branch aktivieren
set_config_int "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int "$ETC_DIR/worldserver.conf" "Updates.AutoSetup" "1"

# --- 4. WAIT FOR EXTERNAL DB ---
echo "[4/7] Waiting for database at $DB_HOST..."
MAX_TRIES=30
COUNT=0
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_TRIES ]; then 
        echo "  ✗ Timeout connecting to $DB_HOST"
        exit 1
    fi
    sleep 2
done
echo "  ✓ Database reachable"

# --- 5. PREPARE DB (DOCS COMPLIANT) ---
echo "[5/7] Checking installation..."

# Wir prüfen ob die Account-Tabelle existiert
TABLE_EXISTS=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -sN -e \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'auth' AND TABLE_NAME = 'account';" \
    2>/dev/null || echo "0")

if [ "$TABLE_EXISTS" = "0" ]; then
    echo "  → Fresh install detected."

    # SCHRITT A: User & DBs erstellen
    if [ -f "$SQL_DIR/create/create_mysql.sql" ]; then
        echo "  → Creating users and DB shells..."
        
        # WICHTIG FÜR EXTERNE DB: 
        # Wir ersetzen 'localhost' durch '%', damit der User von JEDEM Container aus zugreifen darf.
        sed "s/'trinity'@'localhost'/'trinity'@'%'/g" "$SQL_DIR/create/create_mysql.sql" | \
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" 2>&1 | grep -v "Warning" || true
        
        echo "  ✓ Permissions fixed for external access"
    fi

    # SCHRITT B: TDB laden
    echo "  → Checking for TDB..."
    API_RESPONSE=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest 2>/dev/null || echo "{}")
    LATEST_TDB_URL=$(echo "$API_RESPONSE" | jq -r \
        '.assets[] | select(.name | test("TDB_full_.*.7z") and (.name | contains("335") | not)) | .browser_download_url' \
        | head -1)

    if [ -n "$LATEST_TDB_URL" ] && [ "$LATEST_TDB_URL" != "null" ]; then
        TDB_FILENAME=$(basename "$LATEST_TDB_URL")
        if [ -z "$(find "$BIN_DIR" -name 'TDB_full_world_*.sql' -print -quit)" ]; then
            echo "  → Downloading $TDB_FILENAME..."
            curl -L -o "/tmp/$TDB_FILENAME" "$LATEST_TDB_URL"
            echo "  → Extracting to bin..."
            7z e "/tmp/$TDB_FILENAME" -o"$BIN_DIR" -y >/dev/null
            rm -f "/tmp/$TDB_FILENAME"
            echo "  ✓ TDB ready for AutoSetup"
        fi
    fi
else
    echo "  ✓ Database already populated."
fi

# --- 6. REALM SETUP ---
echo "[6/7] Setting Realm IP..."
if [ "$1" = "bnetserver" ] || [ "$1" = "auth" ]; then
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    
    # Update Existing
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e \
        "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
    
    # Insert New (Ignored if exists)
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e \
        "INSERT IGNORE INTO realmlist (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild) 
         VALUES (1, 'Trinity Master Docker', '$REALM_IP', '127.0.0.1', '255.255.255.0', 8085, 0, 0, 1, 0, 0, 57388);" \
        2>/dev/null || true
        
    echo "  ✓ Realm IP set to $REALM_IP"
fi

# --- 7. START ---
echo "=========================================="
echo " Starting $1..."
echo "=========================================="

if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then
    exec "$BIN_DIR/worldserver"
else
    exec "$@"
fi
