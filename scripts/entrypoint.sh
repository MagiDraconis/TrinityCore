#!/bin/bash
set -e

BIN_DIR="/opt/trinitycore/bin"
ETC_DIR="/opt/trinitycore/etc"
SQL_DIR="/opt/trinitycore/sql"

# DB Zugangsdaten (Standard Docker-Compose Werte)
DB_HOST="db"
DB_USER="root"
DB_PASS="trinity"

echo "Starte TrinityCore Container..."

# --- 1. CONFIG HANDLING (Automatische Anpassung) ---
if [ ! -f "$ETC_DIR/authserver.conf" ]; then
    echo "Authserver Config nicht gefunden. Erstelle sie..."
    cp "$ETC_DIR/authserver.conf.dist" "$ETC_DIR/authserver.conf"
    
    # Datenbankverbindung automatisch auf Docker anpassen
    # Ersetzt 127.0.0.1 mit 'db' und User/Passwort
    sed -i "s|127.0.0.1;3306;trinity;trinity|$DB_HOST;3306;$DB_USER;$DB_PASS|g" "$ETC_DIR/authserver.conf"
fi

if [ ! -f "$ETC_DIR/worldserver.conf" ]; then
    echo "Worldserver Config nicht gefunden. Erstelle sie..."
    cp "$ETC_DIR/worldserver.conf.dist" "$ETC_DIR/worldserver.conf"
    
    # DataDir Pfad anpassen
    sed -i 's|^DataDir = .*|DataDir = "/opt/trinitycore/data"|g' "$ETC_DIR/worldserver.conf"
    
    # Datenbankverbindungen automatisch anpassen
    sed -i "s|127.0.0.1;3306;trinity;trinity|$DB_HOST;3306;$DB_USER;$DB_PASS|g" "$ETC_DIR/worldserver.conf"
fi

# --- 2. WARTE AUF DATENBANK ---
echo "Warte auf Datenbank Verbindung ($DB_HOST:3306)..."
while ! nc -z $DB_HOST 3306; do   
  sleep 1
done
echo "Datenbank ist erreichbar!"

# --- 3. AUTO INSTALL & TDB DOWNLOAD ---
if ! mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -e "USE auth;" 2>/dev/null; then
    echo "WARNUNG: Datenbanken leer. Starte Installation..."

    # Struktur erstellen
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASS < "$SQL_DIR/create/create_mysql.sql"

    # Base SQLs importieren
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASS auth < "$(find $SQL_DIR/base -name 'auth_database.sql')"
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASS characters < "$(find $SQL_DIR/base -name 'characters_database.sql')"
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASS world < "$(find $SQL_DIR/base -name 'world_database.sql')"

    # TDB Download (wie vorher besprochen)
    echo "Suche neueste TDB..."
    LATEST_URL=$(curl -s https://api.github.com/repos/TrinityCore/TrinityCore/releases/latest | jq -r '.assets[] | select(.name | contains("TDB_full_world")) | .browser_download_url')
    
    if [ -n "$LATEST_URL" ]; then
        echo "Download TDB: $LATEST_URL"
        curl -L -o /tmp/tdb.7z "$LATEST_URL"
        7z e /tmp/tdb.7z -o/tmp/tdb_extracted -y
        
        echo "Importiere TDB..."
        mysql -h $DB_HOST -u $DB_USER -p$DB_PASS world < "$(find /tmp/tdb_extracted -name '*.sql' | head -n 1)"
        
        rm -rf /tmp/tdb.7z /tmp/tdb_extracted
        echo "Installation abgeschlossen!"
    fi
fi

# --- 4. REALMLIST IP SETZEN (Optional per ENV) ---
# Das setzt die IP, mit der sich Spieler verbinden müssen
if [ ! -z "$TRINITY_REALM_IP" ] && [ "$1" = "auth" ]; then
    echo "Setze Realmlist IP auf: $TRINITY_REALM_IP"
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASS auth -e "UPDATE realmlist SET address = '$TRINITY_REALM_IP' WHERE id = 1;"
fi

# --- 5. SERVER START ---
if [ "$1" = "auth" ]; then
    echo "Starte authserver..."
    exec "$BIN_DIR/authserver"
elif [ "$1" = "world" ]; then
    echo "Starte worldserver..."
    exec "$BIN_DIR/worldserver"
else
    exec "$@"
fi
