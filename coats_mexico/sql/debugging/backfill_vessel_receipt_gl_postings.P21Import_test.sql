/*
================================================================================
TEST VARIANT (P21Import) — Backfill missing Inventory Receipts (IR) GL postings
for ADF-created Coats vessel receipts.

This copy targets P21Import (every reference is P21Import.dbo.*), NOT production.
Use it to dry-run the full @Apply=1 path against the test copy — which carries
the same t_gl_iu insert trigger and its own isolated counters — before running
the production script backfill_vessel_receipt_gl_postings.sql.

Caveats specific to testing here:
 - hdr 765 already has a GL pair in P21Import (from the earlier GUI capture test),
   so the idempotency guard will SKIP it here. That is expected.
 - 762/763/764 may or may not exist in this P21Import copy depending on when it
   was refreshed; the preview will show what it actually finds.
 - P21Import's period-open status and gl/gl_transaction_number counters are
   independent of production, so results here do not predict production numbers.
================================================================================

Why this exists
---------------
The ADF receipt path creates vessel_receipts_hdr/container/line rows but never
posts the general-ledger entries that the P21 GUI vessel-receipt window posts.
As of 2026-07-09 the following production vessel receipts have zero GL rows
(source_type_cd 1674 = "Vessel Receipts"), all created_by = 'ADF':

    hdr_uid  vessel_name        created         natural period   period status
    -------  -----------------  --------------  ---------------  -------------
    765      TM731 2026-07-09   2026-07-09      2026 / 7 (Jul)   OPEN
    764      55197 2026-06-24   2026-06-24      2026 / 6 (Jun)   CLOSED
    763      TA607 2026-06-11   2026-06-11      2026 / 6 (Jun)   CLOSED
    762      TM735 2026-05-14   2026-05-14      2026 / 5 (May)   CLOSED

Everything <= 761 (GUI-created) posted its balanced pair.

The GL posting each receipt is missing (verified against posted receipts 761 &
756, and cross-checked against the P21Import GUI test for 765):

    journal_id     = 'IR'
    source_type_cd = 1674
    source         = vessel_receipts_hdr_uid (as varchar)
    description    = vessel_name
    seq 1 (credit) = account 2161000  A/P - Vessel/Container - Coats   amount = -X
    seq 2 (debit)  = account 1345210  Inventory In Transit To Locations amount = +X
    where  X = ROUND( SUM(po_sku_cost * container_qty_received), 2 )  over the receipt's lines

Validated amounts (computed live in this script, shown here for reference):
    765 -> 198,797.91     764 -> 193,369.14     763 -> 183,865.36     762 -> 150,045.21

Counters (both are SQL-sequence-backed; advanced via dbo.p21_get_counter)
-------------------------------------------------------------------------
    gl_uid             <- counter id 'gl'                    (seq_gl)
    transaction_number <- counter id 'gl_transaction_number' (seq_gl_transaction_number)
As of the last read both prod sequences equal MAX() in gl (no drift), so a
backfill draws fresh consecutive values with no collision. NOTE: p21_get_counter
advances the sequence even if the surrounding transaction rolls back, so a failed
APPLY leaves a permanent (harmless) gap in gl_uid / transaction_number.

DECISIONS THAT ARE NOT MINE TO MAKE — resolve before @Apply = 1
--------------------------------------------------------------
1. PERIOD. Only 2026/period 7 (July) is OPEN. 762 (May) and 763/764 (June) fall
   in CLOSED periods. This script posts every selected receipt to the single
   @TargetPeriod (default 7). That lands May/June inventory-in-transit + A/P in
   July. Accounting must approve posting cross-period, OR reopen May/June and run
   this once per period. Do not just accept the default.
2. SCOPE. Default target set is the LAST 3 (763, 764, 765). 762 (TM735/May) is
   also missing — add it only if accounting wants it.
3. NO DOUBLE POST. Confirm no P21 "post vessel receipts to GL" batch job is
   pending that would also post these (they've sat unposted for weeks, which
   suggests nothing else will — but confirm).
4. TEST FIRST in P21Play/P21Import with the identical script + trigger t_gl_iu.
================================================================================
*/

USE P21Import;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

