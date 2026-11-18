# 2. Apache y Varnish (configuración manual)

## 2.1 Mover Apache a `127.0.0.1:8080` y endurecer cabeceras

Para evitar que un atacante se salte Nginx y Varnish atacando directamente a Apache, se restringe su escucha a `localhost` (`127.0.0.1:8080`).

1. **Editar `/etc/apache2/ports.conf`** para escuchar solo en `127.0.0.1:8080` (y comentar `Listen 443` si existía):
   ```apache
   Listen 127.0.0.1:8080
   # Listen 443
   ```

2. **Actualizar el VirtualHost** en `/etc/apache2/sites-available/000-default.conf`:
   ```apache
   <VirtualHost 127.0.0.1:8080>
       ...
   </VirtualHost>
   ```
   *(Si existían sitios SSL previos en Apache como `default-ssl.conf` o reglas `RewriteRule ^ https://...` añadidas por Certbot, deben desactivarse para evitar conflictos de puerto y bucles de redirección):*
   ```bash
   sudo a2dissite default-ssl
   ```

3. **Recuperar la IP real del cliente y detectar HTTPS (`mod_remoteip`):**
   ```bash
   sudo a2enmod remoteip headers setenvif
   ```
   Crear `/etc/apache2/conf-available/remoteip.conf`:
   ```apache
   RemoteIPHeader X-Forwarded-For
   RemoteIPTrustedProxy 127.0.0.1
   SetEnvIf X-Forwarded-Proto "https" HTTPS=on
   ```
   Activar la configuración:
   ```bash
   sudo a2enconf remoteip
   ```

4. **Endurecimiento en `/etc/apache2/conf-available/security.conf`:**
   ```apache
   ServerTokens Prod
   ServerSignature Off
   TraceEnable Off
   ```

5. **Validar sintaxis y reiniciar Apache** (liberando el puerto `80` y `443`):
   ```bash
   sudo apache2ctl configtest
   sudo systemctl restart apache2
   ```

## 2.2 Instalar y configurar Varnish en `127.0.0.1:6081`

1. **Instalar Varnish:**
   ```bash
   sudo apt update && sudo apt install -y varnish
   ```

2. **Configurar el puerto de escucha** mediante un *drop-in* de `systemd`:
   ```bash
   sudo systemctl edit varnish
   ```
   Añadir:
   ```ini
   [Service]
   ExecStart=
   ExecStart=/usr/sbin/varnishd -j unix,user=vcache -F -a 127.0.0.1:6081 -T localhost:6082 -f /etc/varnish/default.vcl -S /etc/varnish/secret -s malloc,256m
   ```

3. **Configurar `/etc/varnish/default.vcl`:**
   ```vcl
   vcl 4.1;

   backend default {
       .host = "127.0.0.1";
       .port = "8080";
   }

   sub vcl_recv {
       if (req.restarts == 0 && !req.http.X-Forwarded-For) {
           set req.http.X-Forwarded-For = client.ip;
       }

       if (req.method != "GET" && req.method != "HEAD" && req.method != "POST" &&
           req.method != "PUT" && req.method != "DELETE" && req.method != "OPTIONS") {
           return (synth(405, "Method Not Allowed"));
       }

       if (req.url ~ "^/(admin|wp-admin|login)" || req.http.Authorization) {
           return (pass);
       }
   }

   sub vcl_deliver {
       unset resp.http.X-Powered-By;
       unset resp.http.Server;
       unset resp.http.Via;
       unset resp.http.X-Varnish;
   }
   ```

4. **Recargar y arrancar Varnish:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now varnish
   ```
