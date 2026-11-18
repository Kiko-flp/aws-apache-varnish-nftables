#!/usr/bin/env bash
# ==============================================================================
# Script de securización: Nginx (:443 TLS) -> Varnish (127.0.0.1:6081) -> Apache (127.0.0.1:8080) + nftables (GeoIP)
# Países permitidos por defecto: España (es) y Perú (pe)
# ==============================================================================

# -e: detiene el script si algún comando falla
# -u: falla si se usa una variable no definida
# -o pipefail: detecta errores dentro de tuberías (pipes)
set -euo pipefail

# --- VARIABLES CONFIGURABLES ---
DOMAIN="kikomola.ddns.net" # Tu dominio DNS público para el certificado SSL
CERTBOT_EMAIL=""           # Opcional: tu email para avisos de Let's Encrypt (si se deja vacío no pide correo)
COUNTRIES=("es" "pe")      # Códigos ISO de países permitidos (en minúsculas)
RATE_LIMIT="20/second"     # Máximo de conexiones nuevas por segundo permitidas por IP
RATE_BURST=30              # Ráfaga máxima inicial antes de empezar a contar exceso
BAN_TIME="2m"              # Tiempo de bloqueo temporal (ej: 30s, 2m, 5m) tras superar el límite
BACKUP_DIR="/root/backup-sec-$(date +%F_%H%M%S)"

# --- 0. COMPROBACIONES INICIALES ---
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Este script debe ejecutarse con sudo o como root." >&2
    exit 1
fi

echo "=== [1/6] Creando copia de seguridad en $BACKUP_DIR ==="
mkdir -p "$BACKUP_DIR"
cp -a /etc/apache2 "$BACKUP_DIR/apache2" 2>/dev/null || true
cp -a /etc/varnish "$BACKUP_DIR/varnish" 2>/dev/null || true
cp -a /etc/nginx "$BACKUP_DIR/nginx" 2>/dev/null || true
cp -a /etc/nftables.conf "$BACKUP_DIR/nftables.conf" 2>/dev/null || true

# Si UFW está activo, avisamos porque 'nftables' con 'flush ruleset' lo sustituirá
if systemctl is-active --quiet ufw; then
    echo "[AVISO] UFW está activo. Se desactivará para evitar conflictos con nftables."
    systemctl disable --now ufw
fi

echo "=== [2/6] Instalando paquetes (varnish, nginx, certbot, nftables, curl) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq varnish nginx certbot python3-certbot-nginx nftables curl

# ==============================================================================
# 1. APACHE: MOVER A 127.0.0.1:8080 Y SECURIZAR
# ==============================================================================
echo "=== [3/6] Configurando Apache en 127.0.0.1:8080 ==="

# Cambia 'Listen 80' por 'Listen 127.0.0.1:8080' para que nadie acceda directo desde fuera
if grep -qE '^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)' /etc/apache2/ports.conf; then
    sed -i -E 's/^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)/Listen 127.0.0.1:8080\1/' /etc/apache2/ports.conf
else
    # Si no existía Listen 80 ni 127.0.0.1:8080, lo añadimos
    grep -q '127.0.0.1:8080' /etc/apache2/ports.conf || echo "Listen 127.0.0.1:8080" >> /etc/apache2/ports.conf
fi

# Actualiza todos los VirtualHosts del puerto 80 para que escuchen en 127.0.0.1:8080
sed -i 's/<VirtualHost \*:80>/<VirtualHost 127.0.0.1:8080>/g' /etc/apache2/sites-available/*.conf

# Desactiva cualquier escucha de Apache en el puerto 443 (ahora lo gestionará Nginx)
sed -i -E 's/^[[:space:]]*(Listen[[:space:]]+443.*)/# \1/' /etc/apache2/ports.conf
for ssl_site in /etc/apache2/sites-enabled/*ssl*.conf; do
    [[ -e "$ssl_site" ]] && a2dissite -q "$(basename "$ssl_site")" || true
done

# Evita bucles de redirección si Apache tenía una regla previa de Certbot hacia https://
sed -i -E 's/^[[:space:]]*(RewriteRule[[:space:]]+\^[[:space:]]+https:\/\/.*)/# \1/' /etc/apache2/sites-available/*.conf

# Habilita remoteip (para leer la IP real que pasa Nginx/Varnish), headers y setenvif
a2enmod -q remoteip headers setenvif

# Configura Apache para confiar en X-Forwarded-For desde localhost y detectar HTTPS
cat <<'EOF' > /etc/apache2/conf-available/remoteip.conf
RemoteIPHeader X-Forwarded-For
RemoteIPTrustedProxy 127.0.0.1
SetEnvIf X-Forwarded-Proto "https" HTTPS=on
EOF
a2enconf -q remoteip

# Endurecimiento básico de cabeceras en security.conf (oculta versión de Apache y SO)
SEC_CONF="/etc/apache2/conf-available/security.conf"
if [[ -f "$SEC_CONF" ]]; then
    sed -i -E 's/^#?ServerTokens .*/ServerTokens Prod/' "$SEC_CONF"
    sed -i -E 's/^#?ServerSignature .*/ServerSignature Off/' "$SEC_CONF"
    sed -i -E 's/^#?TraceEnable .*/TraceEnable Off/' "$SEC_CONF"
