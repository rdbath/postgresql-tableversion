/**
* Creates trigger and trigger function required for versioning the table.
*
* @param p_table_oid      The table regclass
* @param p_key_col        The unique non-compostite integer column key.
* @return                 If creating the functions was successful.
* @throws RAISE_EXCEPTION If the table is not versioned
*
* -- {
*/
CREATE OR REPLACE FUNCTION ver_create_version_trigger(
    p_table_oid   REGCLASS,
    p_key_col NAME
) 
RETURNS BOOLEAN AS
$$
DECLARE
    v_revision_table TEXT;
    v_sql            TEXT;
    v_trigger_name   VARCHAR;
    v_column_name    NAME;
    v_column_update  TEXT;
    v_col_insert_col TEXT;
    v_col_insert_val TEXT;
    v_table          NAME;
    v_schema         NAME;
    v_owner          NAME;
BEGIN

    SELECT nspname, relname, rolname
    INTO v_schema, v_table, v_owner
    FROM @extschema@._ver_get_table_info(p_table_oid);

    -- Check that SESSION_USER is the owner of the table, or
    -- refuse to add columns to it
    IF NOT pg_has_role(session_user, v_owner, 'usage') THEN
        RAISE EXCEPTION 'User % cannot create version triggers on table %'
            ' for lack of usage privileges on table owner role %',
            session_user, p_table_oid, v_owner;
    END IF;

    IF NOT @extschema@._ver_is_table_versioned(v_schema, v_table) THEN
        RAISE EXCEPTION 'Table %.% is not versioned', quote_ident(v_schema), quote_ident(v_table);
    END IF;
    
    v_revision_table := @extschema@.ver_get_version_table_full(v_schema, v_table);
    

    SELECT string_agg(quote_ident(att_name), ',') INTO v_col_insert_col
    FROM unnest(@extschema@._ver_get_table_columns(v_schema || '.' ||  v_table));

    SELECT string_agg('NEW.' || quote_ident(att_name), E',\n') INTO v_col_insert_val
    FROM unnest(@extschema@._ver_get_table_columns(v_schema || '.' ||  v_table));

    v_column_update := '';
    FOR v_column_name IN
        SELECT att_name AS column_name
        FROM unnest(@extschema@._ver_get_table_columns(v_schema || '.' ||  v_table))
    LOOP
        IF v_column_name = p_key_col THEN
            CONTINUE;
        END IF;
        IF v_column_update != '' THEN
            v_column_update := v_column_update || E',\n                        ';
        END IF;
        
        v_column_update := v_column_update || quote_ident(v_column_name) || ' = NEW.' 
            || quote_ident(v_column_name);
    END LOOP;
    
    v_sql := $template$

CREATE OR REPLACE FUNCTION %revision_table%() RETURNS trigger AS $TRIGGER$
    DECLARE
       v_revision      @extschema@.revision.id%TYPE;
       v_last_revision @extschema@.revision.id%TYPE;
       v_table_id      @extschema@.versioned_tables.id%TYPE;
    BEGIN
        BEGIN
            SELECT
                max(VER.revision)
            INTO
                v_revision
            FROM
                _changeset_revision VER;
                
            IF v_revision IS NULL THEN
                RAISE EXCEPTION 'Versioning system information is missing';
            END IF;
        EXCEPTION
            WHEN undefined_table THEN
                RAISE EXCEPTION 'To begin editing %full_table_name% you need to create a revision';
        END;

        SELECT
            VTB.id
        INTO
            v_table_id
        FROM
            @extschema@.versioned_tables VTB
        WHERE
            VTB.table_name = %table_name% AND
            VTB.schema_name = %schema_name%;
        
        IF v_table_id IS NULL THEN
            RAISE EXCEPTION 'Table versioning system information is missing for %full_table_name%';
        END IF;

        IF NOT EXISTS (
            SELECT TRUE
            FROM   @extschema@.tables_changed
            WHERE  table_id = v_table_id
            AND    revision = v_revision
        )
        THEN
            INSERT INTO @extschema@.tables_changed(revision, table_id)
            VALUES (v_revision, v_table_id);
        END IF;

        
        IF (TG_OP <> 'INSERT') THEN
            SELECT 
                _revision_created INTO v_last_revision
            FROM 
                %revision_table%
            WHERE 
                %key_col% = OLD.%key_col% AND
                _revision_expired IS NULL;

            IF v_last_revision = v_revision THEN
                IF TG_OP = 'UPDATE' AND OLD.%key_col% = NEW.%key_col% THEN
                    UPDATE
                        %revision_table%
                    SET
                        %revision_update_cols%
                    WHERE
                        %key_col% = NEW.%key_col% AND
                        _revision_created = v_revision AND
                        _revision_expired IS NULL;
                    RETURN NEW;
                ELSE
                    DELETE FROM 
                        %revision_table%
                    WHERE
                        %key_col% = OLD.%key_col% AND
                        _revision_created = v_last_revision;
                END IF;
            ELSE
                UPDATE
                    %revision_table%
                SET
                    _revision_expired = v_revision
                WHERE
                    %key_col% = OLD.%key_col% AND
                    _revision_created = v_last_revision;
            END IF;
        END IF;

        IF( TG_OP <> 'DELETE') THEN
            INSERT INTO %revision_table% (
                _revision_created,
                _revision_expired,
                %revision_insert_cols%
            )
            SELECT
                v_revision,
                NULL,
                %revision_insert_vals%;
            RETURN NEW;
        END IF;
        
        RETURN NULL;
    END;
