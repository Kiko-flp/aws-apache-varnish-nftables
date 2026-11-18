# 3. HTTPS con Nginx y Certbot (configuración manual)

Dado que Varnish (versión gratuita) no termina conexiones TLS/HTTPS directamente, se coloca **Nginx** delante como terminador SSL.

## 3.1 Instalación y VirtualHost base

1. **Instalar Nginx y Certbot:**
   ```bash
   sudo apt install -y nginx certbot python3-certbot-nginx
   ```

2. **Eliminar el sitio por defecto y crear `/etc/nginx/sites-available/kikomola.ddns.net`:**
   ```bash
   sudo rm -f /etc/nginx/sites-enabled/default
   ```
   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name kikomola.ddns.net;

       server_tokens off;

       location / {
           proxy_pass http://127.0.0.1:6081;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```

3. **Habilitar el sitio y recargar Nginx:**
   ```bash
   sudo ln -sf /etc/nginx/sites-available/kikomola.ddns.net /etc/nginx/sites-enabled/kikomola.ddns.net
   sudo nginx -t
   sudo systemctl enable --now nginx
   ```

## 3.2 Emisión del certificado SSL con Certbot

> [!IMPORTANT]
> Antes de ejecutar Certbot, si `nftables` ya está bloqueando países fuera de España y Perú en el puerto `80`, los servidores de validación de Let's Encrypt no podrán conectarse. Es necesario abrir temporalmente el puerto `80` durante la emisión y renovación.

```bash
sudo certbot --nginx -d kikomola.ddns.net --non-interactive --agree-tos --register-unsafely-without-email --redirect
```

La opción `--redirect` configura automáticamente en Nginx la redirección permanente `HTTP (:80) -> HTTPS (:443)`.

## 3.3 Hooks de renovación automática con `nftables`

Para que las renovaciones automáticas de Certbot funcionen aunque `nftables` esté activo, se crean dos scripts en `/etc/letsencrypt/renewal-hooks/`:

- **Pre-hook (`/etc/letsencrypt/renewal-hooks/pre/01-open-port80.sh`):** abre temporalmente el puerto `80` al inicio de la tabla `input`.
  ```bash
  #!/usr/bin/env bash
  if nft list chain inet filter input >/dev/null 2>&1; then
      nft insert rule inet filter input tcp dport 80 accept comment \"certbot-renew\"
  fi
  ```

- **Post-hook (`/etc/letsencrypt/renewal-hooks/post/01-close-port80.sh`):** elimina la regla temporal al terminar.
  ```bash
  #!/usr/bin/env bash
  HANDLES=$(nft -a list chain inet filter input 2>/dev/null | awk '/certbot-renew/ {print $NF}')
  for h in $HANDLES; do
      nft delete rule inet filter input handle "$h" || true
  done
  ```

Dar permisos de ejecución:
```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/pre/01-open-port80.sh /etc/letsencrypt/renewal-hooks/post/01-close-port80.sh
```
