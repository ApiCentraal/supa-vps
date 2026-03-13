#!/bin/bash
# ======================================================
# Supabase Zero-Downtime Blue/Green Update & Rollback
# Single VPS, Multi-App, Studio + NGINX auto-switch
# ======================================================

# CONFIGURATION
WORK_DIR="$HOME/supabase-selfhost"
NGINX_CONF="$WORK_DIR/nginx/conf.d/supabase.conf"
APPS=("app1" "app2")
SERVICES=("auth" "realtime" "storage" "studio")  # services to update
NGINX_CONTAINER="nginx"

# HEALTHCHECK URLS (aanpassen per service)
declare -A HEALTHCHECK_URLS
HEALTHCHECK_URLS["auth"]="http://localhost:9999/health"
HEALTHCHECK_URLS["realtime"]="http://localhost:4000/health"
HEALTHCHECK_URLS["storage"]="http://localhost:5000/health"
HEALTHCHECK_URLS["studio"]="http://localhost:3000/health"

# --- FUNCTIONS ---

switch_nginx_upstream() {
    SERVICE=$1
    ACTIVE=$2  # blue of green
    echo "[INFO] Switching NGINX upstream for $SERVICE to $ACTIVE"
    
    sed -i "s/^\(\s*server ${SERVICE}_\).*/\1$ACTIVE;/g" $NGINX_CONF
    docker exec $NGINX_CONTAINER nginx -s reload
}

healthcheck() {
    URL=$1
    for i in {1..10}; do
        if curl -s --max-time 2 $URL | grep -q "ok"; then
            echo "[INFO] Healthcheck passed for $URL"
            return 0
        fi
        echo "[WARN] Healthcheck failed for $URL, retrying..."
        sleep 3
    done
    return 1
}

update_service() {
    SERVICE=$1
    NEW_TAG=$2
    BLUE_CONTAINER="${SERVICE}_blue"
    GREEN_CONTAINER="${SERVICE}_green"

    echo "[INFO] Pulling new image: supabase/$SERVICE:$NEW_TAG"
    docker pull supabase/$SERVICE:$NEW_TAG

    echo "[INFO] Starting green container..."
    docker run -d --name $GREEN_CONTAINER supabase/$SERVICE:$NEW_TAG

    echo "[INFO] Waiting for healthcheck..."
    if healthcheck "${HEALTHCHECK_URLS[$SERVICE]}"; then
        echo "[INFO] Healthcheck passed, switching NGINX..."
        switch_nginx_upstream $SERVICE "green"
        echo "[INFO] Update complete: $SERVICE -> green"
        echo "[INFO] Old blue container kept for rollback"
    else
        echo "[ERROR] Healthcheck failed, stopping green container..."
        docker stop $GREEN_CONTAINER && docker rm $GREEN_CONTAINER
        echo "[INFO] Rollback: $SERVICE remains on blue"
    fi
}

rollback_service() {
    SERVICE=$1
    echo "[INFO] Rolling back $SERVICE to blue..."
    switch_nginx_upstream $SERVICE "blue"
    GREEN_CONTAINER="${SERVICE}_green"
    docker stop $GREEN_CONTAINER && docker rm $GREEN_CONTAINER
    echo "[INFO] Rollback complete"
}

# --- MAIN SCRIPT ---

COMMAND=$1   # update / rollback
SERVICE=$2   # auth / realtime / storage / studio
NEW_TAG=$3   # nieuwe versie voor update

if [[ "$COMMAND" == "update" ]]; then
    if [[ -z "$SERVICE" || -z "$NEW_TAG" ]]; then
        echo "Usage: $0 update <service> <new_tag>"
        exit 1
    fi
    update_service $SERVICE $NEW_TAG
elif [[ "$COMMAND" == "rollback" ]]; then
    if [[ -z "$SERVICE" ]]; then
        echo "Usage: $0 rollback <service>"
        exit 1
    fi
    rollback_service $SERVICE
else
    echo "Usage: $0 <update|rollback> <service> [new_tag]"
    exit 1
fi
