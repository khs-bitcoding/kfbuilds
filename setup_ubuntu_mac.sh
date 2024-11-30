#!/bin/bash

# Check if .env file exists in the same directory
if [ ! -f .env ]; then
    echo "Error: .env file not found! Please create one in the current directory."
    exit 1
fi

if ! [ -x "$(command -v docker)" ]; then
    echo "This script requires Docker to be installed and running on your system."
    exit 1
fi

if ! docker info > /dev/null 2>&1; then
    echo "Docker appears to be installed but not running. Please start Docker and try again."
    exit 1
fi

if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo "Docker Compose is not installed. Please install Docker Compose to continue."
    exit 1
fi

# Create required files
echo "Creating required files..." 

# Extract docker-compose.yml
cat << 'EOF' > docker-compose.yml
version: '3'

services:
  
  # Backend service (Django + Celery)
  backend:
    image: khsb2002/backend:latest
    container_name: backend
    env_file: .env
    volumes:
      - ${IMPORT_DIR}:/app/shared_data
      - backend_data:/app/backend_data
      - ./static:/app/backend/static
    environment:
      - BLAZEGRAPH_URL=http://blazegraph:8080/bigdata
      - SECRET_KEY="django-insecure-h3z%m^lp@az*sb%-h=r3c0=33cwvqvgy263(8mc@$s%k)3zzlf"
      - WATCH_FOLDER=/app/shared_data
      - DATA_FOLDER=/app/backend_data
    ports:
      - "${BACKEND_PORT:-8000}:${BACKEND_PORT:-8000}" 
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy


  # MySQL database service
  db:
    image: mysql:8.0
    container_name: db
    restart: always
    volumes:
      - ${DB_DIR}:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: "kf2024@HIKE"
      MYSQL_DATABASE: ${DB_DATABASE}
    ports:
      - "3307:3306"
    healthcheck:
      test: ["CMD", "mysqladmin" ,"ping", "-h", "localhost"]
      timeout: 20s
      retries: 10


  # Redis service for Celery
  redis:
    image: redis:alpine
    container_name: redis
    ports:
      - "6380:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5


  # Celery worker for background tasks
  celery:
    image: khsb2002/celery:latest
    env_file: 
      - .env
    environment:
      - SECRET_KEY="django-insecure-h3z%m^lp@az*sb%-h=r3c0=33cwvqvgy263(8mc@$s%k)3zzlf"
    working_dir: /app/backend/
    command: >
      sh -c "celery -A graphdb worker --loglevel=info & celery -A graphdb beat --loglevel=info"
    depends_on:
      - backend
      - redis


  # Blazegraph setup script to initialize the database and create necessary directories and files
  blazegraph-setup:
    image: alpine
    volumes:
      - ${TS_DIR}:/data
    env_file: .env
    command: >
      sh -c "
        mkdir -p /data &&
        if [ -d /data/bigdata.jnl ]; then
          rm -rf /data/bigdata.jnl || true;
        fi &&
        touch /data/bigdata.jnl &&
        chown 100:100 /data/bigdata.jnl
      "


  # Blazegraph service with dynamic environment variables
  blazegraph:
    image: lyrasis/blazegraph:2.1.5
    container_name: blazegraph
    ports:
      - "${TS_PORT:-9999}:8080"
    environment:
      - JAVA_OPTS=-Xms${TS_MIN_MEMORY}g -Xmx${TS_MAX_MEMORY}g -Dfile.encoding=UTF-8 -Dfile.client.encoding=UTF-8 -Dclient.encoding.override=UTF-8
    env_file:
      - .env
    volumes:
      - ${IMPORT_DIR}:/blazegraph/shared_data
      - ${TS_DIR}/bigdata.jnl:/var/lib/jetty/bigdata.jnl
      - ./RWStore.properties:/RWStore.properties
    restart: unless-stopped
    depends_on:
      - blazegraph-setup
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/bigdata"]
      interval: 30s
      timeout: 10s
      retries: 5


  blazegraph-perms:
    image: alpine
    volumes:
      - ${IMPORT_DIR}:/blazegraph/shared_data
    command: >
      sh -c "
        chmod -R 755 /blazegraph/shared_data &&
        chown -R 100:100 /blazegraph/shared_data
      "
    depends_on:
      - blazegraph


  # Nginx for reverse proxy For blazegraph
  nginx:
    image: nginx:alpine
    container_name: nginx
    ports: 
      - "${NGINX_PORT:-8888}:${TS_PORT:-9999}"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf.template
    depends_on:
      - blazegraph
    environment:
      - TS_PORT=${TS_PORT:-9999}
    command: /bin/sh -c "envsubst '$$TS_PORT' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'"
    restart: unless-stopped


  # Frontend service
  web:
    image: khsb2002/web:latest
    environment:
      VITE_API_BASE_URL: ${VITE_API_BASE_URL}
      VITE_API_SPARQL_BASE_URL: ${VITE_API_SPARQL_BASE_URL}
      VITE_WS_API_BASE_URL: ${VITE_WS_API_BASE_URL}
      VITE_SUBDIRNAME: ${VITE_SUBDIRNAME}
    container_name: web
    depends_on:
      - backend


  nginx-build:
    image: khsb2002/nginx-build:latest
    environment:
      VITE_API_BASE_URL: ${VITE_API_BASE_URL}
      VITE_API_SPARQL_BASE_URL: ${VITE_API_SPARQL_BASE_URL}
      VITE_WS_API_BASE_URL: ${VITE_WS_API_BASE_URL}
      VITE_SUBDIRNAME: ${VITE_SUBDIRNAME}
    ports:
      - "3001:80"
    depends_on:
      - web


