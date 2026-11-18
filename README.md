# Securización de Apache en AWS con Nginx, Varnish, Certbot y nftables

Proyecto de configuración y automatización para proteger un servidor web Apache en AWS EC2 mediante proxy inverso, caché en RAM, cifrado TLS/HTTPS, filtrado geográfico por país y mitigación básica frente a ataques DoS/DDoS.

## Arquitectura

```text
Internet (:80/:443)
   │
   ▼
nftables (GeoIP ES/PE + baneo temporal anti-DDoS; SSH :22 protegido)
   │
   ▼
Nginx (:80 redirect -> :443 TLS con Let's Encrypt / Certbot)
   │
   ▼
Varnish (127.0.0.1:6081 - Caché en RAM + limpieza de cabeceras)
   │
   ▼
Apache2 (127.0.0.1:8080 - mod_remoteip + hardening)
```

## Archivos incluidos

- **`setup-securizacion.sh`**: Script completo e idempotente que realiza copia de seguridad e instala/configura:
  1. **Apache2** en `127.0.0.1:8080` (inaccesible directamente desde internet), con `mod_remoteip` para registrar la IP real del cliente y ocultación de cabeceras (`ServerTokens Prod`, `ServerSignature Off`, `TraceEnable Off`).
  2. **Varnish** en `127.0.0.1:6081` como caché delante de Apache, filtrando métodos HTTP no estándar y eliminando cabeceras (`Server`, `X-Powered-By`, `Via`, `X-Varnish`).
  3. **Nginx + Certbot** en `:80` y `:443` con redirección automática a HTTPS y *hooks* de renovación (`pre`/`post`) para abrir temporalmente el puerto 80 durante las renovaciones de Let's Encrypt.
  4. **nftables** con:
     - Política por defecto `drop`.
     - Filtrado geográfico (`allowed_countries_v4`) para permitir tráfico web solo desde España (`es`) y Perú (`pe`), actualizado semanalmente por `cron` mediante `/usr/local/sbin/update-geo-nft.sh`.
     - Protección anti-flood con baneo temporal (`banned_ips_v4` con `timeout 2m` al superar `20/second` con ráfaga `30`), sin afectar nunca al puerto SSH (`22`).
- **`restaurar-copias.sh`**: Script de reversión (*rollback*) que detiene Nginx y Varnish, restaura las copias de seguridad de `/root/backup-sec-*` y limpia las reglas de `nftables` y `cron`.

## Uso rápido

1. Configura las variables al inicio de `setup-securizacion.sh` (`DOMAIN`, `COUNTRIES`, `RATE_LIMIT`, `RATE_BURST`, `BAN_TIME`).
2. En el **Security Group** de AWS EC2, abre los puertos `80` y `443` (`0.0.0.0/0`) y restringe el puerto `22 (SSH)` a tu IP (`My IP`).
3. Ejecuta en la instancia:
   ```bash
   chmod +x setup-securizacion.sh restaurar-copias.sh
   sudo ./setup-securizacion.sh
   ```

## Comandos útiles de verificación y pruebas

```bash
# Ver puertos escuchando
sudo ss -tulpn | grep -E ':80|:443|:6081|:8080'

# Ver IPs baneadas temporalmente por exceso de peticiones
sudo nft list set inet filter banned_ips_v4

# Limpiar baneo temporal manualmente para repetir pruebas
sudo nft flush set inet filter banned_ips_v4

# Prueba de carga con ApacheBench y exportación para Gnuplot
ab -n 2000 -c 50 -g resultados.tsv http://127.0.0.1:6081/
```
