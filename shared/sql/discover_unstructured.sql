-- Candidate free-text columns across accessible databases (run with a role that can read INFORMATION_SCHEMA).
-- Replace <DB> or loop over SHOW DATABASES.
SELECT table_catalog, table_schema, table_name, column_name, data_type
FROM <DB>.information_schema.columns
WHERE data_type IN ('TEXT','VARCHAR','VARIANT')
  AND REGEXP_LIKE(column_name, '.*(NOTE|COMMENT|DESC|TRANSCRIPT|BODY|TEXT|MESSAGE|REVIEW|FEEDBACK|REASON|SUMMARY).*', 'i')
ORDER BY 1,2,3;
-- Stages with documents/audio: SHOW STAGES; then LIST @stage PATTERN='.*\.(pdf|docx|png|jpg|wav|mp3|m4a)';
