/*
================================================================================
DEPLOYED (2026-07-12) — IR general-ledger posting for the LIVE CreateP21Receipts
inline script, so ADF-created vessel receipts post GL the same way the P21 GUI does.

Pipeline : LIVE_Coats_Mexico_Shipment_Stage_And_Validate
Path     : IfBlockingValidationIssues (ifFalse) -> CreateP21Receipts [Script, SqlServer1 / coats_automation]
Target   : P21 (the script has already done USE P21; before this point)

This file is the reference for what is live, with exact placement relative to the
current script's structure. Permissions (verified for coats_automation): db_datawriter
(INSERT gl/balances), db_datareader (SELECT periods/balances), EXECUTE ON SCHEMA::dbo
(p21_get_counter). No new grant and no CREATE PROCEDURE — everything stays inline.

Three insertion points. Fragment 3 provisions dbo.balances (carry-forward) before the
GL insert, satisfying fk_gl_balances; the t_gl_iu trigger then rolls the amounts in.
================================================================================
*/


/*------------------------------------------------------------------------------
FRAGMENT 1 — new variables.
Placed in the DECLARE block, immediately before `, @CounterLoop int;`.
------------------------------------------------------------------------------*/
        , @GlApAccount        varchar(32)  = '2161000'   -- credit: A/P - Vessel/Container - Coats
        , @GlInTransitAccount varchar(32)  = '1345210'   -- debit : Inventory In Transit To Locations
        , @GlPostingPeriod    int
        , @GlPostingYear      int
        , @GlPostingDate      datetime
        , @GlUid1             bigint
        , @GlUid2             bigint
        , @GlTransactionNumber bigint
        , @GlAmount           decimal(19,4)


/*------------------------------------------------------------------------------
FRAGMENT 2 — resolve OPEN period + allocate gl counters.
Placed immediately BEFORE `BEGIN TRAN;`. Resolving the period here aborts BEFORE any
receipt row is created if no open period exists, so a vessel receipt is never created
without its GL. Mirrors the script's @UseDirectSequenceCounters counter toggle.
------------------------------------------------------------------------------*/
    SET @GlPostingDate = @Now;

    SELECT TOP (1)
          @GlPostingPeriod = p.period
        , @GlPostingYear   = p.year_for_period
    FROM dbo.periods AS p
    WHERE p.company_no    = @CompanyId
      AND p.period_closed = 'N'
      AND @GlPostingDate >= p.beginning_date
      AND @GlPostingDate <  DATEADD(day, 1, p.ending_date)
    ORDER BY p.year_for_period, p.period;

    IF @GlPostingPeriod IS NULL
        THROW 52020, 'No OPEN GL period contains the posting date; refusing to create receipts without GL. Open the current period and re-run.', 1;

    IF @UseDirectSequenceCounters = 1
    BEGIN
        SELECT @GlUid1 = NEXT VALUE FOR dbo.seq_gl;
        SELECT @GlUid2 = NEXT VALUE FOR dbo.seq_gl;
    END
    ELSE
    BEGIN
        EXEC dbo.p21_get_counter
             @strCounterID = 'gl'
           , @iIncrementValue = 2
           , @LastValue = @LastValue OUTPUT;
        SET @GlUid1 = @LastValue - 1;
        SET @GlUid2 = @LastValue;
    END;

    IF @UseDirectSequenceCounters = 1
        SELECT @GlTransactionNumber = NEXT VALUE FOR dbo.seq_gl_transaction_number;
    ELSE
    BEGIN
        EXEC dbo.p21_get_counter
             @strCounterID = 'gl_transaction_number'
           , @iIncrementValue = 1
           , @LastValue = @LastValue OUTPUT;
        SET @GlTransactionNumber = @LastValue;
    END;


