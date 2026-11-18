# 6. Automatización y restauración (scripts)

Todo el despliegue y su reversión están automatizados en la carpeta [`scripts/`](../scripts/).

## 6.1 Despliegue completo (`setup-securizacion.sh`)

El script [`scripts/setup-securizacion.sh`](../scripts/setup-securizacion.sh) realiza de forma desatendida:
1. Copia de seguridad de `/etc/apache2`, `/etc/varnish`, `/etc/nginx` y `/etc/nftables.conf` en `/root/backup-sec-YYYY-MM-DD_HHMMSS`.
2. Desactivación de `ufw` si estuviera activo para evitar conflictos.
3. Instalación de `varnish`, `nginx`, `certbot`, `python3-certbot-nginx`, `nftables` y `curl`.
4. Configuración de Apache en `127.0.0.1:8080`, `mod_remoteip` y eliminación de redirecciones/SSL heredados.
5. Configuración de Varnish en `127.0.0.1:6081` con `default.vcl`.
6. Configuración de Nginx, emisión del certificado SSL con Certbot y *hooks* de renovación.
7. Carga de `nftables` con GeoIP (`es`, `pe`), baneo temporal (`2m`) y tarea `cron` semanal.

Ejecución:
```bash
chmod +x scripts/setup-securizacion.sh
sudo ./scripts/setup-securizacion.sh
```

## 6.2 Restauración completa (`restaurar-copias.sh`)

El script [`scripts/restaurar-copias.sh`](../scripts/restaurar-copias.sh) revierte la máquina a su estado previo:
1. Detiene y deshabilita Nginx y Varnish para liberar los puertos `80` y `443`.
2. Restaura `/etc/apache2` desde el backup más reciente en `/root/backup-sec-*` (o desde la ruta pasada como parámetro).
3. Elimina los archivos de GeoIP, el `cron` y los *hooks* de Certbot, y restaura o limpia `nftables`.

Ejecución:
```bash
chmod +x scripts/restaurar-copias.sh
sudo ./restaurar-copias.sh
```