------------------------------------------------------------------------------
-- Parameters
------------------------------------------------------------------------------
DECLARE @Apply            bit          = 0;          -- 0 = preview only (NO counters touched); 1 = allocate + insert + verify + commit
DECLARE @TargetPeriod     decimal(9,0) = 7;          -- MUST be OPEN (only 2026/7 is open today)
DECLARE @TargetYear       decimal(9,0) = 2026;
DECLARE @Operator         varchar(50)  = N'DSHAO';   -- who is making the correction (created_by / last_maintained_by)
DECLARE @CompanyNo        varchar(8)   = 'KA';
DECLARE @APAccount        varchar(32)  = '2161000';  -- credit: A/P - Vessel/Container - Coats
DECLARE @InTransitAccount varchar(32)  = '1345210';  -- debit : Inventory In Transit To Locations
DECLARE @SourceTypeCd     smallint     = 1674;       -- Vessel Receipts
DECLARE @JournalId        varchar(8)   = 'IR';
DECLARE @Now              datetime     = P21Import.dbo.p21_fn_GetSystemDatetime(CURRENT_TIMESTAMP, NULL, NULL);
DECLARE @TransactionDate  datetime     = @Now;       -- must fall within @TargetPeriod's begin/end

------------------------------------------------------------------------------
-- Target vessel receipt headers to backfill
------------------------------------------------------------------------------
DROP TABLE IF EXISTS #target;
CREATE TABLE #target
(
      rn          int          NULL
    , hdr_uid     int          NOT NULL PRIMARY KEY
    , vessel_name varchar(255) NULL
    , amount      decimal(19,4) NULL
);

INSERT INTO #target (hdr_uid) VALUES
      (763)
    , (764)
    , (765);
    -- , (762)   -- uncomment ONLY if accounting wants TM735 (May) too

------------------------------------------------------------------------------
-- Build plan: compute amount from live lines, attach vessel_name,
-- and drop any receipt that already has an IR GL posting (idempotent / re-run safe)
------------------------------------------------------------------------------
;WITH amt AS
(
    SELECT vl.vessel_receipts_hdr_uid AS hdr_uid,
           amount = ROUND(SUM(vl.po_sku_cost * vl.container_qty_received), 2)
    FROM P21Import.dbo.vessel_receipts_line AS vl
    WHERE vl.vessel_receipts_hdr_uid IN (SELECT hdr_uid FROM #target)
    GROUP BY vl.vessel_receipts_hdr_uid
)
UPDATE t
   SET t.vessel_name = vh.vessel_name,
       t.amount      = amt.amount
FROM #target AS t
INNER JOIN P21Import.dbo.vessel_receipts_hdr AS vh ON vh.vessel_receipts_hdr_uid = t.hdr_uid
INNER JOIN amt ON amt.hdr_uid = t.hdr_uid;

DELETE t
FROM #target AS t
WHERE EXISTS
(
    SELECT 1 FROM P21Import.dbo.gl g
    WHERE g.source = CONVERT(varchar(50), t.hdr_uid)
      AND g.source_type_cd = @SourceTypeCd
);

;WITH r AS (SELECT hdr_uid, rn2 = ROW_NUMBER() OVER (ORDER BY hdr_uid) FROM #target)
UPDATE t SET t.rn = r.rn2 FROM #target t INNER JOIN r ON r.hdr_uid = t.hdr_uid;

------------------------------------------------------------------------------
-- Validations (fail closed)
------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM #target WHERE amount IS NULL OR amount <= 0)
    THROW 60001, 'A target receipt has null/non-positive computed amount. Investigate before posting.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM P21Import.dbo.periods
    WHERE company_no = @CompanyNo AND year_for_period = @TargetYear
      AND period = @TargetPeriod AND period_closed = 'N'
)
    THROW 60002, 'Target period is not OPEN. Refusing to post. Choose an open period or have accounting reopen.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM P21Import.dbo.periods
    WHERE company_no = @CompanyNo AND year_for_period = @TargetYear AND period = @TargetPeriod
      AND @TransactionDate >= beginning_date
      AND @TransactionDate <  DATEADD(day, 1, ending_date)
)
    THROW 60003, '@TransactionDate does not fall within @TargetPeriod. Adjust @TransactionDate.', 1;

------------------------------------------------------------------------------
-- Preview
------------------------------------------------------------------------------
SELECT phase = CASE WHEN @Apply = 1 THEN 'WILL POST' ELSE 'PREVIEW ONLY' END,
       t.rn, t.hdr_uid, t.vessel_name, t.amount,
       target_period = @TargetPeriod, target_year = @TargetYear,
       credit_acct = @APAccount, debit_acct = @InTransitAccount,
       transaction_date = @TransactionDate
FROM #target t
ORDER BY t.rn;

IF @Apply = 0
BEGIN
    PRINT 'PREVIEW ONLY: no counters advanced, no rows inserted. Review, then set @Apply = 1.';
    RETURN;
