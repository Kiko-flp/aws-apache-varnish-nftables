# 4. Firewall con nftables: GeoIP y anti-DDoS temporal

## 4.1 Estructura de reglas (`/etc/nftables.conf`)

Se utiliza una tabla `inet filter` con política por defecto `drop` en `input` y tres *sets* dinámicos:
- `allowed_countries_v4`: rangos CIDR permitidos (España `es` y Perú `pe`) usando `flags interval` para búsqueda eficiente en kernel.
- `web_ratelimit_v4`: controla la tasa de conexiones nuevas por IP (`20/second` con ráfaga `burst 30`).
- `banned_ips_v4`: lista negra temporal con `timeout 2m` que expira automáticamente para poder realizar pruebas sin bloqueos permanentes.

```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    set allowed_countries_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    set banned_ips_v4 {
        type ipv4_addr
        flags dynamic,timeout
        timeout 2m
    }

    set web_ratelimit_v4 {
        type ipv4_addr
        flags dynamic,timeout
        timeout 10s
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept

        # SSH siempre accesible (protegido por Security Group de AWS)
        tcp dport 22 accept

        # Cortar todo el tráfico web a IPs baneadas temporalmente
        tcp dport { 80, 443 } ip saddr @banned_ips_v4 counter drop

        ct state established,related accept
        ct state invalid drop

        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # Baneo temporal si supera el límite de conexiones nuevas
        tcp dport { 80, 443 } ct state new ip saddr @allowed_countries_v4 \
            add @web_ratelimit_v4 { ip saddr limit rate over 20/second burst 30 packets } \
            add @banned_ips_v4 { ip saddr } counter drop

        # Acceso web permitido solo a los países autorizados
        tcp dport { 80, 443 } ip saddr @allowed_countries_v4 accept
    }

    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}

include "/etc/nftables-geo.nft"
```

## 4.2 Actualización de rangos por país (`/usr/local/sbin/update-geo-nft.sh`)

Los bloques CIDR de España y Perú se descargan desde `ipdeny.com`, se validan con `nft -c -f` antes de aplicarse y se guardan en `/etc/nftables-geo.nft` para persistir tras reinicios.

```bash
sudo nft -c -f /etc/nftables.conf
sudo nft -f /etc/nftables.conf
sudo /usr/local/sbin/update-geo-nft.sh
sudo systemctl enable nftables
```

La tarea programada en `/etc/cron.d/geo-nft` actualiza los rangos cada lunes a las 04:00 AM:
```cron
0 4 * * 1 root /usr/local/sbin/update-geo-nft.sh >/var/log/geo-nft.log 2>&1
```

## 4.3 Gestión manual durante pruebas

```bash
# Ver reglas y contadores de paquetes bloqueados
sudo nft list chain inet filter input

# Ver IPs actualmente baneadas y su tiempo restante
sudo nft list set inet filter banned_ips_v4

# Desbloquear todas las IPs baneadas al instante
sudo nft flush set inet filter banned_ips_v4
```
