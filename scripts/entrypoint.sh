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
echo "[1/7] Restoring clean config templates..."
if [ -d "$BACKUP_DIR" ]; then
    cp -f "$BACKUP_DIR"/*.conf.dist "$ETC_DIR/" 2>/dev/null || true
    echo "  ✓ Config templates restored"
fi

# --- 2. GENERATE CONFIG FILES FROM .DIST ---
echo "[2/7] Generating config files..."
for conf in bnetserver worldserver; do
    if [ -f "$ETC_DIR/$conf.conf.dist" ]; then
        cp -f "$ETC_DIR/$conf.conf.dist" "$ETC_DIR/$conf.conf"
        echo "  ✓ Created $conf.conf"
    else
        echo "  ✗ WARNING: $conf.conf.dist not found!"
    fi
done

# --- 3. SSL CERTIFICATES ---
echo "[3/7] Checking SSL certificates..."
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
    local file=$1; local key=$2; local value=$3
    if [ ! -f "$file" ]; then return 1; fi
    sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
    echo "${key} = \"${value}\"" >> "$file"
}

set_config_int() {
    local file=$1; local key=$2; local value=$3
    if [ ! -f "$file" ]; then return 1; fi
    sed -i "/^\s*#\?\s*${key}\s*=/d" "$file"
    echo "${key} = ${value}" >> "$file"
}

# --- 5. CONFIGURE SERVERS ---
echo "[4/7] Configuring servers..."

# BNETSERVER
set_config_string "$ETC_DIR/bnetserver.conf" "LoginDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"
set_config_string "$ETC_DIR/bnetserver.conf" "BindIP" "0.0.0.0"
set_config_string "$ETC_DIR/bnetserver.conf" "CertificatesFile" "${ETC_DIR}/bnetserver.cert.pem"
set_config_string "$ETC_DIR/bnetserver.conf" "PrivateKeyFile" "${ETC_DIR}/bnetserver.key.pem"

# WORLDSERVER - Database connections
set_config_string "$ETC_DIR/worldserver.conf" "LoginDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};auth"
set_config_string "$ETC_DIR/worldserver.conf" "WorldDatabaseInfo"     "${DB_HOST};3306;${DB_USER};${DB_PASS};world"
set_config_string "$ETC_DIR/worldserver.conf" "CharacterDatabaseInfo" "${DB_HOST};3306;${DB_USER};${DB_PASS};characters"
set_config_string "$ETC_DIR/worldserver.conf" "HotfixDatabaseInfo"    "${DB_HOST};3306;${DB_USER};${DB_PASS};hotfixes"

# WORLDSERVER - Paths and auto-update settings
set_config_string "$ETC_DIR/worldserver.conf" "DataDir" "${DATA_DIR}"
set_config_string "$ETC_DIR/worldserver.conf" "SourceDirectory" "/opt/trinitycore"

# Enable automatic database setup (as per TrinityCore documentation)
set_config_int "$ETC_DIR/worldserver.conf" "Updates.EnableDatabases" "1"
set_config_int "$ETC_DIR/worldserver.conf" "Updates.AutoSetup" "1"

echo "  ✓ Servers configured"

# --- 6. WAIT FOR DATABASE ---
echo "[5/7] Waiting for database connection..."
MAX_TRIES=30
COUNT=0
while ! mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_TRIES ]; then 
        echo "  ✗ Database timeout"
        exit 1
    fi
    sleep 2
done
echo "  ✓ Database is reachable"

# --- 7. PREPARE DATABASE (Following TrinityCore Official Documentation) ---
echo "[6/7] Preparing database..."

# Check if auth database has the account table (sign of completed setup)
TABLE_EXISTS=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -sN -e \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'auth' AND TABLE_NAME = 'account';" \
    2>/dev/null || echo "0")

if [ "$TABLE_EXISTS" = "0" ]; then
    echo "  → First-time setup detected"
    
    # STEP 1: Create users and empty databases using create_mysql.sql
    # (As per TrinityCore docs: "only the file creating users")
    if [ -f "$SQL_DIR/create/create_mysql.sql" ]; then
        echo "  → Running create_mysql.sql (creating users & databases)..."
        
        # Fix: Replace 'localhost' with '%' for Docker compatibility
        sed "s/'trinity'@'localhost'/'trinity'@'%'/g" "$SQL_DIR/create/create_mysql.sql" | \
        mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" 2>&1 | grep -E "(ERROR|Warning)" || true
        
        echo "  ✓ Database structures created"
    else
        echo "  ✗ create_mysql.sql not found!"
        exit 1
    fi
    
    # STEP 2: Download, EXTRACT and COPY TDB SQL files to /bin directory
    # (As per TrinityCore docs: "From the unpacked 7z folder copy the SQL files")
    echo "  → Preparing TDB files..."
    
    # Check if TDB SQL files already exist in /bin
    TDB_WORLD_SQL=$(find "$BIN_DIR" -name "TDB_full_world_*.sql" 2>/dev/null | head -1)
    TDB_HOTFIX_SQL=$(find "$BIN_DIR" -name "TDB_full_hotfixes_*.sql" 2>/dev/null | head -1)
    
    if [ -z "$TDB_WORLD_SQL" ] || [ -z "$TDB_HOTFIX_SQL" ]; then
        echo "  → Downloading and extracting TDB files..."
        
        # Try to fetch from GitHub API
        API_RESPONSE=$(curl -s --max-time 10 https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest 2>/dev/null || echo '{"error": "timeout"}')
        
        if echo "$API_RESPONSE" | jq -e '.assets' >/dev/null 2>&1; then
            # Get World TDB URL
            LATEST_TDB=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | startswith("TDB_full_world_") and (.name | contains("335") | not)) | .browser_download_url' 2>/dev/null | head -1)
            
            # Get Hotfixes TDB URL
            LATEST_HOTFIX=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | startswith("TDB_full_hotfixes_")) | .browser_download_url' 2>/dev/null | head -1)
            
            # Download and extract World TDB
            if [ -n "$LATEST_TDB" ] && [ "$LATEST_TDB" != "null" ]; then
                echo "  → Downloading World TDB..."
                TDB_NAME=$(basename "$LATEST_TDB")
                
                if curl -L --max-time 600 -o "/tmp/${TDB_NAME}" "$LATEST_TDB" 2>/dev/null; then
                    echo "  → Extracting World TDB..."
                    7z e "/tmp/${TDB_NAME}" -o"$BIN_DIR" -y >/dev/null 2>&1
                    rm -f "/tmp/${TDB_NAME}"
                    echo "  ✓ World TDB extracted to ${BIN_DIR}"
                else
                    echo "  ⚠ World TDB download failed"
                fi
            fi
            
            # Download and extract Hotfixes TDB
            if [ -n "$LATEST_HOTFIX" ] && [ "$LATEST_HOTFIX" != "null" ]; then
                echo "  → Downloading Hotfixes TDB..."
                HOTFIX_NAME=$(basename "$LATEST_HOTFIX")
                
                if curl -L --max-time 600 -o "/tmp/${HOTFIX_NAME}" "$LATEST_HOTFIX" 2>/dev/null; then
                    echo "  → Extracting Hotfixes TDB..."
                    7z e "/tmp/${HOTFIX_NAME}" -o"$BIN_DIR" -y >/dev/null 2>&1
                    rm -f "/tmp/${HOTFIX_NAME}"
                    echo "  ✓ Hotfixes TDB extracted to ${BIN_DIR}"
                else
                    echo "  ⚠ Hotfixes TDB download failed"
                fi
            fi
        else
            echo "  ⚠ Could not fetch TDB from GitHub (API rate limit or network issue)"
            echo ""
            echo "  MANUAL SETUP REQUIRED:"
            echo "  1. Download TDB files from: https://github.com/TrinityCore/TrinityCore/releases/latest"
            echo "  2. Look for: TDB_full_world_11XX_*.7z and TDB_full_hotfixes_11XX_*.7z"
            echo "  3. Extract the .7z files"
            echo "  4. Copy the .sql files (NOT the .7z!) to: ${BIN_DIR}/"
            echo "  5. Restart the worldserver container"
            echo ""
        fi
    else
        echo "  ✓ TDB SQL files already exist in ${BIN_DIR}"
    fi
    
    echo "  ✓ Database preparation complete"
    echo ""
    echo "  ==================================================================="
    echo "  IMPORTANT: Worldserver will now start and ask:"
    echo "  'Do you want to create the database? [yes (default) / no]:"
    echo ""
    echo "  The auto-setup is ENABLED (Updates.AutoSetup = 1)"
    echo "  Worldserver will automatically import the TDB SQL files from /bin"
    echo "  ==================================================================="
    echo ""
else
    echo "  ✓ Databases already populated (auth.account exists)"
fi

# --- 8. REALM CONFIGURATION ---
echo "[7/7] Configuring realm..."
if [ "$1" = "bnetserver" ] || [ "$1" = "auth" ]; then
    REALM_IP=${TRINITY_REALM_IP:-"127.0.0.1"}
    
    # Try UPDATE first, then INSERT if needed
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e \
        "UPDATE realmlist SET address = '$REALM_IP' WHERE id = 1;" 2>/dev/null || true
    
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" auth -e \
        "INSERT IGNORE INTO realmlist (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild) 
         VALUES (1, 'Trinity Master Docker', '$REALM_IP', '127.0.0.1', '255.255.255.0', 8085, 0, 0, 1, 0, 0, 57388);" \
        2>/dev/null || true
    
    echo "  ✓ Realm configured (IP: $REALM_IP)"
fi

echo ""
echo "=========================================="
echo " Starting $1 server..."
echo "=========================================="
echo ""

# --- 9. START SERVER ---
if [ "$1" = "auth" ] || [ "$1" = "bnetserver" ]; then
    exec "$BIN_DIR/bnetserver"
elif [ "$1" = "world" ]; then
    exec "$BIN_DIR/worldserver"
else
    echo "Unknown server type: $1"
    echo "Usage: $0 [bnetserver|world]"
    exit 1
fi
