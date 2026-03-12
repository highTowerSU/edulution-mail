#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${GREEN}==>${NC} $1"
}

# Wait for MySQL with timeout
wait_for_mysql() {
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if mysql -h mysql -u $DBUSER -p$DBPASS $DBNAME -e "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for MySQL... ($attempt/$max_attempts)"
        sleep 2
    done
    
    log_error "MySQL not available after $max_attempts attempts"
    return 1
}

# Set Mailcow API Token
set_mailcow_token() {
    log_step "Setting up Mailcow API token"
    
    if [ ! -f ${MAILCOW_PATH}/data/mailcow-token.conf ]; then
        if [ -z ${MAILCOW_API_TOKEN} ]; then
            log_info "Generating new API token"
            MAILCOW_API_TOKEN=$(openssl rand -hex 15 | awk '{printf "%s-%s-%s-%s-%s\n", substr($0,1,6), substr($0,7,6), substr($0,13,6), substr($0,19,6), substr($0,25,6)}')
        fi
        echo "MAILCOW_API_TOKEN=${MAILCOW_API_TOKEN}" > ${MAILCOW_PATH}/data/mailcow-token.conf
        source ${MAILCOW_PATH}/mailcow/.env
        
        # Wait for MySQL and api table
        # log_info "Waiting for MySQL and api table"
        # local attempt=0
        # while ! mysql -h mysql -u $DBUSER -p$DBPASS $DBNAME -e "DESCRIBE api" >/dev/null 2>&1; do
        #     attempt=$((attempt + 1))
        #     if [ $attempt -gt 60 ]; then
        #         log_error "MySQL api table not available after 60 attempts"
        #         break
        #     fi
        #     sleep 5
        # done

        # Wait for MySQL
        if ! wait_for_mysql; then
            log_error "Cannot read/create API token - MySQL unavailable"
            return 1
        fi
        
        # Insert API token
        if mysql -h mysql -u $DBUSER -p$DBPASS $DBNAME -e "INSERT INTO api (api_key, allow_from, skip_ip_check, created, access, active) VALUES ('${MAILCOW_API_TOKEN}', '172.16.0.0/12', '0', NOW(), 'rw', '1')" 2>/dev/null; then
            log_success "API token inserted into database"
        else
            if mysql -h mysql -u $DBUSER -p$DBPASS $DBNAME -e "SELECT api_key FROM api WHERE api_key='${MAILCOW_API_TOKEN}'" | grep -q "${MAILCOW_API_TOKEN}"; then
                log_info "API token already exists in database"
            else
                log_error "Failed to insert API token into database"
            fi
        fi
    else
        source ${MAILCOW_PATH}/data/mailcow-token.conf
        log_info "Using existing API token"
    fi
    
    export MAILCOW_API_TOKEN
}