END;

------------------------------------------------------------------------------
-- Apply: allocate counters (proper sequence advancement), insert, verify, commit
------------------------------------------------------------------------------
DECLARE @N int = (SELECT COUNT(*) FROM #target);
IF @N = 0
BEGIN
    PRINT 'Nothing to post (all targets already have GL).';
    RETURN;
END;

DECLARE @glCount int = @N * 2;
DECLARE @glLast bigint, @glFirst bigint, @txnLast bigint, @txnFirst bigint;

BEGIN TRAN;

    EXEC P21Import.dbo.p21_get_counter @strCounterID = 'gl',
         @iIncrementValue = @glCount, @LastValue = @glLast OUTPUT;
    SET @glFirst = @glLast - @glCount + 1;

    EXEC P21Import.dbo.p21_get_counter @strCounterID = 'gl_transaction_number',
         @iIncrementValue = @N, @LastValue = @txnLast OUTPUT;
    SET @txnFirst = @txnLast - @N + 1;

    -- Safety: allocated blocks must be ahead of existing data
    IF @glFirst <= (SELECT ISNULL(MAX(gl_uid),0) FROM P21Import.dbo.gl)
        THROW 60004, 'Allocated gl_uid block overlaps existing rows (counter behind). Rolled back.', 1;
    IF @txnFirst <= (SELECT ISNULL(MAX(transaction_number),0) FROM P21Import.dbo.gl)
        THROW 60005, 'Allocated transaction_number block overlaps existing rows (counter behind). Rolled back.', 1;

    INSERT INTO P21Import.dbo.gl
    (
          gl_uid, company_no, account_number, period, year_for_period, journal_id,
          amount, source, description, date_created, date_last_modified, last_maintained_by,
          currency_id, foreign_amount, transaction_date, transaction_number, approved,
          sequence_number, encumbered_amount, foreign_encumbered_amount, source_type_cd,
          group_number, created_by
    )
    SELECT
          gl_uid             = @glFirst + (t.rn - 1) * 2 + (s.seq - 1),
          company_no         = @CompanyNo,
          account_number     = CASE WHEN s.seq = 1 THEN @APAccount ELSE @InTransitAccount END,
          period             = @TargetPeriod,
          year_for_period    = @TargetYear,
          journal_id         = @JournalId,
          amount             = CASE WHEN s.seq = 1 THEN -t.amount ELSE t.amount END,
          source             = CONVERT(varchar(50), t.hdr_uid),
          description        = t.vessel_name,
          date_created       = @Now,
          date_last_modified = @Now,
          last_maintained_by = @Operator,
          currency_id        = 1,
          foreign_amount     = CASE WHEN s.seq = 1 THEN -t.amount ELSE t.amount END,
          transaction_date   = @TransactionDate,
          transaction_number = @txnFirst + (t.rn - 1),
          approved           = 'Y',
          sequence_number    = s.seq,
          encumbered_amount  = 0,
          foreign_encumbered_amount = 0,
          source_type_cd     = @SourceTypeCd,
          group_number       = 1,
          created_by         = @Operator
    FROM #target AS t
    CROSS JOIN (VALUES (1),(2)) AS s(seq);

    -- Verify: each target now has exactly 2 IR rows netting to 0.00
    IF EXISTS
    (
        SELECT 1
        FROM
        (
            SELECT g.source, cnt = COUNT(*), net = SUM(g.amount)
            FROM P21Import.dbo.gl g
            WHERE g.source_type_cd = @SourceTypeCd
              AND g.source IN (SELECT CONVERT(varchar(50), hdr_uid) FROM #target)
            GROUP BY g.source
        ) x
        WHERE x.cnt <> 2 OR x.net <> 0
    )
    BEGIN
        ROLLBACK TRAN;
        THROW 60006, 'Verification failed: a posting is not a balanced 2-row pair. Rolled back (counters already advanced by design).', 1;
    END;

    SELECT result = 'POSTED', g.source AS hdr_uid,
           rows = COUNT(*), net_should_be_zero = SUM(g.amount),
           transaction_number = MIN(g.transaction_number),
           gl_uids = CONCAT(MIN(g.gl_uid), '-', MAX(g.gl_uid))
    FROM P21Import.dbo.gl g
    WHERE g.source_type_cd = @SourceTypeCd
      AND g.source IN (SELECT CONVERT(varchar(50), hdr_uid) FROM #target)
    GROUP BY g.source
    ORDER BY g.source;

COMMIT TRAN;
GO
