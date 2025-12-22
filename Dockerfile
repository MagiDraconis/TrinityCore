# --- Stage 1: Builder ---
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
# Matches linux-build.yml logic + Docker specifics
RUN apt-get update && apt-get install -y \
    git clang cmake make gcc g++ \
    libmariadb-dev libssl-dev \
    libbz2-dev libreadline-dev libncurses-dev \
    libboost-all-dev p7zip-full \
    libmariadb-dev-compat gettext curl unzip \
    ninja-build libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src

# Clone TrinityCore (Master Branch)
RUN git clone -b master --depth 1 https://github.com/TrinityCore/TrinityCore.git

WORKDIR /usr/src/TrinityCore/build

# Configure CMake
# Aligned with linux-build.yml settings (Ninja, PCH, Jemalloc)
RUN cmake ../ -DCMAKE_INSTALL_PREFIX=/opt/trinitycore \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -GNinja \
    -DWITH_WARNINGS=0 \
    -DTOOLS=1 \
    -DSCRIPTS=static \
    -DUSE_COREPCH=1 \
    -DUSE_SCRIPTPCH=1 \
    -DENABLE_JEMALLOC=1 \
    -DCMAKE_BUILD_TYPE=Release

# Compile and Install
RUN ninja install \
    && rm -rf /usr/src/TrinityCore/build

# Copy SQL files
RUN cp -r /usr/src/TrinityCore/sql /opt/trinitycore/sql

# --- CRITICAL: Download and extract TDB files (as per TrinityCore docs) ---
# The docs say: "copy the SQL files to the directory where your worldserver binary is"
# We do this during build to avoid runtime GitHub API rate limits
WORKDIR /opt/trinitycore/bin

# Get latest TDB release info and download
# Note: Using a specific release to ensure reproducible builds
RUN curl -L -o /tmp/world.7z \
    "https://github.com/TrinityCore/TrinityCore/releases/download/TDB2413.24121/TDB_full_world_2413.24121_2024_12_21.7z" && \
    curl -L -o /tmp/hotfix.7z \
    "https://github.com/TrinityCore/TrinityCore/releases/download/TDB2413.24121/TDB_full_hotfixes_2413.24121_2024_12_21.7z" && \
    7z e /tmp/world.7z -o/opt/trinitycore/bin -y && \
    7z e /tmp/hotfix.7z -o/opt/trinitycore/bin -y && \
    rm -f /tmp/world.7z /tmp/hotfix.7z


# --- Stage 2: Runtime ---
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
# CRITICAL FIX: Added comprehensive list of Boost runtime libraries to prevent "shared object not found" errors
RUN apt-get update && apt-get install -y \
    libmariadb3 \
    libssl3t64 \
    openssl \
    libboost-system1.83.0 \
    libboost-filesystem1.83.0 \
    libboost-thread1.83.0 \
    libboost-program-options1.83.0 \
    libboost-iostreams1.83.0 \
    libboost-regex1.83.0 \
    libboost-locale1.83.0 \
    libboost-chrono1.83.0 \
    libboost-atomic1.83.0 \
    libboost-date-time1.83.0 \
    libreadline8t64 \
    libncurses6 \
    libjemalloc2 \
    netcat-openbsd iputils-ping \
    mariadb-client curl jq p7zip-full unzip \
    gosu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/trinitycore

# Copy compiled files (including TDB SQL files in /bin)
COPY --from=builder /opt/trinitycore /opt/trinitycore

# Backup config files
RUN mkdir -p /opt/trinitycore/etc-backup && \
    cp -r /opt/trinitycore/etc/* /opt/trinitycore/etc-backup/

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# User setup
RUN groupadd -r trinity && useradd -r -g trinity trinity
RUN chown -R trinity:trinity /opt/trinitycore

# Symlink for DB updater (worldserver expects source at /usr/src/TrinityCore)
RUN mkdir -p /usr/src && ln -s /opt/trinitycore /usr/src/TrinityCore

EXPOSE 3724 8085

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
