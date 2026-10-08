-- Datos minimos para que el monolito funcione sobre una base vacia.

-- Metodo de pago habilitado en el sistema.
INSERT INTO metodos_pago (nombre, descripcion, activo)
VALUES ('Efectivo', 'Pago en efectivo en la Oficina Municipal de Agua', 1);

-- Correlativo de recibos: GeneradorNumeroRecibo falla si no existe.
INSERT INTO correlativos_documentos (tipo, ultimo_numero, created_at, updated_at)
VALUES ('RECIBO', 0, NOW(), NOW());
