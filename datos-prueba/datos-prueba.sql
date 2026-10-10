-- =====================================================================
-- datos-prueba.sql
-- Ubicacion: oficina-agua-infra/datos-prueba/   (NO en db/, para que
-- Docker no lo ejecute solo al crear el volumen).
--
-- Llena la base con datos ficticios 2020-2026:
--   500 clientes, 600 contadores, 1 lectura + 1 recibo por contador/mes,
--   y un pago por cada recibo PAGADO.
--
-- Requisitos: base recien creada (docker compose up -d con db/ ya
-- aplicado: 01-esquema, 02-catalogos, 03-datos-iniciales).
-- Se corre UNA vez por volumen. Si se corre dos veces, falla en el
-- primer INSERT (email UNIQUE) y no cambia nada.
--
-- Determinista: sin RAND() ni NOW(). Todo sale de formulas sobre el
-- numero de fila y fechas fijas, asi que cada corrida da lo mismo.
-- Solo ASCII (sin tildes) para que PowerShell no dane el texto.
-- =====================================================================

SET NAMES utf8mb4;

-- ---- Parametros ajustables -----------------------------------------
SET @prefijo_recibo = 'REC-';          -- numero_recibo = prefijo + 6 digitos
SET @reciente_desde = '2026-07-01';    -- periodos >= esta fecha: "recientes"
SET @moroso_desde   = '2025-10-01';    -- contadores morosos deben desde aqui
-- --------------------------------------------------------------------

-- Ultimo id de auditoria ANTES de cargar (para limpiar al final).
SELECT COALESCE(MAX(id), 0) INTO @aud_max FROM auditoria;

START TRANSACTION;

-- 1. Usuarios de apoyo (rol 3 = Lector, rol 2 = Secretaria) ----------
-- El password NO es un hash valido: estos usuarios solo existen para
-- cumplir las FK (lecturas.usuario_lector_id, pagos.usuario_registro_id).
INSERT INTO users (rol_id, nombre, email, password, activo, created_at, updated_at)
VALUES
 (3, 'Lector de Prueba',     'lector.prueba@oficina-agua.test',     'SIN-LOGIN-DATOS-DE-PRUEBA', 1, '2020-01-01 08:00:00', '2020-01-01 08:00:00'),
 (2, 'Secretaria de Prueba', 'secretaria.prueba@oficina-agua.test', 'SIN-LOGIN-DATOS-DE-PRUEBA', 1, '2020-01-01 08:00:00', '2020-01-01 08:00:00');

SELECT id INTO @lector_id FROM users WHERE email = 'lector.prueba@oficina-agua.test';
SELECT id INTO @cajera_id FROM users WHERE email = 'secretaria.prueba@oficina-agua.test';

-- 2. Metodos de pago (Efectivo ya viene de 03-datos-iniciales.sql) ----
INSERT INTO metodos_pago (nombre, descripcion, activo)
VALUES
 ('Transferencia bancaria', 'Transferencia a la cuenta de la oficina', 1),
 ('Deposito bancario',      'Deposito en ventanilla de banco',         1);

SELECT id INTO @m_efectivo FROM metodos_pago WHERE nombre = 'Efectivo';
SELECT id INTO @m_transf   FROM metodos_pago WHERE nombre = 'Transferencia bancaria';
SELECT id INTO @m_deposito FROM metodos_pago WHERE nombre = 'Deposito bancario';

-- 3. Clientes: 500 (ids explicitos 1..500) ---------------------------
INSERT INTO clientes (id, nombre, dpi, telefono, direccion_principal, activo, created_at, updated_at, nit)
SELECT
  seq,
  CONCAT(
    ELT(MOD(seq, 20) + 1, 'Juan','Maria','Jose','Ana','Luis','Rosa','Carlos','Elena','Pedro','Lucia',
                          'Miguel','Sofia','Jorge','Carmen','Diego','Marta','Oscar','Silvia','Victor','Gloria'),
    ' ',
    ELT(MOD(seq DIV 20, 20) + 1, 'Lopez','Garcia','Martinez','Perez','Gonzalez','Rodriguez','Hernandez',
                                 'Ramirez','Morales','Castillo','Mendoza','Sandoval','Cifuentes','Barrios',
                                 'Ortiz','Reyes','Flores','Giron','Estrada','Aguilar'),
    ' ',
    ELT(MOD(seq * 3, 10) + 1, 'Ajanel','Tzoc','Xiloj','Cux','Batz','Tum','Sac','Ixcoy','Coc','Choc')
  ),
  CONCAT('20', LPAD(seq, 11, '0')),                              -- 13 digitos, unico
  CONCAT('5', LPAD(MOD(seq * 7919, 10000000), 7, '0')),          -- 8 digitos
  CONCAT('Barrio ', ELT(MOD(seq, 5) + 1, 'Centro','Norte','Sur','Oriente','Occidente'),
         ', zona ', MOD(seq, 9) + 1, ', casa ', seq),
  1,
  '2020-01-01 08:00:00', '2020-01-01 08:00:00',
  IF(MOD(seq, 5) = 0, NULL, CONCAT(100000 + seq * 7, '-', MOD(seq, 10)))   -- NIT unico o NULL
