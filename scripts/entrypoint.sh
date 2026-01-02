#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
# Mount point for local TDB files
LOCAL_TDB_DIR="/opt/trinitycore/bin/custom_tdb" 

SQL_DIR="/opt/trinitycore/sql"
DATA_DIR="/opt/trinitycore/data"

# DB credentials
DB_HOST=${DB_HOST:-"db"}
DB_USER=${DB_USER:-"root"}
DB_PASS=${DB_PASS:-"trinity"}

echo "=========================================="
echo " TrinityCore MASTER Entrypoint"
echo " Mode: $1"
echo "=========================================="

# --- 1. CONFIG & SSL (SHARED) ---
# Restore config backups if available
if [ -d "/opt/trinitycore/etc-backup" ]; then 
    cp -f /opt/trinitycore/etc-backup/*.conf.dist "$ETC_DIR/" 2>/dev/null || true
fi

# Restore dist configs to ensure new settings are available
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

# --- 2. CONFIGURE (SHARED) ---
set_config_string() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = \"${3}\"" >> "$1"; }
set_config_int() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = ${3}" >> "$1"; }

# Apply settings to config files
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

# --- 3. WAIT FOR DB (SHARED) ---
echo "[Shared] Waiting for database..."
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do sleep 2; done


# =================================================================
#  EXCLUSIVE SETUP: ONLY WORLDSERVER DOES THIS
# =================================================================
if [ "$1" = "world" ]; then
    
    echo "[World-Only] Checking installation status..."
    
    # Check if Account table exists to determine if this is a fresh install
    TABLE_EXISTS=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -sN -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'auth' AND TABLE_NAME = 'account';" 2>/dev/null || echo "0")

    # A) FIX PERMISSIONS & CREATE DB STRUCTURE
    # We must ensure the user 'trinity' has access from ANY host (%), not just localhost.
    echo "  -> Enforcing permissions for 'trinity'@'%'..."
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO 'trinity'@'%' IDENTIFIED BY 'trinity' WITH GRANT OPTION; FLUSH PRIVILEGES;" || echo "Warning: Grant failed, check root pass"

    if [ "$TABLE_EXISTS" = "0" ]; then
        echo "  -> First run detected. Creating database structure..."
        if [ -f "$SQL_DIR/create/create_mysql.sql" ]; then
            # We filter out 'CREATE USER' to avoid errors if the user already exists (from the GRANT step above).
            # We also replace 'localhost' with '%' to allow Docker container connections.
            grep -v "CREATE USER" "$SQL_DIR/create/create_mysql.sql" | \
            sed "s/'trinity'@'localhost'/'trinity'@'%'/g" | \
            mysql -f -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" 2>&1 | grep -v "Warning" || true
        fi
    else
        echo "  -> Database structure already exists."
    fi

    # B) COPY TDB FILES
    # Always check for TDB files in the mounted directory and copy them to the binary directory
    echo "  -> Checking for local TDB files in $LOCAL_TDB_DIR..."
    FOUND_SQL=$(find "$LOCAL_TDB_DIR" -name "TDB_full_*.sql" 2>/dev/null)
    
    if [ -n "$FOUND_SQL" ]; then
        # Use cp -n to avoid overwriting existing files, saving startup time
        echo "  -> Copying TDB files to binary directory (if missing)..."
        cp -n $LOCAL_TDB_DIR/TDB_full_*.sql "$BIN_DIR/" || true
        echo "  -> Files ready for AutoSetup."
    else
        echo "  WARN: No TDB files found in $LOCAL_TDB_DIR! Automatic setup might fail."
    fi

    # C) REALM CONFIGURATION
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    echo "  -> Setting Realm IP to $REALM_IP..."
    
    # Update existing realm address or insert if missing
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "INSERT IGNORE INTO realmlist (id, name, address, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild) VALUES (1, 'Trinity Master Docker', '$REALM_IP', 8085, 0, 0, 1, 0, 0, 57388);" 2>/dev/null || true

else
    echo "[Auth-Only] Skipping DB setup tasks (handled by worldserver)."
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