volumes:
  backend_data:
    driver: local

EOF

# Extract nginx.conf
cat << 'EOF' > nginx.conf
server {
  listen $TS_PORT;

  location /bigdata/ {
    proxy_hide_header Access-Control-Allow-Origin;
    add_header 'Access-Control-Allow-Origin' '*' always;
    proxy_pass http://blazegraph:8080/bigdata/;  # Use the service name instead of localhost
  }
}
EOF

# Extract nginx.conf
cat << 'EOF' > webnginx.conf
server {
    listen 80;
    server_name localhost;
    client_max_body_size 200M;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri /index.html;
    }
    error_page 404 /index.html;
}

EOF

# Extract RWStore.properties
cat << 'EOF' > RWStore.properties
# Note: These options are applied when the journal and the triple store are
# first created.


##
## Journal options.
##


# The backing file. This contains all your data.  You want to put this someplace
# safe.  The default locator will wind up in the directory from which you start
# your servlet container.
com.bigdata.journal.AbstractJournal.file=/var/lib/jetty/bigdata.jnl


# The persistence engine.  Use 'Disk' for the WORM or 'DiskRW' for the RWStore.
com.bigdata.journal.AbstractJournal.bufferMode=DiskRW


# Setup for the RWStore recycler rather than session protection.
com.bigdata.service.AbstractTransactionService.minReleaseAge=1


# Enable group commit. See http://wiki.blazegraph.com/wiki/index.php/GroupCommit
# Note: Group commit is a beta feature in BlazeGraph release 1.5.1.
#com.bigdata.journal.Journal.groupCommit=true


com.bigdata.btree.writeRetentionQueue.capacity=4000
com.bigdata.btree.BTree.branchingFactor=128


# 200M initial extent. max 10G
com.bigdata.journal.AbstractJournal.initialExtent=209715200
com.bigdata.journal.AbstractJournal.maximumExtent=10737418240


##
## Setup for QUADS mode without the full text index.
##
com.bigdata.rdf.sail.truthMaintenance=false
com.bigdata.rdf.store.AbstractTripleStore.quads=true
com.bigdata.rdf.store.AbstractTripleStore.statementIdentifiers=false
com.bigdata.rdf.store.AbstractTripleStore.textIndex=false
com.bigdata.rdf.store.AbstractTripleStore.axiomsClass=com.bigdata.rdf.axioms.NoAxioms


# Bump up the branching factor for the lexicon indices on the default kb.
com.bigdata.namespace.kb.lex.com.bigdata.btree.BTree.branchingFactor=400


# Bump up the branching factor for the statement indices on the default kb.
com.bigdata.namespace.kb.spo.com.bigdata.btree.BTree.branchingFactor=1024


# Uncomment to enable collection of OS level performance counters.  When
# collected they will be self-reported through the /counters servlet and
# the workbench "Performance" tab.
#
# com.bigdata.journal.Journal.collectPlatformStatistics=true/


com.bigdata.rdf.store.AbstractTripleStore.statementIndices=spoc,posc,ospc
# larger statement buffer capacity for bulk loading.
com.bigdata.rdf.sail.bufferCapacity=100000
# Override the #of write cache buffers to improve bulk load performance. Requires enough native heap!
com.bigdata.journal.AbstractJournal.writeCacheBufferCount=1000

# Enable small slot optimization!
com.bigdata.rwstore.RWStore.smallSlotType=1024
# See https://jira.blazegraph.com/browse/BLZG-1385 - reduce LRU cache timeout
com.bigdata.journal.AbstractJournal.historicalIndexCacheCapacity=20
com.bigdata.journal.AbstractJournal.historicalIndexCacheTimeout=5
EOF

echo "Files created successfully!"

# Build and start Docker containers
echo "Building and starting Docker containers..."
$DOCKER_COMPOSE_CMD up --build -d

if [ $? -eq 0 ]; then
    echo "Project is up and running!"
else
    echo "There was an error starting the project."
    exit 1
fi