# Create edulution_gal view
create_edulution_view() {
    log_step "Creating edulution GAL database view"
    source ${MAILCOW_PATH}/mailcow/.env
    
    # Wait for MySQL
    if ! wait_for_mysql; then
        log_error "Cannot create view - MySQL unavailable"
        return 1
    fi
    
    log_info "Creating edulution_gal view"
    
    mysql -h mysql -u $DBUSER -p$DBPASS $DBNAME <<'EOSQL'
CREATE OR REPLACE VIEW edulution_gal AS

-- Mailboxen (nur Hauptadresse in mail)
SELECT
    m.username                        AS c_uid,
    m.domain                          AS domain,
    m.username                        AS c_name,
    m.password                        AS c_password,
    m.name                            AS c_cn,
    NULL                              AS c_l,
    NULL                              AS c_o,
    NULL                              AS c_ou,
    NULL                              AS c_telephonenumber,
    m.username                        AS mail,
    (
      SELECT GROUP_CONCAT(a.address ORDER BY a.address SEPARATOR ' ')
      FROM alias a
      WHERE a.active=1
        AND a.sogo_visible=1
        AND a.goto = m.username
        AND a.address <> m.username
    )                                 AS aliases,
    ''                                AS ad_aliases,
    ''                                AS ext_acl,
    m.kind                            AS kind,
    m.multiple_bookings               AS multiple_bookings,
    NULL                              AS isGroup,
    NULL                              AS groupMembers
FROM mailbox m
WHERE m.active=1

UNION ALL

-- Aliase (sichtbar, keine Verteiler)
SELECT
    a.address                         AS c_uid,
    a.domain                          AS domain,
    a.address                         AS c_name,
    ''                                AS c_password,
    a.address                         AS c_cn,
    NULL                              AS c_l,
    NULL                              AS c_o,
    NULL                              AS c_ou,
    NULL                              AS c_telephonenumber,
    a.address                         AS mail,
    NULL                              AS aliases,
    ''                                AS ad_aliases,
    ''                                AS ext_acl,
    ''                                AS kind,
    -1                                AS multiple_bookings,
    NULL                              AS isGroup,
    NULL                              AS groupMembers
FROM alias a
LEFT JOIN mailbox m ON a.goto = m.username
WHERE a.active=1
  AND a.sogo_visible=1
  AND (m.username IS NULL OR a.goto <> m.username)

UNION ALL

-- Verteiler als Gruppen (LDAP group expansion)
SELECT
    a.address                         AS c_uid,
    a.domain                          AS domain,
    a.address                         AS c_name,
    ''                                AS c_password,
    COALESCE(
        NULLIF(a.public_comment, ''),
        CONCAT(
            a.address,
            ' (Verteiler, ',
            LENGTH(a.goto) - LENGTH(REPLACE(a.goto, ',', '')) + 1,
            ' Empfaenger)'
        )
    )                                 AS c_cn,
    NULL                              AS c_l,
    NULL                              AS c_o,
    NULL                              AS c_ou,
    NULL                              AS c_telephonenumber,
    a.address                         AS mail,
    NULL                              AS aliases,
    ''                                AS ad_aliases,
    ''                                AS ext_acl,
    ''                                AS kind,
    -1                                AS multiple_bookings,
    1                                 AS isGroup,
    REPLACE(a.goto, ',', ' ')         AS groupMembers
FROM alias a
WHERE a.active=1
  AND a.sogo_visible=0;
EOSQL
    
    if [ $? -eq 0 ]; then
        log_success "edulution_gal view created"
    else
        log_warning "Failed to create edulution_gal view (may already exist)"
    fi
}

