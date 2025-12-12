# --- Stage 1: Builder ---
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
# Added: ninja-build (faster compilation), libjemalloc-dev (better memory management)
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
# Optimisations based on linux-build.yml:
# -GNinja: Uses Ninja build system (faster than Make)
# -DUSE_COREPCH=1 & -DUSE_SCRIPTPCH=1: Uses Precompiled Headers (speeds up build significantly)
# -DENABLE_JEMALLOC=1: Uses jemalloc for better memory handling
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
# Using 'ninja install' instead of 'make'
# Cleaning up build directory immediately to save disk space
RUN ninja install \
    && rm -rf /usr/src/TrinityCore/build

# Copy SQL files
RUN cp -r /usr/src/TrinityCore/sql /opt/trinitycore/sql


# --- Stage 2: Runtime ---
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
# Added: libjemalloc2 (runtime for jemalloc), libboost-regex (critical fix)
RUN apt-get update && apt-get install -y \
    libmariadb3 \
    libssl3t64 \
    libboost-system1.83.0 \
    libboost-filesystem1.83.0 \
    libboost-thread1.83.0 \
    libboost-program-options1.83.0 \
    libboost-iostreams1.83.0 \
    libboost-regex1.83.0 \
    libreadline8t64 \
    libncurses6 \
    libjemalloc2 \
    netcat-openbsd iputils-ping \
    mariadb-client curl jq p7zip-full unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/trinitycore

# Copy compiled files
COPY --from=builder /opt/trinitycore /opt/trinitycore

# Backup config files
RUN mkdir -p /opt/trinitycore/etc-backup && \
    cp -r /opt/trinitycore/etc/* /opt/trinitycore/etc-backup/

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# User setup
RUN groupadd -r trinity && useradd -r -g trinity trinity
RUN chown -R trinity:trinity /opt/trinitycore

EXPOSE 3724 8085

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
