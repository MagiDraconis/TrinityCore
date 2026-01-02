#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
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

# --- 1. CONFIG & SSL ---
if [ -d "/opt/trinitycore/etc-backup" ]; then cp -f /opt/trinitycore/etc-backup/*.conf.dist "$ETC_DIR/" 2>/dev/null || true; fi
for conf in bnetserver worldserver; do
    if [ -f "$ETC_DIR/$conf.conf.dist" ]; then cp -f "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"; fi
done

if [ ! -f "$ETC_DIR/bnetserver.cert.pem" ]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=State/L=City/O=TrinityCore/CN=bnetserver" -keyout "$ETC_DIR/bnetserver.key.pem" -out "$ETC_DIR/bnetserver.cert.pem" 2>/dev/null
    chmod 644 "$ETC_DIR/bnetserver.cert.pem"; chmod 600 "$ETC_DIR/bnetserver.key.pem"
fi

# --- 2. CONFIGURE ---
set_config_string() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = \"${3}\"" >> "$1"; }
set_config_int() { sed -i "/^\s*#\?\s*${2}\s*=/d" "$1"; echo "${2} = ${3}" >> "$1"; }

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

# --- 3. WAIT FOR DB ---
echo "[Shared] Waiting for database..."
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do sleep 2; done

# =================================================================
#  EXCLUSIVE SETUP: ONLY WORLDSERVER DOES THIS
# =================================================================
if [ "$1" = "world" ]; then
    
    echo "[World-Only] Checking installation status..."
    
    # 1. FIX PERMISSIONS (Der Hammer Methode)
    # Wir erzwingen die Rechte, egal ob der User schon existiert oder nicht.
    echo "  -> Forcing Permissions Update for 'trinity'@'%'..."
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO 'trinity'@'%' IDENTIFIED BY 'trinity' WITH GRANT OPTION; FLUSH PRIVILEGES;" || echo "Warning: Grant failed, check root pass"

    # 2. CREATE DATABASES (Shells)
    # Wir erstellen die DBs, falls sie fehlen. Fehler (existiert schon) werden ignoriert.
    if [ -f "$SQL_DIR/create/create_mysql.sql" ]; then
        echo "  -> Ensuring DBs exist..."
        # Wir entfernen CREATE USER aus dem Skript, da wir das oben manuell gemacht haben!
        # Das verhindert den Fehlerabbruch.
        grep -v "CREATE USER" "$SQL_DIR/create/create_mysql.sql" | \
        sed "s/'trinity'@'localhost'/'trinity'@'%'/g" | \
        mysql -f -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" 2>&1 | grep -v "Warning" || true
    fi

    # 3. COPY TDB FILES
    echo "  -> Checking for local TDB files in $LOCAL_TDB_DIR..."
    FOUND_SQL=$(find "$LOCAL_TDB_DIR" -name "TDB_full_*.sql" 2>/dev/null)
    
    if [ -n "$FOUND_SQL" ]; then
        echo "  -> Copying TDB files to binary directory..."
        cp -n $LOCAL_TDB_DIR/TDB_full_*.sql "$BIN_DIR/" || true
        echo "  -> Files ready for AutoSetup."
    else
        echo "  WARN: No TDB files found in $LOCAL_TDB_DIR! Server might fail to install."
    fi

    # 4. REALM IP
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e "INSERT IGNORE INTO realmlist (id, name, address, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild) VALUES (1, 'Trinity Master Docker', '$REALM_IP', 8085, 0, 0, 1, 0, 0, 57388);" 2>/dev/null || true

else
    echo "[Auth-Only] Skipping DB setup tasks."
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