fi

# Verifica que la sintaxis de Apache sea correcta antes de reiniciar
apache2ctl configtest
# Reiniciamos Apache primero para liberar el puerto 80 antes de arrancar Varnish
systemctl restart apache2

# ==============================================================================
# 2. VARNISH: ESCUCHAR EN 127.0.0.1:6081 (DETRÁS DE NGINX) Y LIMPIAR CABECERAS
# ==============================================================================
echo "=== [4/6] Configurando Varnish en 127.0.0.1:6081 ==="

# Varnish escucha solo en localhost:6081 porque Nginx terminará el HTTPS en :443 y :80
mkdir -p /etc/systemd/system/varnish.service.d
cat <<'EOF' > /etc/systemd/system/varnish.service.d/override.conf
[Service]
# La línea vacía es obligatoria para limpiar el ExecStart original de systemd
ExecStart=
ExecStart=/usr/sbin/varnishd -j unix,user=vcache -F -a 127.0.0.1:6081 -T localhost:6082 -f /etc/varnish/default.vcl -S /etc/varnish/secret -s malloc,256m
EOF

# Configuramos el VCL de Varnish: backend en Apache, reenvío de IP y ocultación de cabeceras
cat <<'EOF' > /etc/varnish/default.vcl
vcl 4.1;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
}

sub vcl_recv {
    # Si Nginx ya envió X-Forwarded-For con la IP real, lo conservamos; si no, usamos client.ip
    if (req.restarts == 0 && !req.http.X-Forwarded-For) {
        set req.http.X-Forwarded-For = client.ip;
    }

    # Bloquea métodos HTTP raros o potencialmente peligrosos
    if (req.method != "GET" && req.method != "HEAD" && req.method != "POST" &&
        req.method != "PUT" && req.method != "DELETE" && req.method != "OPTIONS") {
        return (synth(405, "Method Not Allowed"));
    }

    # No cachear paneles de administración ni peticiones autenticadas
    if (req.url ~ "^/(admin|wp-admin|login)" || req.http.Authorization) {
        return (pass);
    }
}

sub vcl_deliver {
    # Elimina cabeceras que revelan tecnologías internas (Apache, PHP, Varnish)
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.Via;
    unset resp.http.X-Varnish;
}
EOF

systemctl daemon-reload
systemctl enable --now varnish
systemctl restart varnish

# ==============================================================================
# 3. NGINX + CERTBOT: TERMINACIÓN HTTPS (443) PARA ${DOMAIN}
# ==============================================================================
echo "=== [5/6] Configurando Nginx y certificado SSL con Certbot para $DOMAIN ==="

# Quitamos el sitio por defecto de Nginx para evitar conflictos con nuestro dominio
rm -f /etc/nginx/sites-enabled/default

# Configuramos Nginx como proxy inverso hacia Varnish (127.0.0.1:6081)
cat <<EOF > "/etc/nginx/sites-available/${DOMAIN}"
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Oculta la versión de Nginx en cabeceras y páginas de error
    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Si nftables ya estaba activo de una ejecución anterior, abrimos temporalmente
# para que los servidores globales de Let's Encrypt puedan validar el dominio en :80
nft flush ruleset 2>/dev/null || true

