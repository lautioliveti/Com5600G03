/*
------------------------------------------------------------
Trabajo Práctico Integrador - ENTREGA 5
Comisión: 5600
Grupo: 03
Materia: Bases de Datos Aplicada
Integrantes: 
Apellido y Nombre             - Github          - DNI
Villan Matias Nicolas         - MatiasKV0       - 46117338
Lucas Tadeo Messina           - TotoMessina     - 44552900
Oliveti Lautaro Nahuel        - lautioliveti    - 43863497
Mamani Estrada Lucas Gabriel  - lucasGME        - 43624305
Sotelo Matias Ivan            - MatiSotelo2004  - 45870010
------------------------------------------------------------
*/

USE Com5600G03;
GO

CREATE OR ALTER PROCEDURE banco.importar_conciliar_pagos
    @RutaArchivo NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------
    -- 1) Cargar CSV
    ---------------------------------------------------------
    IF OBJECT_ID('tempdb..#PagosCSV') IS NOT NULL DROP TABLE #PagosCSV;
    
    CREATE TABLE #PagosCSV (
        id_pago_externo VARCHAR(50),
        fecha_texto VARCHAR(20),
        cbu_origen VARCHAR(100),
        valor_texto VARCHAR(50)
    );

    DECLARE @SQL NVARCHAR(MAX);
    SET @SQL = '
        BULK INSERT #PagosCSV
        FROM ''' + @RutaArchivo + '''
        WITH (
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''\n'',
            FIRSTROW = 2,
            CODEPAGE = ''65001''
        );
    ';

    BEGIN TRY
        EXEC (@SQL);
    END TRY
    BEGIN CATCH
        PRINT 'Error al cargar el CSV: ' + ERROR_MESSAGE();
        RETURN -1;
    END CATCH;

   
    DELETE FROM #PagosCSV WHERE id_pago_externo IS NULL OR LEN(id_pago_externo) = 0;

    ---------------------------------------------------------
    -- 2) Procesar y Vincular 
    ---------------------------------------------------------
    IF OBJECT_ID('tempdb..#PagosProcesados') IS NOT NULL DROP TABLE #PagosProcesados;

    SELECT
        csv.id_pago_externo,
        LTRIM(RTRIM(csv.cbu_origen)) AS cbu_origen, -- Texto plano
        CONVERT(DATE, csv.fecha_texto, 103) AS fecha_pago,
        TRY_CAST(
            REPLACE(REPLACE(LTRIM(RTRIM(csv.valor_texto)), '$', ''), '.', '')
            AS NUMERIC(14,2)
        ) AS importe_pago,

        
        ufc.uf_id,
        uf.consorcio_id AS consorcio_id_origen,
        cb_origen.cuenta_id AS cuenta_origen_id,
        ccb_principal.cuenta_id AS cuenta_destino_id,

        
        CASE 
            WHEN cb_origen.cuenta_id IS NULL THEN 'CBU no existe en BD'
            WHEN ufc.uf_id IS NULL THEN 'CBU existe pero no tiene UF vinculada'
            ELSE NULL 
        END AS motivo_no_vinculado

    INTO #PagosProcesados
    FROM #PagosCSV csv
   
    LEFT JOIN administracion.cuenta_bancaria cb_origen 
        ON cb_origen.cbu_cvu = LTRIM(RTRIM(csv.cbu_origen))
    LEFT JOIN unidad_funcional.uf_cuenta ufc 
        ON cb_origen.cuenta_id = ufc.cuenta_id AND ufc.fecha_hasta IS NULL
    LEFT JOIN unidad_funcional.unidad_funcional uf 
        ON uf.uf_id = ufc.uf_id
    LEFT JOIN administracion.consorcio_cuenta_bancaria ccb_principal
        ON ccb_principal.consorcio_id = uf.consorcio_id
       AND ccb_principal.es_principal = 1;

    ---------------------------------------------------------
    -- 3) Insertar Movimientos 
    ---------------------------------------------------------
    DECLARE @MovimientosInsertados TABLE (
        movimiento_id INT,
        id_externo VARCHAR(50)
    );

    
    MERGE INTO banco.banco_movimiento AS Target
    USING (
        SELECT * FROM #PagosProcesados p
        
        WHERE NOT EXISTS (SELECT 1 FROM banco.pago px WHERE px.id_pago_externo = p.id_pago_externo)
    ) AS Source
    ON 1 = 0 
    WHEN NOT MATCHED THEN
        INSERT (
            consorcio_id,
            cuenta_id,
            cbu_origen, 
            fecha,
            importe,
            estado_conciliacion
        )
        VALUES (
            Source.consorcio_id_origen, 
            Source.cuenta_destino_id,   
            Source.cbu_origen,          
            Source.fecha_pago,
            Source.importe_pago,
            CASE WHEN Source.uf_id IS NOT NULL THEN 'ASOCIADO' ELSE 'NO_ASOCIADO' END
        )
        OUTPUT inserted.movimiento_id, Source.id_pago_externo 
        INTO @MovimientosInsertados (movimiento_id, id_externo);

    PRINT 'Movimientos insertados: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

    ---------------------------------------------------------
    -- 4) Insertar Pagos
    ---------------------------------------------------------
    INSERT INTO banco.pago (
        uf_id,
        fecha,
        importe,
        tipo,
        movimiento_id,
        motivo_no_asociado,
        created_by,
        id_pago_externo
    )
    SELECT
        p.uf_id, 
        p.fecha_pago,
        p.importe_pago,
        'ORDINARIO',
        mi.movimiento_id,
        p.motivo_no_vinculado,
        'SP_Importar',
        p.id_pago_externo
    FROM #PagosProcesados p
    INNER JOIN @MovimientosInsertados mi ON p.id_pago_externo = mi.id_externo;

    PRINT 'Pagos registrados: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

    DROP TABLE #PagosCSV;
    DROP TABLE #PagosProcesados;