FROM seq_1_to_500
ORDER BY seq;

-- 4. Contadores: 600 (ids explicitos 1..600, CONT-001 .. CONT-600) ----
-- Cliente = ((n-1) mod 500) + 1  -> los primeros 100 clientes tienen 2.
-- Tarifa: 60% tarifa 1 (media paja), 40% tarifa 2 (una paja).
-- Alta escalonada: contador n empieza en el mes (n mod 6) * 6, contando
-- desde 2020-01. Con eso salen ~39,600 recibos en total.
INSERT INTO contadores (id, cliente_id, tarifa_id, servicio_id, numero_registro, lectura_inicial,
                        direccion_servicio, punto_referencia, foto_ruta, sector, activo, created_at, updated_at)
SELECT
  seq,
  MOD(seq - 1, 500) + 1,
  IF(MOD(seq, 5) < 3, 1, 2),
  1,                                                             -- Agua potable
  CONCAT('CONT-', LPAD(seq, 3, '0')),
  100 + MOD(seq * 13, 400),
  CONCAT('Calle ', MOD(seq, 20) + 1, ' Avenida ', MOD(seq, 12) + 1, ' casa ', seq),
  NULL,
  NULL,
  ELT(MOD(seq, 5) + 1, 'Centro','Norte','Sur','Oriente','Occidente'),
  1,
  TIMESTAMP(DATE_ADD('2020-01-01', INTERVAL MOD(seq, 6) * 6 MONTH), '08:00:00'),
  TIMESTAMP(DATE_ADD('2020-01-01', INTERVAL MOD(seq, 6) * 6 MONTH), '08:00:00')
FROM seq_1_to_600
ORDER BY seq;

-- 5. Lecturas: 2020-01 a 2026-09 (81 meses posibles) ------------------
-- periodo = dia 1 del mes; fecha_lectura = dia 25 del mismo mes.
-- consumo = base segun tarifa + fraccion (0, .25, .5, .75).
--   tarifa 1: 14..35 m3 (capacidad 30 -> a veces hay exceso)
--   tarifa 2: 35..74 m3 (capacidad 60 -> a veces hay exceso)
-- lectura_actual es el acumulado del contador; la primera lectura
-- parte de contadores.lectura_inicial. Se insertan por mes y contador
-- para que los ids queden en orden cronologico.
INSERT INTO lecturas (contador_id, usuario_lector_id, periodo, fecha_lectura,
                      lectura_anterior, lectura_actual, consumo_m3, observacion, created_at, updated_at)
SELECT
  x.contador_id, @lector_id, x.periodo, x.fecha_lectura,
  x.lectura_inicial + x.acum - x.consumo,
  x.lectura_inicial + x.acum,
  x.consumo,
  NULL, x.fecha_lectura, x.fecha_lectura
FROM (
  SELECT b.contador_id, b.lectura_inicial, b.k, b.periodo, b.fecha_lectura, b.consumo,
         SUM(b.consumo) OVER (PARTITION BY b.contador_id ORDER BY b.k) AS acum
  FROM (
    SELECT c.id AS contador_id, c.lectura_inicial, m.k, m.periodo,
           DATE_ADD(m.periodo, INTERVAL 24 DAY) AS fecha_lectura,
           (CASE WHEN c.tarifa_id = 1 THEN 14 + MOD(c.id * 7 + m.k * 5, 22)
                 ELSE                      35 + MOD(c.id * 7 + m.k * 5, 40) END)
           + MOD(c.id + m.k, 4) * 0.25 AS consumo
    FROM contadores c
    JOIN (SELECT seq - 1 AS k,
                 DATE_ADD('2020-01-01', INTERVAL (seq - 1) MONTH) AS periodo
          FROM seq_1_to_81) m
      ON m.k >= MOD(c.id, 6) * 6
  ) b
) x
ORDER BY x.k, x.contador_id;

