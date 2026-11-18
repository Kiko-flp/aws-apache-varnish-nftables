# 1. Introducción y arquitectura

## 1.1 Objetivo del proyecto

El objetivo de esta práctica es securizar un servidor web **Apache2** desplegado en una instancia **AWS EC2** (Debian/Ubuntu) bajo el dominio `kikomola.ddns.net`, añadiendo varias capas de defensa en profundidad:

- **Ocultación y caché:** situar **Varnish** delante de Apache para responder peticiones repetidas desde memoria RAM y eliminar cabeceras que revelan versiones del servidor.
- **Cifrado TLS (HTTPS):** terminar las conexiones seguras en el puerto `443` mediante **Nginx** y certificados de **Let's Encrypt (Certbot)** con renovación automática.
- **Filtrado geográfico:** restringir el acceso web (`80` y `443`) mediante **nftables** exclusivamente a direcciones IP de **España (`es`)** y **Perú (`pe`)**.
- **Mitigación anti-DDoS:** limitar la tasa de conexiones nuevas por IP y aplicar un baneo temporal automático (`2m`) para evitar saturación sin perder nunca el acceso SSH (`22`).

## 1.2 Flujo de red y puertos

```text
Internet (:80/:443)
   │
   ▼
AWS Security Group (80/443 abiertos; 22 SSH solo Mi IP)
   │
   ▼
nftables (GeoIP ES/PE + baneo temporal 2m si >20 conn/s)
   │
   ▼
Nginx (0.0.0.0:80 redirige a :443 TLS con Certbot)
   │
   ▼
Varnish (127.0.0.1:6081 - Caché RAM + limpieza de cabeceras)
   │
   ▼
Apache2 (127.0.0.1:8080 - mod_remoteip + ServerTokens Prod)
```

| Servicio | Dirección y puerto | Función principal |
| --- | --- | --- |
| **nftables** | Kernel (hook `input`) | Cortafuegos por defecto `drop`, GeoIP (`es`, `pe`) y baneo temporal. |
| **Nginx** | `0.0.0.0:80`, `0.0.0.0:443` | Terminación SSL/TLS, redirección HTTP→HTTPS y proxy inverso. |
| **Varnish** | `127.0.0.1:6081` | Caché HTTP en RAM, filtrado de métodos y ocultación de cabeceras. |
| **Apache2** | `127.0.0.1:8080` | Servidor web backend accesible únicamente desde localhost. |

## 1.3 Requisitos previos en AWS

1. **Security Group de la instancia EC2:**
   - **SSH (`22`):** origen configurado en **My IP** (solo tu IP pública) para evitar accesos no autorizados y no depender del filtro GeoIP.
   - **HTTP (`80`) y HTTPS (`443`):** origen `0.0.0.0/0` (el filtrado por país y tasa se realiza dentro de la máquina con `nftables`).
2. **DNS dinámico:** el dominio `kikomola.ddns.net` debe apuntar a la IP pública de la instancia EC2 antes de solicitar el certificado con Certbot.
