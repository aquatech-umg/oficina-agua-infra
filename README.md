# oficina-agua-infra

Infraestructura compartida de la Fase 2 del proyecto Oficina del Agua (AquaTech, UMG 2026).

Contiene la base de datos del monolito y su réplica de solo lectura, ambas en Docker.

## Componentes

| Contenedor | Función | Puerto en tu máquina |
|---|---|---|
| `db-primary` | Base principal. La usa el monolito Laravel para leer y escribir | 3306 |
| `db-replica` | Réplica de solo lectura. Copia automáticamente cada cambio de la principal | 3307 |

Los microservicios de la Fase 2 **leen de la réplica** con el usuario de solo lectura. Nunca escriben en la base del monolito.

## Contenido de `db/`

Docker ejecuta estos archivos en orden la primera vez que crea la base principal:

| Archivo | Contenido |
|---|---|
| `01-esquema.sql` | Estructura de todas las tablas y triggers de auditoría, exportada de la base del monolito (incluye las tablas creadas por sus migraciones). Sin datos |
| `02-catalogos.sql` | Datos de catálogo: roles, servicios, tarifas y la tabla de control de migraciones de Laravel |
| `03-datos-iniciales.sql` | Método de pago Efectivo y correlativo de recibos |
| `04-usuario-lectura.sh` | Crea el usuario de solo lectura con las credenciales de `.env` |

No se incluyen datos personales (clientes, contadores, lecturas, recibos, pagos ni usuarios). Los datos de prueba se cargan con el generador del equipo.

## Uso

1. Copiar `.env.example` como `.env` y cambiar las contraseñas.
2. Si usas Laragon, detener su MySQL (ocupa el puerto 3306).
3. Levantar:

   ```bash
   docker compose up -d
   docker compose ps
   ```

   Los dos contenedores deben quedar en estado `healthy`. La réplica arranca hasta que la principal está lista.

## Conexiones

| Quién | Host | Puerto | Usuario | Base |
|---|---|---|---|---|
| Monolito Laravel (`.env` sin cambios) | 127.0.0.1 | 3306 | root, sin contraseña | oficina_agua |
| Microservicios fuera de Docker | localhost | 3307 | `DB_LECTURA_USER` | oficina_agua |
| Microservicios dentro de Docker Compose | db-replica | 3306 | `DB_LECTURA_USER` | oficina_agua |

La contraseña vacía de root en la principal es solo para desarrollo local.

## Verificar la réplica

Estado de la replicación (las dos últimas líneas deben decir `Yes`):

```bash
docker exec db-replica mariadb -uroot -p<DB_REPLICA_ROOT_PASSWORD> -e "SHOW REPLICA STATUS\G" | grep -E "Running:"
```

Un cambio en la principal aparece en la réplica:

```bash
docker exec db-primary mariadb -uroot oficina_agua -e "INSERT INTO servicios (nombre, descripcion) VALUES ('Prueba replica', 'Temporal')"
docker exec db-replica mariadb -uroot -p<DB_REPLICA_ROOT_PASSWORD> oficina_agua -e "SELECT id, nombre FROM servicios"
docker exec db-primary mariadb -uroot oficina_agua -e "DELETE FROM servicios WHERE nombre = 'Prueba replica'"
```

El usuario de lectura no puede escribir:

```bash
docker exec db-replica mariadb -u<DB_LECTURA_USER> -p<DB_LECTURA_PASSWORD> oficina_agua -e "INSERT INTO servicios (nombre) VALUES ('x')"
```

Debe responder con un error de permisos.

## Empezar de cero

Borra los datos de ambas bases y las vuelve a crear desde `db/`:

```bash
docker compose down -v
docker compose up -d
```