END;
GO


-----------------------------------------------------------------------
----  LLENAR EXPENSAS Y SIMULAR DEUDA
----------------------------------------------------------------------
CREATE OR ALTER PROCEDURE expensa.llenar_expensas
AS
BEGIN
    SET NOCOUNT ON;
	
	BEGIN TRY 
    INSERT INTO expensa.expensa_uf (
        periodo_id,
        uf_id,
        porcentaje,
        saldo_anterior_abonado,
        pagos_recibidos,
        deuda_anterior,
        interes_mora,
        expensas_ordinarias,
        expensas_extraordinarias,
        total_a_pagar,
        created_at,
        created_by
    )
    SELECT 
        per.periodo_id,
        uf.uf_id,
        uf.porcentaje,
        0 AS saldo_anterior_abonado,
        
        -- Pagos recibidos en ese mes (de la tabla banco.pago)
        ISNULL((
            SELECT SUM(p.importe)
            FROM banco.pago p
            WHERE p.uf_id = uf.uf_id
                AND YEAR(p.fecha) = per.anio
                AND MONTH(p.fecha) = per.mes
        ), 0) AS pagos_recibidos,
        
        -- Deuda anterior simulada (30% de las unidades funcionales con deuda) para poder probar los reportes
        CASE 
            WHEN uf.uf_id % 3 = 0 THEN ROUND(50000 + (uf.uf_id * 1234.56), 2)
            WHEN uf.uf_id % 5 = 0 THEN ROUND(30000 + (uf.uf_id * 789.12), 2)
            ELSE 0
        END AS deuda_anterior,
        
        -- Interes de mora (2% entre vtos, 5% post 2do vto)
        CASE 
            WHEN uf.uf_id % 3 = 0 THEN 
                ROUND((50000 + (uf.uf_id * 1234.56)) * per.interes_post_2do_pct / 100, 2)
            WHEN uf.uf_id % 5 = 0 THEN 
                ROUND((30000 + (uf.uf_id * 789.12)) * per.interes_entre_vtos_pct / 100, 2)
            ELSE 0
        END AS interes_mora,
        
       -- Expensas ordinarias 
        ISNULL((
            SELECT SUM(g.importe)
            FROM expensa.gasto g
            INNER JOIN expensa.tipo_gasto tg ON g.tipo_id = tg.tipo_id
            WHERE g.periodo_id = per.periodo_id
              AND g.consorcio_id = uf.consorcio_id
              AND tg.nombre = 'GASTOS ORDINARIOS'
        ), 0) AS expensas_ordinarias,

        -- Expensas extraordinarias
        ISNULL((
            SELECT SUM(g.importe)
            FROM expensa.gasto g
            INNER JOIN expensa.tipo_gasto tg ON g.tipo_id = tg.tipo_id
            WHERE g.periodo_id = per.periodo_id
              AND g.consorcio_id = uf.consorcio_id
              AND tg.nombre = 'GASTOS EXTRAORDINARIOS'
        ), 0) AS expensas_extraordinarias,
        
        -- Total a pagar
         ROUND(
            -- Deuda anterior
            (
                CASE 
                    WHEN uf.uf_id % 3 = 0 THEN (50000 + (uf.uf_id * 1234.56))
                    WHEN uf.uf_id % 5 = 0 THEN (30000 + (uf.uf_id * 789.12))
                    ELSE 0
                END
            ) +
            -- Interés de mora
            (
                CASE 
                    WHEN uf.uf_id % 3 = 0 THEN ((50000 + (uf.uf_id * 1234.56)) * per.interes_post_2do_pct / 100)
                    WHEN uf.uf_id % 5 = 0 THEN ((30000 + (uf.uf_id * 789.12)) * per.interes_entre_vtos_pct / 100)
                    ELSE 0
                END
            ) +
            -- Expensas ordinarias
            ISNULL((
                SELECT SUM(g.importe)
                FROM expensa.gasto g
                INNER JOIN expensa.tipo_gasto tg ON g.tipo_id = tg.tipo_id
                WHERE g.periodo_id = per.periodo_id
                    AND g.consorcio_id = uf.consorcio_id
                    AND tg.nombre = 'GASTOS ORDINARIOS'
            ), 0) +
            -- Expensas extraordinarias
            ISNULL((
                SELECT SUM(g.importe)
                FROM expensa.gasto g
                INNER JOIN expensa.tipo_gasto tg ON g.tipo_id = tg.tipo_id
                WHERE g.periodo_id = per.periodo_id
                    AND g.consorcio_id = uf.consorcio_id
                    AND tg.nombre = 'GASTOS EXTRAORDINARIOS'
            ), 0)
        , 2) AS total_a_pagar,
        
        GETDATE(),
        'SP-LLENAR_EXPENSAS'

    FROM unidad_funcional.unidad_funcional uf
    CROSS JOIN expensa.periodo per
    WHERE uf.consorcio_id = per.consorcio_id
        AND EXISTS (
            SELECT 1 FROM expensa.gasto g 
            WHERE g.periodo_id = per.periodo_id
        );
    
    -- Generar detalles de expensas
    INSERT INTO expensa.expensa_uf_detalle (
        expensa_uf_id,
        gasto_id,
        concepto,
        importe
    )
    SELECT 
        eu.expensa_uf_id,
        g.gasto_id,
        sg.nombre AS concepto,
        g.importe
    FROM expensa.expensa_uf eu
    INNER JOIN unidad_funcional.unidad_funcional uf ON eu.uf_id = uf.uf_id
    INNER JOIN expensa.gasto g ON g.periodo_id = eu.periodo_id 
        AND g.consorcio_id = uf.consorcio_id
    INNER JOIN expensa.sub_tipo_gasto sg ON g.sub_id = sg.sub_id;
    
    -- Generar intereses

    INSERT INTO expensa.expensa_uf_interes (
        expensa_uf_id,
        tipo,
        porcentaje,
        importe
    )
    SELECT 
        eu.expensa_uf_id,
        CASE WHEN eu.uf_id % 3 = 0 THEN 'POST_2DO' ELSE 'ENTRE_VTOS' END AS tipo,
        CASE WHEN eu.uf_id % 3 = 0 THEN 5.000 ELSE 2.000 END AS porcentaje,
        eu.interes_mora
    FROM expensa.expensa_uf eu
    WHERE eu.interes_mora > 0;
	END TRY
	BEGIN CATCH
	 print 'Pagos importados'
	END CATCH	
