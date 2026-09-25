	
	#!/usr/bin/env bash
	set -euo pipefail
	
	# =============================================================================
	# VERIFICA FORMULE CANDIDATE PER RICOSTRUIRE "Added value" IN ORBIS
	# =============================================================================
	#
	# Obiettivo:
	#   confrontare l'Added value già presente in Orbis con alcune formule candidate,
	#   usando solo le righe dove Added value NON è nullo.
	#
	# Dataset necessario:
	#   Industry-Global_financials_and_ratios-EUR.txt
	#
	# Directory dati:
	#   /var/dati/archivi_gen_26
	#
	# Output:
	#   /var/dati/archivi_gen_26/added_value_check/
	#
	# =============================================================================
	
	
	# -----------------------------------------------------------------------------
	# 1. Percorsi principali
	# -----------------------------------------------------------------------------
	
	DATA_DIR="/var/dati/archivi_gen_26"
	
	IN="${DATA_DIR}/Industry-Global_financials_and_ratios-EUR.txt"
	
	OUT_DIR="${DATA_DIR}/added_value_check"
	
	
	# -----------------------------------------------------------------------------
	# 2. Parametri DuckDB
	# -----------------------------------------------------------------------------
	
	THREADS=16
	MEM="80GB"
	TEMP="/var/tmp"
	
	
	# -----------------------------------------------------------------------------
	# 3. Crea la directory di output se non esiste
	# -----------------------------------------------------------------------------
	
	mkdir -p "$OUT_DIR"
	
	
	# -----------------------------------------------------------------------------
	# 4. Esecuzione DuckDB
	# -----------------------------------------------------------------------------
	#
	# Lo script SQL fa queste cose:
	#
	#   A) legge il file Industry-Global_financials_and_ratios-EUR.txt
	#   B) seleziona e converte in DOUBLE le variabili utili
	#   C) tiene solo le righe dove Added value è presente
	#   D) calcola diverse formule candidate
	#   E) confronta ogni formula con l'Added value Orbis
	#   F) esporta tre CSV di controllo
	#
	# -----------------------------------------------------------------------------
	
	duckdb -c "
	PRAGMA threads=${THREADS};
	PRAGMA memory_limit='${MEM}';
	PRAGMA temp_directory='${TEMP}';
	PRAGMA preserve_insertion_order=false;
	
	
	-- ============================================================================
	-- A) LETTURA DEL FILE ORBIS
	-- ============================================================================
	--
	-- read_csv_auto legge il TSV Orbis.
	--
	-- delim='	' indica che il file è tab-delimited.
	-- header=true indica che la prima riga contiene i nomi delle colonne.
	-- nullstr tratta stringhe vuote, NA, NULL, ecc. come valori nulli.
	-- ignore_errors=true evita che una singola riga problematica blocchi tutto.
	--
	-- Il risultato viene salvato in una tabella temporanea DuckDB chiamata raw.
	-- ============================================================================
	
	CREATE OR REPLACE TABLE raw AS
	SELECT *
	FROM read_csv_auto(
	  '${IN}',
	  delim='	',
	  header=true,
	  nullstr=['', 'n.a.', 'NA', 'NULL'],
	  ignore_errors=true
	);
	
	
	-- ============================================================================
	-- B) NORMALIZZAZIONE DELLE VARIABILI
	-- ============================================================================
	--
	-- Qui estraiamo solo le colonne che ci servono.
	--
	-- try_cast(... AS DOUBLE) prova a convertire i campi numerici in numeri.
	-- Se trova valori sporchi/non convertibili, mette NULL invece di fallire.
	--
	-- Manteniamo anche:
	--   - BvD ID number
	--   - Consolidation code
	--   - Closing date
	--
	-- perché ci serviranno per eventuali controlli per impresa, codice contabile
	-- e anno/data di chiusura.
	-- ============================================================================
	
	CREATE OR REPLACE TABLE base AS
	SELECT
	  \"BvD ID number\"::VARCHAR AS bvd_id,
	  \"Consolidation code\"::VARCHAR AS cons_code,
	  \"Closing date\"::VARCHAR AS closing_date,
	
	  try_cast(\"Added value\" AS DOUBLE) AS added_value,
	  try_cast(\"EBITDA\" AS DOUBLE) AS ebitda,
	  try_cast(\"Costs of employees\" AS DOUBLE) AS costs_employees,
	  try_cast(\"Operating revenue (Turnover)\" AS DOUBLE) AS operating_revenue,
	  try_cast(\"Sales\" AS DOUBLE) AS sales,
	  try_cast(\"Costs of goods sold\" AS DOUBLE) AS cogs,
	  try_cast(\"Gross profit\" AS DOUBLE) AS gross_profit,
	  try_cast(\"Other operating expenses\" AS DOUBLE) AS other_opex,
	  try_cast(\"Depreciation & Amortization\" AS DOUBLE) AS depreciation
	FROM raw;
	
	
	-- ============================================================================
	-- C) CALCOLO DELLE FORMULE CANDIDATE
	-- ============================================================================
	--
	-- Qui lavoriamo SOLO sulle righe dove Added value è già presente.
	--
	-- Non stiamo ancora estraendo nulla.
	-- Stiamo solo verificando se alcune formule candidate ricostruiscono bene
	-- il valore che Orbis ha già valorizzato.
	--
	-- Formule candidate testate:
	--
	--   1) EBITDA + Costs of employees
	--   2) Operating revenue - Costs of goods sold
	--   3) Sales - Costs of goods sold
	--   4) Gross profit + Costs of employees
	--   5) EBITDA + Costs of employees + Depreciation & Amortization
	--
	-- La quinta è volutamente esplorativa: serve a capire se la logica Orbis
	-- è più vicina a un margine prima/dopo ammortamenti.
	-- ============================================================================
	
	CREATE OR REPLACE TABLE tests AS
	SELECT
	  *,
	  ebitda + costs_employees AS f_ebitda_plus_employees,
	  operating_revenue - cogs AS f_revenue_minus_cogs,
	  sales - cogs AS f_sales_minus_cogs,
	  gross_profit + costs_employees AS f_grossprofit_plus_employees,
	  ebitda + costs_employees + depreciation AS f_ebitda_plus_employees_plus_depr
	FROM base
	WHERE added_value IS NOT NULL;
	
	
	-- ============================================================================
	-- D) CONFRONTO GENERALE TRA FORMULE E ADDED VALUE
	-- ============================================================================
	--
	-- Qui trasformiamo le formule candidate in una tabella lunga:
	--
	--   formula | added_value | estimate
	--
	-- In questo modo possiamo calcolare per ogni formula:
	--
	--   n                   = numero di righe confrontabili
	--   mean_error          = errore medio firmato
	--   mean_abs_error      = errore medio assoluto
	--   rmse                = errore quadratico medio
	--   mean_abs_pct_error  = errore percentuale medio assoluto
	--   correlation         = correlazione tra Added value e formula candidata
	--
	-- Come leggere i risultati:
	--
	--   - mean_abs_error basso = formula vicina in valore assoluto
	--   - rmse basso           = pochi errori grandi
	--   - correlation vicina 1 = andamento molto simile
	--   - mean_error vicino 0  = assenza di bias sistematico
	--
	-- ============================================================================
	
	CREATE OR REPLACE TABLE formula_quality AS
	WITH long AS (
	  SELECT 'EBITDA + Costs of employees' AS formula,
	         added_value,
	         f_ebitda_plus_employees AS estimate
	  FROM tests
	  WHERE f_ebitda_plus_employees IS NOT NULL
	
	  UNION ALL
	
	  SELECT 'Operating revenue - COGS' AS formula,
	         added_value,
	         f_revenue_minus_cogs AS estimate
	  FROM tests
	  WHERE f_revenue_minus_cogs IS NOT NULL
	
	  UNION ALL
	
	  SELECT 'Sales - COGS' AS formula,
	         added_value,
	         f_sales_minus_cogs AS estimate
	  FROM tests
	  WHERE f_sales_minus_cogs IS NOT NULL
	
	  UNION ALL
	
	  SELECT 'Gross profit + Costs of employees' AS formula,
	         added_value,
	         f_grossprofit_plus_employees AS estimate
	  FROM tests
	  WHERE f_grossprofit_plus_employees IS NOT NULL
	
	  UNION ALL
	
	  SELECT 'EBITDA + Costs employees + Depreciation' AS formula,
	         added_value,
	         f_ebitda_plus_employees_plus_depr AS estimate
	  FROM tests
	  WHERE f_ebitda_plus_employees_plus_depr IS NOT NULL
	)
	SELECT
	  formula,
	  COUNT(*) AS n,
	  AVG(estimate - added_value) AS mean_error,
	  AVG(ABS(estimate - added_value)) AS mean_abs_error,
	  SQRT(AVG(POWER(estimate - added_value, 2))) AS rmse,
	  AVG(
	    CASE
	      WHEN ABS(added_value) > 0
	      THEN ABS(estimate - added_value) / ABS(added_value)
	    END
	  ) AS mean_abs_pct_error,
	  corr(added_value, estimate) AS correlation
	FROM long
	GROUP BY formula
	ORDER BY mean_abs_error ASC;
	
	
	-- ============================================================================
	-- E) ESPORTA IL RISULTATO GENERALE
	-- ============================================================================
	
	COPY formula_quality
	TO '${OUT_DIR}/formula_quality.csv'
	(HEADER, DELIMITER ',');
	
	
	-- ============================================================================
	-- F) CONFRONTO PER CONSOLIDATION CODE
	-- ============================================================================
	--
	-- Qui ripetiamo il confronto distinguendo per:
	--
	--   U1, U2, C1, C2, LF, ecc.
	--
	-- Questo è importante perché la formula migliore potrebbe cambiare tra
	-- bilanci consolidati e non consolidati.
	--
	-- Output:
	--   formula_quality_by_cons_code.csv
	-- ============================================================================
	
	CREATE OR REPLACE TABLE formula_quality_by_cons_code AS
	WITH long AS (
	  SELECT cons_code, 'EBITDA + Costs of employees' AS formula, added_value, f_ebitda_plus_employees AS estimate
	  FROM tests WHERE f_ebitda_plus_employees IS NOT NULL
	
	  UNION ALL
	  SELECT cons_code, 'Operating revenue - COGS', added_value, f_revenue_minus_cogs
	  FROM tests WHERE f_revenue_minus_cogs IS NOT NULL
	
	  UNION ALL
	  SELECT cons_code, 'Sales - COGS', added_value, f_sales_minus_cogs
	  FROM tests WHERE f_sales_minus_cogs IS NOT NULL
	
	  UNION ALL
	  SELECT cons_code, 'Gross profit + Costs of employees', added_value, f_grossprofit_plus_employees
	  FROM tests WHERE f_grossprofit_plus_employees IS NOT NULL
	
	  UNION ALL
	  SELECT cons_code, 'EBITDA + Costs employees + Depreciation', added_value, f_ebitda_plus_employees_plus_depr
	  FROM tests WHERE f_ebitda_plus_employees_plus_depr IS NOT NULL
	)
	SELECT
	  cons_code,
	  formula,
	  COUNT(*) AS n,
	  AVG(estimate - added_value) AS mean_error,
	  AVG(ABS(estimate - added_value)) AS mean_abs_error,
	  SQRT(AVG(POWER(estimate - added_value, 2))) AS rmse,
	  AVG(
	    CASE
	      WHEN ABS(added_value) > 0
	      THEN ABS(estimate - added_value) / ABS(added_value)
	    END
	  ) AS mean_abs_pct_error,
	  corr(added_value, estimate) AS correlation
	FROM long
	GROUP BY cons_code, formula
	ORDER BY cons_code, mean_abs_error ASC;
	
	COPY formula_quality_by_cons_code
	TO '${OUT_DIR}/formula_quality_by_cons_code.csv'
	(HEADER, DELIMITER ',');
	
	
	-- ============================================================================
	-- G) PROFILO DEI MISSING
	-- ============================================================================
	--
	-- Questo file serve a capire quante righe hanno:
	--
	--   - Added value presente
	--   - Added value mancante
	--   - variabili disponibili per testare le formule candidate
	--
	-- È utile perché una formula può essere molto buona ma applicabile a poche righe.
	--
	-- Output:
	--   missing_profile.csv
	-- ============================================================================
	
	CREATE OR REPLACE TABLE missing_profile AS
	SELECT
	  COUNT(*) AS rows_total,
	
	  COUNT(*) FILTER (WHERE added_value IS NULL) AS added_value_null,
	  COUNT(*) FILTER (WHERE added_value IS NOT NULL) AS added_value_present,
	
	  COUNT(*) FILTER (
	    WHERE added_value IS NULL
	      AND ebitda IS NOT NULL
	      AND costs_employees IS NOT NULL
	  ) AS missing_av_but_can_compute_ebitda_plus_employees,
	
	  COUNT(*) FILTER (
	    WHERE added_value IS NULL
	      AND operating_revenue IS NOT NULL
	      AND cogs IS NOT NULL
	  ) AS missing_av_but_can_compute_revenue_minus_cogs,
	
	  COUNT(*) FILTER (
	    WHERE added_value IS NULL
	      AND sales IS NOT NULL
	      AND cogs IS NOT NULL
	  ) AS missing_av_but_can_compute_sales_minus_cogs,
	
	  COUNT(*) FILTER (
	    WHERE added_value IS NULL
	      AND gross_profit IS NOT NULL
	      AND costs_employees IS NOT NULL
	  ) AS missing_av_but_can_compute_grossprofit_plus_employees,
	
	  COUNT(*) FILTER (
	    WHERE added_value IS NULL
	      AND ebitda IS NOT NULL
	      AND costs_employees IS NOT NULL
	      AND depreciation IS NOT NULL
	  ) AS missing_av_but_can_compute_ebitda_plus_employees_plus_depr
	
	FROM base;
	
	COPY missing_profile
	TO '${OUT_DIR}/missing_profile.csv'
	(HEADER, DELIMITER ',');
	
	
	-- ============================================================================
	-- H) MOSTRA A VIDEO IL RANKING GENERALE DELLE FORMULE
	-- ============================================================================
	
	SELECT * FROM formula_quality;
	"
	
	echo
	echo "OK. Risultati creati in:"
	echo " - ${OUT_DIR}/formula_quality.csv"
	echo " - ${OUT_DIR}/formula_quality_by_cons_code.csv"
	echo " - ${OUT_DIR}/missing_profile.csv"