# Solicitamos/renovamos el certificado SSL y configuramos redirección automática HTTP -> HTTPS
if [[ -n "$CERTBOT_EMAIL" ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$CERTBOT_EMAIL" --redirect
else
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect
fi

# Hooks para que las renovaciones automáticas de Certbot abran el puerto 80 unos segundos
# (necesario porque nftables bloquea IPs fuera de ES/PE y Let's Encrypt valida desde fuera)
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/pre/01-open-port80.sh
#!/usr/bin/env bash
if nft list chain inet filter input >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept comment \"certbot-renew\"
fi
EOF
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/post/01-close-port80.sh
#!/usr/bin/env bash
HANDLES=$(nft -a list chain inet filter input 2>/dev/null | awk '/certbot-renew/ {print $NF}')
for h in $HANDLES; do
    nft delete rule inet filter input handle "$h" || true
done
EOF
chmod +x /etc/letsencrypt/renewal-hooks/pre/01-open-port80.sh /etc/letsencrypt/renewal-hooks/post/01-close-port80.sh

# ==============================================================================
# 4. NFTABLES: FILTRADO GEOGRÁFICO + ANTI-DDOS TEMPORAL (SOLO WEB, SSH PROTEGIDO)
# ==============================================================================
echo "=== [6/6] Configurando nftables y filtrado por país (${COUNTRIES[*]}) ==="

# Creamos el archivo de IPs vacío inicialmente para que nftables.conf pueda incluirlo
touch /etc/nftables-geo.nft

# Creamos la configuración principal del firewall (sin comillas en EOF para usar las variables de límite/baneo)
cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    # Set optimizado en árbol (flags interval) para miles de subredes CIDR
    set allowed_countries_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    # Lista negra temporal: las IPs bloqueadas se borran automáticamente tras BAN_TIME
    set banned_ips_v4 {
        type ipv4_addr
        flags dynamic,timeout
        timeout ${BAN_TIME}
    }

    # Contador dinámico por IP para detectar ráfagas de conexiones nuevas
    set web_ratelimit_v4 {
        type ipv4_addr
        flags dynamic,timeout
        timeout 10s
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # 1. Permitir tráfico interno (localhost/Varnish->Apache)
        iif "lo" accept

        # 2. SSH (puerto 22) SIEMPRE permitido aquí (aunque la IP esté baneada en web)
        #    (La restricción por IP del puerto 22 debe hacerse en el Security Group de AWS)
        tcp dport 22 accept

        # 3. Si la IP está en la lista negra temporal, cortar TODO el tráfico web (incluso keep-alive)
        tcp dport { 80, 443 } ip saddr @banned_ips_v4 counter drop

        # 4. Permitir conexiones ya establecidas y descartar paquetes inválidos
        ct state established,related accept
        ct state invalid drop

        # 5. ICMP básico (ping y diagnóstico de red)
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # 6. Anti-DDoS: si una IP permitida supera RATE_LIMIT (con ráfaga RATE_BURST),
        #    se añade a banned_ips_v4 durante BAN_TIME y se descarta la conexión
        tcp dport { 80, 443 } ct state new ip saddr @allowed_countries_v4 \\
            add @web_ratelimit_v4 { ip saddr limit rate over ${RATE_LIMIT} burst ${RATE_BURST} packets } \\
            add @banned_ips_v4 { ip saddr } counter drop

        # 7. Puertos web (80/443): SOLO accesibles desde las IPs del set de países
        tcp dport { 80, 443 } ip saddr @allowed_countries_v4 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# Carga la lista persistente de IPs por país (generada por update-geo-nft.sh)
include "/etc/nftables-geo.nft"
EOF

# Creamos el script que descarga los bloques CIDR y actualiza nftables de forma segura
cat <<'EOF' > /usr/local/sbin/update-geo-nft.sh
#!/usr/bin/env bash
set -euo pipefail

# Países permitidos (códigos ISO en minúsculas)
COUNTRIES=("es" "pe")
GEO_FILE="/etc/nftables-geo.nft"
TMP_LIST=$(mktemp)
TMP_NFT=$(mktemp)
trap 'rm -f "$TMP_LIST" "$TMP_NFT"' EXIT

# Descarga las zonas CIDR desde ipdeny.com
for cc in "${COUNTRIES[@]}"; do
    curl -fsSL "https://www.ipdeny.com/ipblocks/data/countries/${cc}.zone" >> "$TMP_LIST"
done

# Seguridad: si la descarga falla o viene vacía, abortamos sin borrar las reglas actuales
if [[ ! -s "$TMP_LIST" ]]; then
    echo "[ERROR] La lista de IPs descargada está vacía. Abortando." >&2
    exit 1
fi

# Generamos el archivo nft atómico: vacía el set y carga todas las redes de golpe
{
    echo "flush set inet filter allowed_countries_v4"
    echo -n "add element inet filter allowed_countries_v4 { "
    paste -sd, "$TMP_LIST"
    echo " }"
} > "$TMP_NFT"

# Validamos la sintaxis antes de aplicarlo al kernel
nft -c -f "$TMP_NFT"
mv "$TMP_NFT" "$GEO_FILE"
chmod 644 "$GEO_FILE"
nft -f "$GEO_FILE"

echo "[OK] GeoIP actualizado: $(wc -l < "$TMP_LIST") rangos CIDR cargados."
EOF

chmod +x /usr/local/sbin/update-geo-nft.sh

# Validamos y cargamos la base de nftables, luego poblamos las IPs y activamos el servicio
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
/usr/local/sbin/update-geo-nft.sh
systemctl enable nftables

# Programamos actualización automática todos los lunes a las 04:00 AM
cat <<'EOF' > /etc/cron.d/geo-nft
0 4 * * 1 root /usr/local/sbin/update-geo-nft.sh >/var/log/geo-nft.log 2>&1
EOF

# ==============================================================================
# VERIFICACIÓN FINAL
# ==============================================================================
echo ""
echo "=========================================================="
echo " ¡INSTALACIÓN COMPLETADA CON ÉXITO!"
echo "=========================================================="
echo "1) Puertos escuchando (nginx en :80/:443, varnishd en 127.0.0.1:6081, apache2 en 127.0.0.1:8080):"
ss -tulpn | grep -E ':80|:443|:6081|:8080' || true
echo ""
echo "2) Prueba HTTPS local hacia https://$DOMAIN (no debe verse Server: Apache ni X-Varnish):"
curl -sI --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}" | head -n 12 || true
echo ""
echo "3) Reglas nftables cargadas (primeras líneas):"
nft list chain inet filter input