# Load override configuration if available
load_override_config() {
    local OVERRIDE_FILE="${MAILCOW_PATH}/mail.override.config"

    if [ -f "$OVERRIDE_FILE" ]; then
        log_info "Loading configuration from override file"

        # Read SOGO_GROUP_DISPLAY_FIELD from override file if present
        if command -v jq >/dev/null 2>&1; then
            # Use jq if available (preferred method)
            local OVERRIDE_FIELD=$(jq -r '.SOGO_GROUP_DISPLAY_FIELD // empty' "$OVERRIDE_FILE" 2>/dev/null)
            if [ -n "$OVERRIDE_FIELD" ]; then
                export SOGO_GROUP_DISPLAY_FIELD="$OVERRIDE_FIELD"
                log_info "Override: SOGO_GROUP_DISPLAY_FIELD = $OVERRIDE_FIELD"
            fi
        else
            # Fallback: use grep/sed if jq is not available
            local OVERRIDE_FIELD=$(grep -o '"SOGO_GROUP_DISPLAY_FIELD"[[:space:]]*:[[:space:]]*"[^"]*"' "$OVERRIDE_FILE" 2>/dev/null | sed 's/.*"SOGO_GROUP_DISPLAY_FIELD"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            if [ -n "$OVERRIDE_FIELD" ]; then
                export SOGO_GROUP_DISPLAY_FIELD="$OVERRIDE_FIELD"
                log_info "Override: SOGO_GROUP_DISPLAY_FIELD = $OVERRIDE_FIELD"
            fi
        fi
    fi
}

# Configure SOGo GAL
configure_sogo_gal() {
    log_step "Configuring SOGo Global Address List"
    source ${MAILCOW_PATH}/mailcow/.env

    # Load override configuration
    load_override_config

    SOGO_CONF="${MAILCOW_PATH}/mailcow/data/conf/sogo/sogo.conf"
    
    # Wait for sogo.conf
    local attempt=0
    while [ ! -f "$SOGO_CONF" ]; do
        attempt=$((attempt + 1))
        if [ $attempt -gt 60 ]; then
            log_error "sogo.conf not found after 60 attempts"
            return 1
        fi
        log_info "Waiting for sogo.conf... ($attempt/60)"
        sleep 5
    done
    
    # Determine which field to use for group display names (default: displayName)
    # Set SOGO_GROUP_DISPLAY_FIELD=cn to use technical names instead of descriptions
    GROUP_CN_FIELD="${SOGO_GROUP_DISPLAY_FIELD:-displayName}"

    # Check if LDAP config already exists (new version)
    if grep -q "ldap://edulution:3890" "$SOGO_CONF" 2>/dev/null; then
        # Check current CNFieldName setting in config
        CURRENT_CN_FIELD=$(grep -A 10 'id = "groups"' "$SOGO_CONF" | grep "CNFieldName" | sed -n 's/.*CNFieldName = \([^;]*\);.*/\1/p' | tr -d ' ')

        # Update if different from desired setting
        if [ "$CURRENT_CN_FIELD" != "$GROUP_CN_FIELD" ]; then
            log_warning "Updating groups CNFieldName from '$CURRENT_CN_FIELD' to '$GROUP_CN_FIELD'"
            cp "$SOGO_CONF" "${SOGO_CONF}.bak.cnfield.$(date +%Y%m%d%H%M%S)"

            # Update CNFieldName to desired value
            sed -i "/id = \"groups\"/,/GroupObjectClasses/ {
                s/CNFieldName = [^;]*;/CNFieldName = ${GROUP_CN_FIELD};/
            }" "$SOGO_CONF"

            # Ensure SearchFieldNames exists (add if missing)
            if ! grep -A 10 'id = "groups"' "$SOGO_CONF" | grep -q "SearchFieldNames"; then
                sed -i "/id = \"groups\"/,/GroupObjectClasses/ {
                    /UIDFieldName = cn;/a\      SearchFieldNames = (displayName, cn, mail);
                }" "$SOGO_CONF"
            fi

            log_success "Updated CNFieldName to '$GROUP_CN_FIELD'"

            # Restart SOGo to apply changes
            if docker ps --format "{{.Names}}" | grep -q "sogo-mailcow"; then
                log_info "Restarting SOGo to apply configuration changes"
                docker restart mailcowdockerized-sogo-mailcow-1 2>/dev/null || true
            fi
        else
            log_info "LDAP GAL already configured with CNFieldName='$GROUP_CN_FIELD'"
        fi

        # Ensure SOGoLDAPGroupExpansionEnabled is set (may be missing on older installations)
        if ! grep -q "SOGoLDAPGroupExpansionEnabled" "$SOGO_CONF" 2>/dev/null; then
            log_warning "SOGoLDAPGroupExpansionEnabled missing - adding it now"
            cp "$SOGO_CONF" "${SOGO_CONF}.bak.groupexp.$(date +%Y%m%d%H%M%S)"

            # Add SOGoLDAPGroupExpansionEnabled after the closing of SOGoUserSources
            sed -i '/^  );$/a\
\
  SOGoLDAPGroupExpansionEnabled = YES;' "$SOGO_CONF"

            log_success "Added SOGoLDAPGroupExpansionEnabled = YES"

            # Restart SOGo to apply changes
            if docker ps --format "{{.Names}}" | grep -q "sogo-mailcow"; then
                log_info "Restarting SOGo to apply configuration changes"
                docker restart mailcowdockerized-sogo-mailcow-1 2>/dev/null || true
            fi
        fi

        return 0
    fi

    # Check if old SQL config exists and needs migration
    if grep -q "id = \"edulution\"" "$SOGO_CONF" 2>/dev/null && grep -q "type = sql" "$SOGO_CONF" 2>/dev/null; then
        log_warning "Migrating from SQL GAL to LDAP GAL"
        # Remove old SQL config
        cp "$SOGO_CONF" "${SOGO_CONF}.bak.sql.$(date +%Y%m%d%H%M%S)"
        sed -i '/SOGoUserSources = (/,/^  );/d' "$SOGO_CONF"
    fi

    log_info "Adding LDAP GAL configuration for group expansion"
    log_info "Using '${GROUP_CN_FIELD}' for group display names"

    # Create LDAP-based GAL configuration
    GAL_CONFIG="  SOGoUserSources = (
    {
      type = ldap;
      id = \"users\";
      CNFieldName = cn;
      IDFieldName = uid;
      UIDFieldName = uid;
      IMAPHostFieldName = \"\";
      SearchFieldNames = (cn, sn, displayName, mail, telephoneNumber);
      MailFieldNames = (\"mail\");
      baseDN = \"ou=users,dc=schule,dc=lan\";
      bindDN = \"\";
      bindPassword = \"\";
      canAuthenticate = NO;
      displayName = \"Benutzer\";
      hostname = \"ldap://edulution:3890\";
      isAddressBook = YES;
      listRequiresDot = NO;
    },
    {
      type = ldap;
      id = \"groups\";
      CNFieldName = ${GROUP_CN_FIELD};
      IDFieldName = cn;
      UIDFieldName = cn;
      MailFieldNames = (\"mail\", \"rfc822MailMember\");
      SearchFieldNames = (displayName, cn, mail);
      baseDN = \"ou=groups,dc=schule,dc=lan\";
      bindDN = \"\";
      bindPassword = \"\";
      canAuthenticate = YES;
      displayName = \"Gruppen\";
      hostname = \"ldap://edulution:3890\";
      lookupFields = (\"*\", \"uniqueMember\");
      isAddressBook = YES;
      GroupObjectClasses = (\"groupOfUniqueNames\");
    }
  );

  SOGoLDAPGroupExpansionEnabled = YES;"

    # Backup and modify configuration
    cp "$SOGO_CONF" "${SOGO_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    
    # Insert configuration before last closing brace
    awk -v config="$GAL_CONFIG" '
        /^}$/ && !done {
            print config
            print ""
            done=1
        }
        {print}
    ' "$SOGO_CONF" > "${SOGO_CONF}.tmp"
    
    if [ $? -eq 0 ]; then
        mv "${SOGO_CONF}.tmp" "$SOGO_CONF"
        log_success "GAL configuration added"

        # Restart SOGo if it's already running
        if docker ps --format "{{.Names}}" | grep -q "sogo-mailcow"; then
            log_info "Restarting SOGo container to apply configuration"
            docker restart mailcowdockerized-sogo-mailcow-1 2>/dev/null || true
        else
            log_info "SOGo container not running yet - will be started later"
        fi
    else
        log_error "Failed to add GAL configuration"
        rm -f "${SOGO_CONF}.tmp"
        return 1
    fi
}

# Start LDAP server
start_ldap_server() {
    log_step "Starting LDAP-to-SQL bridge for SOGo group expansion"

    source /app/venv/bin/activate

    # Export DB credentials for ldap-server.py
    export DBUSER=$DBUSER
    export DBPASS=$DBPASS
    export DBNAME=$DBNAME
    export LDAP_DEBUG=${LDAP_DEBUG:-true}  # Enable debug by default for testing

    log_info "Starting LDAP server on port 3890 (Debug: $LDAP_DEBUG)"
    log_info "DB Config: host=mysql, user=$DBUSER, database=$DBNAME"
    python /app/ldap-server.py >> /app/ldap-server.log 2>&1 &
    LDAP_PID=$!

    # Wait for LDAP server to be ready
    sleep 2

    if kill -0 $LDAP_PID 2>/dev/null; then
        log_success "LDAP server started (PID: $LDAP_PID)"
        log_info "LDAP server log: /app/ldap-server.log"
    else
        log_error "LDAP server failed to start"
        log_error "Check log: docker exec edulution-mail cat /app/ldap-server.log"
    fi
}

# Start API and sync services
start_services() {
    log_step "Starting API and sync services"

    source /app/venv/bin/activate

    log_info "Starting API service"
    python /app/api.py 2>&1 >> /app/log.log &

    sleep 5

    log_info "Starting sync service"
    python /app/sync.py
}

# Initialize Mailcow
init_mailcow() {
    log_step "Initializing Mailcow instance"
    
    mkdir -p ${MAILCOW_PATH}/mailcow/data
    
    if [ ! -f ${MAILCOW_PATH}/mailcow/docker-compose.yml ]; then
        log_info "Copying Mailcow files"
        cp -r /opt/mailcow/. ${MAILCOW_PATH}/mailcow/
    fi
    
    cd ${MAILCOW_PATH}/mailcow
    
    # Generate config if needed
    export MAILCOW_TZ=${MAILCOW_TZ:-Europe/Berlin}
    export MAILCOW_BRANCH=${MAILCOW_BRANCH:-legacy}
    
    if [ ! -f ${MAILCOW_PATH}/data/mailcow.conf ]; then
        log_info "Generating Mailcow configuration"
        source ./generate_config.sh
        rm -f generate_config.sh
        mkdir -p ${MAILCOW_PATH}/data
        mv mailcow.conf ${MAILCOW_PATH}/data/
    fi
    
    # Create symlinks
    rm -rf ${MAILCOW_PATH}/mailcow/.env
    ln -s ${MAILCOW_PATH}/data/mailcow.conf ${MAILCOW_PATH}/mailcow/.env
    ln -s ${MAILCOW_PATH}/data/mailcow.conf ${MAILCOW_PATH}/mailcow/mailcow.conf
    
    mkdir -p ${MAILCOW_PATH}/data/mail
    
    log_success "Mailcow initialized"
}

# Extract @tag (e.g. theme/version) from the first /* ... */ block near the top.
get_css_tag() {
  local file="$1" tag="$2"
  [ -f "$file" ] || return 1

  tag=${tag#@}
  tag=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')

  sed -n '1,500p' "$file" \
    | tr -d '\r' \
    | sed -n '/\/\*/,/\*\//p' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -n "s/.*@${tag}[[:space:]]*:*[[:space:]]*\([^[:space:]*][^[:space:]*]*\).*/\1/p" \
    | head -n1
}

debug_css_header() {
  local file="$1"
  local t v
  t="$(get_css_tag "$file" "theme"    || echo "")"
  v="$(get_css_tag "$file" "version"  || echo "")"
  log_info "Parsed header from $(basename "$file"): theme='${t:-<none>}' version='${v:-<none>}'"
}

# Compare two semver strings A vs B.
# Returns 0 if A > B (greater), 1 otherwise.
semver_gt() {
  # Normalize: missing -> 0.0.0
  local A="${1:-0.0.0}" B="${2:-0.0.0}"
  IFS='.' read -r a1 a2 a3 <<<"$A"
  IFS='.' read -r b1 b2 b3 <<<"$B"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  # numeric compare
  ((a1 > b1)) && return 0
  ((a1 < b1)) && return 1
  ((a2 > b2)) && return 0
  ((a2 < b2)) && return 1
  ((a3 > b3)) && return 0
  ((a3 < b3)) && return 1
  return 1
}

# Equality helper (A == B)
semver_eq() {
  local A="${1:-0.0.0}" B="${2:-0.0.0}"
  IFS='.' read -r a1 a2 a3 <<<"$A"
  IFS='.' read -r b1 b2 b3 <<<"$B"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  [[ "$a1" = "$b1" && "$a2" = "$b2" && "$a3" = "$b3" ]]
}

# Copy if source is newer than current (by semver); if current missing, copy.
install_css_if_newer() {
  local src="$1" dst="$2" label="$3"

  local src_theme src_ver cur_theme cur_ver
  src_theme="$(get_css_tag "$src" "theme"   || true)"
  src_ver="$(get_css_tag "$src" "version"   || true)"

  if [ -f "$dst" ]; then
    cur_theme="$(get_css_tag "$dst" "theme"   || true)"
    cur_ver="$(get_css_tag "$dst" "version"   || true)"
  fi

  # Normalize defaults for decision making
  cur_theme="${cur_theme:-edulution-dark}"
  cur_ver="${cur_ver:-0.0.0}"

  log_info "Installed theme: ${cur_theme} v${cur_ver} | Candidate ($label): ${src_theme:-<none>} v${src_ver:-<none>}"

  # Only update if SAME theme AND source version is greater
  if [[ "$src_theme" = "$cur_theme" ]] && semver_gt "$src_ver" "$cur_ver"; then
    cp -f "$src" "$dst"
    log_success "Updated ${label} theme to v${src_ver}"
    return 0
  fi

  # If destination missing entirely, install src
  if [ ! -f "$dst" ]; then
    cp -f "$src" "$dst"
    log_success "Installed ${label} theme v${src_ver}"
    return 0
  fi

  log_info "Keeping existing ${cur_theme} v${cur_ver} (no newer $label available)"
  return 1
}


# Ensure SOGo theme files exist (respect existing theme + version)
ensure_sogo_files() {
  log_info "Ensuring SOGo theme files (no unwanted overwrites)"

  local sogo_dir="${MAILCOW_PATH}/mailcow/data/conf/sogo"
  local target_css="${sogo_dir}/custom-theme.css"
  local dark_src="/templates/sogo/custom-theme.css"      # dark in the image
  local light_src="/templates/sogo/light-theme.css"      # light in the image
  local svg_src="/templates/sogo/sogo-full.svg"
  local target_svg="${sogo_dir}/sogo-full.svg"

  mkdir -p "$sogo_dir"

  # Remove directories if someone mis-mounted a dir with the same name
  [ -d "$target_css" ] && rm -rf "$target_css"
  [ -d "$target_svg" ] && rm -rf "$target_svg"

  # Detect currently installed theme (if any). Default to dark when absent or tag missing.
  local current_theme="" current_ver=""
  if [ -f "$target_css" ]; then
    current_theme="$(get_css_tag "$target_css" "theme"    || true)"
    current_ver="$(get_css_tag "$target_css" "version"    || true)"
    debug_css_header "$target_css"
  fi

  # Decide which source to consider based on the *actual* installed theme.
  local chosen_src chosen_label
  if [[ "$current_theme" =~ edulution-light ]]; then
    chosen_src="$light_src"; chosen_label="light"
  elif [[ "$current_theme" =~ edulution-dark ]]; then
    chosen_src="$dark_src";  chosen_label="dark"
  else
    # No file or no tag: default to light (policy), but log it
    log_warning "No recognizable @theme in installed CSS; defaulting to light"
    chosen_src="$light_src"; chosen_label="light"
  fi

  if [ ! -f "$chosen_src" ]; then
    log_warning "Chosen theme source ($chosen_label) missing; falling back to light source"
    chosen_src="$light_src"; chosen_label="light"
  fi

  # Try to update the matching theme **only if the same theme** and src version is greater
  install_css_if_newer "$chosen_src" "$target_css" "$chosen_label" || true

  # First install on empty systems (no target file at all)
  if [ ! -f "$target_css" ]; then
    log_info "No custom-theme.css present; installing default light"
    cp -f "$light_src" "$target_css"
    debug_css_header "$target_css"
  fi


  # Always ensure the SVG is present (copy if missing or different)
  if [ ! -f "$target_svg" ]; then
    cp -f "$svg_src" "$target_svg"
  fi

  # Verify files
  if [ ! -f "$target_css" ]; then
    log_error "custom-theme.css is not a file!"
    exit 1
  fi
  if [ ! -f "$target_svg" ]; then
    log_error "sogo-full.svg is not a file!"
    exit 1
  fi

  log_success "SOGo theme files ready (respected active theme + version)"
}

# Apply template files
apply_templates() {
    log_step "Applying template files"
    
    # Dovecot templates
    log_info "Copying Dovecot authentication templates"
    mkdir -p ${MAILCOW_PATH}/mailcow/data/conf/dovecot/lua/
    cp /templates/dovecot/edulution-sso.lua ${MAILCOW_PATH}/mailcow/data/conf/dovecot/lua/edulution-sso.lua
    cp /templates/dovecot/extra.conf ${MAILCOW_PATH}/mailcow/data/conf/dovecot/extra.conf
    chown root:401 ${MAILCOW_PATH}/mailcow/data/conf/dovecot/lua/edulution-sso.lua
    
    # Web templates
    log_info "Copying web authentication templates"
    mkdir -p ${MAILCOW_PATH}/mailcow/data/web/inc/
    cp /templates/web/functions.inc.php ${MAILCOW_PATH}/mailcow/data/web/inc/functions.inc.php
    cp /templates/web/sogo-auth.php ${MAILCOW_PATH}/mailcow/data/web/sogo-auth.php
    
    # SOGo files
    ensure_sogo_files
    
    # Docker override
    log_info "Creating Docker Compose override"
    cat <<EOF > ${MAILCOW_PATH}/mailcow/docker-compose.override.yml
services:
  nginx-mailcow:
    ports: !override
      - 8443:443
  sogo-mailcow:
    volumes:
      #- ./data/conf/sogo/custom-theme.css:/usr/lib/GNUstep/SOGo/WebServerResources/css/theme-default.css:z
      #- ./data/conf/sogo/sogo-full.svg:/usr/lib/GNUstep/SOGo/WebServerResources/img/sogo-full.svg:z

volumes:
  vmail-vol-1:
    driver_opts:
      type: none
      device: ${MAILCOW_PATH}/data/mail
      o: bind
EOF
    
    log_success "Templates applied"
}

# Pull and start Mailcow containers
pull_and_start_mailcow() {
    log_step "Starting Mailcow containers"
    
    ensure_sogo_files
    
    log_info "Pulling Docker images"
    docker compose pull -q 2>&1 > /dev/null
    
    log_info "Starting containers"
    docker compose up -d --quiet-pull 2>&1 > /dev/null
    
    log_success "Mailcow containers started"
}

# Apply Docker network connections
apply_docker_network() {
    log_step "Configuring Docker networks"
    
    log_info "Connecting to mailcow network"
    docker network connect --alias edulution mailcowdockerized_mailcow-network ${HOSTNAME} 2>/dev/null || true
    
    log_info "Connecting to UI network"
    docker network connect --alias edulution edulution-ui_default ${HOSTNAME} 2>/dev/null || true
    
    log_info "Connecting Traefik"
    docker network connect --alias edulution-traefik mailcowdockerized_mailcow-network edulution-traefik 2>/dev/null || true
    
    # Backward compatibility
    docker network connect --alias nginx mailcowdockerized_mailcow-network mailcowdockerized-nginx-mailcow-1 2>/dev/null || true
    
    log_success "Networks configured"
}

# Wait for Mailcow to be ready
wait_for_mailcow() {
    log_step "Waiting for Mailcow to be ready"
    
    # Connect to network first
    log_info "Connecting to Mailcow network"
    docker network connect mailcowdockerized_mailcow-network ${HOSTNAME} 2>/dev/null || true
    
    # Wait for nginx
    local attempt=0
    while ! curl -s -k --head --request GET --max-time 2 "https://nginx-mailcow/" 2>/dev/null | grep -q "HTTP/"; do
        attempt=$((attempt + 1))
        if [ $attempt -gt 60 ]; then
            log_error "Nginx not ready after 60 attempts"
            break
        fi
        log_info "Waiting for Nginx... ($attempt/60)"
        sleep 2
    done
    
    log_success "Nginx is ready"
    
    # Wait for API
    log_info "Checking Mailcow API"
    attempt=0
    while [ $attempt -lt 60 ]; do
        API_RESPONSE=$(curl -s -k --max-time 5 -H "X-API-Key: ${MAILCOW_API_TOKEN}" --ipv4 "https://nginx-mailcow/api/v1/get/status/containers" 2>/dev/null || echo "")
        
        if echo "$API_RESPONSE" | grep -q "running"; then
            log_success "Mailcow API is ready"
            break
        elif echo "$API_RESPONSE" | grep -q "Preparing"; then
            log_info "Mailcow is still preparing..."
        else
            log_info "Waiting for API... ($attempt/60)"
        fi
        
        attempt=$((attempt + 1))
        sleep 5
    done
    
    if [ $attempt -eq 60 ]; then
        log_warning "Mailcow API timeout - continuing anyway"
    fi
}

# Main execution
main() {
    # Banner
    cat <<EOF

  _____ ____  _   _ _    _   _ _____ ___ ___  _   _       __  __    _    ___ _     
 | ____|  _ \| | | | |  | | | |_   _|_ _/ _ \| \ | |     |  \/  |  / \  |_ _| |    
 |  _| | | | | | | | |  | | | | | |  | | | | |  \| |_____| |\/| | / _ \  | || |    
 | |___| |_| | |_| | |__| |_| | | |  | | |_| | |\  |_____| |  | |/ ___ \ | || |___ 
 |_____|____/ \___/|_____\___/  |_| |___\___/|_| \_|     |_|  |_/_/   \_\___|_____|

EOF
    
    # Check if Mailcow is already running
    if docker compose --project-directory "${MAILCOW_PATH}/mailcow/" ps | grep -q 'mailcow'; then
        log_warning "Mailcow is already running - only starting API and sync services"

        ensure_sogo_files
        configure_sogo_gal
        apply_docker_network
        set_mailcow_token
        create_edulution_view
        start_ldap_server
        start_services
        exit 0
    fi

    # Full initialization
    init_mailcow
    apply_templates
    configure_sogo_gal
    pull_and_start_mailcow
    apply_docker_network
    set_mailcow_token
    create_edulution_view
    wait_for_mailcow
    start_ldap_server
    start_services
}

# Run main function
main