$TRIGGER$ LANGUAGE plpgsql SECURITY DEFINER;

    $template$;

    v_sql := REPLACE(v_sql, '%schema_name%',    quote_literal(v_schema));
    v_sql := REPLACE(v_sql, '%table_name%',     quote_literal(v_table));
    v_sql := REPLACE(v_sql, '%full_table_name%', quote_ident(v_schema) || '.' || quote_ident(v_table));
    v_sql := REPLACE(v_sql, '%key_col%',        quote_ident(p_key_col));
    v_sql := REPLACE(v_sql, '%revision_table%', v_revision_table);
    v_sql := REPLACE(v_sql, '%revision_update_cols%', v_column_update);
    v_sql := REPLACE(v_sql, '%revision_insert_cols%', v_col_insert_col);
    v_sql := REPLACE(v_sql, '%revision_insert_vals%', v_col_insert_val);
    
    EXECUTE v_sql;

    SELECT @extschema@._ver_get_version_trigger(v_schema, v_table)
    INTO v_trigger_name;
    

    EXECUTE 'DROP TRIGGER IF EXISTS '  || v_trigger_name || ' ON ' ||  
        quote_ident(v_schema) || '.' || quote_ident(v_table);

    EXECUTE 'CREATE TRIGGER '  || v_trigger_name || ' AFTER INSERT OR UPDATE OR DELETE ON ' ||  
        quote_ident(v_schema) || '.' || quote_ident(v_table) ||
        ' FOR EACH ROW EXECUTE PROCEDURE ' || v_revision_table || '()';
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
--}

/*
* Creates trigger and trigger function required for versioning the table.
*
* @param p_schema         The table schema
* @param p_table          The table name
* @param p_key_col        The unique non-compostite integer column key.
* @return                 If creating the functions was successful.
* @throws RAISE_EXCEPTION If the table is not versioned
*
* {
*/
CREATE OR REPLACE FUNCTION ver_create_version_trigger(
    p_schema  NAME,
    p_table   NAME,
    p_key_col NAME
) 
RETURNS BOOLEAN AS
$$
    SELECT @extschema@.ver_create_version_trigger(
        ( p_schema || '.' || p_table)::regclass,
        p_key_col
    );
$$ LANGUAGE sql;
-- }

--
-- Fix existing table triggers if coming from a version prior to 1.5.0
--
-- WARNING: this needs to be sourced _before_ the script defining
--          ver_version() function
-- {
DO $$
DECLARE
    old_version TEXT;
    is_extension BOOL;
    rec RECORD;
BEGIN
    BEGIN
        old_version := @extschema@.ver_version();
    EXCEPTION WHEN undefined_function THEN
        RAISE DEBUG 'ver_version not available, '
                    'we are either doing a new install '
                    'or coming from version before 1.3';
    END;

    SELECT EXISTS ( SELECT * FROM pg_catalog.pg_extension
                    WHERE extname = 'table_version' )
    INTO is_extension;

    -- We only need to update triggers when coming
    -- from versions 1.4 or earlier. Function ver_version
    -- was introduced in 1.3 so no need to check any previous
    -- version (old_version would be null in those cases)
    --
    -- Note that if old_version would also be NULL for new
    -- installs in which case the SELECT below will do nothing
    -- as ver_get_versioned_tables() would return the empty set
    --
    IF ( old_version IS NULL OR
       old_version LIKE '1.3.%' OR
       old_version LIKE '1.4.%' ) AND
       EXISTS (
          SELECT * FROM @extschema@.ver_get_versioned_tables()
       ) versioned_tables
    THEN
        RAISE NOTICE 'Updating triggers on versioned tables';
        FOR rec IN SELECT schema_name, table_name,
            @extschema@.ver_create_version_trigger(
                schema_name, table_name, key_column)
            FROM (
                SELECT * FROM @extschema@.ver_get_versioned_tables()
            ) versioned_tables
        LOOP
            IF is_extension THEN
                EXECUTE format('ALTER EXTENSION table_version '
                    ' DROP FUNCTION '
                    '@extschema@.%s_%s_revision()',
                    rec.schema_name, rec.table_name);
            END IF;
        END LOOP;
    END IF;
END
$$ LANGUAGE 'plpgsql';
--}