-- 6. Recibos: uno por lectura -----------------------------------------
-- monto: si consumo <= capacidad -> consumo * precio_por_m3;
--        si no -> capacidad * precio + excedente * precio_exceso (o precio base si es NULL).
-- fecha_emision = fecha_lectura (como en el monolito: misma transaccion).
-- Estado:
--   ANULADO   1 de cada 47 recibos
--   Recientes (periodo >= @reciente_desde): PENDIENTE; PAGADO si contador mod 4 = 0
--             y el periodo es anterior a 2026-09
--   Morosos   (contador mod 25 = 0, periodo >= @moroso_desde): PENDIENTE
--   Resto: PAGADO
INSERT INTO recibos (lectura_id, tarifa_id, numero_recibo, fecha_emision, monto, estado, observacion, created_at, updated_at)
SELECT
  r.lectura_id,
  r.tarifa_id,
  CONCAT(@prefijo_recibo, LPAD(r.rn, 6, '0')),
  r.fecha_emision,
  r.monto,
  CASE
    WHEN MOD(r.rn, 47) = 0                                   THEN 'ANULADO'
    WHEN r.periodo >= @reciente_desde
         THEN IF(MOD(r.contador_id, 4) = 0 AND r.periodo < '2026-09-01', 'PAGADO', 'PENDIENTE')
    WHEN MOD(r.contador_id, 25) = 0 AND r.periodo >= @moroso_desde THEN 'PENDIENTE'
    ELSE 'PAGADO'
  END,
  IF(MOD(r.rn, 47) = 0, 'Anulado (dato de prueba)', NULL),
  r.fecha_emision,
  r.fecha_emision
FROM (
  SELECT l.id AS lectura_id, l.contador_id, l.periodo, l.fecha_lectura AS fecha_emision,
         c.tarifa_id,
         ROW_NUMBER() OVER (ORDER BY l.id) AS rn,
         ROUND(CASE
                 WHEN l.consumo_m3 <= t.capacidad
                   THEN l.consumo_m3 * t.precio_por_m3
                 ELSE t.capacidad * t.precio_por_m3
                      + (l.consumo_m3 - t.capacidad) * COALESCE(t.precio_exceso_m3, t.precio_por_m3)
               END, 2) AS monto
  FROM lecturas l
  JOIN contadores c ON c.id = l.contador_id
  JOIN tarifas    t ON t.id = c.tarifa_id
) r
ORDER BY r.rn;

-- 7. Pagos: uno por cada recibo PAGADO --------------------------------
-- monto = monto del recibo. fecha_pago = emision + 1..25 dias, entre las
-- 08:00 y las 17:59 (siempre anterior a hoy). Metodo: 70% efectivo,
-- 20% transferencia, 10% deposito.
INSERT INTO pagos (recibo_id, usuario_registro_id, monto, fecha_pago, referencia, observacion,
                   created_at, updated_at, metodo_pago_id)
SELECT
  p.id, @cajera_id, p.monto, p.fecha_pago,
  CASE p.metodo WHEN 'T' THEN CONCAT('TRF-', LPAD(p.id, 7, '0'))
                WHEN 'D' THEN CONCAT('DEP-', LPAD(p.id, 7, '0'))
                ELSE NULL END,
  NULL,
  p.fecha_pago, p.fecha_pago,
  CASE p.metodo WHEN 'T' THEN @m_transf WHEN 'D' THEN @m_deposito ELSE @m_efectivo END
FROM (
  SELECT r.id, r.monto,
         TIMESTAMP(DATE_ADD(r.fecha_emision, INTERVAL (1 + MOD(r.id, 25)) DAY),
                   SEC_TO_TIME(28800 + MOD(r.id * 37, 36000))) AS fecha_pago,
         CASE WHEN MOD(r.id, 10) < 7 THEN 'E' WHEN MOD(r.id, 10) < 9 THEN 'T' ELSE 'D' END AS metodo
  FROM recibos r
  WHERE r.estado = 'PAGADO'
) p
ORDER BY p.id;

-- 8. Correlativo: que el proximo recibo del monolito no choque --------
UPDATE correlativos_documentos
SET ultimo_numero = (SELECT COUNT(*) FROM recibos)
WHERE tipo = 'RECIBO';

-- 9. Auditoria: quitar lo que generaron los triggers de esta carga ----
-- (son datos historicos simulados, no acciones de usuarios reales).
-- Si prefieres conservar esas filas, borra este DELETE y el ALTER de abajo.
DELETE FROM auditoria WHERE id > @aud_max;

COMMIT;

SET @sql_ai = CONCAT('ALTER TABLE auditoria AUTO_INCREMENT = ', @aud_max + 1);
PREPARE st FROM @sql_ai;
EXECUTE st;
DEALLOCATE PREPARE st;

-- 10. Resumen para verificar -----------------------------------------
SELECT 'clientes' AS tabla, COUNT(*) AS filas FROM clientes
UNION ALL SELECT 'contadores', COUNT(*) FROM contadores
UNION ALL SELECT 'lecturas',   COUNT(*) FROM lecturas
UNION ALL SELECT 'recibos',    COUNT(*) FROM recibos
UNION ALL SELECT 'pagos',      COUNT(*) FROM pagos
UNION ALL SELECT 'auditoria',  COUNT(*) FROM auditoria;

SELECT estado, COUNT(*) AS recibos, SUM(monto) AS total FROM recibos GROUP BY estado ORDER BY estado;

SELECT tipo, ultimo_numero FROM correlativos_documentos;
