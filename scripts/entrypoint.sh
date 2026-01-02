#!/bin/bash
set -e

# Directories
BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
LOCAL_TDB_DIR="/opt/trinitycore/bin/custom_tdb" 
DATA_DIR="/opt/trinitycore/data"

# Database Configuration
DB_HOST=${DB_HOST:-"db"}

echo "=========================================="
echo " TrinityCore MASTER Entrypoint (Direct)"
echo " Mode: $1"
echo "=========================================="

# --- 1. CONFIGURATION & SSL (SHARED) ---
# Restore backup configs if they exist
if [ -d "/opt/trinitycore/etc-backup" ]; then 
    cp -f /opt/trinitycore/etc-backup/*.conf.dist "$ETC_DIR/" 2>/dev/null || true
fi

# Always restore dist configs to ensure compatibility
for conf in bnetserver worldserver; do
    if [ -f "$ETC_DIR/$conf.conf.dist" ]; then 
        cp -f "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"
    fi
done

# Generate SSL certificates if missing
if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ]; then
    echo "[Shared] Generating SSL certificates..."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" -keyout "$ETC_DIR/bnetserver.key.pem" -out "$ETC_DIR/bnetserver.cert.pem" 2>/dev/null
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"; chmod 600 "$ETC_DIR/bnetserver.key.pem"
fi

# Helper functions for config manipulation
set_config_string() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = \"${3}\"" >> "$1"; }
set_config_int() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = ${3}" >> "$1"; }

# Configure Server Files
echo "[Shared] Updating configuration files..."
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
set_config_int "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int "$ETC_DIR/worldserver.conf" "Updates.AutoSetup" "1"

# --- 2. WAIT FOR DATABASE (SHARED) ---
echo "[Shared] Waiting for database port at $DB_HOST:3306..."
# Using netcat to check the port.
while ! nc -z $DB_HOST 3306; do   
  sleep 3
done
echo "[Shared] Database is reachable."

# --- 3. WORLDSERVER SPECIFIC TASKS ---
if [ "$1" = "world" ]; then
    
    # A) COPY TDB FILES (Mandatory for AutoSetup)
    echo "  -> Checking for local TDB files in $LOCAL_TDB_DIR..."
    FOUND_SQL=$(find "$LOCAL_TDB_DIR" -name "TDB_full_*.sql" 2>/dev/null)
    
    if [ -n "$FOUND_SQL" ]; then
        echo "  -> Copying TDB files to binary directory..."
        cp -n $LOCAL_TDB_DIR/TDB_full_*.sql "$BIN_DIR/" || true
        echo "  -> Files ready for AutoSetup."
    else
        echo "  WARN: No TDB files found in $LOCAL_TDB_DIR!"
    fi

    # B) REALM CONFIGURATION
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    echo "  -> Setting Realm IP to $REALM_IP..."
    
    # Try to set the realm IP. 
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "INSERT IGNORE INTO realmlist (id, name, address, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild) VALUES (1, 'Trinity Master Docker', '$REALM_IP', 8085, 0, 0, 1, 0, 0, 57388);" 2>/dev/null || true
fi

# --- START SERVER ---
echo "Starting $1 process..."
if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then 
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then 
    exec "$BIN_DIR/worldserver"
else 
    exec "$@"
fi
