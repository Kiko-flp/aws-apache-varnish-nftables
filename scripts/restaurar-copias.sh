#!/usr/bin/env bash
# ==============================================================================
# Script de restauración: revierte Apache, Varnish y nftables a su estado previo
# ==============================================================================

set -euo pipefail

# --- 0. COMPROBACIONES INICIALES ---
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Este script debe ejecutarse con sudo o como root." >&2
    exit 1
fi

# Si se pasa una carpeta como argumento la usa; si no, busca el backup más reciente
if [[ $# -ge 1 ]]; then
    BACKUP_DIR="$1"
else
    BACKUP_DIR=$(ls -dt /root/backup-sec-* 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
    echo "[ERROR] No se encontró ningún directorio de backup en /root/backup-sec-*" >&2
    exit 1
fi

echo "=== Usando copia de seguridad: $BACKUP_DIR ==="

# ==============================================================================
# 1. DETENER NGINX Y VARNISH PRIMERO (LIBERAR PUERTOS 80 Y 443)
# ==============================================================================
echo "=== [1/4] Deteniendo Nginx y Varnish ==="
if systemctl is-active --quiet nginx; then
    systemctl stop nginx
fi
systemctl disable nginx 2>/dev/null || true

if [[ -d "$BACKUP_DIR/nginx" ]]; then
    rm -rf /etc/nginx
    cp -a "$BACKUP_DIR/nginx" /etc/nginx
fi

if systemctl is-active --quiet varnish; then
    systemctl stop varnish
fi
systemctl disable varnish 2>/dev/null || true

# Eliminamos el override que forzaba a Varnish a escuchar en el puerto 80
rm -f /etc/systemd/system/varnish.service.d/override.conf
rmdir /etc/systemd/system/varnish.service.d 2>/dev/null || true
systemctl daemon-reload

# Restauramos la configuración de Varnish si existía en el backup
if [[ -d "$BACKUP_DIR/varnish" ]]; then
    rm -rf /etc/varnish
    cp -a "$BACKUP_DIR/varnish" /etc/varnish
fi

# ==============================================================================
# 2. RESTAURAR APACHE Y VOLVER AL PUERTO 80
# ==============================================================================
echo "=== [2/4] Restaurando configuración original de Apache ==="
if [[ -d "$BACKUP_DIR/apache2" ]]; then
    rm -rf /etc/apache2
    cp -a "$BACKUP_DIR/apache2" /etc/apache2
else
    echo "[ERROR] No hay copia de /etc/apache2 en $BACKUP_DIR" >&2
    exit 1
fi

# Comprobamos sintaxis y reiniciamos Apache (ya con el puerto 80 libre)
apache2ctl configtest
systemctl restart apache2

# ==============================================================================
# 3. RESTAURAR NFTABLES Y LIMPIAR GEOIP
# ==============================================================================
echo "=== [3/4] Limpiando reglas GeoIP y restaurando nftables ==="

# Eliminamos el cron, el script actualizador, hooks de certbot y la lista de IPs
rm -f /etc/cron.d/geo-nft
rm -f /usr/local/sbin/update-geo-nft.sh
rm -f /etc/nftables-geo.nft
rm -f /etc/letsencrypt/renewal-hooks/pre/01-open-port80.sh
rm -f /etc/letsencrypt/renewal-hooks/post/01-close-port80.sh

if [[ -f "$BACKUP_DIR/nftables.conf" ]]; then
    # Si ya tenías un nftables.conf previo, lo restauramos y recargamos
    cp -a "$BACKUP_DIR/nftables.conf" /etc/nftables.conf
    nft -f /etc/nftables.conf
    systemctl restart nftables
else
    # Si no existía antes, vaciamos las reglas para no dejar bloqueos activos
    nft flush ruleset || true
    systemctl disable --now nftables 2>/dev/null || true
    rm -f /etc/nftables.conf
fi

# ==============================================================================
# 4. VERIFICACIÓN FINAL
# ==============================================================================
echo "=== [4/4] Verificación tras restaurar ==="
echo "1) Puertos escuchando (apache2 debe volver a estar en :80):"
ss -tulpn | grep -E ':80|:8080' || true
echo ""
echo "2) Reglas nftables activas:"
nft list ruleset || true
echo ""
echo "[OK] Restauración completada."