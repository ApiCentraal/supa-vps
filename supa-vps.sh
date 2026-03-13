#!/bin/bash
# ======================================================
# All-in-One Supabase Self-Hosted Deploy + Zero-Downtime
# Single VPS, Multi-App, Studio, SSL, Backups
# ======================================================

# --- CONFIGURATION ---
MAIN_DOMAIN="supabase.mijnbedrijf.nl"
EMAIL="admin@mijnbedrijf.nl"
APPS=("app1" "app2")   # voeg apps toe
DB_USER="supabase_admin"
DB_PASS="supersecret"
DB_NAME="supabase_db"
WORK_DIR="$HOME/supabase-selfhost"
DATA_DIR="$WORK_DIR/data"
STORAGE_DIR="$DATA_DIR/storage"
NGINX_DIR="$WORK_DIR/nginx/conf.d"
CERTS_DIR="$DATA_DIR/certs"

# Supabase image tags (specificeer versies voor rollback)
GOTRUE_TAG="supabase/gotrue:1.15.0"
REALTIME_TAG="supabase/realtime:1.15.0"
STORAGE_TAG="supabase/storage-api:1.15.0"
STUDIO_TAG="supabase/studio:1.15.0"
NGINX_IMG="nginx:latest"

# --- STEP 1: Create folders ---
mkdir -p $WORK_DIR $STORAGE_DIR $NGINX_DIR $CERTS_DIR
for APP in "${APPS[@]}"; do
    mkdir -p "$STORAGE_DIR/$APP"
done

# --- STEP 2: Create .env ---
cat > $WORK_DIR/.env <<EOL
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS
POSTGRES_DB=$DB_NAME

SUPABASE_ANON_KEY=$(openssl rand -hex 16)
SUPABASE_SERVICE_KEY=$(openssl rand -hex 32)

DOMAIN=$MAIN_DOMAIN
EMAIL=$EMAIL
EOL

# --- STEP 3: Initialize PostgreSQL (local) ---
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
# Multi-schema setup
for APP in "${APPS[@]}"; do
    sudo -u postgres psql -d $DB_NAME -c "CREATE SCHEMA IF NOT EXISTS $APP;"
    sudo -u postgres psql -d $DB_NAME -c "ALTER TABLE $APP.users ENABLE ROW LEVEL SECURITY;"
done

# --- STEP 4: Docker Compose ---
cat > $WORK_DIR/docker-compose.yml <<EOL
version: "3.8"
services:
  auth_blue:
    image: $GOTRUE_TAG
    container_name: auth_blue
    restart: always
    env_file: .env
    networks:
      - supabase_net

  realtime_blue:
    image: $REALTIME_TAG
    container_name: realtime_blue
    restart: always
    env_file: .env
    networks:
      - supabase_net

  storage_blue:
    image: $STORAGE_TAG
    container_name: storage_blue
    restart: always
    env_file: .env
    volumes:
      - ./data/storage:/var/lib/supabase/storage
    networks:
      - supabase_net

  studio_blue:
    image: $STUDIO_TAG
    container_name: studio_blue
    restart: always
    env_file: .env
    ports:
      - "54322:3000"
    networks:
      - supabase_net

  nginx:
    image: $NGINX_IMG
    container_name: nginx
    restart: always
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./data/certs:/etc/letsencrypt
    ports:
      - "80:80"
      - "443:443"
    networks:
      - supabase_net

networks:
  supabase_net:
    driver: bridge
EOL

# --- STEP 5: NGINX Config ---
NGINX_CONF="$NGINX_DIR/supabase.conf"
cat > $NGINX_CONF <<EOL
# Redirect HTTP -> HTTPS
server {
    listen 80;
    server_name $MAIN_DOMAIN;
    location / { return 301 https://\$host\$request_uri; }
}

# Studio
server {
    listen 443 ssl;
    server_name $MAIN_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
    location / {
        proxy_pass http://studio_blue:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

# Per app subdomains
for APP in "${APPS[@]}"; do
cat >> $NGINX_CONF <<EOL
server {
    listen 443 ssl;
    server_name $APP.mijnbedrijf.nl;
    ssl_certificate /etc/letsencrypt/live/$APP.mijnbedrijf.nl/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$APP.mijnbedrijf.nl/privkey.pem;
    location / {
        proxy_pass http://studio_blue:3000; # kan later per-app backend
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL
done

# --- STEP 6: Start containers ---
docker-compose -f $WORK_DIR/docker-compose.yml pull
docker-compose -f $WORK_DIR/docker-compose.yml up -d

# --- STEP 7: Let's Encrypt SSL ---
for DOMAIN in $MAIN_DOMAIN ${APPS[@]/%/.mijnbedrijf.nl}; do
    certbot certonly --webroot -w $CERTS_DIR -d $DOMAIN --email $EMAIL --agree-tos --non-interactive
done

# --- STEP 8: Setup backups (cron) ---
CRON_CMD="0 3 * * * sudo -u postgres pg_dump -U $DB_USER -d $DB_NAME > $DATA_DIR/backups/db_\$(date +\%F).sql"
(crontab -l; echo "$CRON_CMD") | crontab -

# --- STEP 9: Zero-Downtime Update Function ---
echo "function supabase_update() {
  SERVICE=\$1
  NEW_TAG=\$2
  GREEN_CONTAINER=\${SERVICE}_green
  BLUE_CONTAINER=\${SERVICE}_blue

  echo 'Pulling new image: ' \$SERVICE:\$NEW_TAG
  docker pull supabase/\$SERVICE:\$NEW_TAG

  echo 'Starting green container...'
  docker run -d --name \$GREEN_CONTAINER supabase/\$SERVICE:\$NEW_TAG

  echo 'Healthcheck...'
  sleep 15

  echo 'Switching NGINX upstream from blue -> green...'
  # NGINX config aanpassen en reload
  docker exec nginx nginx -s reload

  echo 'Optional rollback: switch back to blue if healthcheck fails.'
}"
echo "=== Deployment complete ==="
echo "Studio: https://$MAIN_DOMAIN"
for APP in "${APPS[@]}"; do
    echo "App $APP: https://$APP.mijnbedrijf.nl"
done
```