/*------------------------------------------------------------------------------
FRAGMENT 3 — amount, ensure balances (carry-forward), post the IR pair.
Placed INSIDE the transaction, immediately BEFORE `INSERT INTO dbo.oe_line_po`
(right after the vessel_receipts_line insert). Same transaction as the receipt
inserts => GL posts atomically with the vessel receipt.
------------------------------------------------------------------------------*/
        SELECT @GlAmount = ROUND(SUM(vl.po_sku_cost * vl.container_qty_received), 2)
        FROM dbo.vessel_receipts_line AS vl
        WHERE vl.vessel_receipts_hdr_uid = @VesselReceiptsHdrUid;

        IF @GlAmount IS NULL OR @GlAmount <= 0
            THROW 52021, 'Computed GL amount is null/non-positive; rolling back receipt creation.', 1;

        -- Provision missing dbo.balances rows exactly as P21's posting does
        -- (verified via capture DIFF 6->7): cumulative = latest prior-period cumulative
        -- (carry-forward; 0 if none), period_balance = 0. Satisfies fk_gl_balances;
        -- the t_gl_iu trigger then rolls the posted amounts in. Idempotent.
        INSERT INTO dbo.balances
        (
              company_no, account_no, period, year_for_period, currency_id,
              cumulative_balance, period_balance,
              budget_1, budget_2, budget_3,
              delete_flag, date_created, date_last_modified, last_maintained_by,
              encumbered_balance, encumbered_this_period, date_budget_changed,
              cumulative_budget_1, cumulative_budget_2, cumulative_budget_3
        )
        SELECT
              @CompanyId, acct.account_no, @GlPostingPeriod, @GlPostingYear, 1,
              COALESCE(carry.cumulative_balance, 0), 0,
              0, 0, 0,
              'N', @Now, @Now, @CreatedBy,
              0, 0, CONVERT(datetime, '1980-01-01'),
              0, 0, 0
        FROM (VALUES (@GlApAccount), (@GlInTransitAccount)) AS acct(account_no)
        OUTER APPLY
        (
            SELECT TOP (1) b.cumulative_balance
            FROM dbo.balances AS b
            WHERE b.company_no = @CompanyId
              AND b.account_no = acct.account_no
              AND b.currency_id = 1
              AND (b.year_for_period < @GlPostingYear
                   OR (b.year_for_period = @GlPostingYear AND b.period < @GlPostingPeriod))
            ORDER BY b.year_for_period DESC, b.period DESC
        ) AS carry
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.balances AS x
            WHERE x.company_no = @CompanyId
              AND x.account_no = acct.account_no
              AND x.period = @GlPostingPeriod
              AND x.year_for_period = @GlPostingYear
              AND x.currency_id = 1
        );

        INSERT INTO dbo.gl
        ( gl_uid, company_no, account_number, period, year_for_period, journal_id
        , amount, source, description, date_created, date_last_modified, last_maintained_by
        , currency_id, foreign_amount, transaction_date, transaction_number, approved
        , sequence_number, encumbered_amount, foreign_encumbered_amount, source_type_cd
        , group_number, created_by )
        SELECT
              CASE WHEN v.seq = 1 THEN @GlUid1 ELSE @GlUid2 END
            , @CompanyId
            , CASE WHEN v.seq = 1 THEN @GlApAccount ELSE @GlInTransitAccount END
            , @GlPostingPeriod
            , @GlPostingYear
            , 'IR'
            , CASE WHEN v.seq = 1 THEN -@GlAmount ELSE @GlAmount END
            , CONVERT(varchar(50), @VesselReceiptsHdrUid)
            , @ContainerName
            , @Now
            , @Now
            , @CreatedBy
            , 1
            , CASE WHEN v.seq = 1 THEN -@GlAmount ELSE @GlAmount END
            , @GlPostingDate
            , @GlTransactionNumber
            , 'Y'
            , v.seq
            , 0
            , 0
            , 1674
            , 1
            , @CreatedBy
        FROM (VALUES (1),(2)) AS v(seq);
