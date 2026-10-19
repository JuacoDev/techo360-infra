# Certificado TLS de Let's Encrypt (frontend)

El nginx del contenedor `techo360-frontend` termina TLS en el 443 para
`techo360.bucaramanga.upb.edu.co`. Hasta el 16-oct-2026 usaba un certificado
autofirmado (`certs/`, CN=localhost); ese archivo se **conserva** como respaldo.

## Estado (17-oct-2026): emisión NO realizada

El *staging* falló: `Timeout during connect (likely firewall problem)` al pedir
`http://techo360.bucaramanga.upb.edu.co/.well-known/acme-challenge/<token>` desde Let's Encrypt.
nginx no registró ninguna petición del validador (solo las pruebas propias): el tráfico no llegó
al VPS. Desde otras redes el puerto 80 sí responde, así que el filtro parece estar del lado de la
universidad/CCA (HIPÓTESIS; `ufw`/`iptables` no son visibles sin sudo). No se emitió el
certificado real, no se instaló el cron y el 443 sigue con el autofirmado.
Para reintentar: abrir el 80 a internet (CCA/CTIC) y repetir "Emisión"; o usar DNS-01 (requiere
crear un TXT `_acme-challenge` en la zona de la universidad). Cuando haya certificado: cambiar
`ssl_certificate`/`ssl_certificate_key` de `nginx.conf` (frontend) a
`/etc/letsencrypt/live/techo360.bucaramanga.upb.edu.co/{fullchain,privkey}.pem`, comprobar con
`nginx -t` en un contenedor efímero y desplegar el frontend; luego instalar el cron de
`scripts/renovar-certificado.sh` y probar `--dry-run`.

## Piezas

| Pieza | Dónde | Notas |
|---|---|---|
| Config nginx | `techo360-frontend/nginx.conf` (se hornea en la imagen) | puerto 80: `location /.well-known/acme-challenge/` antes del 301; 443 usa `/etc/letsencrypt/live/<dominio>/` |
| Mounts | `docker-compose.yml` (frontend) | `./certbot/conf:/etc/letsencrypt:ro`, `./certbot/www:/var/www/certbot:ro`, y `./certs` (autofirmado) |
| Estado de certbot | VPS: `/opt/techo360/techo360-infra/certbot/{conf,www}` | no versionado (`.gitignore`); `conf` contiene llaves privadas |
| Emisión / renovación | certbot en contenedor efímero (`certbot/certbot`) | HTTP-01 por webroot, sin plugin de nginx |
| Renovación automática | cron de `techo360-admin` → `scripts/renovar-certificado.sh` | recarga nginx solo si renovó |

Requisitos: DNS A del dominio → IP del VPS; puertos 80 y 443 alcanzables desde internet
(CCA: aprobados); sin registros CAA que excluyan a Let's Encrypt (no los hay).

## Emisión (una vez)

```bash
cd /opt/techo360/techo360-infra
mkdir -p certbot/conf certbot/www
# 1) staging en un directorio aparte (no ensucia el linaje real)
mkdir -p certbot/staging
docker run --rm -v "$PWD/certbot/staging:/etc/letsencrypt" -v "$PWD/certbot/www:/var/www/certbot" \
  certbot/certbot certonly --webroot -w /var/www/certbot -d techo360.bucaramanga.upb.edu.co \
  --staging --register-unsafely-without-email --agree-tos --non-interactive
# 2) solo si el staging pasó: emisión real
docker run --rm -v "$PWD/certbot/conf:/etc/letsencrypt" -v "$PWD/certbot/www:/var/www/certbot" \
  certbot/certbot certonly --webroot -w /var/www/certbot -d techo360.bucaramanga.upb.edu.co \
  --register-unsafely-without-email --agree-tos --non-interactive
```

Se registró sin correo de contacto: Let's Encrypt **no avisará** por correo si falla la
renovación. Vigilar `/opt/techo360/logs/renovar-certificado.log` o registrar un correo del equipo.

## Reversa

1. Volver al nginx anterior: `git revert -m 1 <SHA del merge en techo360-frontend>` + push a
   `development` (redespliega el frontend con el `nginx.conf` previo, que usa `/etc/nginx/certs/`).
2. Si hiciera falta restaurar a mano: el respaldo del nginx anterior y de `certs/` está en
   `/opt/techo360/respaldos-config/frontend-nginx-certs-20261017/` (con `SHA256SUMS`).
3. Quitar el cron: `crontab -l | grep -v renovar-certificado | crontab -`.
4. Los mounts nuevos del compose son inocuos sin uso; se pueden revertir con `git revert -m 1`
   del merge de infra.
