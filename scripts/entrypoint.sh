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

echo "=========================================="
echo " TrinityCore MASTER Entrypoint"
echo "=========================================="
echo "Database Host: $DB_HOST"
echo "Server Mode: $1"

# --- 1. RESTORE CLEAN CONFIG FILES ---
echo "[1/9] Restoring clean config templates..."
if [ -d "$BACKUP_DIR" ]; then
    # Always copy fresh .dist files
    cp -f "$BACKUP_DIR"/*.conf.dist "$ETC_DIR/" 2>/dev/null || true
    echo "  ✓ Config templates restored"
fi

# --- 2. GENERATE CONFIG FILES FROM .DIST ---
echo "[2/9] Generating config files..."
for conf in bnetserver worldserver; do
    if [ -f "$ETC_DIR/$conf.conf.dist" ]; then
        cp -f "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"
        echo "  ✓ Created $conf.conf"
    else
        echo "  ✗ WARNING: $conf.conf.dist not found!"
    fi
done

# --- 3. SSL CERTIFICATES ---
echo "[3/9] Checking SSL certificates..."
if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ] || [ ! -f "$ETC_DIR/bnetserver.key.pem" ]; then
    echo "  → Generating new SSL certificates..."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" \
        -keyout "$ETC_DIR/bnetserver.key.pem" \
        -out "$ETC_DIR/bnetserver.cert.pem" \
        2>/dev/null
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"
    chmod 600 "$ETC_DIR/bnetserver.key.pem"
    echo "  ✓ SSL certificates created"
else
    echo "  ✓ SSL certificates already exist"
fi

# --- 4. CONFIG HELPER FUNCTIONS ---
set_config_string() {
    local file=$1
    local key=$2
    local value=$3
    
    if [ ! -f "$file" ]; then
        echo "  ✗ Config file not found: $file"
        return 1
    fi
    
    # Remove existing lines (including commented)
    sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
    # Append new value
    echo "${key} = \"${value}\"" >> "$file"
}

set_config_int() {
    local file=$1
    local key=$2
    local value=$3
    
    if [ ! -f "$file" ]; then
        echo "  ✗ Config file not found: $file"
        return 1
    fi
    
    sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
    echo "${key} = ${value}" >> "$file"
}

# --- 5. CONFIGURE BNETSERVER ---
echo "[4/9] Configuring bnetserver..."

# Database connection
set_config_string "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"

# Network settings
set_config_string "$ETC_DIR/bnetserver.conf" "BindIP" "0.0.0.0"

# SSL configuration (CRITICAL: Correct key names for Master branch!)
set_config_string "$ETC_DIR/bnetserver.conf" "CertificatesFile" "${ETC_DIR}/bnetserver.cert.pem"
set_config_string "$ETC_DIR/bnetserver.conf" "PrivateKeyFile" "${ETC_DIR}/bnetserver.key.pem"

echo "  ✓ Bnetserver configured"

# --- 6. CONFIGURE WORLDSERVER ---
echo "[5/9] Configuring worldserver..."

# Database connections (Master needs 4 databases!)
set_config_string "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"
set_config_string "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};world"
set_config_string "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};characters"
set_config_string "$ETC_DIR/worldserver.conf" "HotfixDatabaseInfo"    "${DB_HOST};3306;${DB_USER};${DB_PASS};hotfixes"

# Data directory
set_config_string "$ETC_DIR/worldserver.conf" "DataDir" "${DATA_DIR}"

# Auto-update settings
set_config_int "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int "$ETC_DIR/worldserver.conf" "Updates.AutoSetup" "1"

echo "  ✓ Worldserver configured"

# --- 7. WAIT FOR DATABASE ---
echo "[6/9] Waiting for database connection..."
MAX_TRIES=30
COUNT=0

while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_TRIES ]; then
        echo "  ✗ Database connection timeout after ${MAX_TRIES} attempts"
        exit 1
    fi
    echo "  → Attempt $COUNT/$MAX_TRIES..."
    sleep 2
done

echo "  ✓ Database is reachable"

# --- 8. DATABASE INITIALIZATION ---
echo "[7/9] Checking database status..."

# Check if auth database exists and has tables
DB_EXISTS=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -sN -e \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'auth';" \
    2>/dev/null || echo "0")

if [ "$DB_EXISTS" = "0" ]; then
    echo "  → Databases not found, creating..."
    
    if [ -f "$SQL_DIR/create/create_mysql.sql" ]; then
        echo "  → Running create_mysql.sql..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" < "$SQL_DIR/create/create_mysql.sql" 2>/dev/null || {
            echo "  ✗ Failed to create databases"
            exit 1
        }
        echo "  ✓ Databases created"
    else
        echo "  ✗ create_mysql.sql not found!"
        exit 1
    fi
    
    # Import base schemas
    echo "  → Importing base schemas..."
    for db_type in auth characters world; do
        SQL_FILE=$(find "$SQL_DIR/base" -name "${db_type}_database.sql" 2>/dev/null | head -1)
        if [ -n "$SQL_FILE" ]; then
            echo "    → Importing ${db_type}..."
            mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$db_type" < "$SQL_FILE" || {
                echo "  ✗ Failed to import ${db_type}"
                exit 1
            }
        fi
    done
    
    # Download and import TDB
    echo "  → Fetching latest TDB from GitHub..."
    API_RESPONSE=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest)
    
    if echo "$API_RESPONSE" | jq -e . >/dev/null 2>&1; then
        # Get TDB for master (NOT 335!)
        LATEST_TDB=$(echo "$API_RESPONSE" | jq -r \
            '.assets[] | select(.name | startswith("TDB_full_world_") and (.name | contains("335") | not)) | .browser_download_url' \
            | head -1)
        
        LATEST_HOTFIX=$(echo "$API_RESPONSE" | jq -r \
            '.assets[] | select(.name | startswith("TDB_full_hotfixes_")) | .browser_download_url' \
            | head -1)
        
        if [ -n "$LATEST_TDB" ] && [ "$LATEST_TDB" != "null" ]; then
            echo "  → Downloading world TDB..."
            curl -L -o /tmp/tdb_world.7z "$LATEST_TDB"
            7z e /tmp/tdb_world.7z -o/tmp/tdb_world -y >/dev/null 2>&1
            
            TDB_SQL=$(find /tmp/tdb_world -name "*.sql" | head -1)
            if [ -n "$TDB_SQL" ]; then
                echo "  → Importing world data..."
                mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" world < "$TDB_SQL"
                echo "  ✓ World TDB imported"
            fi
            rm -rf /tmp/tdb_world.7z /tmp/tdb_world
        fi
        
        if [ -n "$LATEST_HOTFIX" ] && [ "$LATEST_HOTFIX" != "null" ]; then
            echo "  → Downloading hotfixes TDB..."
            curl -L -o /tmp/tdb_hotfix.7z "$LATEST_HOTFIX"
            7z e /tmp/tdb_hotfix.7z -o/tmp/tdb_hotfix -y >/dev/null 2>&1
            
            HOTFIX_SQL=$(find /tmp/tdb_hotfix -name "*.sql" | head -1)
            if [ -n "$HOTFIX_SQL" ]; then
                echo "  → Importing hotfixes data..."
                mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" hotfixes < "$HOTFIX_SQL"
                echo "  ✓ Hotfixes TDB imported"
            fi
            rm -rf /tmp/tdb_hotfix.7z /tmp/tdb_hotfix
        fi
    fi
else
    echo "  ✓ Databases already exist"
fi

# --- 9. REALM CONFIGURATION ---
echo "[8/9] Configuring realm..."

if [ "$1" = "bnetserver" ] || [ "$1" = "auth" ]; then
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    
    # Check if realm exists
    REALM_COUNT=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -sN auth -e \
        "SELECT COUNT(*) FROM realmlist WHERE id = 1;" 2>/dev/null || echo "0")
    
    if [ "$REALM_COUNT" = "0" ]; then
        echo "  → Creating realm entry..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth <<-EOSQL 2>/dev/null || true
            INSERT INTO realmlist 
                (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild)
            VALUES 
                (1, 'Trinity Master Docker', '$REALM_IP', '127.0.0.1', '255.255.255.0', 8085, 0, 0, 1, 0, 0, 57388);
EOSQL
        echo "  ✓ Realm created with IP: $REALM_IP"
    else
        echo "  → Updating realm IP..."
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e \
            "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
        echo "  ✓ Realm updated"
    fi
fi

# --- 10. VERIFY AND START ---
echo "[9/9] Final verification..."

# Verify config
if [ "$1" = "world" ]; then
    echo "  → Checking worldserver config..."
    grep -q "$DB_HOST" "$ETC_DIR/worldserver.conf" && echo "  ✓ Config looks good" || {
        echo "  ✗ Config verification failed!"
        exit 1
    }
fi

echo ""
echo "=========================================="
echo " Starting $1 server..."
echo "=========================================="
echo ""

# Start the appropriate server
if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then
    exec "$BIN_DIR/worldserver"
else
    echo "Unknown server type: $1"
    echo "Usage: $0 [bnetserver|world]"
    exit 1
fi
