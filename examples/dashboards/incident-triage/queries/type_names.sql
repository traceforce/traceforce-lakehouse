-- Custom sensitive-data type names, keyed by the custom_<id> value findings carry. Fails on a lake whose
-- module predates the table; the page then shows the raw value.
SELECT type, name FROM org_sensitive_data_custom_types