END;
GO


--------------------------------------------------------------------
--Generar liquidacion de expensa para un mes
--------------------------------------------------------------------

CREATE OR ALTER PROCEDURE expensa.generar_liquidacion_mensual
    @ConsorcioId INT,
    @Anio INT,
    @Mes INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- 1. VALIDACIONES DE PERIODO
    DECLARE @PeriodoId INT;
    SELECT @PeriodoId = periodo_id 
    FROM expensa.periodo 
    WHERE consorcio_id = @ConsorcioId AND anio = @Anio AND mes = @Mes;

    IF @PeriodoId IS NULL
    BEGIN
        RAISERROR('El periodo solicitado no existe. Ejecute primero administracion.crear_periodos.', 16, 1);
        RETURN;
    END


    IF EXISTS (SELECT 1 FROM expensa.expensa_uf WHERE periodo_id = @PeriodoId)
    BEGIN
        
        SELECT 
            periodo_id,
            uf_id,
            porcentaje,
            saldo_anterior_abonado,
            pagos_recibidos,
            deuda_anterior,
            interes_mora,
            expensas_ordinarias,
            expensas_extraordinarias,
            total_a_pagar,
            created_by 
        FROM expensa.expensa_uf 
        WHERE periodo_id = @PeriodoId;

        RETURN;
    END

    DECLARE @InteresMora DECIMAL(5,2); 
    SELECT @InteresMora = interes_post_2do_pct FROM expensa.periodo WHERE periodo_id = @PeriodoId;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 2. LIMPIEZA
        DELETE d FROM expensa.expensa_uf_detalle d
        INNER JOIN expensa.expensa_uf e ON d.expensa_uf_id = e.expensa_uf_id
        WHERE e.periodo_id = @PeriodoId;

        DELETE i FROM expensa.expensa_uf_interes i
        INNER JOIN expensa.expensa_uf e ON i.expensa_uf_id = e.expensa_uf_id
        WHERE e.periodo_id = @PeriodoId;

        DELETE FROM expensa.expensa_uf WHERE periodo_id = @PeriodoId;

        -- 3. CÁLCULO DE TOTALES A DISTRIBUIR
        DECLARE @TotalOrdinario NUMERIC(14,2) = 0;
        DECLARE @TotalExtraordinario NUMERIC(14,2) = 0;

        -- Sumar Gastos Ordinarios
        SELECT @TotalOrdinario = ISNULL(SUM(g.importe), 0)
        FROM expensa.gasto g
        INNER JOIN expensa.sub_tipo_gasto st ON g.sub_id = st.sub_id
        INNER JOIN expensa.tipo_gasto t ON st.tipo_id = t.tipo_id
        WHERE g.periodo_id = @PeriodoId 
          AND t.nombre = 'GASTOS ORDINARIOS';

        -- Sumar Gastos Extraordinarios
        SELECT @TotalExtraordinario = ISNULL(SUM(g.importe), 0)
        FROM expensa.gasto g
        INNER JOIN expensa.sub_tipo_gasto st ON g.sub_id = st.sub_id
        INNER JOIN expensa.tipo_gasto t ON st.tipo_id = t.tipo_id
        WHERE g.periodo_id = @PeriodoId 
          AND t.nombre = 'GASTOS EXTRAORDINARIOS';

        IF (@TotalOrdinario = 0 AND @TotalExtraordinario = 0)
        BEGIN
            ROLLBACK TRANSACTION;
            RAISERROR('No se encontraron gastos cargados para este periodo. Cargue los gastos antes de liquidar.', 16, 1);
            RETURN;
        END;

        -- 4. GENERACIÓN DE LA EXPENSA POR UF
        INSERT INTO expensa.expensa_uf (
            periodo_id,
            uf_id,
            porcentaje,
            saldo_anterior_abonado,
            pagos_recibidos,
            deuda_anterior,
            interes_mora,
            expensas_ordinarias,
            expensas_extraordinarias,
            total_a_pagar,
            created_by
        )
        SELECT 
            @PeriodoId,
            uf.uf_id,
            uf.porcentaje,
            0, 
            0, 
            -- Deuda Anterior
            ISNULL((
                SELECT TOP 1 (prev.total_a_pagar - prev.pagos_recibidos)
                FROM expensa.expensa_uf prev
                JOIN expensa.periodo p_prev ON prev.periodo_id = p_prev.periodo_id
                WHERE prev.uf_id = uf.uf_id 
                  AND p_prev.consorcio_id = @ConsorcioId
                  AND (p_prev.anio < @Anio OR (p_prev.anio = @Anio AND p_prev.mes < @Mes))
                ORDER BY p_prev.anio DESC, p_prev.mes DESC
            ), 0),
            0, 
            -- Ordinario
            CAST((@TotalOrdinario * uf.porcentaje / 100.0) AS NUMERIC(14,2)),
            -- Extraordinario
            CAST((@TotalExtraordinario * uf.porcentaje / 100.0) AS NUMERIC(14,2)),
            0, 
            'SP_LIQUIDACION'
        FROM unidad_funcional.unidad_funcional uf
        WHERE uf.consorcio_id = @ConsorcioId;

        -- 5. ACTUALIZAR INTERESES Y TOTAL FINAL
        UPDATE expensa.expensa_uf
        SET 
            interes_mora = CASE 
                WHEN deuda_anterior > 0 THEN ROUND(deuda_anterior * (@InteresMora / 100.0), 2)
                ELSE 0 
            END,
            total_a_pagar = deuda_anterior 
                          + CASE WHEN deuda_anterior > 0 THEN ROUND(deuda_anterior * (@InteresMora / 100.0), 2) ELSE 0 END
                          + expensas_ordinarias 
                          + expensas_extraordinarias
        WHERE periodo_id = @PeriodoId;

        -- 6. GENERAR DETALLE DE GASTOS
        INSERT INTO expensa.expensa_uf_detalle (expensa_uf_id, gasto_id, concepto, importe)
        SELECT 
            e.expensa_uf_id,
            g.gasto_id,
            CONCAT(st.nombre, ': ', ISNULL(g.detalle, 'Sin detalle')),
            CAST((g.importe * e.porcentaje / 100.0) AS NUMERIC(14,2))
        FROM expensa.expensa_uf e
        CROSS JOIN expensa.gasto g
        INNER JOIN expensa.sub_tipo_gasto st ON g.sub_id = st.sub_id
        WHERE e.periodo_id = @PeriodoId 
          AND g.periodo_id = @PeriodoId
          AND g.consorcio_id = @ConsorcioId;

        COMMIT TRANSACTION;
        
        SELECT * FROM expensa.expensa_uf WHERE periodo_id = @PeriodoId;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        PRINT 'Error al liquidar expensas: ' + ERROR_MESSAGE();
    END CATCH
END;
GO