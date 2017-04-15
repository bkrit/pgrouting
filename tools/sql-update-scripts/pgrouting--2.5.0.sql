\echo Use "CREATE EXTENSION pgrouting" to load this file. \quit




--- -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
---
--- pgRouting provides geospatial routing functionality.
--- http://pgrouting.org
--- copyright 
--- -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
---
---
--- This is free software; you can redistribute and/or modify it:
--- the terms of the GNU General Public Licence. See the COPYING file.
--- the terms of the MIT-X Licence. See the COPYING file.
---
--- The following functions have MIT-X licence:
---     pgr_version()
---     pgr_tsp(matrix float8[][], startpt integer, endpt integer DEFAULT -1, OUT seq integer, OUT id integer)
---     _pgr_makeDistanceMatrix(sqlin text, OUT dmatrix double precision[], OUT ids integer[])
---     pgr_analyzegraph(edge_table text,tolerance double precision,the_geom text default 'the_geom',id text default 'id',source text default 'source',target text default 'target',rows_where text default 'true')
---
---
--- All other functions are under GNU General Public Licence.
---
--- -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
--
-- WARNING: Any change in this file must be evaluated for compatibility.
--          Changes cleanly handled by postgis_upgrade.sql are fine,
--          other changes will require a bump in Major version.
--          Currently only function replaceble by CREATE OR REPLACE
--          are cleanly handled.
--
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -




--  pgRouting 2.0 types



CREATE TYPE pgr_costResult AS
(
    seq integer,
    id1 integer,
    id2 integer,
    cost float8
);



CREATE TYPE pgr_costResult3 AS
(
    seq integer,
    id1 integer,
    id2 integer,
    id3 integer,
    cost float8
);

CREATE TYPE pgr_geomResult AS
(
    seq integer,
    id1 integer,
    id2 integer,
    geom geometry
);

-- -------------------------------------------------------------------
-- pgrouting_version.sql
-- AuthorL Stephen Woodbridge <woodbri@imaptools.com>
-- Copyright 2013 Stephen Woodbridge
-- This file is release unde an MIT-X license.
-- -------------------------------------------------------------------

/*
.. function:: pgr_version()

   Author: Stephen Woodbridge <woodbri@imaptools.com>

   Returns the version of pgrouting,Git build,Git hash, Git branch and boost
*/

CREATE OR REPLACE FUNCTION pgr_version()
RETURNS TABLE(
        "version" varchar,
        tag varchar,
        hash varchar,
        branch varchar,
        boost varchar
    ) AS
$BODY$
    SELECT '2.5.0'::varchar AS version,
        'v2.5.0-dev'::varchar AS tag,
        ''::varchar AS hash,
        ''::varchar AS branch,
        '1.54.0'::varchar AS boost;
$BODY$
LANGUAGE sql IMMUTABLE;





/*
.. function:: _pgr_getTableName(tab)

   Examples:
        *          select * from  _pgr_getTableName('tab');
        *        naming record;
                 execute 'select * from  _pgr_getTableName('||quote_literal(tab)||')' INTO naming;
                 schema=naming.sname; table=naming.tname


   Returns (schema,name) of table "tab" considers Caps and when not found considers lowercases
           (schema,NULL) when table was not found
           (NULL,NULL) when schema was not found.

   Author: Vicky Vergara <vicky_vergara@hotmail.com>>
  
  HISTORY
     2015/11/01 Changed to handle views and refactored
     Created: 2013/08/19  for handling schemas

*/


CREATE OR REPLACE FUNCTION _pgr_getTableName(IN tab text, IN reportErrs int default 0, IN fnName text default '_pgr_getTableName', OUT sname text,OUT tname text)
  RETURNS RECORD AS
$$
DECLARE
        naming record;
        i integer;
        query text;
        sn text; -- schema name
        tn text; -- table name
        ttype text; --table type for future use
        err boolean;
        debuglevel text;
        var_types text[] = ARRAY['BASE TABLE', 'VIEW'];
BEGIN

    execute 'show client_min_messages' into debuglevel;


    perform _pgr_msg( 0, fnName, 'Checking table ' || tab || ' exists');
    --RAISE DEBUG 'Checking % exists',tab;

    i := strpos(tab,'.');
    IF (i <> 0) THEN
        sn := split_part(tab, '.',1); 
        tn := split_part(tab, '.',2);
    ELSE
        sn := current_schema;
        tn := tab;
    END IF;


   SELECT schema_name INTO sname 
   FROM information_schema.schemata WHERE schema_name = sn;

    IF sname IS NOT NULL THEN -- found schema (as is)
       SELECT table_name, table_type INTO tname, ttype 
       FROM information_schema.tables 
       WHERE
                table_type = ANY(var_types) and
                table_schema = sname and
                table_name = tn ;
        IF tname is NULL THEN
            SELECT table_name, table_type INTO tname, ttype 
            FROM information_schema.tables 
            WHERE
                table_type  = ANY(var_types) and
                table_schema = sname and
                table_name = lower(tn) ORDER BY table_name;
        END IF;
    END IF;
    IF sname is NULL or tname is NULL THEN --schema not found or table not found
        SELECT schema_name INTO sname 
        FROM information_schema.schemata 
        WHERE schema_name = lower(sn) ;

        IF sname IS NOT NULL THEN -- found schema (with lower caps)
            SELECT table_name, table_type INTO tname, ttype 
            FROM information_schema.tables 
            WHERE
                table_type  =  ANY(var_types) and
                table_schema = sname and
                table_name= tn ;
                
           IF tname IS NULL THEN
                SELECT table_name, table_type INTO tname, ttype 
                FROM information_schema.tables 
                WHERE
                    table_type  =  ANY(var_types) and
                    table_schema = sname and
                    table_name= lower(tn) ;
           END IF;
        END IF;
    END IF;
   err = (sname IS NULL OR tname IS NULL);
   perform _pgr_onError(err, reportErrs, fnName, 'Table ' || tab ||' not found',' Check your table name', 'Table '|| tab || ' found');

END;
$$
LANGUAGE plpgsql VOLATILE STRICT;



/*
.. function:: _pgr_getColumnName(sname,tname,col,reportErrs default 1) returns text
.. function:: _pgr_getColumnName(tab,col,reportErrs default 1) returns text

    Returns:
          cname  registered column "col" in table "tab" or "sname.tname" considers Caps and when not found considers lowercases
          NULL   when "tab"/"sname"/"tname" is not found or when "col" is not in table "tab"/"sname.tname"
    unless otherwise indicated raises notices on errors

 Examples:
        *          select  _pgr_getColumnName('tab','col');
        *          select  _pgr_getColumnName('myschema','mytable','col');
                 execute 'select _pgr_getColumnName('||quote_literal('tab')||','||quote_literal('col')||')' INTO column;
                 execute 'select _pgr_getColumnName('||quote_literal(sname)||','||quote_literal(sname)||','||quote_literal('col')||')' INTO column;

   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2013/08/19  for handling schemas
     Modified: 2014/JUL/28 added overloadig
*/


CREATE OR REPLACE FUNCTION _pgr_getColumnName(sname text, tname text, col text, IN reportErrs int default 1, IN fnName text default '_pgr_getColumnName')
RETURNS text AS
$BODY$
DECLARE
    cname text;
    naming record;
    err boolean;
BEGIN

    execute 'SELECT column_name FROM information_schema.columns
          WHERE table_name='||quote_literal(tname)||' and table_schema='||quote_literal(sname)||' and column_name='||quote_literal(col) into cname;

    IF cname is null  THEN
    execute 'SELECT column_name FROM information_schema.columns
          WHERE table_name='||quote_literal(tname)||' and table_schema='||quote_literal(sname)||' and column_name='||quote_literal(lower(col))  into cname;
    END if;

    err = cname is null;

    perform _pgr_onError(err, reportErrs, fnName,  'Column '|| col ||' not found', ' Check your column name','Column '|| col || ' found');
    RETURN cname;
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;



CREATE OR REPLACE FUNCTION _pgr_getColumnName(tab text, col text, IN reportErrs int default 1, IN fnName text default '_pgr_getColumnName')
RETURNS text AS
$BODY$
DECLARE
    sname text;
    tname text;
    cname text;
    naming record;
    err boolean;
BEGIN
    select * into naming from _pgr_getTableName(tab,reportErrs, fnName) ;
    sname=naming.sname;
    tname=naming.tname;

    select * into cname from _pgr_getColumnName(sname,tname,col,reportErrs, fnName);
    RETURN cname;
END;

$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


/*
.. function:: _pgr_isColumnInTable(tab, col)

   Examples:
        *          select  _pgr_isColumnName('tab','col');
        *        flag boolean;
                 execute 'select _pgr_getColumnName('||quote_literal('tab')||','||quote_literal('col')||')' INTO flag;

   Returns true  if column "col" exists in table "tab"
           false when "tab" doesn't exist or when "col" is not in table "tab"

   Author: Stephen Woodbridge <woodbri@imaptools.com>

   Modified by: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Modified: 2013/08/19  for handling schemas
*/
CREATE OR REPLACE FUNCTION _pgr_isColumnInTable(tab text, col text)
RETURNS boolean AS
$BODY$
DECLARE
    cname text;
BEGIN
    select * from _pgr_getColumnName(tab,col,0, '_pgr_isColumnInTable') into cname;
    return cname is not null;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;


/*
.. function:: _pgr_isColumnIndexed(tab, col)

   Examples:
        *          select  _pgr_isColumnIndexed('tab','col');
        *        flag boolean;
                 execute 'select _pgr_getColumnIndexed('||quote_literal('tab')||','||quote_literal('col')||')' INTO flag;

   Author: Stephen Woodbridge <woodbri@imaptools.com>

   Modified by: Vicky Vergara <vicky_vergara@hotmail.com>>

   Returns true  when column "col" in table "tab" is indexed.
           false when table "tab"  is not found or
                 when column "col" is nor found in table "tab" or
                   when column "col" is not indexed
*/

CREATE OR REPLACE FUNCTION _pgr_isColumnIndexed(sname text, tname text, cname text,
      IN reportErrs int default 1, IN fnName text default '_pgr_isColumnIndexed')
RETURNS boolean AS
$BODY$
DECLARE
    naming record;
    rec record;
    pkey text;
BEGIN
    SELECT
          pg_attribute.attname into pkey
         --  format_type(pg_attribute.atttypid, pg_attribute.atttypmod)
          FROM pg_index, pg_class, pg_attribute
          WHERE
                  pg_class.oid = _pgr_quote_ident(sname||'.'||tname)::regclass AND
                  indrelid = pg_class.oid AND
                  pg_attribute.attrelid = pg_class.oid AND
                  pg_attribute.attnum = any(pg_index.indkey)
                  AND indisprimary;

    IF pkey=cname then
          RETURN TRUE;
    END IF;

    SELECT a.index_name,
           b.attname,
           b.attnum,
           a.indisunique,
           a.indisprimary
      INTO rec
      FROM ( SELECT a.indrelid,
                    a.indisunique,
                    a.indisprimary,
                    c.relname index_name,
                    unnest(a.indkey) index_num
               FROM pg_index a,
                    pg_class b,
                    pg_class c,
                    pg_namespace d
              WHERE b.relname=tname
                AND b.relnamespace=d.oid
                AND d.nspname=sname
                AND b.oid=a.indrelid
                AND a.indexrelid=c.oid
           ) a,
           pg_attribute b
     WHERE a.indrelid = b.attrelid
       AND a.index_num = b.attnum
       AND b.attname = cname
  ORDER BY a.index_name,
           a.index_num;

  RETURN FOUND;
  EXCEPTION WHEN OTHERS THEN
    perform _pgr_onError( true, reportErrs, fnName,
    'Error when checking for the postgres system attributes', SQLERR);
    RETURN FALSE;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _pgr_isColumnIndexed(tab text, col text,
      IN reportErrs int default 1, IN fnName text default '_pgr_isColumnIndexed')
RETURNS boolean AS
$BODY$
DECLARE
    naming record;
    rec record;
    sname text;
    tname text;
    cname text;
    pkey text;
    value boolean;
BEGIN
    SELECT * into naming FROM _pgr_getTableName(tab, 0, fnName);
    sname=naming.sname;
    tname=naming.tname;
    IF sname IS NULL OR tname IS NULL THEN
        RETURN FALSE;
    END IF;
    SELECT * into cname from _pgr_getColumnName(sname, tname, col, 0, fnName) ;
    IF cname IS NULL THEN
        RETURN FALSE;
    END IF;
    select * into value  from _pgr_isColumnIndexed(sname, tname, cname, reportErrs, fnName);
    return value;
END
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;

/*
.. function:: _pgr_quote_ident(text)

   Author: Stephen Woodbridge <woodbri@imaptools.com>

   Function to split a string on '.' characters and then quote the
   components as postgres identifiers and then join them back together
   with '.' characters. multile '.' will get collapsed into a single
   '.' so 'schema...table' till get returned as 'schema."table"' and
   'Schema.table' becomes '"Schema'.'table"'

*/

create or replace function _pgr_quote_ident(idname text)
    returns text as
$body$
declare
    t text[];
    pgver text;

begin
    pgver := regexp_replace(version(), E'^PostgreSQL ([^ ]+)[ ,].*$', E'\\1');

    if _pgr_versionless(pgver, '9.2') then
        select into t array_agg(quote_ident(term)) from
            (select nullif(unnest, '') as term
               from unnest(string_to_array(idname, '.'))) as foo;
    else
        select into t array_agg(quote_ident(term)) from
            (select unnest(string_to_array(idname, '.', '')) as term) as foo;
    end if;
    return array_to_string(t, '.');
end;
$body$
language plpgsql immutable;

/*
 * function for comparing version strings.
 * Ex: select _pgr_version_less(postgis_lib_version(), '2.1');

   Author: Stephen Woodbridge <woodbri@imaptools.com>
 *
 * needed because postgis 2.1 deprecates some function names and
 * we need to detect the version at runtime
*/
CREATE OR REPLACE FUNCTION _pgr_versionless(v1 text, v2 text)
  RETURNS boolean AS
$BODY$


declare
    v1a text[];
    v2a text[];
    nv1 integer;
    nv2 integer;
    ne1 integer;
    ne2 integer;

begin
    -- separate components into an array, like:
    -- '2.1.0-beta3dev'  =>  {2,1,0,beta3dev}
    v1a := regexp_matches(v1, E'^(\\d+)(?:[\\.](\\d+))?(?:[\\.](\\d+))?[-+\\.]?(.*)$');
    v2a := regexp_matches(v2, E'^(\\d+)(?:[\\.](\\d+))?(?:[\\.](\\d+))?[-+\\.]?(.*)$');

    -- convert modifiers to numbers for comparison
    -- we do not delineate between alpha1, alpha2, alpha3, etc
    ne1 := case when v1a[4] is null or v1a[4]='' then 5
                when v1a[4] ilike 'rc%' then 4
                when v1a[4] ilike 'beta%' then 3
                when v1a[4] ilike 'alpha%' then 2
                when v1a[4] ilike 'dev%' then 1
                else 0 end;

    ne2 := case when v2a[4] is null or v2a[4]='' then 5
                when v2a[4] ilike 'rc%' then 4
                when v2a[4] ilike 'beta%' then 3
                when v2a[4] ilike 'alpha%' then 2
                when v2a[4] ilike 'dev%' then 1
                else 0 end;

    nv1 := v1a[1]::integer * 10000 +
           coalesce(v1a[2], '0')::integer * 1000 +
           coalesce(v1a[3], '0')::integer *  100 + ne1;
    nv2 := v2a[1]::integer * 10000 +
           coalesce(v2a[2], '0')::integer * 1000 +
           coalesce(v2a[3], '0')::integer *  100 + ne2;

    --raise notice 'nv1: %, nv2: %, ne1: %, ne2: %', nv1, nv2, ne1, ne2;

    return nv1 < nv2;
end;
$BODY$
  LANGUAGE plpgsql IMMUTABLE STRICT
  COST 1;

create or replace function _pgr_startPoint(g geometry)
    returns geometry as
$body$
declare

begin
    if geometrytype(g) ~ '^MULTI' then
        return st_startpoint(st_geometryn(g,1));
    else
        return st_startpoint(g);
    end if;
end;
$body$
language plpgsql IMMUTABLE;



create or replace function _pgr_endPoint(g geometry)
    returns geometry as
$body$
declare

begin
    if geometrytype(g) ~ '^MULTI' then
        return st_endpoint(st_geometryn(g,1));
    else
        return st_endpoint(g);
    end if;
end;
$body$
language plpgsql IMMUTABLE;




-----------------------------------------------------------------------
-- Function _pgr_parameter_check
-- Check's the parameters type of the sql input
-----------------------------------------------------------------------

-- change the default to true when all the functions will use the bigint
-- put TRUE when it uses BGINT
-- Query styles:
-- dijkstra (id, source, target, cost, [reverse_cost])
-- johnson (source, target, cost, [reverse_cost])

CREATE OR REPLACE FUNCTION _pgr_parameter_check(fn text, sql text, big boolean default false)
  RETURNS bool AS
  $BODY$  

  DECLARE
  rec record;
  rec1 record;
  has_rcost boolean;
  safesql text;
  BEGIN 
    IF (big) THEN
       RAISE EXCEPTION 'This function is for old style functions';
    END IF;

    -- checking query is executable
    BEGIN
      safesql =  'select * from ('||sql||' ) AS __a__ limit 1';
      execute safesql into rec;
      EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Could not execute query please verify syntax of: '
              USING HINT = sql;
    END;

    -- checking the fixed columns and data types of the integers
    IF fn IN ('dijkstra','astar') THEN
        BEGIN
          execute 'select id,source,target,cost  from ('||safesql||') as __b__' into rec;
          EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'An expected column was not found in the query'
                  USING ERRCODE = 'XX000',
                   HINT = 'Please veryfy the column names: id, source, target, cost';
        END;
        execute 'select pg_typeof(id)::text as id_type, pg_typeof(source)::text as source_type, pg_typeof(target)::text as target_type, pg_typeof(cost)::text as cost_type'
            || ' from ('||safesql||') AS __b__ ' into rec;
        -- Version 2.0.0 is more restrictive
        IF NOT(   (rec.id_type in ('integer'::text))
              AND (rec.source_type in ('integer'::text))
              AND (rec.target_type in ('integer'::text))
              AND (rec.cost_type = 'double precision'::text)) THEN
            RAISE EXCEPTION 'Error, columns ''source'', ''target'' must be of type int4, ''cost'' must be of type float8'
            USING ERRCODE = 'XX000';
        END IF;
    END IF;
 

    IF fn IN ('astar') THEN
        BEGIN
          execute 'select x1,y1,x2,y2  from ('||safesql||') as __b__' into rec;
          EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'An expected column was not found in the query'
                  USING ERRCODE = 'XX000',
                   HINT = 'Please veryfy the column names: x1,y1, x2,y2';
        END;
        execute 'select pg_typeof(x1)::text as x1_type, pg_typeof(y1)::text as y1_type, pg_typeof(x2)::text as x2_type, pg_typeof(y2)::text as y2_type'
            || ' from ('||safesql||') AS __b__ ' into rec;
        -- Version 2.0.0 is more restrictive
        IF NOT(   (rec.x1_type = 'double precision'::text)
              AND (rec.y1_type = 'double precision'::text)
              AND (rec.x2_type = 'double precision'::text)
              AND (rec.y2_type = 'double precision'::text)) THEN
            RAISE EXCEPTION 'Columns: x1, y1, x2, y2 must be of type float8'
            USING ERRCODE = 'XX000';
        END IF;
    END IF;

    -- checking the fixed columns and data types of the integers
    IF fn IN ('johnson') THEN
        BEGIN
          execute 'select source,target,cost  from ('||safesql||') as __b__' into rec;
          EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'An expected column was not found in the query'
                  USING HINT = 'Please veryfy the column names: id, source, target, cost',
                         ERRCODE = 'XX000';
        END;

        execute 'select pg_typeof(source)::text as source_type, pg_typeof(target)::text as target_type, pg_typeof(cost)::text as cost_type'
            || ' from ('||safesql||') AS __b__ ' into rec;
        -- Version 2.0.0 is more restrictive
        IF NOT(   (rec.source_type in ('integer'::text))
              AND (rec.target_type in ('integer'::text))
              AND (rec.cost_type = 'double precision'::text)) THEN
            RAISE EXCEPTION 'Support for source,target columns only of type: integer. Support for Cost: double precision'
            USING ERRCODE = 'XX000';
        END IF;
    END IF;


    -- Checking the data types of the optional reverse_cost";
    has_rcost := false;
    IF fn IN ('johnson','dijkstra','astar') THEN
      BEGIN
        execute 'select reverse_cost, pg_typeof(reverse_cost)::text as rev_type  from ('||safesql||' ) AS __b__ limit 1 ' into rec1;
        has_rcost := true;
        EXCEPTION
          WHEN OTHERS THEN
            has_rcost = false;
            return has_rcost;  
      END;
      if (has_rcost) then
        IF (big) then
           IF  not (rec1.rev_type in ('bigint'::text, 'integer'::text, 'smallint'::text, 'double precision'::text, 'real'::text)) then
             RAISE EXCEPTION 'Illegar type in optional parameter reverse_cost.'
             USING ERRCODE = 'XX000';
           END IF;
        ELSE -- Version 2.0.0 is more restrictive
           IF (rec1.rev_type != 'double precision') then
             RAISE EXCEPTION 'Illegal type in optional parameter reverse_cost, must be of type float8'
             USING ERRCODE = 'XX000';
           END IF;
        END IF;
      end if;
      return true;
    END IF;
    -- just for keeps
    return true;
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 1;





/************************************************************************
.. function:: _pgr_onError(errCond,reportErrs,functionname,msgerr,hinto,msgok)
  
  If the error condition is is true, i.e., there is an error,
   it will raise a message based on the reportErrs:
  0: debug_      raise debug_
  1: report     raise notice
  2: abort      throw a raise_exception  
   Examples:  
   
	*	preforn _pgr_onError( idname=gname, 2, 'pgr_createToplogy',
                     'Two columns share the same name');
	*	preforn _pgr_onError( idname=gname, 2, 'pgr_createToplogy',
                     'Two columns share the same name', 'Idname and gname must be different');
    *	preforn _pgr_onError( idname=gname, 2, 'pgr_createToplogy',
                     'Two columns share the same name', 'Idname and gname must be different',
                     'Column names are OK');

   
   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUl/28  handling the errors, and have a more visual output
  
************************************************************************/

CREATE OR REPLACE FUNCTION _pgr_onError(
  IN errCond boolean,  -- true there is an error
  IN reportErrs int,   -- 0, 1 or 2
  IN fnName text,      -- function name that generates the error
  IN msgerr text,      -- error message
  IN hinto text default 'No hint', -- hint help
  IN msgok text default 'OK')      -- message if everything is ok
  RETURNS void AS
$BODY$
BEGIN
  if errCond=true then 
     if reportErrs=0 then
       raise debug '----> PGR DEBUG in %: %',fnName,msgerr USING HINT = '  ---->'|| hinto;
     else
       if reportErrs = 2 then
         raise notice '----> PGR ERROR in %: %',fnName,msgerr USING HINT = '  ---->'|| hinto;
         raise raise_exception;
       else
         raise notice '----> PGR NOTICE in %: %',fnName,msgerr USING HINT = '  ---->'|| hinto;
       end if;
     end if;
  else
       raise debug 'PGR ----> %: %',fnName,msgok;
  end if;
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;

/************************************************************************
.. function:: _pgr_msg(msgKind, fnName, msg)
  
  It will raise a message based on the msgKind:
  0: debug_      raise debug_
  1: notice     raise notice
  anything else: report     raise notice

   Examples:  
   
	*	preforn _pgr_msg( 1, 'pgr_createToplogy', 'Starting a long process... ');
	*	preforn _pgr_msg( 1, 'pgr_createToplogy');

   
   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUl/28  handling the errors, and have a more visual output
  
************************************************************************/

CREATE OR REPLACE FUNCTION _pgr_msg(IN msgKind int, IN fnName text, IN msg text default '---->OK')
  RETURNS void AS
$BODY$
BEGIN
  if msgKind = 0 then
       raise debug '----> PGR DEBUG in %: %',fnName,msg;
  else
       raise notice '----> PGR NOTICE in %: %',fnName,msg;
  end if;
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


/************************************************************************
.. function:: _pgr_getColumnType(sname,tname,col,reportErrs,fnName) returns text
.. function:: _pgr_getColumnType(tab,col,reportErrs,fname) returns text

    Returns:
          type   the types of the registered column "col" in table "tab" or "sname.tname" 
          NULL   when "tab"/"sname"/"tname" is not found or when "col" is not in table "tab"/"sname.tname"
    unless otherwise indicated raises debug_  on errors
 
 Examples:  
	* 	 select  _pgr_getColumnType('tab','col');
	* 	 select  _pgr_getColumnType('myschema','mytable','col');
        	 execute 'select _pgr_getColumnType('||quote_literal('tab')||','||quote_literal('col')||')' INTO column;
        	 execute 'select _pgr_getColumnType('||quote_literal(sname)||','||quote_literal(sname)||','||quote_literal('col')||')' INTO column;

   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUL/28 
************************************************************************/

CREATE OR REPLACE FUNCTION _pgr_getColumnType(sname text, tname text, cname text,
     IN reportErrs int default 0, IN fnName text default '_pgr_getColumnType')
RETURNS text AS
$BODY$
DECLARE
    ctype text;
    naming record;
    err boolean;
BEGIN

    EXECUTE 'select data_type  from information_schema.columns ' 
            || 'where table_name = '||quote_literal(tname)
                 || ' and table_schema=' || quote_literal(sname)
                 || ' and column_name='||quote_literal(cname)
       into ctype;
    err = ctype is null;
    perform _pgr_onError(err, reportErrs, fnName,
            'Type of Column '|| cname ||' not found',
            'Check your column name',
            'OK: Type of Column '|| cname || ' is ' || ctype);
    RETURN ctype;
END;

$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


CREATE OR REPLACE FUNCTION _pgr_getColumnType(tab text, col text,
     IN reportErrs int default 0, IN fnName text default '_pgr_getColumnType')
RETURNS text AS
$BODY$
DECLARE
    sname text;
    tname text;
    cname text;
    ctype text;
    naming record;
    err boolean;
BEGIN
  
    select * into naming from _pgr_getTableName(tab,reportErrs, fnName) ;
    sname=naming.sname;
    tname=naming.tname;
    select * into cname from _pgr_getColumnName(tab,col,reportErrs, fnName) ;
    select * into ctype from _pgr_getColumnType(sname,tname,cname,reportErrs, fnName);
    RETURN ctype;
END;

$BODY$
LANGUAGE plpgsql VOLATILE STRICT;





/************************************************************************
.. function:: _pgr_get_statement( sql ) returns the original statement if its a prepared statement

    Returns:
          sname,vname  registered schemaname, vertices table name 
    
          
 Examples:  
    select * from _pgr_dijkstra(_pgr_get_statament($1),$2,$3,$4);

   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUL/27 
************************************************************************/
CREATE OR REPLACE FUNCTION _pgr_get_statement(o_sql text)
RETURNS text AS
$BODY$
DECLARE
sql TEXT;
BEGIN
    EXECUTE 'SELECT statement FROM pg_prepared_statements WHERE name ='  || quote_literal(o_sql) || ' limit 1 ' INTO sql;
    IF (sql IS NULL) THEN
      RETURN   o_sql;
    ELSE
      RETURN  regexp_replace(sql, '(.)* as ', '', 'i');
    END IF;
END
$BODY$
LANGUAGE plpgsql STABLE STRICT;


/************************************************************************
.. function:: _pgr_checkVertTab(vertname,columnsArr,reportErrs) returns record of sname,vname

    Returns:
          sname,vname  registered schemaname, vertices table name 
    
    if the table is not found will stop any further checking.
    if a column is missing, then its added as integer ---  (id also as integer but is bigserial when the vertices table is created with the pgr functions)
          
 Examples:  
	* 	execute 'select * from  _pgr_checkVertTab('||quote_literal(vertname) ||', ''{"id","cnt","chk"}''::text[])' into naming;
	* 	execute 'select * from  _pgr_checkVertTab('||quote_literal(vertname) ||', ''{"id","ein","eout"}''::text[])' into naming;

   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUL/27 
************************************************************************/
CREATE OR REPLACE FUNCTION _pgr_checkVertTab(vertname text, columnsArr  text[],
    IN reportErrs int default 1, IN fnName text default '_pgr_checkVertTab',
    OUT sname text,OUT vname text)
RETURNS record AS
$BODY$
DECLARE
    cname text;
    colname text;
    naming record;
    debuglevel text;
    err  boolean;
    msgKind int;

BEGIN
    msgKind = 0; -- debug_
    execute 'show client_min_messages' into debuglevel;

    perform _pgr_msg(msgKind, fnName, 'Checking table ' || vertname || ' exists');
       select * from _pgr_getTableName(vertname, 0, fnName) into naming;
       sname=naming.sname;
       vname=naming.tname;
       err = sname is NULL or vname is NULL;
    perform _pgr_onError( err, 2, fnName,
          'Vertex Table: ' || vertname || ' not found',
          'Please create ' || vertname || ' using  _pgr_createTopology() or pgr_createVerticesTable()',
          'Vertex Table: ' || vertname || ' found');
    

    perform _pgr_msg(msgKind, fnName, 'Checking columns of ' || vertname);
      FOREACH cname IN ARRAY columnsArr
      loop
         select _pgr_getcolumnName(vertname, cname, 0, fnName) into colname;
         if colname is null then
           perform _pgr_msg(msgKind, fnName, 'Adding column ' || cname || ' in ' || vertname);
           set client_min_messages  to warning;
                execute 'ALTER TABLE '||_pgr_quote_ident(vertname)||' ADD COLUMN '||cname|| ' integer';
           execute 'set client_min_messages  to '|| debuglevel;
           perform _pgr_msg(msgKind, fnName);
         end if;
      end loop;
    perform _pgr_msg(msgKind, fnName, 'Finished checking columns of ' || vertname);

    perform _pgr_createIndex(vertname , 'id' , 'btree', reportErrs, fnName);
 END
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;





/************************************************************************
.. function:: _pgr_createIndex(tab, col,indextype)
              _pgr_createIndex(sname,tname,colname,indextypes)
              
   if the column is not indexed it creates a 'gist' index otherwise a 'btree' index
   Examples:  
	* 	 select  _pgr_createIndex('tab','col','btree');
	* 	 select  _pgr_createIndex('myschema','mytable','col','gist');
	* 	 perform 'select _pgr_createIndex('||quote_literal('tab')||','||quote_literal('col')||','||quote_literal('btree'))' ;
	* 	 perform 'select _pgr_createIndex('||quote_literal('myschema')||','||quote_literal('mytable')||','||quote_literal('col')||','||quote_literal('gist')')' ;
   Precondition:
      sname.tname.colname is a valid column on table tname in schema sname
      indext  is the indexType btree or gist
   Postcondition:
      sname.tname.colname its indexed using the indextype

  
   Author: Vicky Vergara <vicky_vergara@hotmail.com>>

  HISTORY
     Created: 2014/JUL/28 
************************************************************************/

CREATE OR REPLACE FUNCTION _pgr_createIndex(
    sname text, tname text, colname text, indext text,
    IN reportErrs int default 1, IN fnName text default '_pgr_createIndex')
RETURNS void AS
$BODY$
DECLARE
    debuglevel text;
    naming record;
    tabname text;
    query text;
    msgKind int;
BEGIN
  msgKind = 0; -- debug_

  execute 'show client_min_messages' into debuglevel;
  tabname=_pgr_quote_ident(sname||'.'||tname);
  perform _pgr_msg(msgKind, fnName, 'Checking ' || colname || ' column in ' || tabname || ' is indexed');
    IF (_pgr_isColumnIndexed(sname,tname,colname, 0, fnName)) then
       perform _pgr_msg(msgKind, fnName);
    else
      if indext = 'gist' then
        query = 'create  index '||_pgr_quote_ident(tname||'_'||colname||'_idx')||' 
                         on '||tabname||' using gist('||quote_ident(colname)||')';
      else
        query = 'create  index '||_pgr_quote_ident(tname||'_'||colname||'_idx')||' 
                         on '||tabname||' using btree('||quote_ident(colname)||')';
      end if;
      perform _pgr_msg(msgKind, fnName, 'Adding index ' || tabname || '_' ||  colname || '_idx');
      perform _pgr_msg(msgKind, fnName, ' Using ' ||  query);
      set client_min_messages  to warning;
      BEGIN
        execute query;
        EXCEPTION WHEN others THEN
          perform _pgr_onError( true, reportErrs, fnName,
            'Could not create index on:' || cname, SQLERRM);
      END;
      execute 'set client_min_messages  to '|| debuglevel;
      perform _pgr_msg(msgKind, fnName);
    END IF;
END;

$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;


CREATE OR REPLACE FUNCTION _pgr_createIndex(tabname text, colname text, indext text,
    IN reportErrs int default 1, IN fnName text default '_pgr_createIndex')
RETURNS void AS
$BODY$
DECLARE
    naming record;
    sname text;
    tname text;

BEGIN
    select * from _pgr_getTableName(tabname, 2, fnName)  into naming;
    sname=naming.sname;
    tname=naming.tname;
    execute _pgr_createIndex(sname, tname, colname, indext, reportErrs, fnName);
END;

$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;



/*
.. function:: _pgr_pointToId(point geometry, tolerance double precision,vname text,srid integer)
Using tolerance to determine if its an existing point:
    - Inserts a point into the vertices table "vertname" with the srid "srid", 
and returns
    - the id of the new point
    - the id of the existing point.
   
Tolerance is the minimal distance between existing points and the new point to create a new point.

Last changes: 2013-03-22

HISTORY
Last changes: 2013-03-22
2013-08-19: handling schemas
*/

CREATE OR REPLACE FUNCTION _pgr_pointToId(
    point geometry, 
    tolerance double precision,
    vertname text,
    srid integer)

  RETURNS bigint AS
$BODY$
DECLARE
    rec record;
    pid bigint;

BEGIN
    EXECUTE 'SELECT ST_Distance(
        the_geom,
        ST_GeomFromText(ST_AsText('
                || quote_literal(point::text)
                || '),'
            || srid ||')) AS d, id, the_geom
    FROM '||_pgr_quote_ident(vertname)||'
    WHERE ST_DWithin(
        the_geom, 
        ST_GeomFromText(
            ST_AsText(' || quote_literal(point::text) ||'),
            ' || srid || '),' || tolerance||')
    ORDER BY d
    LIMIT 1' INTO rec ;
    IF rec.id IS NOT NULL THEN
        pid := rec.id;
    ELSE
        execute 'INSERT INTO '||_pgr_quote_ident(vertname)||' (the_geom) VALUES ('||quote_literal(point::text)||')';
        pid := lastval();
END IF;

RETURN pid;

END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;



/*
CREATE OR REPLACE FUNCTION _pgr_dijkstra(edges_sql TEXT, start_vid BIGINT, end_vid BIGINT, directed BOOLEAN,
    only_cost BOOLEAN DEFAULT false,
  OUT seq integer, OUT path_seq integer, OUT node BIGINT, OUT edge BIGINT, OUT cost float, OUT agg_cost float)
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'one_to_one_dijkstra'
    LANGUAGE c IMMUTABLE STRICT;

    -- One to many


CREATE OR REPLACE FUNCTION _pgr_dijkstra(edges_sql TEXT, start_vid BIGINT, end_vids ANYARRAY, directed BOOLEAN DEFAULT true,
    only_cost BOOLEAN DEFAULT false,
  OUT seq integer, OUT path_seq integer, OUT end_vid BIGINT, OUT node BIGINT, OUT edge BIGINT, OUT cost float, OUT agg_cost float)
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'one_to_many_dijkstra'
    LANGUAGE c IMMUTABLE STRICT;


--  many to one


CREATE OR REPLACE FUNCTION _pgr_dijkstra(edges_sql TEXT, start_vids ANYARRAY, end_vid BIGINT, directed BOOLEAN DEFAULT true,
    only_cost BOOLEAN DEFAULT false,
    OUT seq integer, OUT path_seq integer, OUT start_vid BIGINT, OUT node BIGINT, OUT edge BIGINT, OUT cost float, OUT agg_cost float)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'many_to_one_dijkstra'
LANGUAGE c IMMUTABLE STRICT;

--  many to many
*/

CREATE OR REPLACE FUNCTION _pgr_dijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    only_cost BOOLEAN DEFAULT false,
    normal BOOLEAN DEFAULT true,

    OUT seq integer,
    OUT path_seq integer,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'many_to_many_dijkstra'
LANGUAGE c IMMUTABLE STRICT;


-- V3 signature 1 to 1
CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vid BIGINT,

    OUT seq integer,
    OUT path_seq integer,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], true, false, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- V3 signature 1 to 1
CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vid BIGINT,
    directed BOOLEAN,

    OUT seq integer,
    OUT path_seq integer,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], directed, false, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;



CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,

    OUT seq integer,
    OUT path_seq integer,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.end_vid, a.node, a.edge, a.cost, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, false, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    OUT seq integer,
    OUT path_seq integer,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.start_vid, a.node, a.edge, a.cost, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, false, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    OUT seq integer, OUT path_seq integer,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost float,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.start_vid, a.end_vid, a.node, a.edge, a.cost, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], $4, false, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- COMMENTS

COMMENT ON FUNCTION  pgr_dijkstra(TEXT, BIGINT, BIGINT) IS 'pgr_dijkstra(One to One)';
COMMENT ON FUNCTION  pgr_dijkstra(TEXT, BIGINT, BIGINT, BOOLEAN) IS 'pgr_dijkstra(One to One)';
COMMENT ON FUNCTION  pgr_dijkstra(TEXT, BIGINT, ANYARRAY, BOOLEAN) IS 'pgr_dijkstra(One to Many)';
COMMENT ON FUNCTION  pgr_dijkstra(TEXT, ANYARRAY, BIGINT, BOOLEAN) IS 'pgr_dijkstra(Many to One)';
COMMENT ON FUNCTION  pgr_dijkstra(TEXT, ANYARRAY, ANYARRAY, BOOLEAN) IS 'pgr_dijkstra(Many to Many)';



CREATE OR REPLACE FUNCTION pgr_dijkstraCost(
    edges_sql TEXT,
    BIGINT,
    BIGINT,
    directed BOOLEAN DEFAULT TRUE,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;



CREATE OR REPLACE FUNCTION pgr_dijkstraCost(
    edges_sql TEXT,
    BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_dijkstraCost(
    edges_sql TEXT,
    start_vids ANYARRAY,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_dijkstraCost(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost 
    FROM _pgr_dijkstra(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], $4, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- COMMENTS

COMMENT ON FUNCTION  pgr_dijkstraCost(TEXT, BIGINT, BIGINT, BOOLEAN) IS 'pgr_dijkstraCost(One to One)';
COMMENT ON FUNCTION  pgr_dijkstraCost(TEXT, BIGINT, ANYARRAY, BOOLEAN) IS 'pgr_dijkstraCost(One to Many)';
COMMENT ON FUNCTION  pgr_dijkstraCost(TEXT, ANYARRAY, BIGINT, BOOLEAN) IS 'pgr_dijkstraCost(Many to One)';
COMMENT ON FUNCTION  pgr_dijkstraCost(TEXT, ANYARRAY, ANYARRAY, BOOLEAN) IS 'pgr_dijkstraCost(Many to Many)';





CREATE OR REPLACE FUNCTION pgr_dijkstraVia(
    edges_sql TEXT,
    via_vertices ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    strict BOOLEAN DEFAULT FALSE,
    U_turn_on_edge BOOLEAN DEFAULT TRUE,


    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT,
    OUT route_agg_cost FLOAT)

  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'dijkstraVia'
    LANGUAGE c IMMUTABLE STRICT;




CREATE OR REPLACE FUNCTION pgr_johnson(edges_sql TEXT, directed BOOLEAN DEFAULT TRUE,
  OUT start_vid BIGINT, OUT end_vid BIGINT, OUT agg_cost float)
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'johnson'
    LANGUAGE c IMMUTABLE STRICT;



CREATE OR REPLACE FUNCTION pgr_floydWarshall(edges_sql TEXT, directed BOOLEAN DEFAULT TRUE, 
  OUT start_vid BIGINT, OUT end_vid BIGINT, OUT agg_cost float)
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'floydWarshall'  
    LANGUAGE c IMMUTABLE STRICT;



/*
CREATE OR REPLACE FUNCTION _pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    only_cost BOOLEAN DEFAULT false,
    normal BOOLEAN DEFAULT true,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'astarOneToOne'
LANGUAGE c IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION _pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    only_cost BOOLEAN DEFAULT false,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'astarOneToMany'
LANGUAGE c IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    only_cost BOOLEAN DEFAULT false,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'astarManyToOne'
LANGUAGE c IMMUTABLE STRICT;
*/

CREATE OR REPLACE FUNCTION _pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    only_cost BOOLEAN DEFAULT false,
    normal BOOLEAN DEFAULT false,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'astarManyToMany'
LANGUAGE c IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_astar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[],  ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.end_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_astar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[],  $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.start_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_astar(_pgr_get_statement($1), $2::BIGINT[],  ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, normal:=false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_astar(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT *
    FROM _pgr_astar(_pgr_get_statement($1), $2::BIGINT[],  $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- COMMENTS

COMMENT ON FUNCTION pgr_astar(TEXT, BIGINT, BIGINT, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_astar(One to One)';
COMMENT ON FUNCTION pgr_astar(TEXT, BIGINT, ANYARRAY, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_astar(One to Many)';
COMMENT ON FUNCTION pgr_astar(TEXT, ANYARRAY, BIGINT, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_astar(Many to One)';
COMMENT ON FUNCTION pgr_astar(TEXT, ANYARRAY, ANYARRAY, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_astar(Many to Many)';


CREATE OR REPLACE FUNCTION pgr_aStarCost(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_aStar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[],  ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a
    ORDER BY  a.start_vid, a.end_vid;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_aStarCost(
    edges_sql TEXT, -- XY edges sql
    start_vid BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_aStar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[],  $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a
    ORDER BY  a.start_vid, a.end_vid;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_aStarCost(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_aStar(_pgr_get_statement($1), $2::BIGINT[],  ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true, normal:=false) AS a
    ORDER BY  a.start_vid, a.end_vid;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

CREATE OR REPLACE FUNCTION pgr_aStarCost(
    edges_sql TEXT, -- XY edges sql
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_aStar(_pgr_get_statement($1), $2::BIGINT[],  $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a
    ORDER BY  a.start_vid, a.end_vid;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- COMMENTS

COMMENT ON FUNCTION pgr_aStarCost(TEXT, BIGINT, BIGINT, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_aStarCost(One to One)';
COMMENT ON FUNCTION pgr_aStarCost(TEXT, BIGINT, ANYARRAY, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_aStarCost(One to Many)';
COMMENT ON FUNCTION pgr_aStarCost(TEXT, ANYARRAY, BIGINT, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_aStarCost(Many to One)';
COMMENT ON FUNCTION pgr_aStarCost(TEXT, ANYARRAY, ANYARRAY, BOOLEAN, INTEGER, FLOAT, FLOAT) IS 'pgr_aStarCost(Many to Many)';


CREATE OR REPLACE FUNCTION pgr_withPointsDD(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid ANYARRAY,
    distance FLOAT,

    directed BOOLEAN DEFAULT TRUE,
    driving_side CHAR DEFAULT 'b', 
    details BOOLEAN DEFAULT FALSE, 
    equicost BOOLEAN DEFAULT FALSE, 

    OUT seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
  RETURNS SETOF RECORD AS
     '$libdir/libpgrouting-2.5', 'many_withPointsDD'
 LANGUAGE c VOLATILE STRICT;


CREATE OR REPLACE FUNCTION pgr_withPointsDD(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid BIGINT,
    distance FLOAT,

    directed BOOLEAN DEFAULT TRUE,
    driving_side CHAR DEFAULT 'b', 
    details BOOLEAN DEFAULT FALSE, 

    OUT seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
  RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.node, a.edge, a.cost, a.agg_cost
    FROM pgr_withPointsDD($1, $2, ARRAY[$3]::BIGINT[], $4, $5, $6, $7, false) a;
$BODY$
LANGUAGE SQL VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_drivingDistance(
    edges_sql text,
    start_vids anyarray,
    distance FLOAT,
    directed BOOLEAN DEFAULT TRUE,
    equicost BOOLEAN DEFAULT FALSE,
    OUT seq integer,
    OUT from_v  bigint,
    OUT node bigint,
    OUT edge bigint,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
  RETURNS SETOF RECORD AS
     '$libdir/libpgrouting-2.5', 'driving_many_to_dist'
 LANGUAGE c VOLATILE STRICT;


CREATE OR REPLACE FUNCTION pgr_drivingDistance(
    edges_sql text,
    start_vid bigint,
    distance FLOAT8,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq integer,
    OUT node bigint,
    OUT edge bigint,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
  RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.node, a.edge, a.cost, a.agg_cost
    FROM pgr_drivingDistance($1, ARRAY[$2]::BIGINT[], $3, $4, false) a;
$BODY$
LANGUAGE SQL VOLATILE
COST 100
ROWS 1000;






CREATE OR REPLACE FUNCTION _pgr_ksp(edges_sql text, start_vid bigint, end_vid bigint, k integer, directed boolean, heap_paths boolean,
  OUT seq integer, OUT path_id integer, OUT path_seq integer, OUT node bigint, OUT edge bigint, OUT cost float, OUT agg_cost float)
  RETURNS SETOF RECORD AS
    '$libdir/libpgrouting-2.5', 'kshortest_path'
    LANGUAGE c STABLE STRICT;

-- V2 the graph is directed and there are no heap paths 
CREATE OR REPLACE FUNCTION pgr_ksp(edges_sql text, start_vid integer, end_vid integer, k integer, has_rcost boolean)
  RETURNS SETOF pgr_costresult3 AS
  $BODY$  
  DECLARE
  has_reverse boolean;
  sql TEXT;
  BEGIN
      RAISE NOTICE 'Deprecated signature of pgr_ksp';
      has_reverse =_pgr_parameter_check('dijkstra', edges_sql::text, false);
      sql = edges_sql;
      IF (has_reverse != has_rcost) THEN
         IF (has_rcost) THEN
           -- user says that it has reverse_cost but its not true
           RAISE EXCEPTION 'has_reverse_cost set to true but reverse_cost not found';
         ELSE  
           -- user says that it does not have reverse_cost but it does have it
           -- to ignore we remove reverse_cost from the query
           sql = 'SELECT id, source, target, cost FROM (' || edges_sql || ') a';
         END IF;
      END IF;

      RETURN query SELECT ((row_number() over()) -1)::integer  AS seq,  (path_id - 1)::integer AS id1, node::integer AS id2, edge::integer AS id3, cost 
            FROM _pgr_ksp(sql::text, start_vid, end_vid, k, TRUE, FALSE) WHERE path_id <= k;
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;


CREATE OR REPLACE FUNCTION pgr_ksp(edges_sql text, start_vid bigint, end_vid bigint, k integer,
  directed boolean default true, heap_paths boolean default false,
  --directed boolean, heap_paths boolean,
  OUT seq integer, OUT path_id integer, OUT path_seq integer, OUT node bigint, OUT edge bigint, OUT cost float, OUT agg_cost float)
  RETURNS SETOF RECORD AS
  $BODY$
  DECLARE
  BEGIN
         RETURN query SELECT *
                FROM _pgr_ksp(edges_sql::text, start_vid, end_vid, k, directed, heap_paths);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_withPointsKSP(
    edges_sql TEXT, 
    points_sql TEXT,
    start_pid BIGINT, 
    end_pid BIGINT, 
    k INTEGER,

    directed BOOLEAN DEFAULT TRUE,
    heap_paths BOOLEAN DEFAULT FALSE,
    driving_side CHAR DEFAULT 'b',
    details BOOLEAN DEFAULT FALSE,

    OUT seq INTEGER, OUT path_id INTEGER, OUT path_seq INTEGER,
    OUT node BIGINT, OUT edge BIGINT,
    OUT cost FLOAT, OUT agg_cost FLOAT)
  RETURNS SETOF RECORD AS
    '$libdir/libpgrouting-2.5', 'withPoints_ksp'
    LANGUAGE c STABLE STRICT;



CREATE OR REPLACE FUNCTION _pgr_unnest_matrix(matrix float8[][], OUT start_vid integer, OUT end_vid integer, out agg_cost float8)
RETURNS SETOF record AS 

$body$
DECLARE

m float8[];

BEGIN
    start_vid = 1;
    foreach m slice 1 in  ARRAY matrix
    LOOP
        end_vid = 1;
        foreach agg_cost in  ARRAY m
        LOOP
            RETURN next;
            end_vid = end_vid + 1;
        END LOOP;
        start_vid = start_vid + 1;
    END LOOP;
END;
$body$
language plpgsql volatile cost 500 ROWS 50;



CREATE OR REPLACE FUNCTION pgr_tsp(
    matrix float8[][],
    startpt INTEGER,
    endpt INTEGER DEFAULT -1,
    OUT seq INTEGER,
    OUT id INTEGER)
RETURNS SETOF record AS
$body$
DECLARE
table_sql TEXT;
debuglevel TEXT;
BEGIN
    RAISE NOTICE 'Deprecated Signature pgr_tsp(float8[][], integer, integer)';

    CREATE TEMP TABLE ___tmp2 ON COMMIT DROP AS SELECT * FROM _pgr_unnest_matrix( matrix );


    startpt := startpt + 1;
    IF endpt = -1 THEN endpt := startpt;
    END IF;

    
    RETURN QUERY
    WITH 
    result AS (
        SELECT * FROM pgr_TSP(
        $$SELECT * FROM ___tmp2 $$,
        startpt, endpt,

        tries_per_temperature :=  500 :: INTEGER,
        max_changes_per_temperature := 30 :: INTEGER,
        max_consecutive_non_changes := 500 :: INTEGER,

        randomize:=false)
    )
    SELECT (row_number() over(ORDER BY result.seq) - 1)::INTEGER AS seq, (result.node - 1)::INTEGER AS id

    FROM result WHERE NOT(result.node = startpt AND result.seq != 1);

    DROP TABLE ___tmp2;
END;
$body$
language plpgsql volatile cost 500 ROWS 50;

/*
    Old signature has:
    sql: id INTEGER, x FLOAT, y FLOAT
*/




CREATE OR  REPLACE FUNCTION pgr_tsp(sql text, start_id INTEGER, end_id INTEGER default (-1))
returns setof pgr_costResult as
$body$
DECLARE
table_sql TEXT;
rec RECORD;
debuglevel TEXT;
n BIGINT;

BEGIN
    RAISE NOTICE 'Deprecated Signature pgr_tsp(sql, integer, integer)';

    table_sql := 'CREATE TEMP TABLE ___tmp ON COMMIT DROP AS ' || sql ;
    EXECUTE table_sql;


    BEGIN
        EXECUTE 'SELECT id, x, y FROM ___tmp' INTO rec;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE EXCEPTION 'An expected column was not found in the query'
                USING ERRCODE = 'XX000',
                HINT = 'Please verify the column names: id, x, y';
    END;

    EXECUTE
    'SELECT
        pg_typeof(id)::text as id_type,
        pg_typeof(x)::text as x_type,
        pg_typeof(y)::text as y_type FROM ___tmp' INTO rec;


    IF NOT((rec.id_type in ('integer'::text))
        AND (rec.x_type = 'double precision'::text)
        AND (rec.y_type = 'double precision'::text)) THEN
            RAISE EXCEPTION '''id'' must be of type INTEGER, ''x'' ad ''y'' must be of type FLOAT'
            USING ERRCODE = 'XX000';
    END IF;

    EXECUTE 'SELECT count(*) AS n FROM (' || sql || ') AS __a__' INTO rec;
    n = rec.n;

    RETURN query
        SELECT (seq - 1)::INTEGER AS seq, node::INTEGER AS id1, node::INTEGER AS id2, cost
        FROM pgr_eucledianTSP(sql, start_id, end_id,

            tries_per_temperature :=  500 * n :: INTEGER,
            max_changes_per_temperature := 60 * n :: INTEGER,
            max_consecutive_non_changes := 500 * n :: INTEGER,

            randomize := false) WHERE seq <= n;
    DROP TABLE ___tmp;

END;
$body$
language plpgsql volatile cost 500 ROWS 50;




create or replace function _pgr_makeDistanceMatrix(sqlin text, OUT dmatrix double precision[], OUT ids integer[])
  as
$body$
declare
    sql text;
    r record;
    
begin
    dmatrix := array[]::double precision[];
    ids := array[]::integer[];

    sql := 'with nodes as (' || sqlin || ')
        select i, array_agg(dist) as arow from (
            select a.id as i, b.id as j, st_distance(st_makepoint(a.x, a.y), st_makepoint(b.x, b.y)) as dist
              from nodes a, nodes b
             order by a.id, b.id
           ) as foo group by i order by i';

    for r in execute sql loop
        dmatrix := array_cat(dmatrix, array[r.arow]);
        ids := ids || array[r.i];
    end loop;

end;
$body$
language plpgsql stable cost 10;


CREATE OR REPLACE FUNCTION pgr_TSP(
    matrix_row_sql TEXT,
    start_id BIGINT DEFAULT 0,
    end_id BIGINT DEFAULT 0,

    max_processing_time FLOAT DEFAULT '+infinity'::FLOAT,

    tries_per_temperature INTEGER DEFAULT 500,
    max_changes_per_temperature INTEGER DEFAULT 60,
    max_consecutive_non_changes INTEGER DEFAULT 100,

    initial_temperature FLOAT DEFAULT 100,
    final_temperature FLOAT DEFAULT 0.1,
    cooling_factor FLOAT DEFAULT 0.9,

    randomize BOOLEAN DEFAULT true,

    OUT seq INTEGER,
    OUT node BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF record
AS '$libdir/libpgrouting-2.5', 'newTSP'
LANGUAGE c VOLATILE STRICT;


CREATE OR REPLACE FUNCTION pgr_eucledianTSP(
    coordinates_sql TEXT,
    start_id BIGINT DEFAULT 0,
    end_id BIGINT DEFAULT 0,

    max_processing_time FLOAT DEFAULT '+infinity'::FLOAT,

    tries_per_temperature INTEGER DEFAULT 500,
    max_changes_per_temperature INTEGER DEFAULT 60,
    max_consecutive_non_changes INTEGER DEFAULT 100,

    initial_temperature FLOAT DEFAULT 100,
    final_temperature FLOAT DEFAULT 0.1,
    cooling_factor FLOAT DEFAULT 0.9,

    randomize BOOLEAN DEFAULT true,

    OUT seq integer,
    OUT node BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF record
AS '$libdir/libpgrouting-2.5', 'eucledianTSP'
LANGUAGE c VOLATILE STRICT;





-----------------------------------------------------------------------
-- Core function for alpha shape computation.
-- The sql should return vertex ids and x,y values. Return ordered
-- vertex ids. 
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_alphashape(sql text, alpha float8 DEFAULT 0, OUT x float8, OUT y float8)
    RETURNS SETOF record
    AS '$libdir/libpgrouting-2.5', 'alphashape'
    LANGUAGE c IMMUTABLE STRICT;

----------------------------------------------------------
-- Draws an alpha shape around given set of points.
-- ** This should be rewritten as an aggregate. **
----------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_pointsAsPolygon(query varchar, alpha float8 DEFAULT 0)
	RETURNS geometry AS
	$$
	DECLARE
		r record;
		geoms geometry[];
		vertex_result record;
		i int;
		n int;
		spos int;
		q text;
		x float8[];
		y float8[];

	BEGIN
		geoms := array[]::geometry[];
		i := 1;

		FOR vertex_result IN EXECUTE 'SELECT x, y FROM pgr_alphashape('''|| query || ''', ' || alpha || ')' 
		LOOP
			x[i] = vertex_result.x;
			y[i] = vertex_result.y;
			i := i+1;
		END LOOP;

		n := i;
		IF n = 1 THEN
			RAISE NOTICE 'n = 1';
			RETURN NULL;
		END IF;

		spos := 1;
		q := 'SELECT ST_GeometryFromText(''POLYGON((';
		FOR i IN 1..n LOOP
			IF x[i] IS NULL AND y[i] IS NULL THEN
				q := q || ', ' || x[spos] || ' ' || y[spos] || '))'',0) AS geom;';
				EXECUTE q INTO r;
				geoms := geoms || array[r.geom];
				q := '';
			ELSE
				IF q = '' THEN
					spos := i;
					q := 'SELECT ST_GeometryFromText(''POLYGON((';
				END IF;
				IF i = spos THEN
					q := q || x[spos] || ' ' || y[spos];
				ELSE
					q := q || ', ' || x[i] || ' ' || y[i];
				END IF;
			END IF;
		END LOOP;

		RETURN ST_BuildArea(ST_Collect(geoms));
	END;
	$$
	LANGUAGE 'plpgsql' VOLATILE STRICT;



CREATE OR REPLACE FUNCTION _pgr_bdAstar(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    only_cost BOOLEAN DEFAULT false,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
    '$libdir/libpgrouting-2.5', 'bd_astar'
LANGUAGE C IMMUTABLE STRICT;





-- V3
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    TEXT,
    BIGINT,
    BIGINT,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], directed:=true, only_cost:=false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- V3
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    TEXT,
    BIGINT,
    BIGINT,
    BOOLEAN,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- one to many
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    TEXT,
    BIGINT,
    ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.end_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- many to one
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    TEXT,
    ANYARRAY,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.start_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- many to many
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT *
    FROM _pgr_bdAstar(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, false);
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- COMMENTS

COMMENT ON FUNCTION pgr_bdAstar(TEXT, BIGINT, BIGINT) IS 'pgr_bdAstar(One to One)';
COMMENT ON FUNCTION pgr_bdAstar(TEXT, BIGINT, BIGINT, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstar(One to One)';
COMMENT ON FUNCTION pgr_bdAstar(TEXT, ANYARRAY, BIGINT, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstar(Many to One)';
COMMENT ON FUNCTION pgr_bdAstar(TEXT, BIGINT, ANYARRAY, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstar(One to Many)';
COMMENT ON FUNCTION pgr_bdAstar(TEXT, ANYARRAY, ANYARRAY, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstar(Many to Many)';



-- one to one
CREATE OR REPLACE FUNCTION pgr_bdAstarCost(
    TEXT,
    BIGINT,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- one to many
CREATE OR REPLACE FUNCTION pgr_bdAstarCost(
    TEXT,
    BIGINT,
    ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- many to one
CREATE OR REPLACE FUNCTION pgr_bdAstarCost(
    TEXT,
    ANYARRAY,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- many to many
CREATE OR REPLACE FUNCTION pgr_bdAstarCost(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], $4, $5, $6::FLOAT, $7::FLOAT, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- COMMENTS

COMMENT ON FUNCTION pgr_bdAstarCost(TEXT, BIGINT, BIGINT, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstarCost(One to One)';
COMMENT ON FUNCTION pgr_bdAstarCost(TEXT, BIGINT, ANYARRAY, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstarCost(One to Many)';
COMMENT ON FUNCTION pgr_bdAstarCost(TEXT, ANYARRAY, BIGINT, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstarCost(Many to One)';
COMMENT ON FUNCTION pgr_bdAstarCost(TEXT, ANYARRAY, ANYARRAY, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstarCost(Many to Many)';


-- bdDijkstra MANY TO MANY
CREATE OR REPLACE FUNCTION _pgr_bdDijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    only_cost BOOLEAN DEFAULT false,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'bdDijkstra'
LANGUAGE c IMMUTABLE STRICT;



-- ONE TO ONE
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vid BIGINT,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], true, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- TODO directed BOOLEAN DEFAULT TRUE,  on version 3
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vid BIGINT,
    directed BOOLEAN,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4, false) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- ONE TO MANY
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(
    edges_sql TEXT,
    start_vid BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.end_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, false) as a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- MANY TO ONE
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vid BIGINT,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.seq, a.path_seq, a.start_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, false) as a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;



-- MANY TO MANY
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT *
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], directed, false) as a;
$BODY$
LANGUAGE SQL VOLATILE
COST 100
ROWS 1000;



CREATE OR REPLACE FUNCTION pgr_bdDijkstraCost(
    edges_sql TEXT,
    BIGINT,
    BIGINT,
    directed BOOLEAN DEFAULT TRUE,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4, true) AS a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;

-- ONE TO MANY
CREATE OR REPLACE FUNCTION pgr_bdDijkstraCost(
    edges_sql TEXT,
    BIGINT,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4, true) as a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;


-- MANY TO ONE
CREATE OR REPLACE FUNCTION pgr_bdDijkstraCost(
    edges_sql TEXT,
    start_vids ANYARRAY,
    BIGINT,
    directed BOOLEAN DEFAULT TRUE,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4, true) as a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;



-- MANY TO MANY
CREATE OR REPLACE FUNCTION pgr_bdDijkstraCost(
    edges_sql TEXT,
    start_vids ANYARRAY,
    end_vids ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], directed, true) as a;
$BODY$
LANGUAGE SQL VOLATILE
COST 100
ROWS 1000;

-----------------------------------------------------------------------
-- Core function for time_dependent_shortest_path computation
-- See README for description
-----------------------------------------------------------------------
--TODO - Do we need to add another sql text for the query on time-dependent-weights table?
--     - For now just checking with static data, so the query is similar to shortest_paths.

CREATE OR REPLACE FUNCTION _pgr_trsp(
    sql text,
    source_vid integer,
    target_vid integer,
    directed boolean,
    has_reverse_cost boolean,
    turn_restrict_sql text DEFAULT null)
RETURNS SETOF pgr_costResult
AS '$libdir/libpgrouting-2.5', 'turn_restrict_shortest_path_vertex'
LANGUAGE 'c' IMMUTABLE;

CREATE OR REPLACE FUNCTION _pgr_trsp(
    sql text,
    source_eid integer,
    source_pos float8,
    target_eid integer,
    target_pos float8,
    directed boolean,
    has_reverse_cost boolean,
    turn_restrict_sql text DEFAULT null)
RETURNS SETOF pgr_costResult
AS '$libdir/libpgrouting-2.5', 'turn_restrict_shortest_path_edge'
LANGUAGE 'c' IMMUTABLE;




/*  pgr_trsp    VERTEX

 - if size of restrictions_sql  is Zero or no restrictions_sql are given
     then call to pgr_dijkstra is made

 - because it reads the data wrong, when there is a reverse_cost column:
   - put all data costs in one cost column and
   - a call is made to trsp without only the positive values
*/
CREATE OR REPLACE FUNCTION pgr_trsp(
    edges_sql TEXT,
    start_vid INTEGER,
    end_vid INTEGER,
    directed BOOLEAN,
    has_rcost BOOLEAN,
    restrictions_sql TEXT DEFAULT NULL)
RETURNS SETOF pgr_costResult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
trsp_sql TEXT;
BEGIN
    has_reverse =_pgr_parameter_check('dijkstra', edges_sql, false);

    new_sql := edges_sql;
    IF (has_reverse != has_rcost) THEN  -- user contradiction
        IF (has_reverse) THEN  -- it has reverse_cost but user don't want it.
            -- to be on the safe side because it reads the data wrong, sending only postitive values
            new_sql :=
            'WITH old_sql AS (' || edges_sql || ')' ||
            '   SELECT id, source, target, cost FROM old_sql';
        ELSE -- it does not have reverse_cost but user wants it
            RAISE EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
            USING ERRCODE := 'XX000';
        END IF;
    END IF;

    IF (restrictions_sql IS NULL OR length(restrictions_sql) = 0) THEN
        -- no restrictions then its a dijkstra
        RETURN query SELECT a.seq - 1 AS seq, node::INTEGER AS id1, edge::INTEGER AS id2, cost
        FROM pgr_dijkstra(new_sql, start_vid, end_vid, directed) a;
        RETURN;
    END IF;

    RETURN query SELECT * FROM _pgr_trsp(new_sql, start_vid, end_vid, directed, has_rcost, restrictions_sql);
    RETURN;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;


/* pgr_trspVia Vertices
 - if size of restrictions_sql  is Zero or no restrictions_sql are given
     then call to pgr_dijkstra is made

 - because it reads the data wrong, when there is a reverse_cost column:
   - put all data costs in one cost column and
   - a call is made to trspViaVertices without only the positive values
*/
CREATE OR REPLACE FUNCTION pgr_trspViaVertices(
    edges_sql TEXT,
    via_vids ANYARRAY,
    directed BOOLEAN,
    has_rcost BOOLEAN,
    restrictions_sql TEXT DEFAULT NULL)
RETURNS SETOF pgr_costResult3 AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
BEGIN

    has_reverse =_pgr_parameter_check('dijkstra', edges_sql, false);

    new_sql := edges_sql;
    IF (has_reverse != has_rcost) THEN  -- user contradiction
        IF (has_reverse) THEN  -- it has reverse_cost but user don't want it.
            new_sql :=
               'WITH old_sql AS (' || edges_sql || ')' ||
                '   SELECT id, source, target, cost FROM old_sql';
        ELSE -- it does not have reverse_cost but user wants it
            RAISE EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
            USING ERRCODE := 'XX000';
        END IF;
    END IF;

    IF (restrictions_sql IS NULL OR length(restrictions_sql) = 0) THEN
        RETURN query SELECT (row_number() over())::INTEGER, path_id:: INTEGER, node::INTEGER,
            (CASE WHEN edge = -2 THEN -1 ELSE edge END)::INTEGER, cost
            FROM pgr_dijkstraVia(new_sql, via_vids, directed, strict:=true) WHERE edge != -1;
        RETURN;
    END IF;


    -- make the call without contradiction from part of the user
    RETURN query SELECT * FROM _pgr_trspViaVertices(new_sql, via_vids::INTEGER[], directed, has_rcost, restrictions_sql);
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;


CREATE OR REPLACE FUNCTION pgr_trsp(
    sql text,
    source_eid integer,
    source_pos float8,
    target_eid integer,
    target_pos float8,
    directed boolean,
    has_reverse_cost boolean,
    turn_restrict_sql text DEFAULT null)
RETURNS SETOF pgr_costResult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
trsp_sql TEXT;
BEGIN
    has_reverse =_pgr_parameter_check('dijkstra', sql, false);

    new_sql := sql;
    IF (has_reverse != has_reverse_cost) THEN  -- user contradiction
        IF (has_reverse) THEN
            -- it has reverse_cost but user don't want it.
            -- to be on the safe side because it reads the data wrong, sending only postitive values
            new_sql :=
            'WITH old_sql AS (' || sql || ')' ||
            '   SELECT id, source, target, cost FROM old_sql';
        ELSE -- it does not have reverse_cost but user wants it
            RAISE EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
            USING ERRCODE := 'XX000';
        END IF;
    END IF;

    IF (turn_restrict_sql IS NULL OR length(turn_restrict_sql) = 0) THEN
        -- no restrictions then its a with points
        RETURN query SELECT a.seq-1 AS seq, node::INTEGER AS id1, edge::INTEGER AS id2, cost
        FROM pgr_withpoints(new_sql,
            '(SELECT 1 as pid, ' || source_eid || 'as edge_id, ' || source_pos || '::float8 as fraction)'
            || ' UNION '
            || '(SELECT 2, ' || target_eid || ', ' || target_pos || ')' ::TEXT,
            -1, -2, directed) a;
        -- WHERE node != -2;
        RETURN;
    END IF;

    RETURN query SELECT * FROM _pgr_trsp(new_sql, source_eid, source_pos, target_eid, target_pos, directed, has_reverse_cost, turn_restrict_sql);
    RETURN;

END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;

create or replace function _pgr_trspViaVertices(sql text, vids integer[], directed boolean, has_rcost boolean, turn_restrict_sql text DEFAULT NULL::text)
    RETURNS SETOF pgr_costresult3 AS
$body$
/*
 *  pgr_trsp(sql text, vids integer[], directed boolean, has_reverse_cost boolean, turn_restrict_sql text DEFAULT NULL::text)
 *
 *  Compute TRSP with via points. We compute the path between vids[i] and vids[i+1] and chain the results together.
 *
 *  NOTE: this is a prototype function, we can gain a lot of efficiencies by implementing this in C/C++
 *
*/
declare
    i integer;
    rr pgr_costresult3;
    lrr pgr_costresult3;
    lrra boolean := false;
    seq integer := 0;
    seq2 integer := 0;

begin

    -- loop through each pair of vids and compute the path
    for i in 1 .. array_length(vids, 1)-1 loop
        seq2 := seq2 + 1;
        for rr in select a.seq, seq2 as id1, a.id1 as id2, a.id2 as id3, a.cost
                    from _pgr_trsp(sql, vids[i], vids[i+1], directed, has_rcost, turn_restrict_sql) as a loop
            -- filter out the individual path ends except the last one
            -- we might not want to do this so we can know where the via points are in the path result
            -- but this needs more thought
            --raise notice 'rr: %', rr;
            if rr.id3 = -1 then
                lrr := rr;
                lrra := true;
            else
                seq := seq + 1;
                rr.seq := seq;
                return next rr;
            end if;
        end loop;
    end loop;

    if lrra then
        seq := seq + 1;
        lrr.seq := seq;
        return next lrr;
    end if;
    return;
end;
$body$
    language plpgsql stable
    cost 100
    rows 1000;




----------------------------------------------------------------------------------------------------------

create or replace function pgr_trspViaEdges(sql text, eids integer[], pcts float8[], directed boolean, has_rcost boolean, turn_restrict_sql text DEFAULT NULL::text)
    RETURNS SETOF pgr_costresult3 AS
$body$
/*
 *  pgr_trsp(sql text, eids integer[], pcts float8[], directed boolean, has_reverse_cost boolean, turn_restrict_sql text DEFAULT NULL::text)
 *
 *  Compute TRSP with edge_ids and pposition along edge. We compute the path between eids[i], pcts[i] and eids[i+1], pcts[i+1]
 *  and chain the results together.
 *
 *  NOTE: this is a prototype function, we can gain a lot of efficiencies by implementing this in C/C++
 *
*/
declare
    i integer;
    rr pgr_costresult3;
    lrr pgr_costresult3;
    first boolean := true;
    seq integer := 0;
    seq2 integer :=0;
    has_reverse BOOLEAN;
    point_is_vertex BOOLEAN := false;
    edges_sql TEXT;
    f float;

begin
    has_reverse =_pgr_parameter_check('dijkstra', sql, false);
    edges_sql := sql;
    IF (has_reverse != has_rcost) THEN
        IF (NOT has_rcost) THEN
            -- user does not want to use reverse cost column
            edges_sql = 'SELECT id, source, target, cost FROM (' || sql || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    FOREACH f IN ARRAY pcts LOOP
        IF f in (0,1) THEN
           point_is_vertex := true;
        END IF;
    END LOOP;

    IF (turn_restrict_sql IS NULL OR length(turn_restrict_sql) = 0) AND NOT point_is_vertex THEN
        -- no restrictions then its a _pgr_withPointsVia
        RETURN query SELECT a.seq::INTEGER, path_id::INTEGER AS id1, node::INTEGER AS id2, edge::INTEGER AS id3, cost
        FROM _pgr_withPointsVia(edges_sql, eids, pcts, directed) a;
        RETURN;
    END IF;

    if array_length(eids, 1) != array_length(pcts, 1) then
        raise exception 'The length of arrays eids and pcts must be the same!';
    end if;

    -- loop through each pair of vids and compute the path
    for i in 1 .. array_length(eids, 1)-1 loop
        seq2 := seq2 + 1;
        for rr in select a.seq, seq2 as id1, a.id1 as id2, a.id2 as id3, a.cost
                    from pgr_trsp(edges_sql,
                                  eids[i], pcts[i],
                                  eids[i+1], pcts[i+1],
                                  directed,
                                  has_rcost,
                                  turn_restrict_sql) as a loop
            -- combine intermediate via costs when cost is split across
            -- two parts of a segment because it stops it and
            -- restarts the next leg also on it
            -- we might not want to do this so we can know where the via points are in the path result
            -- but this needs more thought
            --
            -- there are multiple condition we have to deal with
            -- between the end of one leg and start of the next
            -- 1. same vertex_id. edge_id=-1; drop record with edge_id=-1
            -- means: path ends on vertex
            -- NOTICE:  rr: (19,1,44570022,-1,0)
            -- NOTICE:  rr: (0,2,44570022,1768045,2.89691196717448)
            -- 2. vertex_id=-1; sum cost components
            -- means: path end/starts with the segment
            -- NOTICE:  rr: (11,2,44569628,1775909,9.32885885148532)
            -- NOTICE:  rr: (0,3,-1,1775909,0.771386350984395)

            --raise notice 'rr: %', rr;
            if first then
                lrr := rr;
                first := false;
            else
                if lrr.id3 = -1 then
                    lrr := rr;
                elsif lrr.id3 = rr.id3 then
                    lrr.cost := lrr.cost + rr.cost;
                    if rr.id2 = -1 then
                        rr.id2 := lrr.id2;
                    end if;
                else
                    seq := seq + 1;
                    lrr.seq := seq;
                    return next lrr;
                    lrr := rr;
                end if;
            end if;
        end loop;
    end loop;

    seq := seq + 1;
    lrr.seq := seq;
    return next lrr;
    return;
end;
$body$
    language plpgsql stable
    cost 100
    rows 1000;


----------------------------------------------------------------------------------------------------------
/*this via functions are not documented they will be deleted on 2.2

create or replace function pgr_trsp(sql text, vids integer[], directed boolean, has_reverse_cost boolean, turn_restrict_sql text DEFAULT NULL::text)
    RETURNS SETOF pgr_costresult AS
$body$
begin
    return query select seq, id2 as id1, id3 as id2, cost from pgr_trspVia( sql, vids, directed, has_reverse_cost, turn_restrict_sql);
end;
$body$
    language plpgsql stable
    cost 100
    rows 1000;



create or replace function pgr_trsp(sql text, eids integer[], pcts float8[], directed boolean, has_reverse_cost boolean, turn_restrict_sql text DEFAULT NULL::text)
    RETURNS SETOF pgr_costresult AS
$body$
begin
    return query select seq, id2 as id1, id3 as id2, cost from pgr_trspVia(sql, eids, pcts, directed, has_reverse_cost, turn_restrict_sql);
end;
$body$
    language plpgsql stable
    cost 100
    rows 1000;
*/



----------------------------
--    MANY TO MANY
----------------------------


CREATE OR REPLACE FUNCTION _pgr_maxflow(
    edges_sql TEXT,
    sources ANYARRAY,
    targets ANYARRAY,
    algorithm INTEGER DEFAULT 1,
    only_flow BOOLEAN DEFAULT false,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'max_flow_many_to_many'
    LANGUAGE c IMMUTABLE STRICT;




------------------------------------
-- 3 pgr_edmondsKarp
------------------------------------


CREATE OR REPLACE FUNCTION pgr_edmondsKarp(
    TEXT,
    BIGINT,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], 3);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_edmondsKarp(
    TEXT,
    BIGINT,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], 3);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_edmondsKarp(
    TEXT,
    ANYARRAY,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], 3);
  $BODY$
  LANGUAGE sql VOLATILE;


CREATE OR REPLACE FUNCTION pgr_edmondsKarp(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], 3);
  $BODY$
  LANGUAGE sql VOLATILE;



------------------------------------
-- 2 boykov_kolmogorov
------------------------------------


CREATE OR REPLACE FUNCTION pgr_boykovKolmogorov(
    TEXT,
    BIGINT,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], 2);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_boykovKolmogorov(
    TEXT,
    BIGINT,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], 2);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_boykovKolmogorov(
    TEXT,
    ANYARRAY,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], 2);
  $BODY$
  LANGUAGE sql VOLATILE;


CREATE OR REPLACE FUNCTION pgr_boykovKolmogorov(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], 2);
  $BODY$
  LANGUAGE sql VOLATILE;



------------------------------------
-- 1 pgr_pushRelabel
------------------------------------


CREATE OR REPLACE FUNCTION pgr_pushRelabel(
    TEXT,
    BIGINT,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], 1);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_pushRelabel(
    TEXT,
    BIGINT,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], 1);
  $BODY$
  LANGUAGE sql VOLATILE;



CREATE OR REPLACE FUNCTION pgr_pushRelabel(
    TEXT,
    ANYARRAY,
    BIGINT,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], 1);
  $BODY$
  LANGUAGE sql VOLATILE;


CREATE OR REPLACE FUNCTION pgr_pushRelabel(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
        SELECT *
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], 1);
  $BODY$
  LANGUAGE sql VOLATILE;



/***********************************
        MANY TO MANY
***********************************/

CREATE OR REPLACE FUNCTION pgr_maxFlow(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertices ANYARRAY
    )
  RETURNS BIGINT AS
  $BODY$
        SELECT flow
        FROM _pgr_maxflow(_pgr_get_statement($1), $2::BIGINT[], $3::BIGINT[], algorithm := 1, only_flow := true);
  $BODY$
  LANGUAGE SQL VOLATILE;

/***********************************
        ONE TO ONE
***********************************/

CREATE OR REPLACE FUNCTION pgr_maxFlow(
    edges_sql TEXT,
    source_vertices BIGINT,
    sink_vertices BIGINT
    )
  RETURNS BIGINT AS
  $BODY$
        SELECT *
        FROM pgr_maxflow($1, ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[]);
  $BODY$
  LANGUAGE SQL VOLATILE;

/***********************************
        ONE TO MANY
***********************************/

CREATE OR REPLACE FUNCTION pgr_maxFlow(
    edges_sql TEXT,
    source_vertices BIGINT,
    sink_vertices ANYARRAY
    )
  RETURNS BIGINT AS
  $BODY$
        SELECT *
        FROM pgr_maxflow($1, ARRAY[$2]::BIGINT[], $3::BIGINT[]);
  $BODY$
  LANGUAGE SQL VOLATILE;

/***********************************
        MANY TO ONE
***********************************/

CREATE OR REPLACE FUNCTION pgr_maxFlow(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertices BIGINT
    )
  RETURNS BIGINT AS
  $BODY$
        SELECT *
        FROM pgr_maxflow($1, $2::BIGINT[], ARRAY[$3]::BIGINT[]);
  $BODY$
  LANGUAGE SQL VOLATILE;



--FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maxCardinalityMatch(
    edges_sql TEXT,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT edge BIGINT,
    OUT source BIGINT,
    OUT target BIGINT
    )
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'maximum_cardinality_matching'
    LANGUAGE c IMMUTABLE STRICT;




/***********************************
        MANY TO MANY
***********************************/

CREATE OR REPLACE FUNCTION pgr_edgeDisjointPaths(
    TEXT,
    ANYARRAY,
    ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT
    )
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'edge_disjoint_paths_many_to_many'
    LANGUAGE c IMMUTABLE STRICT;

/***********************************
        ONE TO ONE
***********************************/

CREATE OR REPLACE FUNCTION pgr_edgeDisjointPaths(
    TEXT,
    bigint,
    bigint,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT
    )
  RETURNS SETOF RECORD AS
  $BODY$
    SELECT a.seq, a.path_id, a.path_seq, a.node, a.edge, a.cost, a.agg_cost
    FROM pgr_edgeDisjointPaths(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], $4) AS a;
  $BODY$
LANGUAGE sql VOLATILE;

/***********************************
        ONE TO MANY
***********************************/

CREATE OR REPLACE FUNCTION pgr_edgeDisjointPaths(
    TEXT,
    bigint,
    ANYARRAY,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT
    )
  RETURNS SETOF RECORD AS
  $BODY$
    SELECT a.seq, a.path_id, a.path_seq, a.end_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM pgr_edgeDisjointPaths(_pgr_get_statement($1), ARRAY[$2]::BIGINT[], $3::BIGINT[], $4) AS a;
  $BODY$
LANGUAGE sql VOLATILE;

/***********************************
        MANY TO ONE
***********************************/

CREATE OR REPLACE FUNCTION pgr_edgeDisjointPaths(
    TEXT,
    ANYARRAY,
    BIGINT,
    IN directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT
    )
  RETURNS SETOF RECORD AS
  $BODY$
    SELECT a.seq, a.path_id, a.path_seq, a.start_vid, a.node, a.edge, a.cost, a.agg_cost
    FROM pgr_edgeDisjointPaths(_pgr_get_statement($1), $2::BIGINT[], ARRAY[$3]::BIGINT[], $4) AS a;
  $BODY$
LANGUAGE sql VOLATILE;


CREATE OR REPLACE FUNCTION pgr_contractGraph(
    edges_sql TEXT,
    contraction_order BIGINT[],
    max_cycles integer DEFAULT 1,
    forbidden_vertices BIGINT[] DEFAULT ARRAY[]::BIGINT[],
    directed BOOLEAN DEFAULT true,
    OUT seq integer,
    OUT type TEXT,
    OUT id BIGINT,
    OUT contracted_vertices BIGINT[],
    OUT source BIGINT,
    OUT target BIGINT,
    OUT cost float)

  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'contractGraph'
    LANGUAGE c IMMUTABLE STRICT;



CREATE OR REPLACE FUNCTION _pgr_pickDeliverEuclidean (
    orders_sql TEXT,
    vehicles_sql TEXT,
    max_cycles INTEGER DEFAULT 10, 

    OUT seq INTEGER,
    OUT vehicle_number INTEGER,
    OUT vehicle_id BIGINT,
    OUT vehicle_seq INTEGER,
    OUT order_id BIGINT,
    OUT stop_type INT,
    OUT cargo FLOAT,
    OUT travel_time FLOAT,
    OUT arrival_time FLOAT,
    OUT wait_time FLOAT,
    OUT service_time FLOAT,
    OUT departure_time FLOAT
)

  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'pickDeliverEuclidean'
    LANGUAGE c IMMUTABLE STRICT;



CREATE OR REPLACE FUNCTION _pgr_pickDeliver(
    orders_sql TEXT,
    vehicles_sql TEXT,
    matrix_cell_sql TEXT,
    max_cycles INTEGER DEFAULT 10, 

    OUT seq INTEGER,
    OUT vehicle_number INTEGER,
    OUT vehicle_id BIGINT,
    OUT vehicle_seq INTEGER,
    OUT order_id BIGINT,
    OUT stop_type INT,
    OUT cargo FLOAT,
    OUT travel_time FLOAT,
    OUT arrival_time FLOAT,
    OUT wait_time FLOAT,
    OUT service_time FLOAT,
    OUT departure_time FLOAT
)

RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'pickDeliver'
LANGUAGE c IMMUTABLE STRICT;




-- for the sake of Reginas book I am keeping this signature

CREATE OR REPLACE FUNCTION _pgr_pickDeliver(
    customers_sql TEXT,
    max_vehicles INTEGER,
    capacity FLOAT,
    speed FLOAT DEFAULT 1, 
    max_cycles INTEGER DEFAULT 10, 

    OUT seq INTEGER,
    OUT vehicle_id INTEGER,
    OUT vehicle_seq INTEGER,
    OUT stop_id BIGINT,
    OUT travel_time FLOAT,
    OUT arrival_time FLOAT,
    OUT wait_time FLOAT,
    OUT service_time FLOAT,
    OUT departure_time FLOAT
)
RETURNS SETOF RECORD AS
$BODY$
DECLARE
    orders_sql TEXT;
    vehicles_sql TEXT;
    final_sql TEXT;
BEGIN
    orders_sql = $$WITH
        customer_data AS ($$ || customers_sql || $$ ),
        pickups AS (
            SELECT id, demand, x as p_x, y as p_y, opentime as p_open, closetime as p_close, servicetime as p_service
            FROM  customer_data WHERE pindex = 0 AND id != 0
        ),
        deliveries AS (
            SELECT pindex AS id, x as d_x, y as d_y, opentime as d_open, closetime as d_close, servicetime as d_service
            FROM  customer_data WHERE dindex = 0 AND id != 0
        )
        SELECT * FROM pickups JOIN deliveries USING(id) ORDER BY pickups.id
    $$;

    vehicles_sql = $$WITH
        customer_data AS ($$ || customers_sql || $$ )
        SELECT id, x AS start_x, y AS start_y,
            opentime AS start_open, closetime AS start_close, $$ ||
            capacity || $$ AS capacity, $$ || max_vehicles || $$ AS number, $$ || speed || $$ AS speed
            FROM customer_data WHERE id = 0 LIMIT 1
        $$;
--  seq | vehicle_id | vehicle_seq | stop_id | travel_time | arrival_time | wait_time | service_time | departure_time 
    final_sql = $$ WITH
        customer_data AS ($$ || customers_sql || $$ ),
        p_deliver AS (SELECT * FROM _pgr_pickDeliverEuclidean('$$ || orders_sql || $$',  '$$ || vehicles_sql || $$',  $$ || max_cycles || $$ )),
        picks AS (SELECT p_deliver.*, pindex, dindex, id AS the_id FROM p_deliver JOIN customer_data ON (id = order_id AND stop_type = 2)),
        delivers AS (SELECT p_deliver.*, pindex, dindex, dindex AS the_id FROM p_deliver JOIN customer_data ON (id = order_id AND stop_type = 3)),
        depots AS (SELECT p_deliver.*, 0 as pindex, 0 as dindex, 0 AS the_id FROM p_deliver WHERE (stop_type IN (0,1,6))),
        the_union AS (SELECT * FROM picks UNION SELECT * FROM delivers UNION SELECT * from depots)

        SELECT (row_number() over(ORDER BY a.seq))::INTEGER, vehicle_number, a.vehicle_seq, the_id::BIGINT, a.travel_time, a.arrival_time, a.wait_time, a.service_time, a.departure_time
        FROM (SELECT * FROM the_union) AS a ORDER BY a.seq
        $$;
    RETURN QUERY EXECUTE final_sql;
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


-----------------------------------------------------------------------
-- Core function for vrp with sigle depot computation
-- See README for description
-----------------------------------------------------------------------
--
--

create or replace function pgr_vrpOneDepot(
	order_sql text,
	vehicle_sql text,
	cost_sql text,
	depot_id integer,
	 
	OUT oid integer, 
	OUT opos integer, 
	OUT vid integer, 
	OUT tarrival integer, 
	OUT tdepart integer)
returns setof record as
'$libdir/libpgrouting-2.5', 'vrp'
LANGUAGE c VOLATILE STRICT;




/*
ONE TO ONE
*/

CREATE OR REPLACE FUNCTION _pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid BIGINT,
    end_pid BIGINT,
    directed BOOLEAN,
    driving_side CHAR,
    details BOOLEAN,

    only_cost BOOLEAN DEFAULT false, -- gets path


    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'one_to_one_withPoints'
LANGUAGE c IMMUTABLE STRICT;

/*
ONE TO MANY
*/

CREATE OR REPLACE FUNCTION _pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid BIGINT,
    end_pids ANYARRAY,
    directed BOOLEAN,
    driving_side CHAR,
    details BOOLEAN,

    only_cost BOOLEAN DEFAULT false, -- gets path


    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'one_to_many_withPoints'
LANGUAGE c IMMUTABLE STRICT;


/*
MANY TO ONE
*/

CREATE OR REPLACE FUNCTION _pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    end_pid BIGINT,
    directed BOOLEAN,
    driving_side CHAR,
    details BOOLEAN,

    only_cost BOOLEAN DEFAULT false, -- gets path


    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'many_to_one_withPoints'
LANGUAGE c IMMUTABLE STRICT;




/*
MANY TO MANY
*/

CREATE OR REPLACE FUNCTION _pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    end_pids ANYARRAY,
    directed BOOLEAN,
    driving_side CHAR,
    details BOOLEAN,

    only_cost BOOLEAN DEFAULT false, -- gets path


    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
'$libdir/libpgrouting-2.5', 'many_to_many_withPoints'
LANGUAGE c IMMUTABLE STRICT;




/*
ONE TO ONE
*/
CREATE OR REPLACE FUNCTION pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid BIGINT,
    end_pid BIGINT,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL
    details BOOLEAN DEFAULT false,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT *
        FROM _pgr_withPoints($1, $2, $3, $4, $5, $6, $7);
    END
    $BODY$
    LANGUAGE plpgsql VOLATILE
    COST 100
    ROWS 1000;


/*
ONE TO MANY
*/
CREATE OR REPLACE FUNCTION pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pid BIGINT,
    end_pids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL
    details BOOLEAN DEFAULT false,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT end_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT *
        FROM _pgr_withPoints($1, $2, $3, $4, $5, $6, $7);
    END
    $BODY$
    LANGUAGE plpgsql VOLATILE
    COST 100
    ROWS 1000;

/*
MANY TO ONE
*/
CREATE OR REPLACE FUNCTION pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    end_pid BIGINT,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL
    details BOOLEAN DEFAULT false,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT *
        FROM _pgr_withPoints($1, $2, $3, $4, $5, $6, $7);
    END
    $BODY$
    LANGUAGE plpgsql VOLATILE
    COST 100
    ROWS 1000;

/*
MANY TO MANY
*/
CREATE OR REPLACE FUNCTION pgr_withPoints(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    end_pids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL
    details BOOLEAN DEFAULT false,

    OUT seq INTEGER,
    OUT path_seq INTEGER,
    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT *
        FROM _pgr_withPoints($1, $2, $3, $4, $5, $6, $7);
    END
    $BODY$
    LANGUAGE plpgsql VOLATILE
    COST 100
    ROWS 1000;


/*
ONE TO ONE
*/

CREATE OR REPLACE FUNCTION pgr_withPointsCost(
    edges_sql TEXT,
    points_sql TEXT,
    BIGINT,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL

    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT $3, $4, a.agg_cost
        FROM _pgr_withPoints($1, $2, $3, $4, $5, $6, TRUE, TRUE) AS a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;

/*
ONE TO MANY
*/

CREATE OR REPLACE FUNCTION pgr_withPointsCost(
    edges_sql TEXT,
    points_sql TEXT,
    BIGINT,
    end_pids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL

    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT $3, a.end_pid, a.agg_cost
        FROM _pgr_withPoints($1, $2, $3, $4, $5,  $6, TRUE, TRUE) AS a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;

/*
MANY TO ONE
*/

CREATE OR REPLACE FUNCTION pgr_withPointsCost(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    BIGINT,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL

    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT a.start_pid, $4, a.agg_cost
        FROM _pgr_withPoints($1, $2, $3, $4, $5,  $6, TRUE, TRUE) AS a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;

/*
MANY TO MANY
*/

CREATE OR REPLACE FUNCTION pgr_withPointsCost(
    edges_sql TEXT,
    points_sql TEXT,
    start_pids ANYARRAY,
    end_pids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL

    OUT start_pid BIGINT,
    OUT end_pid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT a.start_pid, a.end_pid, a.agg_cost
        FROM _pgr_withPoints($1, $2, $3, $4, $5,  $6, TRUE, TRUE) AS a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;




CREATE OR REPLACE FUNCTION  _pgr_withPointsVia(
    sql text,
    via_edges bigint[], 
    fraction float[], 
    directed BOOLEAN DEFAULT TRUE,

    OUT seq INTEGER,
    OUT path_id INTEGER,
    OUT path_seq INTEGER,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT node BIGINT,
    OUT edge BIGINT,
    OUT cost FLOAT,
    OUT agg_cost FLOAT,
    OUT route_agg_cost FLOAT)

  RETURNS SETOF RECORD AS
  $BODY$
  DECLARE
  has_rcost boolean;
  sql_new_vertices text := ' ';
  sql_on_vertex text;
  v_union text := ' ';
  dummyrec record;
  rec1 record;
  via_vertices int[];
  sql_safe text;
  new_edges text;
  BEGIN
     BEGIN
        sql_safe = 'SELECT id, source, target, cost, reverse_cost FROM ('|| sql || ') AS __a';

        EXECUTE 'select reverse_cost, pg_typeof(reverse_cost)::text as rev_type  from ('||sql_safe||' ) AS __b__ limit 1 ' INTO rec1;
        has_rcost := true;
        EXCEPTION
          WHEN OTHERS THEN
            has_rcost = false;
     END;
 

      IF array_length(via_edges, 1) != array_length(fraction, 1) then
        RAISE EXCEPTION 'The length of via_edges is different of length of via_edges';
      END IF;

      FOR i IN 1 .. array_length(via_edges, 1)
      LOOP
          IF fraction[i] = 0 THEN
              sql_on_vertex := 'SELECT source FROM ('|| sql || ') __a where id = ' || via_edges[i];
              EXECUTE sql_on_vertex into dummyrec; 
              via_vertices[i] = dummyrec.source;
          ELSE IF fraction[i] = 1 THEN
              sql_on_vertex := 'SELECT target FROM ('|| sql || ') __a where id = ' || via_edges[i];
              EXECUTE sql_on_vertex into dummyrec; 
              via_vertices[i] = dummyrec.target;
          ELSE
              via_vertices[i] = -i;
              IF has_rcost THEN
                   sql_new_vertices = sql_new_vertices || v_union ||
                          '(SELECT id, source, ' ||  -i || ' AS target, cost * ' || fraction[i] || ' AS cost,
                              reverse_cost * (1 - ' || fraction[i] || ')  AS reverse_cost
                          FROM (SELECT * FROM (' || sql || ') __b' || i || ' WHERE id = ' || via_edges[i] || ') __a' || i ||')
                             UNION
                          (SELECT id, ' ||  -i || ' AS source, target, cost * (1 -' || fraction[i] || ') AS cost,
                              reverse_cost *  ' || fraction[i] || '  AS reverse_cost
                          FROM (SELECT * FROM (' || sql || ') __b' || i || ' where id = ' || via_edges[i] || ') __a' || i ||')';
                      v_union = ' UNION ';
               ELSE 
                   sql_new_vertices = sql_new_vertices || v_union ||
                          '(SELECT id, source, ' ||  -i || ' AS target, cost * ' || fraction[i] || ' AS cost
                          FROM (SELECT * FROM (' || sql || ') __b' || i || ' WHERE id = ' || via_edges[i] || ') __a' || i ||')
                             UNION
                          (SELECT id, ' ||  -i || ' AS source, target, cost * (1 -' || fraction[i] || ') AS cost
                          FROM (SELECT * FROM (' || sql || ') __b' || i || ' WHERE id = ' || via_edges[i] || ') __a' || i ||')';
                      v_union = ' UNION ';
               END IF;
          END IF;
          END IF;
     END LOOP;

     IF sql_new_vertices = ' ' THEN
         new_edges := sql; 
     ELSE
         IF has_rcost THEN
            new_edges:= 'WITH
                   original AS ( ' || sql || '),
                   the_union AS ( ' || sql_new_vertices || '),
                   first_part AS ( SELECT * FROM (SELECT id, target AS source,  lead(target) OVER w  AS target,
                         lead(cost) OVER w  - cost AS cost,
                         lead(cost) OVER w  - cost AS reverse_cost
                      FROM  the_union  WHERE source > 0 AND cost > 0
                      WINDOW w AS (PARTITION BY id  ORDER BY cost ASC) ) as n2
                      WHERE target IS NOT NULL),
                   second_part AS ( SELECT * FROM (SELECT id, lead(source) OVER w  AS source, source as target,
                         reverse_cost - lead(reverse_cost) OVER w  AS cost,
                         reverse_cost - lead(reverse_cost) OVER w  AS reverse_cost
                      FROM  the_union  WHERE target > 0 and reverse_cost > 0
                      WINDOW w AS (PARTITION BY id  ORDER BY reverse_cost ASC) ) as n2
                      WHERE source IS NOT NULL),
                   more_union AS ( SELECT * from (
                       (SELECT * FROM original) 
                             UNION 
                       (SELECT * FROM the_union) 
                             UNION 
                       (SELECT * FROM first_part) 
                             UNION
                       (SELECT * FROM second_part) ) _union )
                  SELECT *  FROM more_union';
         ELSE
            new_edges:= 'WITH
                   original AS ( ' || sql || '),
                   the_union AS ( ' || sql_new_vertices || '),
                   first_part AS ( SELECT * FROM (SELECT id, target AS source,  lead(target) OVER w  AS target,
                         lead(cost) OVER w  - cost AS cost
                      FROM  the_union  WHERE source > 0 AND cost > 0
                      WINDOW w AS (PARTITION BY id  ORDER BY cost ASC) ) as n2
                      WHERE target IS NOT NULL ),
                   more_union AS ( SELECT * from (
                       (SELECT * FROM original) 
                             UNION 
                       (SELECT * FROM the_union) 
                             UNION 
                       (SELECT * FROM first_part) ) _union )
                  SELECT *  FROM more_union';
          END IF;
      END IF;

 -- raise notice '%', new_edges;
     sql_new_vertices := sql_new_vertices || v_union || ' (' || sql || ')';
     RETURN query SELECT *
         FROM pgr_dijkstraVia(new_edges, via_vertices, directed, has_rcost);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;




/*
.. function:: _pgr_createtopology(edge_table, tolerance,the_geom,id,source,target,rows_where)

Based on the geometry:
Fill the source and target column for all lines.
All line end points within a distance less than tolerance, are assigned the same id

Author: Christian Gonzalez <christian.gonzalez@sigis.com.ve>
Author: Stephen Woodbridge <woodbri@imaptools.com>
Modified by: Vicky Vergara <vicky_vergara@hotmail,com>

HISTORY
Last changes: 2013-03-22
2013-08-19:  handling schemas
2014-july: fixes issue 211
*/

CREATE OR REPLACE FUNCTION pgr_createtopology(edge_table text, tolerance double precision, 
		   the_geom text default 'the_geom', id text default 'id',
		   source text default 'source', target text default 'target',rows_where text default 'true',
		   clean boolean default FALSE)
RETURNS VARCHAR AS
$BODY$

DECLARE
    points record;
    sridinfo record;
    source_id bigint;
    target_id bigint;
    totcount bigint;
    rowcount bigint;
    srid integer;
    sql text;
    sname text;
    tname text;
    tabname text;
    vname text;
    vertname text;
    gname text;
    idname text;
    sourcename text;
    targetname text;
    notincluded integer;
    i integer;
    naming record;
    info record;
    flag boolean;
    query text;
    idtype text;
    gtype text;
    sourcetype text;
    targettype text;
    debuglevel text;
    dummyRec text;
    fnName text;
    err bool;
    msgKind int;
    emptied BOOLEAN;

BEGIN
    msgKind = 1; -- notice
    fnName = 'pgr_createTopology';
    raise notice 'PROCESSING:'; 
    raise notice 'pgr_createTopology(''%'', %, ''%'', ''%'', ''%'', ''%'', rows_where := ''%'', clean := %)',edge_table,tolerance,the_geom,id,source,target,rows_where, clean;
    execute 'show client_min_messages' into debuglevel;


    raise notice 'Performing checks, please wait .....';

        execute 'select * from _pgr_getTableName('|| quote_literal(edge_table)
                                                  || ',2,' || quote_literal(fnName) ||' )' into naming;
        sname=naming.sname;
        tname=naming.tname;
        tabname=sname||'.'||tname;
        vname=tname||'_vertices_pgr';
        vertname= sname||'.'||vname;
        rows_where = ' AND ('||rows_where||')'; 
      raise DEBUG '     --> OK';


      raise debug 'Checking column names in edge table';
        select * into idname     from _pgr_getColumnName(sname, tname,id,2,fnName);
        select * into sourcename from _pgr_getColumnName(sname, tname,source,2,fnName);
        select * into targetname from _pgr_getColumnName(sname, tname,target,2,fnName);
        select * into gname      from _pgr_getColumnName(sname, tname,the_geom,2,fnName);


        err = sourcename in (targetname,idname,gname) or  targetname in (idname,gname) or idname=gname;
        perform _pgr_onError( err, 2, fnName,
               'Two columns share the same name', 'Parameter names for id,the_geom,source and target  must be different',
	       'Column names are OK');

      raise DEBUG '     --> OK';

      raise debug 'Checking column types in edge table';
        select * into sourcetype from _pgr_getColumnType(sname,tname,sourcename,1, fnName);
        select * into targettype from _pgr_getColumnType(sname,tname,targetname,1, fnName);
        select * into idtype from _pgr_getColumnType(sname,tname,idname,1, fnName);

        err = idtype not in('integer','smallint','bigint');
        perform _pgr_onError(err, 2, fnName,
	       'Wrong type of Column id:'|| idname, ' Expected type of '|| idname || ' is integer,smallint or bigint but '||idtype||' was found');

        err = sourcetype not in('integer','smallint','bigint');
        perform _pgr_onError(err, 2, fnName,
	       'Wrong type of Column source:'|| sourcename, ' Expected type of '|| sourcename || ' is integer,smallint or bigint but '||sourcetype||' was found');

        err = targettype not in('integer','smallint','bigint');
        perform _pgr_onError(err, 2, fnName,
	       'Wrong type of Column target:'|| targetname, ' Expected type of '|| targetname || ' is integer,smallint or bigint but '||targettype||' was found');

      raise DEBUG '     --> OK';

      raise debug 'Checking SRID of geometry column';
         query= 'SELECT ST_SRID(' || quote_ident(gname) || ') as srid '
            || ' FROM ' || _pgr_quote_ident(tabname)
            || ' WHERE ' || quote_ident(gname)
            || ' IS NOT NULL LIMIT 1';
         raise debug '%',query;
         EXECUTE query INTO sridinfo;

         err =  sridinfo IS NULL OR sridinfo.srid IS NULL;
         perform _pgr_onError(err, 2, fnName,
	     'Can not determine the srid of the geometry '|| gname ||' in table '||tabname, 'Check the geometry of column '||gname);

         srid := sridinfo.srid;
      raise DEBUG '     --> OK';

      raise debug 'Checking and creating indices in edge table';
        perform _pgr_createIndex(sname, tname , idname , 'btree'::text);
        perform _pgr_createIndex(sname, tname , sourcename , 'btree'::text);
        perform _pgr_createIndex(sname, tname , targetname , 'btree'::text);
        perform _pgr_createIndex(sname, tname , gname , 'gist'::text);

        gname=quote_ident(gname);
        idname=quote_ident(idname);
        sourcename=quote_ident(sourcename);
        targetname=quote_ident(targetname);
      raise DEBUG '     --> OK';





    BEGIN 
        -- issue #193 & issue #210 & #213
        -- this sql is for trying out the where clause
        -- the select * is to avoid any column name conflicts
        -- limit 1, just try on first record
        -- if the where clasuse is ill formed it will be caught in the exception
        sql = 'select * from '||_pgr_quote_ident(tabname)||' WHERE true'||rows_where ||' limit 1';
        EXECUTE sql into dummyRec;
        -- end 

        -- if above where clasue works this one should work
        -- any error will be caught by the exception also
        sql = 'select count(*) from '||_pgr_quote_ident(tabname)||' WHERE (' || gname || ' IS NOT NULL AND '||
	    idname||' IS NOT NULL)=false '||rows_where;
        EXECUTE SQL  into notincluded;

        if clean then 
            raise debug 'Cleaning previous Topology ';
               execute 'UPDATE ' || _pgr_quote_ident(tabname) ||
               ' SET '||sourcename||' = NULL,'||targetname||' = NULL'; 
        else 
            raise debug 'Creating topology for edges with non assigned topology';
            if rows_where=' AND (true)' then
                rows_where=  ' and ('||quote_ident(sourcename)||' is null or '||quote_ident(targetname)||' is  null)'; 
            end if;
        end if;
        -- my thoery is that the select Count(*) will never go through here
        EXCEPTION WHEN OTHERS THEN  
             RAISE NOTICE 'Got %', SQLERRM; -- issue 210,211
             RAISE NOTICE 'ERROR: Condition is not correct, please execute the following query to test your condition'; 
             RAISE NOTICE '%',sql;
             RETURN 'FAIL'; 
    END;    

    BEGIN
         raise DEBUG 'initializing %',vertname;
         execute 'select * from _pgr_getTableName('||quote_literal(vertname)
                                                  || ',0,' || quote_literal(fnName) ||' )' into naming;
         emptied = false;
         set client_min_messages  to warning;
         IF sname=naming.sname AND vname=naming.tname  THEN
            if clean then 
                execute 'TRUNCATE TABLE '||_pgr_quote_ident(vertname)||' RESTART IDENTITY';
                execute 'SELECT DROPGEOMETRYCOLUMN('||quote_literal(sname)||','||quote_literal(vname)||','||quote_literal('the_geom')||')';
                emptied = true;
            end if;
         ELSE -- table doesn't exist
            execute 'CREATE TABLE '||_pgr_quote_ident(vertname)||' (id bigserial PRIMARY KEY,cnt integer,chk integer,ein integer,eout integer)';
            emptied = true;
         END IF;
         IF (emptied) THEN
             execute 'select addGeometryColumn('||quote_literal(sname)||','||quote_literal(vname)||','||
	         quote_literal('the_geom')||','|| srid||', '||quote_literal('POINT')||', 2)';
             perform _pgr_createIndex(vertname , 'the_geom'::text , 'gist'::text);
         END IF;
         execute 'select * from  _pgr_checkVertTab('||quote_literal(vertname) ||', ''{"id"}''::text[])' into naming;
         execute 'set client_min_messages  to '|| debuglevel;
         raise DEBUG  '  ------>OK'; 
         EXCEPTION WHEN OTHERS THEN  
             RAISE NOTICE 'Got %', SQLERRM; -- issue 210,211
             RAISE NOTICE 'ERROR: something went wrong when initializing the verties table';
             RETURN 'FAIL'; 
    END;       



    raise notice 'Creating Topology, Please wait...';
        rowcount := 0;
        FOR points IN EXECUTE 'SELECT ' || idname || '::bigint AS id,'
            || ' _pgr_StartPoint(' || gname || ') AS source,'
            || ' _pgr_EndPoint('   || gname || ') AS target'
            || ' FROM '  || _pgr_quote_ident(tabname)
            || ' WHERE ' || gname || ' IS NOT NULL AND ' || idname||' IS NOT NULL '||rows_where
        LOOP

            rowcount := rowcount + 1;
            IF rowcount % 1000 = 0 THEN
                RAISE NOTICE '% edges processed', rowcount;
            END IF;


            source_id := _pgr_pointToId(points.source, tolerance,vertname,srid);
            target_id := _pgr_pointToId(points.target, tolerance,vertname,srid);
            BEGIN                         
                sql := 'UPDATE ' || _pgr_quote_ident(tabname) || 
                    ' SET '||sourcename||' = '|| source_id::text || ','||targetname||' = ' || target_id::text || 
                    ' WHERE ' || idname || ' =  ' || points.id::text;

                IF sql IS NULL THEN
                    RAISE NOTICE 'WARNING: UPDATE % SET source = %, target = % WHERE % = % ', tabname, source_id::text, target_id::text, idname,  points.id::text;
                ELSE
                    EXECUTE sql;
                END IF;
                EXCEPTION WHEN OTHERS THEN 
                    RAISE NOTICE '%', SQLERRM;
                    RAISE NOTICE '%',sql;
                    RETURN 'FAIL'; 
            end;
        END LOOP;
        raise notice '-------------> TOPOLOGY CREATED FOR  % edges', rowcount;
        RAISE NOTICE 'Rows with NULL geometry or NULL id: %',notincluded;
        Raise notice 'Vertices table for table % is: %',_pgr_quote_ident(tabname), _pgr_quote_ident(vertname);
        raise notice '----------------------------------------------';

    RETURN 'OK';
 EXCEPTION WHEN OTHERS THEN
   RAISE NOTICE 'Unexpected error %', SQLERRM; -- issue 210,211
   RETURN 'FAIL';
END;


$BODY$
LANGUAGE plpgsql VOLATILE STRICT;
COMMENT ON FUNCTION pgr_createTopology(text, double precision,text,text,text,text,text,boolean) 
IS 'args: edge_table,tolerance, the_geom:=''the_geom'',source:=''source'', target:=''target'',rows_where:=''true'' - fills columns source and target in the geometry table and creates a vertices table for selected rows';







/*
.. function:: pgr_analyzeGraph(edge_tab, tolerance,the_geom, source,target)

   Analyzes the "edge_tab" and "edge_tab_vertices_pgr" tables and flags if
   nodes are deadends, ie vertices_tmp.cnt=1 and identifies nodes
   that might be disconnected because of gaps < tolerance or because of
   zlevel errors in the data. For example:

.. code-block:: sql

       select pgr_analyzeGraph('mytab', 0.000002);

   After the analyzing the graph, deadends are identified by *cnt=1*
   in the "vertices_tmp" table and potential problems are identified
   with *chk=1*.  (Using 'source' and 'target' columns for analysis)

.. code-block:: sql

       select * from vertices_tmp where chk = 1;

HISOTRY
:Author: Stephen Woodbridge <woodbri@swoodbridge.com>
:Modified: 2013/08/20 by Vicky Vergara <vicky_vergara@hotmail.com>

Makes more checks:
   checks table edge_tab exists in the schema
   checks source and target columns exist in edge_tab
   checks that source and target are completely populated i.e. do not have NULL values
   checks table edge_tabVertices exist in the appropriate schema
       if not, it creates it and populates it
   checks 'cnt','chk' columns exist in  edge_tabVertices
       if not, it creates them
   checks if 'id' column of edge_tabVertices is indexed
       if not, it creates the index
   checks if 'source','target',the_geom columns of edge_tab are indexed
       if not, it creates their index
   populates cnt in edge_tabVertices  <--- changed the way it was processed, because on large tables took to long.
					   For sure I am wrong doing this, but it gave me the same result as the original.
   populates chk                      <--- added a notice for big tables, because it takes time
           (edge_tab text, the_geom text, tolerance double precision)
*/

CREATE OR REPLACE FUNCTION pgr_analyzegraph(edge_table text,tolerance double precision,the_geom text default 'the_geom',id text default 'id',source text default 'source',target text default 'target',rows_where text default 'true')
RETURNS character varying AS
$BODY$

DECLARE
    points record;
    seg record;
    naming record;
    sridinfo record;
    srid integer;
    ecnt integer;
    vertname text;
    sname text;
    tname text;
    vname text;
    idname text;
    sourcename text;
    targetname text;
    sourcetype text;
    targettype text;
    geotype text;
    gname text;
    tabName text;
    flag boolean ;
    query text;
    selectionquery text;
    i integer;
    tot integer;
    NumIsolated integer;
    numdeadends integer;
    numgaps integer;
    NumCrossing integer;
    numRings integer;
    debuglevel text;




BEGIN
  raise notice 'PROCESSING:';
  raise notice 'pgr_analyzeGraph(''%'',%,''%'',''%'',''%'',''%'',''%'')',edge_table,tolerance,the_geom,id,source,target,rows_where;
  raise notice 'Performing checks, please wait ...';
  execute 'show client_min_messages' into debuglevel;


  BEGIN
    RAISE DEBUG 'Checking % exists',edge_table;
    execute 'select * from _pgr_getTableName('||quote_literal(edge_table)||',2)' into naming;
    sname=naming.sname;
    tname=naming.tname;
    tabname=sname||'.'||tname;
    vname=tname||'_vertices_pgr';
    vertname= sname||'.'||vname;
    rows_where = ' AND ('||rows_where||')';
    raise DEBUG '     --> OK';
/*    EXCEPTION WHEN raise_exception THEN
      RAISE NOTICE 'ERROR: something went wrong checking the table name';
      RETURN 'FAIL';
*/
  END;

  BEGIN
       raise debug 'Checking Vertices table';
       execute 'select * from  _pgr_checkVertTab('||quote_literal(vertname) ||', ''{"id","cnt","chk"}''::text[])' into naming;
       execute 'UPDATE '||_pgr_quote_ident(vertname)||' SET cnt=0 ,chk=0';
       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the vertices table';
          RETURN 'FAIL';
  END;



  BEGIN
       raise debug 'Checking column names in edge table';
       select * into idname     from _pgr_getColumnName(sname, tname,id,2);
       select * into sourcename from _pgr_getColumnName(sname, tname,source,2);
       select * into targetname from _pgr_getColumnName(sname, tname,target,2);
       select * into gname      from _pgr_getColumnName(sname, tname,the_geom,2);


       perform _pgr_onError( sourcename in (targetname,idname,gname) or  targetname in (idname,gname) or idname=gname, 2,
                       'pgr_analyzeGraph',  'Two columns share the same name', 'Parameter names for id,the_geom,source and target  must be different',
                       'Column names are OK');

        raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the column names';
          RETURN 'FAIL';
  END;


  BEGIN
       raise debug 'Checking column types in edge table';
       select * into sourcetype from _pgr_getColumnType(sname,tname,sourcename,1);
       select * into targettype from _pgr_getColumnType(sname,tname,targetname,1);

       perform _pgr_onError(sourcetype not in('integer','smallint','bigint') , 2,
                       'pgr_analyzeGraph',  'Wrong type of Column '|| sourcename, ' Expected type of '|| sourcename || ' is integer,smallint or bigint but '||sourcetype||' was found',
                       'Type of Column '|| sourcename || ' is ' || sourcetype);

       perform _pgr_onError(targettype not in('integer','smallint','bigint') , 2,
                       'pgr_analyzeGraph',  'Wrong type of Column '|| targetname, ' Expected type of '|| targetname || ' is integer,smallint or biginti but '||targettype||' was found',
                       'Type of Column '|| targetname || ' is ' || targettype);

       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the column types';
          RETURN 'FAIL';
   END;

   BEGIN
       raise debug 'Checking SRID of geometry column';
         query= 'SELECT ST_SRID(' || quote_ident(gname) || ') as srid '
            || ' FROM ' || _pgr_quote_ident(tabname)
            || ' WHERE ' || quote_ident(gname)
            || ' IS NOT NULL LIMIT 1';
         EXECUTE QUERY INTO sridinfo;

         perform _pgr_onError( sridinfo IS NULL OR sridinfo.srid IS NULL,2,
                 'Can not determine the srid of the geometry '|| gname ||' in table '||tabname, 'Check the geometry of column '||gname,
                 'SRID of '||gname||' is '||sridinfo.srid);

         IF sridinfo IS NULL OR sridinfo.srid IS NULL THEN
             RAISE NOTICE ' Can not determine the srid of the geometry "%" in table %', the_geom,tabname;
             RETURN 'FAIL';
         END IF;
         srid := sridinfo.srid;
         raise DEBUG '     --> OK';
         EXCEPTION WHEN OTHERS THEN
             RAISE NOTICE 'Got %', SQLERRM;--issue 210,211,213
             RAISE NOTICE 'ERROR: something went wrong when checking for SRID of % in table %', the_geom,tabname;
             RETURN 'FAIL';
    END;


    BEGIN
       raise debug 'Checking  indices in edge table';
       perform _pgr_createIndex(tabname , idname , 'btree');
       perform _pgr_createIndex(tabname , sourcename , 'btree');
       perform _pgr_createIndex(tabname , targetname , 'btree');
       perform _pgr_createIndex(tabname , gname , 'gist');

       gname=quote_ident(gname);
       sourcename=quote_ident(sourcename);
       targetname=quote_ident(targetname);
       idname=quote_ident(idname);
       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking indices';
          RETURN 'FAIL';
    END;


    BEGIN
        query='select count(*) from '||_pgr_quote_ident(tabname)||' where true  '||rows_where;
        EXECUTE query into ecnt;
        raise DEBUG '-->Rows Where condition: OK';
        raise DEBUG '     --> OK';
         EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Got %', SQLERRM;  --issue 210,211,213
            RAISE NOTICE 'ERROR: Condition is not correct. Please execute the following query to test your condition';
            RAISE NOTICE '%',query;
            RETURN 'FAIL';
    END;

    selectionquery ='with
           selectedRows as( (select '||sourcename||' as id from '||_pgr_quote_ident(tabname)||' where true '||rows_where||')
                           union
                           (select '||targetname||' as id from '||_pgr_quote_ident(tabname)||' where true '||rows_where||'))';





   BEGIN
       RAISE NOTICE 'Analyzing for dead ends. Please wait...';
       query= 'with countingsource as (select a.'||sourcename||' as id,count(*) as cnts
               from (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||' ) a  group by a.'||sourcename||')
                     ,countingtarget as (select a.'||targetname||' as id,count(*) as cntt
                    from (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||' ) a  group by a.'||targetname||')
                   ,totalcount as (select id,case when cnts is null and cntt is null then 0
                                                   when cnts is null then cntt
                                                   when cntt is null then cnts
                                                   else cnts+cntt end as totcnt
                                   from ('||_pgr_quote_ident(vertname)||' as a left
                                   join countingsource as t using(id) ) left join countingtarget using(id))
               update '||_pgr_quote_ident(vertname)||' as a set cnt=totcnt from totalcount as b where a.id=b.id';
       raise debug '%',query;
       execute query;
       query=selectionquery||'
              SELECT count(*)  FROM '||_pgr_quote_ident(vertname)||' WHERE cnt=1 and id in (select id from selectedRows)';
       raise debug '%',query;
       execute query  INTO numdeadends;
       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'Got %', SQLERRM;  --issue 210,211,213
          RAISE NOTICE 'ERROR: something went wrong when analizing for dead ends';
          RETURN 'FAIL';
   END;



    BEGIN
          RAISE NOTICE 'Analyzing for gaps. Please wait...';
          query = 'with
                   buffer as (select id,st_buffer(the_geom,'||tolerance||') as buff from '||_pgr_quote_ident(vertname)||' where cnt=1)
                   ,veryclose as (select b.id,st_crosses(a.'||gname||',b.buff) as flag
                   from  (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||' ) as a
                   join buffer as b on (a.'||gname||'&&b.buff)
                   where '||sourcename||'!=b.id and '||targetname||'!=b.id )
                   update '||_pgr_quote_ident(vertname)||' set chk=1 where id in (select distinct id from veryclose where flag=true)';
          raise debug '%' ,query;
          execute query;
          GET DIAGNOSTICS  numgaps= ROW_COUNT;
          raise DEBUG '     --> OK';
          EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'ERROR: something went wrong when Analyzing for gaps';
            RETURN 'FAIL';
    END;

    BEGIN
        RAISE NOTICE 'Analyzing for isolated edges. Please wait...';
        query=selectionquery|| ' SELECT count(*) FROM (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||' )  as a,
                                                 '||_pgr_quote_ident(vertname)||' as b,
                                                 '||_pgr_quote_ident(vertname)||' as c
                            WHERE b.id in (select id from selectedRows) and a.'||sourcename||' =b.id
                            AND b.cnt=1 AND a.'||targetname||' =c.id
                            AND c.cnt=1';
        raise debug '%' ,query;
        execute query  INTO NumIsolated;
        raise DEBUG '     --> OK';
        EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'ERROR: something went wrong when Analyzing for isolated edges';
            RETURN 'FAIL';
    END;

    BEGIN
        RAISE NOTICE 'Analyzing for ring geometries. Please wait...';
        execute 'SELECT geometrytype('||gname||')  FROM '||_pgr_quote_ident(tabname) limit 1 into geotype;
        IF (geotype='MULTILINESTRING') THEN
            query ='SELECT count(*)  FROM '||_pgr_quote_ident(tabname)||'
                                 WHERE true  '||rows_where||' and st_isRing(st_linemerge('||gname||'))';
            raise debug '%' ,query;
            execute query  INTO numRings;
        ELSE query ='SELECT count(*)  FROM '||_pgr_quote_ident(tabname)||'
                                  WHERE true  '||rows_where||' and st_isRing('||gname||')';
            raise debug '%' ,query;
            execute query  INTO numRings;
        END IF;
        raise DEBUG '     --> OK';
        EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'ERROR: something went wrong when Analyzing for ring geometries';
            RETURN 'FAIL';
    END;

    BEGIN
        RAISE NOTICE 'Analyzing for intersections. Please wait...';
        query = 'select count(*) from (select distinct case when a.'||idname||' < b.'||idname||' then a.'||idname||'
                                                        else b.'||idname||' end,
                                                   case when a.'||idname||' < b.'||idname||' then b.'||idname||'
                                                        else a.'||idname||' end
                                    FROM (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||') as a
                                    JOIN (select * from '||_pgr_quote_ident(tabname)||' where true '||rows_where||') as b
                                    ON (a.'|| gname||' && b.'||gname||')
                                    WHERE a.'||idname||' != b.'||idname|| '
                                        and (a.'||sourcename||' in (b.'||sourcename||',b.'||targetname||')
                                              or a.'||targetname||' in (b.'||sourcename||',b.'||targetname||')) = false
                                        and st_intersects(a.'||gname||', b.'||gname||')=true) as d ';
        raise debug '%' ,query;
        execute query  INTO numCrossing;
        raise DEBUG '     --> OK';
        EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'ERROR: something went wrong when Analyzing for intersections';
            RETURN 'FAIL';
    END;




    RAISE NOTICE '            ANALYSIS RESULTS FOR SELECTED EDGES:';
    RAISE NOTICE '                  Isolated segments: %', NumIsolated;
    RAISE NOTICE '                          Dead ends: %', numdeadends;
    RAISE NOTICE 'Potential gaps found near dead ends: %', numgaps;
    RAISE NOTICE '             Intersections detected: %',numCrossing;
    RAISE NOTICE '                    Ring geometries: %',numRings;


    RETURN 'OK';
END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;
COMMENT ON FUNCTION pgr_analyzeGraph(text,double precision,text,text,text,text,text) IS 'args: edge_table, tolerance,the_geom:=''the_geom'',id:=''id'',source column:=''source'', target column:=''target'' rows_where:=''true'' - creates a vertices table based on the geometry for selected rows';





/*
.. function:: _pgr_analyzeOneway(tab, col, s_in_rules, s_out_rules, t_in_rules, t_out_rules)

   This function analyzes oneway streets in a graph and identifies any
   flipped segments. Basically if you count the edges coming into a node
   and the edges exiting a node the number has to be greater than one.

   * tab              - edge table name (TEXT)
   * col              - oneway column name (TEXT)
   * s_in_rules       - source node in rules
   * s_out_rules      - source node out rules
   * t_in_tules       - target node in rules
   * t_out_rules      - target node out rules
   * two_way_if_null  - flag to treat oneway nNULL values as by directional

   After running this on a graph you can identify nodes with potential
   problems with the following query.

.. code-block:: sql

       select * from vertices_tmp where in=0 or out=0;

   The rules are defined as an array of text strings that if match the "col"
   value would be counted as true for the source or target in or out condition.

   Example
   =======

   Lets assume we have a table "st" of edges and a column "one_way" that
   might have values like:

   * 'FT'    - oneway from the source to the target node.
   * 'TF'    - oneway from the target to the source node.
   * 'B'     - two way street.
   * ''      - empty field, assume teoway.
   * <NULL>  - NULL field, use two_way_if_null flag.

   Then we could form the following query to analyze the oneway streets for
   errors.

.. code-block:: sql

   select _pgr_analyzeOneway('st', 'one_way',
        ARRAY['', 'B', 'TF'],
        ARRAY['', 'B', 'FT'],
        ARRAY['', 'B', 'FT'],
        ARRAY['', 'B', 'TF'],
        true);

   -- now we can see the problem nodes
   select * from vertices_tmp where ein=0 or eout=0;

   -- and the problem edges connected to those nodes
   select gid

     from st a, vertices_tmp b
    where a.source=b.id and ein=0 or eout=0
   union
   select gid
     from st a, vertices_tmp b
    where a.target=b.id and ein=0 or eout=0;

Typically these problems are generated by a break in the network, the
oneway direction set wrong, maybe an error releted to zlevels or
a network that is not properly noded.

*/

CREATE OR REPLACE FUNCTION pgr_analyzeOneway(
   edge_table text,
   s_in_rules TEXT[],
   s_out_rules TEXT[],
   t_in_rules TEXT[],
   t_out_rules TEXT[],
   two_way_if_null boolean default true,
   oneway text default 'oneway',
   source text default 'source',
   target text default 'target')
  RETURNS text AS
$BODY$


DECLARE
    rule text;
    ecnt integer;
    instr text;
    naming record;
    sname text;
    tname text;
    tabname text;
    vname text;
    owname text;
    sourcename text;
    targetname text;
    sourcetype text;
    targettype text;
    vertname text;
    debuglevel text;


BEGIN
  raise notice 'PROCESSING:';
  raise notice 'pgr_analyzeOneway(''%'',''%'',''%'',''%'',''%'',''%'',''%'',''%'',%)',
		edge_table, s_in_rules , s_out_rules, t_in_rules, t_out_rules, oneway, source ,target,two_way_if_null ;
  execute 'show client_min_messages' into debuglevel;

  BEGIN
    RAISE DEBUG 'Checking % exists',edge_table;
    execute 'select * from _pgr_getTableName('||quote_literal(edge_table)||',2)' into naming;
    sname=naming.sname;
    tname=naming.tname;
    tabname=sname||'.'||tname;
    vname=tname||'_vertices_pgr';
    vertname= sname||'.'||vname;
    raise DEBUG '     --> OK';
    EXCEPTION WHEN raise_exception THEN
      RAISE NOTICE 'ERROR: something went wrong checking the table name';
      RETURN 'FAIL';
  END;

  BEGIN
       raise debug 'Checking Vertices table';
       execute 'select * from  _pgr_checkVertTab('||quote_literal(vertname) ||', ''{"id","ein","eout"}''::text[])' into naming;
       execute 'UPDATE '||_pgr_quote_ident(vertname)||' SET eout=0 ,ein=0';
       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the vertices table';
          RETURN 'FAIL';
  END;


  BEGIN
       raise debug 'Checking column names in edge table';
       select * into sourcename from _pgr_getColumnName(sname, tname,source,2);
       select * into targetname from _pgr_getColumnName(sname, tname,target,2);
       select * into owname from _pgr_getColumnName(sname, tname,oneway,2);


       perform _pgr_onError( sourcename in (targetname,owname) or  targetname=owname, 2,
                       '_pgr_createToplogy',  'Two columns share the same name', 'Parameter names for oneway,source and target  must be different',
                       'Column names are OK');

       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the column names';
          RETURN 'FAIL';
  END;

  BEGIN
       raise debug 'Checking column types in edge table';
       select * into sourcetype from _pgr_getColumnType(sname,tname,sourcename,1);
       select * into targettype from _pgr_getColumnType(sname,tname,targetname,1);


       perform _pgr_onError(sourcetype not in('integer','smallint','bigint') , 2,
                       '_pgr_createTopology',  'Wrong type of Column '|| sourcename, ' Expected type of '|| sourcename || ' is integer,smallint or bigint but '||sourcetype||' was found',
                       'Type of Column '|| sourcename || ' is ' || sourcetype);

       perform _pgr_onError(targettype not in('integer','smallint','bigint') , 2,
                       '_pgr_createTopology',  'Wrong type of Column '|| targetname, ' Expected type of '|| targetname || ' is integer,smallint or biginti but '||targettype||' was found',
                       'Type of Column '|| targetname || ' is ' || targettype);

       raise DEBUG '     --> OK';
       EXCEPTION WHEN raise_exception THEN
          RAISE NOTICE 'ERROR: something went wrong checking the column types';
          RETURN 'FAIL';
   END;



    RAISE NOTICE 'Analyzing graph for one way street errors.';

    rule := CASE WHEN two_way_if_null
            THEN owname || ' IS NULL OR '
            ELSE '' END;

    instr := '''' || array_to_string(s_in_rules, ''',''') || '''';
       EXECUTE 'update '||_pgr_quote_ident(vertname)||' a set ein=coalesce(ein,0)+b.cnt
      from (
         select '|| sourcename ||', count(*) as cnt
           from '|| tabname ||'
          where '|| rule || owname ||' in ('|| instr ||')
          group by '|| sourcename ||' ) b
     where a.id=b.'|| sourcename;

    RAISE NOTICE 'Analysis 25%% complete ...';

    instr := '''' || array_to_string(t_in_rules, ''',''') || '''';
    EXECUTE 'update '||_pgr_quote_ident(vertname)||' a set ein=coalesce(ein,0)+b.cnt
        from (
         select '|| targetname ||', count(*) as cnt
           from '|| tabname ||'
          where '|| rule || owname ||' in ('|| instr ||')
          group by '|| targetname ||' ) b
        where a.id=b.'|| targetname;

    RAISE NOTICE 'Analysis 50%% complete ...';

    instr := '''' || array_to_string(s_out_rules, ''',''') || '''';
    EXECUTE 'update '||_pgr_quote_ident(vertname)||' a set eout=coalesce(eout,0)+b.cnt
        from (
         select '|| sourcename ||', count(*) as cnt
           from '|| tabname ||'
          where '|| rule || owname ||' in ('|| instr ||')
          group by '|| sourcename ||' ) b
        where a.id=b.'|| sourcename;
    RAISE NOTICE 'Analysis 75%% complete ...';

    instr := '''' || array_to_string(t_out_rules, ''',''') || '''';
    EXECUTE 'update '||_pgr_quote_ident(vertname)||' a set eout=coalesce(eout,0)+b.cnt
        from (
         select '|| targetname ||', count(*) as cnt
           from '|| tabname ||'
          where '|| rule || owname ||' in ('|| instr ||')
          group by '|| targetname ||' ) b
        where a.id=b.'|| targetname;

    RAISE NOTICE 'Analysis 100%% complete ...';

    EXECUTE 'SELECT count(*)  FROM '||_pgr_quote_ident(vertname)||' WHERE ein=0 or eout=0' INTO ecnt;

    RAISE NOTICE 'Found % potential problems in directionality' ,ecnt;

    RETURN 'OK';

END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;

COMMENT ON FUNCTION pgr_analyzeOneway(text,TEXT[],TEXT[], TEXT[],TEXT[],boolean,text,text,text)
IS 'args:edge_table , s_in_rules , s_out_rules, t_in_rules , t_out_rules, two_way_if_null:= true, oneway:=''oneway'',source:= ''source'',target:=''target'' - Analizes the directionality of the edges based on the rules';


/* 

This function should not be used directly. Use assign_vertex_id instead
Inserts a point into the vertices tablei "vname" with the srid "srid", and return an id
of a new point or an existing point. Tolerance is the minimal distance
between existing points and the new point to create a new point.

Modified by: Vicky Vergara <vicky_vergara@hotmail,com>

HISTORY
Last changes: 2013-03-22
2013-08-19: handling schemas
*/



/*
.. function:: pgr_createVerticesTable(edge_table text, the_geom text, source text default 'source', target text default 'target')

  Based on "source" and "target" columns creates the vetrices_pgr table for edge_table
  Ignores rows where "source" or "target" have NULL values 

  Author: Vicky Vergara <vicky_vergara@hotmail,com>

 HISTORY
    Created 2013-08-19
*/

CREATE OR REPLACE FUNCTION pgr_createverticestable(
   edge_table text,
   the_geom text DEFAULT 'the_geom'::text,
   source text DEFAULT 'source'::text,
   target text DEFAULT 'target'::text,
    rows_where text DEFAULT 'true'::text
)
  RETURNS text AS
$BODY$
DECLARE
    naming record;
    sridinfo record;
    sname text;
    tname text;
    tabname text;
    vname text;
    vertname text;
    gname text;
    sourcename text;
    targetname text;
    query text;
    ecnt bigint; 
    srid integer;
    sourcetype text;
    targettype text;
    sql text;
    totcount integer;
    i integer;
    notincluded integer;
    included integer;
    debuglevel text;
    dummyRec text;
    fnName text;
    err bool;


BEGIN 
  fnName = 'pgr_createVerticesTable';
  raise notice 'PROCESSING:'; 
  raise notice 'pgr_createVerticesTable(''%'',''%'',''%'',''%'',''%'')',edge_table,the_geom,source,target,rows_where;
  execute 'show client_min_messages' into debuglevel;

  raise notice 'Performing checks, please wait .....';

  RAISE DEBUG 'Checking % exists',edge_table;
        execute 'select * from _pgr_getTableName('|| quote_literal(edge_table)
                                                  || ',2,' || quote_literal(fnName) ||' )' into naming;

    sname=naming.sname;
    tname=naming.tname;
    tabname=sname||'.'||tname;
    vname=tname||'_vertices_pgr';
    vertname= sname||'.'||vname;
    rows_where = ' AND ('||rows_where||')';
  raise debug '--> Edge table exists: OK';
   
  raise debug 'Checking column names';
    select * into sourcename from _pgr_getColumnName(sname, tname,source,2, fnName);
    select * into targetname from _pgr_getColumnName(sname, tname,target,2, fnName);
    select * into gname      from _pgr_getColumnName(sname, tname,the_geom,2, fnName);


    err = sourcename in (targetname,gname) or  targetname=gname;
    perform _pgr_onError(err, 2, fnName,
        'Two columns share the same name', 'Parameter names for the_geom,source and target  must be different');
  raise debug '--> Column names: OK';

  raise debug 'Checking column types in edge table';
    select * into sourcetype from _pgr_getColumnType(sname,tname,sourcename,1, fnName);
    select * into targettype from _pgr_getColumnType(sname,tname,targetname,1, fnName);


    err = sourcetype not in('integer','smallint','bigint');
    perform _pgr_onError(err, 2, fnName,
        'Wrong type of Column source: '|| sourcename, ' Expected type of '|| sourcename || ' is integer,smallint or bigint but '||sourcetype||' was found');

    err = targettype not in('integer','smallint','bigint');
    perform _pgr_onError(err, 2, fnName,
        'Wrong type of Column target: '|| targetname, ' Expected type of '|| targetname || ' is integer,smallint or biginti but '||targettype||' was found');

  raise debug '-->Column types:OK';

  raise debug 'Checking SRID of geometry column';
     query= 'SELECT ST_SRID(' || quote_ident(gname) || ') as srid '
        || ' FROM ' || _pgr_quote_ident(tabname)
        || ' WHERE ' || quote_ident(gname)
        || ' IS NOT NULL LIMIT 1';
     raise debug '%',query;
     EXECUTE query INTO sridinfo;

     err =  sridinfo IS NULL OR sridinfo.srid IS NULL;
     perform _pgr_onError(err, 2, fnName,
         'Can not determine the srid of the geometry '|| gname ||' in table '||tabname, 'Check the geometry of column '||gname);
     srid := sridinfo.srid;
  raise DEBUG '     --> OK';

  raise debug 'Checking and creating Indices';
     perform _pgr_createIndex(sname, tname , sourcename , 'btree'::text);
     perform _pgr_createIndex(sname, tname , targetname , 'btree'::text);
     perform _pgr_createIndex(sname, tname , gname , 'gist'::text);
  raise DEBUG '-->Check and create indices: OK';

     gname=quote_ident(gname);
     sourcename=quote_ident(sourcename);
     targetname=quote_ident(targetname);


  BEGIN
  raise debug 'Checking Condition';
    -- issue #193 & issue #210 & #213
    -- this sql is for trying out the where clause
    -- the select * is to avoid any column name conflicts
    -- limit 1, just try on first record
    -- if the where clasuse is ill formed it will be caught in the exception
    sql = 'select * from '||_pgr_quote_ident(tabname)||' WHERE true'||rows_where ||' limit 1';
    EXECUTE sql into dummyRec;
    -- end 

    -- if above where clasue works this one should work
    -- any error will be caught by the exception also
    sql = 'select count(*) from '||_pgr_quote_ident(tabname)||' WHERE (' || gname || ' IS NULL or '||
		sourcename||' is null or '||targetname||' is null)=true '||rows_where;
    raise debug '%',sql;
    EXECUTE SQL  into notincluded;
    EXCEPTION WHEN OTHERS THEN  
         RAISE NOTICE 'Got %', SQLERRM; -- issue 210,211
         RAISE NOTICE 'ERROR: Condition is not correct, please execute the following query to test your condition';
         RAISE NOTICE '%',sql;
         RETURN 'FAIL';
  END;



    
  BEGIN
     raise DEBUG 'initializing %',vertname;
       execute 'select * from _pgr_getTableName('||quote_literal(vertname)||',0)' into naming;
       IF sname=naming.sname  AND vname=naming.tname  THEN
           execute 'TRUNCATE TABLE '||_pgr_quote_ident(vertname)||' RESTART IDENTITY';
           execute 'SELECT DROPGEOMETRYCOLUMN('||quote_literal(sname)||','||quote_literal(vname)||','||quote_literal('the_geom')||')';
       ELSE
           set client_min_messages  to warning;
       	   execute 'CREATE TABLE '||_pgr_quote_ident(vertname)||' (id bigserial PRIMARY KEY,cnt integer,chk integer,ein integer,eout integer)';
       END IF;
       execute 'select addGeometryColumn('||quote_literal(sname)||','||quote_literal(vname)||','||
                quote_literal('the_geom')||','|| srid||', '||quote_literal('POINT')||', 2)';
       execute 'CREATE INDEX '||quote_ident(vname||'_the_geom_idx')||' ON '||_pgr_quote_ident(vertname)||'  USING GIST (the_geom)';
       execute 'set client_min_messages  to '|| debuglevel;
       raise DEBUG  '  ------>OK'; 
       EXCEPTION WHEN OTHERS THEN  
         RAISE NOTICE 'Got %', SQLERRM; -- issue 210,211
         RAISE NOTICE 'ERROR: Initializing vertex table';
         RAISE NOTICE '%',sql;
         RETURN 'FAIL';
  END;       

  BEGIN
       raise notice 'Populating %, please wait...',vertname;
       sql= 'with
		lines as ((select distinct '||sourcename||' as id, _pgr_startpoint(st_linemerge('||gname||')) as the_geom from '||_pgr_quote_ident(tabname)||
		                  ' where ('|| gname || ' IS NULL 
                                    or '||sourcename||' is null 
                                    or '||targetname||' is null)=false 
                                     '||rows_where||')
			union (select distinct '||targetname||' as id,_pgr_endpoint(st_linemerge('||gname||')) as the_geom from '||_pgr_quote_ident(tabname)||
			          ' where ('|| gname || ' IS NULL 
                                    or '||sourcename||' is null 
                                    or '||targetname||' is null)=false
                                     '||rows_where||'))
		,numberedLines as (select row_number() OVER (ORDER BY id) AS i,* from lines )
		,maxid as (select id,max(i) as maxi from numberedLines group by id)
		insert into '||_pgr_quote_ident(vertname)||'(id,the_geom)  (select id,the_geom  from numberedLines join maxid using(id) where i=maxi order by id)';
       RAISE debug '%',sql;
       execute sql;
       GET DIAGNOSTICS totcount = ROW_COUNT;

       sql = 'select count(*) from '||_pgr_quote_ident(tabname)||' a, '||_pgr_quote_ident(vertname)||' b 
            where '||sourcename||'=b.id and '|| targetname||' in (select id from '||_pgr_quote_ident(vertname)||')';
       RAISE debug '%',sql;
       execute sql into included;



       execute 'select max(id) from '||_pgr_quote_ident(vertname) into ecnt;
       execute 'SELECT setval('||quote_literal(vertname||'_id_seq')||','||coalesce(ecnt,1)||' , false)';
       raise notice '  ----->   VERTICES TABLE CREATED WITH  % VERTICES', totcount;
       raise notice '                                       FOR   %  EDGES', included+notincluded;
       RAISE NOTICE '  Edges with NULL geometry,source or target: %',notincluded;
       RAISE NOTICE '                            Edges processed: %',included;
       Raise notice 'Vertices table for table % is: %',_pgr_quote_ident(tabname),_pgr_quote_ident(vertname);
       raise notice '----------------------------------------------';
    END;
    
    RETURN 'OK';
 EXCEPTION WHEN OTHERS THEN
   RAISE NOTICE 'Unexpected error %', SQLERRM; -- issue 210,211
   RETURN 'FAIL';
END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;

COMMENT ON FUNCTION pgr_createVerticesTable(text,text,text,text,text) 
IS 'args: edge_table, the_geom:=''the_geom'',source:=''source'', target:=''target'' rows_where:=''true'' - creates a vertices table based on the source and target identifiers for selected rows';


CREATE OR REPLACE FUNCTION pgr_nodeNetwork(edge_table text, tolerance double precision, 
			id text default 'id', the_geom text default 'the_geom', table_ending text default 'noded',
            rows_where text DEFAULT ''::text, outall boolean DEFAULT false) RETURNS text AS
$BODY$
DECLARE
	/*
	 * Author: Nicolas Ribot, 2013
	*/
	p_num int := 0;
	p_ret text := '';
    pgis_ver_old boolean := _pgr_versionless(postgis_lib_version(), '2.1.0.0');
    vst_line_substring text;
    vst_line_locate_point text;
    intab text;
    outtab text;
    n_pkey text;
    n_geom text;
    naming record;
    sname text;
    tname text;
    outname text;
    srid integer;
    sridinfo record;
    splits bigint;
    touched bigint;
    untouched bigint;
    geomtype text;
    debuglevel text;
    rows_where text;
   

BEGIN
  raise notice 'PROCESSING:'; 
  raise notice 'pgr_nodeNetwork(''%'', %, ''%'', ''%'', ''%'', ''%'',  %)',
    edge_table, tolerance, id,  the_geom, table_ending, rows_where, outall;
  raise notice 'Performing checks, please wait .....';
  execute 'show client_min_messages' into debuglevel;

  BEGIN
    RAISE DEBUG 'Checking % exists',edge_table;
    execute 'select * from _pgr_getTableName('||quote_literal(edge_table)||',0)' into naming;
    sname=naming.sname;
    tname=naming.tname;
    IF sname IS NULL OR tname IS NULL THEN
	RAISE NOTICE '-------> % not found',edge_table;
        RETURN 'FAIL';
    ELSE
	RAISE DEBUG '  -----> OK';
    END IF;
  
    intab=sname||'.'||tname;
    outname=tname||'_'||table_ending;
    outtab= sname||'.'||outname;
    rows_where = CASE WHEN length(rows_where) > 2 and not outall THEN ' AND (' || rows_where || ')' ELSE '' END;
    rows_where = CASE WHEN length(rows_where) > 2 THEN ' WHERE (' || rows_where || ')' ELSE '' END;
  END;

  BEGIN 
       raise DEBUG 'Checking id column "%" columns in  % ',id,intab;
       EXECUTE 'select _pgr_getColumnName('||quote_literal(intab)||','||quote_literal(id)||')' INTO n_pkey;
       IF n_pkey is NULL then
          raise notice  'ERROR: id column "%"  not found in %',id,intab;
          RETURN 'FAIL';
       END IF;
  END; 


  BEGIN 
       raise DEBUG 'Checking id column "%" columns in  % ',the_geom,intab;
       EXECUTE 'select _pgr_getColumnName('||quote_literal(intab)||','||quote_literal(the_geom)||')' INTO n_geom;
       IF n_geom is NULL then
          raise notice  'ERROR: the_geom  column "%"  not found in %',the_geom,intab;
          RETURN 'FAIL';
       END IF;
  END;

  IF n_pkey=n_geom THEN
	raise notice  'ERROR: id and the_geom columns have the same name "%" in %',n_pkey,intab;
        RETURN 'FAIL';
  END IF;
 
  BEGIN 
       	raise DEBUG 'Checking the SRID of the geometry "%"', n_geom;
       	EXECUTE 'SELECT ST_SRID(' || quote_ident(n_geom) || ') as srid '
          		|| ' FROM ' || _pgr_quote_ident(intab)
          		|| ' WHERE ' || quote_ident(n_geom)
          		|| ' IS NOT NULL LIMIT 1' INTO sridinfo;
       	IF sridinfo IS NULL OR sridinfo.srid IS NULL THEN
        	RAISE NOTICE 'ERROR: Can not determine the srid of the geometry "%" in table %', n_geom,intab;
           	RETURN 'FAIL';
       	END IF;
       	srid := sridinfo.srid;
       	raise DEBUG '  -----> SRID found %',srid;
       	EXCEPTION WHEN OTHERS THEN
           		RAISE NOTICE 'ERROR: Can not determine the srid of the geometry "%" in table %', n_geom,intab;
           		RETURN 'FAIL';
  END;

    BEGIN
      RAISE DEBUG 'Checking "%" column in % is indexed',n_pkey,intab;
      if (_pgr_isColumnIndexed(intab,n_pkey)) then 
	RAISE DEBUG '  ------>OK';
      else 
        RAISE DEBUG ' ------> Adding  index "%_%_idx".',n_pkey,intab;

	set client_min_messages  to warning;
        execute 'create  index '||tname||'_'||n_pkey||'_idx on '||_pgr_quote_ident(intab)||' using btree('||quote_ident(n_pkey)||')';
	execute 'set client_min_messages  to '|| debuglevel;
      END IF;
    END;

    BEGIN
      RAISE DEBUG 'Checking "%" column in % is indexed',n_geom,intab;
      if (_pgr_iscolumnindexed(intab,n_geom)) then 
	RAISE DEBUG '  ------>OK';
      else 
        RAISE DEBUG ' ------> Adding unique index "%_%_gidx".',intab,n_geom;
	set client_min_messages  to warning;
        execute 'CREATE INDEX '
            || quote_ident(tname || '_' || n_geom || '_gidx' )
            || ' ON ' || _pgr_quote_ident(intab)
            || ' USING gist (' || quote_ident(n_geom) || ')';
	execute 'set client_min_messages  to '|| debuglevel;
      END IF;
    END;
---------------
    BEGIN
       raise DEBUG 'initializing %',outtab;
       execute 'select * from _pgr_getTableName('||quote_literal(outtab)||',0)' into naming;
       IF sname=naming.sname  AND outname=naming.tname  THEN
           execute 'TRUNCATE TABLE '||_pgr_quote_ident(outtab)||' RESTART IDENTITY';
           execute 'SELECT DROPGEOMETRYCOLUMN('||quote_literal(sname)||','||quote_literal(outname)||','||quote_literal(n_geom)||')';
       ELSE
	   set client_min_messages  to warning;
       	   execute 'CREATE TABLE '||_pgr_quote_ident(outtab)||' (id bigserial PRIMARY KEY,old_id integer,sub_id integer,
								source bigint,target bigint)';
       END IF;
       execute 'select geometrytype('||quote_ident(n_geom)||') from  '||_pgr_quote_ident(intab)||' limit 1' into geomtype;
       execute 'select addGeometryColumn('||quote_literal(sname)||','||quote_literal(outname)||','||
                quote_literal(n_geom)||','|| srid||', '||quote_literal(geomtype)||', 2)';
       execute 'CREATE INDEX '||quote_ident(outname||'_'||n_geom||'_idx')||' ON '||_pgr_quote_ident(outtab)||'  USING GIST ('||quote_ident(n_geom)||')';
	execute 'set client_min_messages  to '|| debuglevel;
       raise DEBUG  '  ------>OK'; 
    END;  
----------------


  raise notice 'Processing, please wait .....';


    if pgis_ver_old then
        vst_line_substring    := 'st_line_substring';
        vst_line_locate_point := 'st_line_locate_point';
    else
        vst_line_substring    := 'st_linesubstring';
        vst_line_locate_point := 'st_linelocatepoint';
    end if;

--    -- First creates temp table with intersection points
    p_ret = 'create temp table intergeom on commit drop as (
        select l1.' || quote_ident(n_pkey) || ' as l1id, 
               l2.' || quote_ident(n_pkey) || ' as l2id, 
	       l1.' || quote_ident(n_geom) || ' as line,
	       _pgr_startpoint(l2.' || quote_ident(n_geom) || ') as source,
	       _pgr_endpoint(l2.' || quote_ident(n_geom) || ') as target,
               st_intersection(l1.' || quote_ident(n_geom) || ', l2.' || quote_ident(n_geom) || ') as geom 
        from (SELECT * FROM ' || _pgr_quote_ident(intab) || rows_where || ') as l1 
             join (SELECT * FROM ' || _pgr_quote_ident(intab) || rows_where || ') as l2 
             on (st_dwithin(l1.' || quote_ident(n_geom) || ', l2.' || quote_ident(n_geom) || ', ' || tolerance || '))'||
        'where l1.' || quote_ident(n_pkey) || ' <> l2.' || quote_ident(n_pkey)||' and 
	st_equals(_pgr_startpoint(l1.' || quote_ident(n_geom) || '),_pgr_startpoint(l2.' || quote_ident(n_geom) || '))=false and 
	st_equals(_pgr_startpoint(l1.' || quote_ident(n_geom) || '),_pgr_endpoint(l2.' || quote_ident(n_geom) || '))=false and 
	st_equals(_pgr_endpoint(l1.' || quote_ident(n_geom) || '),_pgr_startpoint(l2.' || quote_ident(n_geom) || '))=false and 
	st_equals(_pgr_endpoint(l1.' || quote_ident(n_geom) || '),_pgr_endpoint(l2.' || quote_ident(n_geom) || '))=false  )';
    raise debug '%',p_ret;	
    EXECUTE p_ret;	

    -- second temp table with locus (index of intersection point on the line)
    -- to avoid updating the previous table
    -- we keep only intersection points occurring onto the line, not at one of its ends
--    drop table if exists inter_loc;

--HAD TO CHANGE THIS QUERY
-- p_ret= 'create temp table inter_loc on commit drop as ( 
--        select l1id, l2id, ' || vst_line_locate_point || '(line,point) as locus from (
--        select DISTINCT l1id, l2id, line, (ST_DumpPoints(geom)).geom as point from intergeom) as foo
--        where ' || vst_line_locate_point || '(line,point)<>0 and ' || vst_line_locate_point || '(line,point)<>1)';
    p_ret= 'create temp table inter_loc on commit drop as ( select * from (
        (select l1id, l2id, ' || vst_line_locate_point || '(line,source) as locus from intergeom)
         union
        (select l1id, l2id, ' || vst_line_locate_point || '(line,target) as locus from intergeom)) as foo
        where locus<>0 and locus<>1)';
    raise debug  '%',p_ret;	
    EXECUTE p_ret;	

    -- index on l1id
    create index inter_loc_id_idx on inter_loc(l1id);

    -- Then computes the intersection on the lines subset, which is much smaller than full set 
    -- as there are very few intersection points

--- outab needs to be formally created with id, old_id, subid,the_geom, source,target
---  so it can be inmediatly be used with createTopology

--   EXECUTE 'drop table if exists ' || _pgr_quote_ident(outtab);
--   EXECUTE 'create table ' || _pgr_quote_ident(outtab) || ' as 
     P_RET = 'insert into '||_pgr_quote_ident(outtab)||' (old_id,sub_id,'||quote_ident(n_geom)||') (  with cut_locations as (
           select l1id as lid, locus 
           from inter_loc
           -- then generates start and end locus for each line that have to be cut buy a location point
           UNION ALL
           select i.l1id  as lid, 0 as locus
           from inter_loc i left join ' || _pgr_quote_ident(intab) || ' b on (i.l1id = b.' || quote_ident(n_pkey) || ')
           UNION ALL
           select i.l1id  as lid, 1 as locus
           from inter_loc i left join ' || _pgr_quote_ident(intab) || ' b on (i.l1id = b.' || quote_ident(n_pkey) || ')
           order by lid, locus
       ), 
       -- we generate a row_number index column for each input line 
       -- to be able to self-join the table to cut a line between two consecutive locations 
       loc_with_idx as (
           select lid, locus, row_number() over (partition by lid order by locus) as idx
           from cut_locations
       ) 
       -- finally, each original line is cut with consecutive locations using linear referencing functions
       select l.' || quote_ident(n_pkey) || ', loc1.idx as sub_id, ' || vst_line_substring || '(l.' || quote_ident(n_geom) || ', loc1.locus, loc2.locus) as ' || quote_ident(n_geom) || ' 
       from loc_with_idx loc1 join loc_with_idx loc2 using (lid) join ' || _pgr_quote_ident(intab) || ' l on (l.' || quote_ident(n_pkey) || ' = loc1.lid)
       where loc2.idx = loc1.idx+1
           -- keeps only linestring geometries
           and geometryType(' || vst_line_substring || '(l.' || quote_ident(n_geom) || ', loc1.locus, loc2.locus)) = ''LINESTRING'') ';
    raise debug  '%',p_ret;	
    EXECUTE p_ret;	
	GET DIAGNOSTICS splits = ROW_COUNT;
        execute 'with diff as (select distinct old_id from '||_pgr_quote_ident(outtab)||' )
                 select count(*) from diff' into touched; 
	-- here, it misses all original line that did not need to be cut by intersection points: these lines
	-- are already clean
	-- inserts them in the final result: all lines which gid is not in the res table.
	EXECUTE 'insert into ' || _pgr_quote_ident(outtab) || ' (old_id , sub_id, ' || quote_ident(n_geom) || ')
                ( with used as (select distinct old_id from '|| _pgr_quote_ident(outtab)||')
		select ' ||  quote_ident(n_pkey) || ', 1 as sub_id, ' ||  quote_ident(n_geom) ||
		' from '|| _pgr_quote_ident(intab) ||' where  '||quote_ident(n_pkey)||' not in (select * from used)' || rows_where || ')';
	GET DIAGNOSTICS untouched = ROW_COUNT;

	raise NOTICE '  Split Edges: %', touched;
	raise NOTICE ' Untouched Edges: %', untouched;
	raise NOTICE '     Total original Edges: %', touched+untouched;
        RAISE NOTICE ' Edges generated: %', splits;
	raise NOTICE ' Untouched Edges: %',untouched;
	raise NOTICE '       Total New segments: %', splits+untouched;
        RAISE NOTICE ' New Table: %', outtab;
        RAISE NOTICE '----------------------------------';

    drop table  if exists intergeom;
    drop table if exists inter_loc;
    RETURN 'OK';
END;
$BODY$
    LANGUAGE 'plpgsql' VOLATILE STRICT COST 100;


COMMENT ON FUNCTION pgr_nodeNetwork(text, double precision, text, text, text, text, boolean )
 IS  'edge_table, tolerance, id:=''id'', the_geom:=''the_geom'', table_ending:=''noded'' ';


CREATE OR REPLACE FUNCTION pgr_labelGraph(
                edge_table text,
                id text default 'id',
                source text default 'source',
                target text default 'target',
                subgraph text default 'subgraph',
                rows_where text default 'true'
        )
        RETURNS character varying AS
$BODY$

DECLARE
        naming record;
        schema_name text;
        table_name text;
        garbage text;
        incre integer;
        table_schema_name text;
        query text;
        ecnt integer;
        sql1 text;
        rec1 record;
        sql2 text;
        rec2 record;
        rec_count record;
        rec_single record;
        graph_id integer;
        gids int [];   

BEGIN   
        raise notice 'Processing:';
        raise notice 'pgr_brokenGraph(''%'',''%'',''%'',''%'',''%'',''%'')', edge_table,id,source,target,subgraph,rows_where;
        raise notice 'Performing initial checks, please hold on ...';

        Raise Notice 'Starting - Checking table ...';
        BEGIN
                raise debug 'Checking % table existance', edge_table;
                execute 'select * from pgr_getTableName('|| quote_literal(edge_table) ||')' into naming;
                schema_name = naming.sname;
                table_name = naming.tname;
                table_schema_name = schema_name||'.'||table_name;
                IF schema_name is null then
                        raise notice 'no schema';
                        return 'FAIL';
                else 
                        if table_name is null then
                                raise notice 'no table';
                                return 'FAIL';
                        end if;
                end if;
        END;
        Raise Notice 'Ending - Checking table';

        Raise Notice 'Starting - Checking columns';
        BEGIN
                raise debug 'Checking exitance of necessary columns inside % table', edge_table;
                execute 'select * from pgr_isColumnInTable('|| quote_literal(table_schema_name) ||', '|| quote_literal(id) ||')' into naming;
                if naming.pgr_iscolumnintable = 'f' then
                        raise notice 'no id column';
                        return 'FAIL';
                end if;
                execute 'select * from pgr_isColumnInTable('|| quote_literal(table_schema_name) ||', '|| quote_literal(source) ||')' into naming;
                if naming.pgr_iscolumnintable = 'f' then
                        raise notice 'no source column';
                        return 'FAIL';
                end if;
                execute 'select * from pgr_isColumnInTable('|| quote_literal(table_schema_name) ||', '|| quote_literal(target) ||')' into naming;
                if naming.pgr_iscolumnintable = 'f' then
                        raise notice 'no target column';
                        return 'FAIL';
                end if;
                execute 'select * from pgr_isColumnInTable('|| quote_literal(table_schema_name) ||', '|| quote_literal(subgraph) ||')' into naming;
                if naming.pgr_iscolumnintable = 't' then
                        raise notice 'subgraph column already in the table';
                        return 'FAIL';
                end if;
        END;
        Raise Notice 'Ending - Checking columns';

        Raise Notice 'Starting - Checking rows_where condition';
        BEGIN
                raise debug 'Checking rows_where condition';
                query='select count(*) from '|| pgr_quote_ident(table_schema_name) ||' where '|| rows_where;
                execute query into ecnt;
                raise debug '-->Rows where condition: OK';
                raise debug '    --> OK';
                EXCEPTION WHEN OTHERS THEN
                        raise notice 'Got %', SQLERRM;
                        Raise notice 'ERROR: Condition is not correct. Please execute the following query to test your condition';
                        Raise notice '%', query;
                        return 'FAIL';
        END;
        Raise Notice 'Ending - Checking rows_where condition';

        garbage := 'garbage001';
        incre := 1;
        Raise Notice 'Starting - Checking temporary column';
        Begin
                raise debug 'Checking Checking temporary columns existance';
                
                While True
                        Loop
                                execute 'select * from pgr_isColumnInTable('|| quote_literal(table_schema_name) ||', '|| quote_literal(garbage) ||')' into naming;
                                If naming.pgr_iscolumnintable = 't' THEN
                                        incre := incre + 1;
                                        garbage := 'garbage00'||incre||'';
                                ELSE
                                        EXIT;
                                END IF;
                        End Loop;
        End;
        Raise Notice 'Ending - Checking temporary column';

        Raise Notice 'Starting - Calculating subgraphs';
        BEGIN
                --------- Add necessary columns ----------
                EXECUTE 'ALTER TABLE '|| pgr_quote_ident(table_schema_name) ||' ADD COLUMN ' || pgr_quote_ident(subgraph) || ' INTEGER DEFAULT -1';
                EXECUTE 'ALTER TABLE '|| pgr_quote_ident(table_schema_name) ||' ADD COLUMN ' || pgr_quote_ident(garbage) || ' INTEGER DEFAULT 0';
                graph_id := 1;

                EXECUTE 'select count(*) as count from '|| pgr_quote_ident(table_schema_name) ||' where '|| rows_where ||'' into rec_count;
                if rec_count.count = 0 then
                        RETURN 'rows_where condition generated 0 rows';
                end if; 

                WHILE TRUE
                        LOOP
                                ---------- Assign the very first -1 row graph_id ----------
                                EXECUTE 'SELECT ' || pgr_quote_ident(id) || ' AS gid FROM '|| pgr_quote_ident(table_schema_name) ||' WHERE '|| rows_where ||' AND ' || pgr_quote_ident(subgraph) || ' = -1 LIMIT 1' INTO rec_single;
                                EXECUTE 'UPDATE '|| pgr_quote_ident(table_schema_name) ||' SET ' || pgr_quote_ident(subgraph) || ' = ' || graph_id || ' WHERE ' || pgr_quote_ident(id) || ' = ' || rec_single.gid || '';

                                --------- Search other rows with that particular graph_id -----------
                                WHILE TRUE
                                        LOOP
                                                EXECUTE 'SELECT COUNT(*) FROM '|| pgr_quote_ident(table_schema_name) ||' WHERE ' || pgr_quote_ident(subgraph) || ' = ' || graph_id || ' AND ' || pgr_quote_ident(garbage) || ' = 0' into rec_count;
                                                ----------- The following if else will check those rows which already have entertained ------------
                                                IF (rec_count.count > 0) THEN
                                                        sql1 := 'SELECT ' || pgr_quote_ident(id) || ' AS gid, ' || pgr_quote_ident(source) || ' AS source, ' || pgr_quote_ident(target) || ' AS target FROM '|| pgr_quote_ident(table_schema_name) ||' WHERE ' || pgr_quote_ident(subgraph) || ' = ' || graph_id || ' AND ' || pgr_quote_ident(garbage) || ' = 0';
                                                        FOR rec1 IN EXECUTE sql1
                                                                LOOP
                                                                        sql2 := 'SELECT ' || pgr_quote_ident(id) || ' AS gid, ' || pgr_quote_ident(source) || ' AS source, ' || pgr_quote_ident(target) || ' AS target FROM '|| pgr_quote_ident(table_schema_name) ||' WHERE '|| pgr_quote_ident(source) ||' = '|| rec1.source ||' OR '|| pgr_quote_ident(target) ||' = '|| rec1.source ||' OR '|| pgr_quote_ident(source) ||' = '|| rec1.target ||' OR '|| pgr_quote_ident(target) ||' = '|| rec1.target ||'';
                                                                        FOR rec2 IN EXECUTE sql2
                                                                                LOOP
                                                                                        EXECUTE 'UPDATE '|| pgr_quote_ident(table_schema_name) ||' SET ' || pgr_quote_ident(subgraph) || ' = ' || graph_id || ' WHERE ' || pgr_quote_ident(id) || ' = ' || rec2.gid || '';
                                                                                END LOOP;
                                                                        EXECUTE 'UPDATE '|| pgr_quote_ident(table_schema_name) ||' SET ' || pgr_quote_ident(garbage) || ' = 1 WHERE ' || pgr_quote_ident(id) || ' = ' || rec1.gid || '';
                                                                END LOOP;
                                                ELSE
                                                        EXIT;
                                                END IF;
                                        END LOOP;
                                
                                ------ Following is to exit the while loop. 0 means no more -1 id.
                                EXECUTE 'SELECT COUNT(*) AS count FROM '|| pgr_quote_ident(table_schema_name) ||' WHERE '|| rows_where ||' AND ' || pgr_quote_ident(subgraph) || ' = -1' INTO rec_count;
                                If (rec_count.count = 0) THEN
                                        EXIT;
                                ELSE
                                        graph_id := graph_id + 1;
                                END IF;
                        END LOOP;

                ----------- Drop garbage column ------------
                EXECUTE 'ALTER TABLE '|| pgr_quote_ident(table_schema_name) ||' DROP COLUMN ' || pgr_quote_ident(garbage) ||'';
                Raise Notice 'Successfully complicated calculating subgraphs';
        END;
        Raise Notice 'Ending - Calculating subgraphs';

        RETURN 'OK';

END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


/*
MANY TO MANY
*/

CREATE OR REPLACE FUNCTION pgr_withPointsCostMatrix(
    edges_sql TEXT,
    points_sql TEXT,
    pids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    driving_side CHAR DEFAULT 'b', -- 'r'/'l'/'b'/NULL

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT a.start_pid, a.end_pid, a.agg_cost
        FROM _pgr_withPoints($1, $2, $3, $3, $4,  $5, TRUE, TRUE) AS a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;



--  DIJKSTRA DMatrix

/***********************************
        MANY TO MANY
***********************************/

CREATE OR REPLACE FUNCTION pgr_dijkstraCostMatrix(edges_sql TEXT, vids ANYARRAY, directed BOOLEAN DEFAULT true,
    OUT start_vid BIGINT, OUT end_vid BIGINT, OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_dijkstra(_pgr_get_statement($1), $2, $2, $3, true) a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;






--  BIDIRECTIONAL DIJKSTRA Matrix


CREATE OR REPLACE FUNCTION pgr_bdDijkstraCostMatrix(edges_sql TEXT, vids ANYARRAY, directed BOOLEAN DEFAULT true,
    OUT start_vid BIGINT, OUT end_vid BIGINT, OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdDijkstra(_pgr_get_statement($1), $2::BIGINT[], $2::BIGINT[], $3, true) a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;





CREATE OR REPLACE FUNCTION pgr_astarCostMatrix(
    edges_sql TEXT, -- XY edges sql
    vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor FLOAT DEFAULT 1.0,
    epsilon FLOAT DEFAULT 1.0,
    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost FLOAT)

RETURNS SETOF RECORD AS
$BODY$
BEGIN
    RETURN query SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_astar(_pgr_get_statement($1), $2, $2, $3, $4, $5::FLOAT, $6::FLOAT, true) a;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;




--  BIDIRECTIONAL ASTAR Matrix


CREATE OR REPLACE FUNCTION pgr_bdAstarCostMatrix(
    edges_sql TEXT,
    vids ANYARRAY,
    directed BOOLEAN DEFAULT true,
    heuristic INTEGER DEFAULT 5,
    factor NUMERIC DEFAULT 1.0,
    epsilon NUMERIC DEFAULT 1.0,

    OUT start_vid BIGINT,
    OUT end_vid BIGINT,
    OUT agg_cost float)
RETURNS SETOF RECORD AS
$BODY$
    SELECT a.start_vid, a.end_vid, a.agg_cost
    FROM _pgr_bdAstar(_pgr_get_statement($1), $2::BIGINT[], $2::BIGINT[], $3, $4, $5::FLOAT, $6::FLOAT, true) a;
$BODY$
LANGUAGE sql VOLATILE
COST 100
ROWS 1000;
COMMENT ON FUNCTION pgr_bdAstarCostMatrix(TEXT, ANYARRAY, BOOLEAN, INTEGER, NUMERIC, NUMERIC) IS 'pgr_bdAstarCostMatrix';



CREATE OR REPLACE FUNCTION pgr_gsoc_vrppdtw(
    sql text,
    vehicle_num INTEGER,
    capacity INTEGER
)
RETURNS SETOF pgr_costresult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
customers_sql TEXT;
BEGIN
    RETURN query
         SELECT a.seq, vehicle_id::INTEGER AS id1, stop_id::INTEGER AS id2, departure_time AS cost
        FROM _pgr_pickDeliver($1, $2, $3, 1, 30) AS a WHERE vehicle_id NOT IN (-2);
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;



CREATE OR REPLACE FUNCTION pgr_getTableName(IN tab text,OUT sname text,OUT tname text)
RETURNS RECORD AS
$BODY$ 
BEGIN
    raise notice 'pgr_getTableName: This function will no longer be soported';
    select * from _pgr_getTableName(tab, 0, 'pgr_getTableName') into sname,tname;
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;

CREATE OR REPLACE FUNCTION pgr_getColumnName(tab text, col text)
RETURNS text AS
$BODY$
BEGIN
    raise notice 'pgr_getColumnName: This function will no longer be soported';
    return _pgr_getColumnName(tab,col, 0, 'pgr_getColumnName');
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;

CREATE OR REPLACE FUNCTION pgr_isColumnInTable(tab text, col text)
RETURNS boolean AS
$BODY$
DECLARE
    cname text;
BEGIN
    raise notice 'pgr_isColumnInTable: This function will no longer be soported';
    select * from _pgr_getColumnName(tab,col,0, 'pgr_isColumnInTable') into cname;
    return  cname IS not NULL;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE STRICT;

CREATE OR REPLACE FUNCTION pgr_isColumnIndexed(tab text, col text)
RETURNS boolean AS
$BODY$
BEGIN
    raise notice 'pgr_isColumnIndexed: This function will no longer be soported';
    return  _pgr_isColumnIndexed(tab,col);
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;


create or replace function pgr_quote_ident(idname text)
returns text as
$BODY$
BEGIN
    raise notice 'pgr_isColumnInTable: This function will no longer be soported';
    return  _pgr_quote_ident(idname);
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;

CREATE OR REPLACE FUNCTION pgr_versionless(v1 text, v2 text)
RETURNS boolean AS
$BODY$
BEGIN
    raise notice 'pgr_versionless: This function will no longer be soported';
    return  _pgr_versionless(v1,v2);
END;
$BODY$
LANGUAGE plpgsql VOLATILE STRICT;

create or replace function pgr_startPoint(g geometry)
    returns geometry as
$body$
BEGIN
    raise notice 'pgr_startPoint: This function will no longer be soported';
    return  _pgr_startPoint(g);
END;
$body$
language plpgsql IMMUTABLE;



create or replace function pgr_endPoint(g geometry)
    returns geometry as
$body$
BEGIN
    raise notice 'pgr_endPoint: This function will no longer be soported';
    return  _pgr_endPoint(g);
END;
$body$
language plpgsql IMMUTABLE;



CREATE OR REPLACE FUNCTION pgr_apspJohnson(edges_sql text)
    RETURNS SETOF pgr_costResult AS
  $BODY$
  DECLARE
  has_reverse boolean;
  sql TEXT;
  BEGIN
      RAISE NOTICE 'Deprecated function: Use pgr_johnson instead';
      has_reverse =_pgr_parameter_check('johnson', edges_sql, false);
      sql = edges_sql;
      IF (has_reverse) THEN
           RAISE NOTICE 'reverse_cost column found, removing.';
           sql = 'SELECT source, target, cost FROM (' || edges_sql || ') a';
      END IF;

      RETURN query
         SELECT (row_number() over () - 1)::integer as seq, start_vid::integer AS id1, end_vid::integer AS id2, agg_cost AS cost
         FROM  pgr_johnson(sql, TRUE);
  END
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;




CREATE OR REPLACE FUNCTION pgr_apspWarshall(edges_sql text, directed boolean, has_rcost boolean)
    RETURNS SETOF pgr_costResult AS
  $BODY$
  DECLARE
  has_reverse boolean;
  sql TEXT;
  BEGIN
      RAISE NOTICE 'Deprecated function: Use pgr_floydWarshall instead';
      has_reverse =_pgr_parameter_check('dijkstra', edges_sql, false);
      sql := edges_sql;
      IF (has_reverse != has_rcost) THEN
         IF (has_reverse) THEN
           sql = 'SELECT id, source, target, cost FROM (' || edges_sql || ') a';
         ELSE raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
         END IF;
      END IF;

      RETURN query
         SELECT (row_number() over () -1)::integer as seq, start_vid::integer AS id1, end_vid::integer AS id2, agg_cost AS cost
         FROM  pgr_floydWarshall(sql, directed);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;




-- V2 signature
CREATE OR REPLACE FUNCTION pgr_astar(edges_sql TEXT, source_id INTEGER, target_id INTEGER, directed BOOLEAN, has_rcost BOOLEAN)
RETURNS SETOF pgr_costresult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
sql TEXT;
BEGIN
    RAISE NOTICE 'Deprecated signature pgr_astar(text, integer, integer, boolean, boolean)';
    has_reverse =_pgr_parameter_check('astar', edges_sql, false);
    sql = edges_sql;
    IF (has_reverse != has_rcost) THEN
        IF (has_reverse) THEN
            sql = 'SELECT id, source, target, cost, x1,y1, x2, y2 FROM (' || edges_sql || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    RETURN query SELECT seq - 1 AS seq, node::INTEGER AS id1, edge::INTEGER AS id2, cost 
    FROM pgr_astar(sql, ARRAY[$2], ARRAY[$3], directed);
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;



-- V2 signature
CREATE OR REPLACE FUNCTION pgr_bdAstar(
    sql TEXT,
    source_vid INTEGER,
    target_vid INTEGER,
    directed BOOLEAN,
    has_reverse_cost BOOLEAN)
RETURNS SETOF pgr_costresult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
BEGIN
    RAISE NOTICE 'Deprecated Signature of pgr_bdAstar';
    has_reverse =_pgr_parameter_check('astar', $1, false);
    new_sql = $1;
    IF (has_reverse != $5) THEN
        IF (has_reverse) THEN
            new_sql = 'SELECT id, source, target, cost FROM (' || $1 || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    RETURN query SELECT seq-1 AS seq, node::integer AS id1, edge::integer AS id2, cost
    FROM _pgr_bdAstar(new_sql, ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], directed);
  END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;




-- V2 signature
CREATE OR REPLACE FUNCTION pgr_bdDijkstra(edges_sql TEXT, start_vid INTEGER, end_vid INTEGER, directed BOOLEAN, has_rcost BOOLEAN)
RETURNS SETOF pgr_costresult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
BEGIN
    RAISE NOTICE 'Deprecated Signature of pgr_bdDijkstra';
    has_reverse =_pgr_parameter_check('dijkstra', $1, false);
    new_sql = $1;
    IF (has_reverse != $5) THEN
        IF (has_reverse) THEN
            new_sql = 'SELECT id, source, target, cost FROM (' || $1 || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    RETURN query SELECT seq-1 AS seq, node::integer AS id1, edge::integer AS id2, cost
    FROM _pgr_bdDijkstra(new_sql, ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], directed, false);
  END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;



CREATE OR REPLACE FUNCTION pgr_kdijkstraPath(
    sql text,
    source INTEGER,
    targets INTEGER ARRAY,
    directed BOOLEAN,
    has_rcost BOOLEAN)
    RETURNS SETOF pgr_costResult3 AS
    $BODY$
    DECLARE
    has_reverse BOOLEAN;
    new_sql TEXT;
    result pgr_costResult3;
    tmp pgr_costResult3;
    sseq INTEGER;
    i INTEGER;
    BEGIN
        RAISE NOTICE 'Deprecated function: Use pgr_dijkstra instead.';
        has_reverse =_pgr_parameter_check('dijkstra', sql, false);
        new_sql = sql;
        IF (array_ndims(targets) != 1) THEN
            raise EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
            USING ERRCODE = 'XX000';
        END IF;

        IF (has_reverse != has_rcost) THEN
            IF (has_reverse) THEN
                new_sql = 'SELECT id, source, target, cost FROM (' || sql || ') a';
            ELSE
                raise EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
                USING ERRCODE = 'XX000';
            END IF;
        END IF;
        SELECT ARRAY(SELECT DISTINCT UNNEST(targets) ORDER BY 1) INTO targets;

        sseq = 0; i = 1;
        FOR result IN 
            SELECT seq, a.end_vid::INTEGER AS id1, a.node::INTEGER AS i2, a.edge::INTEGER AS id3, cost
            FROM pgr_dijkstra(new_sql, source, targets, directed) a ORDER BY a.end_vid, seq LOOP
            WHILE (result.id1 != targets[i]) LOOP
                tmp.seq = sseq;
                tmp.id1 = targets[i];
                IF (targets[i] = source) THEN
                    tmp.id2 = source;
                    tmp.cost =0;
                ELSE
                    tmp.id2 = 0;
                    tmp.cost = -1;
                END IF;
                tmp.id3 = -1;
                RETURN next tmp;
                i = i + 1;
                sseq = sseq + 1;
            END LOOP;
        IF (result.id1 = targets[i] AND result.id3 != -1) THEN
            result.seq = sseq;
            RETURN next result;
            sseq = sseq + 1;
            CONTINUE;
        END IF;
        IF (result.id1 = targets[i] AND result.id3 = -1) THEN
            result.seq = sseq;
            RETURN next result;
            i = i + 1;
            sseq = sseq + 1;
            CONTINUE;
        END IF;
    END LOOP;
    WHILE (i <= array_length(targets,1)) LOOP
        tmp.seq = sseq;
        tmp.id1 = targets[i];
        IF (targets[i] = source) THEN
            tmp.id2 = source;
            tmp.cost = 0;
        ELSE
            tmp.id2 = 0;
            tmp.cost = -1;
        END IF;
        tmp.id3 = -1;
        RETURN next tmp;
        i = i + 1;
        sseq = sseq + 1;
    END LOOP;

END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;


CREATE OR REPLACE FUNCTION pgr_kdijkstracost(
    sql text,
    source INTEGER,
    targets INTEGER array,
    directed BOOLEAN,
    has_rcost BOOLEAN)
RETURNS SETOF pgr_costResult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
new_sql TEXT;
result pgr_costResult;
tmp pgr_costResult;
sseq INTEGER;
i INTEGER;
BEGIN
    RAISE NOTICE 'Deprecated function. Use pgr_dijkstraCost instead.';
    has_reverse =_pgr_parameter_check('dijkstra', sql, false);
    new_sql = sql;
    IF (array_ndims(targets) != 1) THEN
        raise EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
        USING ERRCODE = 'XX000';
    END IF;


    IF (has_reverse != has_rcost) THEN
        IF (has_reverse) THEN
            new_sql = 'SELECT id, source, target, cost FROM (' || sql || ') a';
        ELSE
            RAISE EXCEPTION 'Error, reverse_cost is used, but query did''t return ''reverse_cost'' column'
            USING ERRCODE = 'XX000';
        END IF;
    END IF;

    SELECT ARRAY(SELECT DISTINCT UNNEST(targets) ORDER BY 1) INTO targets;

    sseq = 0; i = 1;
    FOR result IN 
        SELECT ((row_number() over()) -1)::INTEGER, a.start_vid::INTEGER, a.end_vid::INTEGER, agg_cost
        FROM pgr_dijkstraCost(new_sql, source, targets, directed) a ORDER BY end_vid LOOP
        WHILE (result.id2 != targets[i]) LOOP
            tmp.seq = sseq;
            tmp.id1 = source;
            tmp.id2 = targets[i];
            IF (targets[i] = source) THEN
                tmp.cost = 0;
            ELSE
                tmp.cost = -1;
            END IF;
            RETURN next tmp;
            i = i + 1;
            sseq = sseq + 1;
        END LOOP;
        IF (result.id2 = targets[i]) THEN
            result.seq = sseq;
            RETURN next result;
            i = i + 1;
            sseq = sseq + 1;
        END IF;
    END LOOP;
    WHILE (i <= array_length(targets,1)) LOOP
        tmp.seq = sseq;
        tmp.id1 = source;
        tmp.id2 = targets[i];
        IF (targets[i] = source) THEN
            tmp.cost = 0;
        ELSE
            tmp.cost = -1;
        END IF;
        RETURN next tmp;
        i = i + 1;
        sseq = sseq + 1;
    END LOOP;

END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;



create or replace function pgr_pointtoedgenode(edges text, pnt geometry, tol float8)
    returns integer as
$body$
/*
 *  pgr_pointtoedgenode(edges text, pnt geometry, tol float8)
 *
 *  Given and table of edges with a spatial index on the_geom
 *  and a point geometry search for the closest edge within tol distance to the edges
 *  then compute the projection of the point onto the line segment and select source or target
 *  based on whether the projected point is closer to the respective end and return source or target.
 *  If no edge is within tol distance then return -1
*/
declare
    rr record;
    pct float;
    debuglevel text;
    
begin
    -- find the closest edge within tol distance
    execute 'select * from ' || _pgr_quote_ident(edges) || 
            ' where st_dwithin(''' || pnt::text ||
            '''::geometry, the_geom, ' || tol || ') order by st_distance(''' || pnt::text ||
            '''::geometry, the_geom) asc limit 1' into rr;

    if rr.the_geom is not null then
        -- deal with MULTILINESTRINGS
        if geometrytype(rr.the_geom)='MULTILINESTRING' THEN
            rr.the_geom := ST_GeometryN(rr.the_geom, 1);
        end if;

        -- project the point onto the linestring
        execute 'show client_min_messages' into debuglevel;
        SET client_min_messages='ERROR';
        pct := st_line_locate_point(rr.the_geom, pnt);
        execute 'set client_min_messages  to '|| debuglevel;

        -- return the node we are closer to
        if pct < 0.5 then
            return rr.source;
        else
            return rr.target;
        end if;
    else
        -- return a failure to find an edge within tol distance
        return -1;
    end if;
end;
$body$
  language plpgsql volatile
  cost 5;


----------------------------------------------------------------------------

create or replace function pgr_flipedges(ga geometry[])
    returns geometry[] as
$body$
/*
 *  pgr_flipedges(ga geometry[])
 *
 *  Given an array of linestrings that are supposedly connected end to end like the results
 *  of a route, check the edges and flip any end for end if they do not connect with the
 *  previous seegment and return the array with the segments flipped as appropriate.
 *
 *  NOTE: no error checking is done for conditions like adjacent edges are not connected.
*/
declare
    nn integer;
    i integer;
    g geometry;
    
begin
    RAISE NOTICE 'Deperecated function: pgr_flipEdges';
    -- get the count of edges, and return if only one edge
    nn := array_length(ga, 1);
    if nn=1 then
        return ga;
    end if;

    -- determine if first needs to be flipped
    g := _pgr_startpoint(ga[1]);

    -- if the start of the first is connected to the second then it needs to be flipped
    if _pgr_startpoint(ga[2])=g or _pgr_endpoint(ga[2])=g then
        ga[1] := st_reverse(ga[1]);
    end if;
    g := _pgr_endpoint(ga[1]);

    -- now if  the end of the last edge matchs the end of the current edge we need to flip it
    for i in 2 .. nn loop
        if _pgr_endpoint(ga[i])=g then
            ga[i] := st_reverse(ga[i]);
        end if;
        -- save the end of this edge into the last end for the next cycle
        g := _pgr_endpoint(ga[i]);
    end loop;

    return ga;
end;
$body$
    language plpgsql immutable;


------------------------------------------------------------------------------

create or replace function pgr_texttopoints(pnts text, srid integer DEFAULT(4326))
    returns geometry[] as
$body$
/*
 *  pgr_texttopoints(pnts text, srid integer DEFAULT(4326))
 *
 *  Given a text string of the format "x,y;x,y;x,y;..." and the srid to use,
 *  split the string and create and array point geometries
*/
declare
    a text[];
    t text;
    p geometry;
    g geometry[];
    
begin
    RAISE NOTICE 'Deperecated function: pgr_textToPoints';
    -- convert commas to space and split on ';'
    a := string_to_array(replace(pnts, ',', ' '), ';');
    -- convert each 'x y' into a point geometry and concattenate into a new array
    for t in select unnest(a) loop
        p := st_pointfromtext('POINT(' || t || ')', srid);
        g := g || p;
    end loop;

    return g;
end;
$body$
    language plpgsql immutable;

-----------------------------------------------------------------------

create or replace function pgr_pointstovids(pnts geometry[], edges text, tol float8 DEFAULT(0.01))
    returns integer[] as
$body$
/*
 *  pgr_pointstovids(pnts geometry[], edges text, tol float8 DEFAULT(0.01))
 *
 *  Given an array of point geometries and an edge table and a max search tol distance
 *  convert points into vertex ids using pgr_pointtoedgenode()
 *
 *  NOTE: You need to check the results for any vids=-1 which indicates if failed to locate an edge
*/
declare
    v integer[];
    g geometry;
    
begin
    RAISE NOTICE 'Deperecated function: pgr_pointsToVids';
    -- cycle through each point and locate the nearest edge and vertex on that edge
    for g in select unnest(pnts) loop
        v := v || pgr_pointtoedgenode(edges, g, tol);
    end loop;

    return v;
end;
$body$
    language plpgsql stable;


create or replace function pgr_pointstodmatrix(pnts geometry[], mode integer default (0), OUT dmatrix double precision[], OUT ids integer[])
    returns record as
$body$
/*
 *  pgr_pointstodmatrix(pnts geometry[], OUT dmatrix double precision[], OUT ids integer[])
 *
 *  Create a distance symmetric distance matrix suitable for TSP using Euclidean distances
 *  based on the st_distance(). You might want to create a variant of this the uses st_distance_sphere()
 *  or st_distance_spheriod() or some other function.
 *
*/
declare
    r record;
    
begin
    RAISE NOTICE 'Deprecated function pgr_pointsToDMatrix';
    dmatrix := array[]::double precision[];
    ids := array[]::integer[];

    -- create an id for each point in the array and unnest it into a table nodes in the with clause
    for r in with nodes as (select row_number() over()::integer as id, p from (select unnest(pnts) as p) as foo)
        -- compute a row of distances
        select i, array_agg(dist) as arow from (
            select a.id as i, b.id as j, 
                case when mode=0
                    then st_distance(a.p, b.p)
                    else st_distance_sphere(a.p, b.p)
                end as dist
              from nodes a, nodes b
             order by a.id, b.id
           ) as foo group by i order by i loop

        -- you must concat an array[array[]] to make dmatrix[][]
        -- concat the row of distances to the dmatrix
        dmatrix := array_cat(dmatrix, array[r.arow]);
        ids := ids || array[r.i];
    end loop;
end;
$body$
    language plpgsql stable;


------------------------------------------------------------------------------

create or replace function pgr_vidstodmatrix(IN vids integer[], IN pnts geometry[], IN edges text, tol float8 DEFAULT(0.1), OUT dmatrix double precision[], OUT ids integer[])
    returns record as
$body$
/*
 *  pgr_vidstodmatrix(IN vids integer[], IN pnts geometry[], IN edges text, tol float8 DEFAULT(0.1),
 *                    OUT dmatrix double precision[], OUT ids integer[])
 *
 *  This function that's an array vertex ids, the original array of points, the edge table name and a tol.
 *  It then computes kdijkstra() distances for each vertex to all the other vertices and creates a symmetric
 *  distances matrix suitable for TSP. The pnt array and the tol are used to establish a BBOX for limiteding
 *  selection of edges.the extents of the points is expanded by tol.
 *
 *  NOTES:
 *  1. we compute a symmetric matrix because TSP requires that so the distances are better the Euclidean but
 *     but are not perfect
 *  2. kdijkstra() can fail to find a path between some of the vertex ids. We to not detect this other than
 *     the cost might get set to -1.0, so the dmatrix should be checked for this as it makes it invalid for TSP
 *
*/
declare
    i integer;
    j integer;
    nn integer;
    rr record;
    bbox geometry;
    t float8[];

begin
    RAISE NOTICE 'Deprecated function pgr_vidsToDMatrix';
    -- check if the input arrays has any -1 values, maybe this whould be a raise exception
    if vids @> ARRAY[-1] then
    raise notice 'Some vids are undefined (-1)!';
    dmatrix := null;
    ids := null;
    return;
    end if;

    ids := vids;

    -- get the count of nodes
    nn := array_length(vids,1);

    -- zero out a dummy row
    for i in 1 .. nn loop
        t := t || 0.0::float8;
    end loop;

    -- using the dummy row, zero out the whole matrix
    for i in 1 .. nn loop
    dmatrix := dmatrix || ARRAY[t];
    end loop;

    for i in 1 .. nn-1 loop
        j := i;
        -- compute the bbox for the point needed for this row
        select st_expand(st_collect(pnts[id]), tol) into bbox
          from (select generate_series as id from generate_series(i, nn)) as foo;

        -- compute kdijkstra() for this row
        for rr in execute 'select * from pgr_dijkstracost($1, $2, $3, false)'
                  using 'select id, source, target, cost from ' || edges || 
                        ' where the_geom && ''' || bbox::text || '''::geometry'::text, vids[i], vids[i+1:nn] loop

            -- TODO need to check that all node were reachable from source
            -- I think unreachable paths between nodes returns cost=-1.0

            -- populate the matrix with the cost values, remember this is symmetric
            j := j + 1;
            -- raise notice 'cost(%,%)=%', i, j, rr.agg_cost;
            dmatrix[i][j] := rr.agg_cost;
            dmatrix[j][i] := rr.agg_cost;
        end loop;
    end loop;

end;
$body$
    language plpgsql stable cost 200;



CREATE OR REPLACE FUNCTION pgr_vidsToDMatrix(sql TEXT, vids  INTEGER[], dir BOOLEAN, has_rcost BOOLEAN, want_symmetric BOOLEAN)
RETURNS float8[] AS
$BODY$
DECLARE
directed BOOLEAN;
has_reverse BOOLEAN;
edges_sql TEXT;
dmatrix_row float8[];
dmatrix float8[];
cell RECORD;
unique_vids INTEGER[];
total BIGINT;
from_v BIGINT;
to_v BIGINT;
BEGIN
    RAISE NOTICE 'Deprecated function pgr_vidsToDMatrix';
    has_reverse =_pgr_parameter_check('dijkstra', sql, false);
    edges_sql = sql;
    IF (has_reverse != has_rcost) THEN
        IF (has_reverse) THEN
            sql = 'SELECT id, source, target, cost FROM (' || sql || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    unique_vids :=  ARRAY(SELECT DISTINCT UNNEST(vids) ORDER BY 1);

    IF want_symmetric THEN
        directed = false;
    ELSE
        directed = dir;
    END IF;

    total := array_length(unique_vids, 1);

    -- initializing dmatrix
    FOR i in 1 .. total LOOP
        dmatrix_row := dmatrix_row || '+Infinity'::float8;
    END LOOP;
    FOR i in 1 .. total LOOP
    dmatrix := dmatrix || ARRAY[dmatrix_row];
    dmatrix[i][i] = 0;
    END LOOP;

    CREATE TEMP TABLE __x___y____temp AS
        WITH result AS
            (SELECT unnest(unique_vids) AS vid)
        SELECT row_number() OVER() AS idx, vid FROM result;

    FOR cell IN SELECT * FROM pgr_dijkstraCostMatrix(sql, unique_vids, directed) LOOP
        SELECT idx INTO from_v FROM __x___y____temp WHERE vid =  cell.start_vid;
        SELECT idx INTO to_v FROM __x___y____temp WHERE vid =  cell.end_vid;

        dmatrix[from_v][to_v] = cell.agg_cost;
        dmatrix[to_v][from_v] = cell.agg_cost;
    END LOOP;

    DROP TABLE IF EXISTS __x___y____temp;
    RETURN dmatrix;

    EXCEPTION WHEN others THEN 
       DROP TABLE IF EXISTS __x___y____temp;
       raise exception '% %', SQLERRM, SQLSTATE;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;



-- V2 signature
CREATE OR REPLACE FUNCTION pgr_dijkstra(
    edges_sql TEXT,
    start_vid INTEGER,
    end_vid INTEGER,
    directed BOOLEAN,
    has_rcost BOOLEAN)
RETURNS SETOF pgr_costresult AS
$BODY$
DECLARE
has_reverse BOOLEAN;
sql TEXT;
BEGIN
    RAISE NOTICE 'Deprecated function';
    has_reverse =_pgr_parameter_check('dijkstra', edges_sql, false);
    sql = edges_sql;
    IF (has_reverse != has_rcost) THEN
        IF (has_reverse) THEN
            sql = 'SELECT id, source, target, cost FROM (' || edges_sql || ') a';
        ELSE
            raise EXCEPTION 'has_rcost set to true but reverse_cost not found';
        END IF;
    END IF;

    RETURN query SELECT seq-1 AS seq, node::integer AS id1, edge::integer AS id2, cost
    FROM _pgr_dijkstra(sql, ARRAY[$2]::BIGINT[], ARRAY[$3]::BIGINT[], directed, false);
  END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100
ROWS 1000;
COMMENT ON FUNCTION pgr_dijkstra( TEXT, INTEGER, INTEGER, BOOLEAN, BOOLEAN) IS 'pgr_dijkstra(Deprecated signature)';





-- OLD SIGNATURE
CREATE OR REPLACE FUNCTION pgr_drivingDistance(edges_sql text, source INTEGER, distance FLOAT, directed BOOLEAN, has_rcost BOOLEAN)
  RETURNS SETOF pgr_costresult AS
  $BODY$
  DECLARE
  has_reverse BOOLEAN;
  sql TEXT;
  BEGIN
      RAISE NOTICE 'Deprecated function';

      has_reverse =_pgr_parameter_check('dijkstra', edges_sql, FALSE);

      sql = edges_sql;
      IF (has_reverse != has_rcost) THEN
         IF (has_reverse) THEN 
             -- the user says it doesn't have reverse cost but its false
             -- removing from query
             RAISE NOTICE 'Contradiction found: has_rcost set to false but reverse_cost column found';
             sql = 'SELECT id, source, target, cost, -1 as reverse_cost FROM (' || edges_sql || ') __q ';
         ELSE
             -- the user says it has reverse cost but its false
             -- can't do anything
             RAISE EXCEPTION 'has_rcost set to true but reverse_cost not found';
         END IF;
      END IF;

      RETURN query SELECT seq - 1 AS seq, node::integer AS id1, edge::integer AS id2, agg_cost AS cost
                FROM pgr_drivingDistance($1, ARRAY[$2]::BIGINT[], $3, $4, false);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;



--FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maximumcardinalitymatching(
    edges_sql TEXT,
    directed BOOLEAN DEFAULT TRUE,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT
    )
  RETURNS SETOF RECORD AS
 '$libdir/libpgrouting-2.5', 'maximum_cardinality_matching'
    LANGUAGE c IMMUTABLE STRICT;


/***********************************
        ONE TO ONE
***********************************/


--FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maxFlowPushRelabel(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_PushRelabel($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowBoykovKolmogorov(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_boykovKolmogorov($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowEdmondsKarp(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_edmondsKarp($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

/***********************************
        ONE TO MANY
***********************************/

--INTERNAL FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maxFlowPushRelabel(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_PushRelabel($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowBoykovKolmogorov(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_boykovKolmogorov($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowEdmondsKarp(
    edges_sql TEXT,
    source_vertex BIGINT,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_edmondsKarp($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

/***********************************
        MANY TO ONE
***********************************/

--FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maxFlowPushRelabel(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_PushRelabel($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowBoykovKolmogorov(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_boykovKolmogorov($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowEdmondsKarp(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertex BIGINT,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_edmondsKarp($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

/***********************************
        MANY TO MANY
***********************************/


--FUNCTIONS

CREATE OR REPLACE FUNCTION pgr_maxFlowPushRelabel(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_PushRelabel($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowBoykovKolmogorov(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_boykovKolmogorov($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION pgr_maxFlowEdmondsKarp(
    edges_sql TEXT,
    source_vertices ANYARRAY,
    sink_vertices ANYARRAY,
    OUT seq INTEGER,
    OUT edge_id BIGINT,
    OUT source BIGINT,
    OUT target BIGINT,
    OUT flow BIGINT,
    OUT residual_capacity BIGINT
    )
  RETURNS SETOF RECORD AS
  $BODY$
  BEGIN
        RETURN QUERY SELECT *
        FROM pgr_edmondsKarp($1, $2, $3);
  END
  $BODY$
  LANGUAGE plpgsql VOLATILE;




------------------------
-- deprecated signatures
-----------------------

COMMENT ON FUNCTION pgr_astar(TEXT, INTEGER, INTEGER, BOOLEAN, BOOLEAN)
    IS 'pgr_astar(Deprecated signature)';

COMMENT ON FUNCTION pgr_bdAstar( TEXT, INTEGER, INTEGER, BOOLEAN, BOOLEAN)    
    IS 'pgr_bdAstar(Deprecated signature)';

COMMENT ON FUNCTION pgr_bdDijkstra( TEXT, INTEGER, INTEGER, BOOLEAN, BOOLEAN)
    IS 'pgr_bdDijkstra(Deprecated signature)';

COMMENT ON FUNCTION pgr_dijkstra(TEXT, INTEGER, INTEGER, BOOLEAN, BOOLEAN)
    IS 'pgr_dijkstra(Deprecated signature)';

COMMENT ON FUNCTION pgr_drivingDistance(text,  INTEGER,  FLOAT8,  BOOLEAN,  BOOLEAN)
    IS 'pgr_drivingDistance(Deprecated signature)';

------------------------
-- Renamed /deprecated
-----------------------
COMMENT ON FUNCTION pgr_apspJohnson(TEXT)
    IS 'pgr_apspJohnson(Renamed function) use pgr_Johnson insteaad';

COMMENT ON FUNCTION pgr_apspWarshall(text, boolean, boolean)
    IS 'pgr_apspWarshall(Renamed function) use pgr_floydWarshall insteaad';

COMMENT ON FUNCTION pgr_kdijkstraPath( text, INTEGER, INTEGER ARRAY, BOOLEAN, BOOLEAN)
    IS 'pgr_kdijkstraPath(Renamed function) use pgr_dijkstra insteaad';

COMMENT ON FUNCTION pgr_kdijkstracost( text, INTEGER, INTEGER array, BOOLEAN, BOOLEAN)
    IS 'pgr_kDijkstraCost(Renamed function) use pgr_dijkstraCost insteaad';

COMMENT ON FUNCTION  pgr_maxFlowPushRelabel(TEXT, BIGINT, BIGINT)
    IS 'pgr_maxFlowPushRelabel(Renamed function) use pgr_pushRelabel insteaad';
COMMENT ON FUNCTION  pgr_maxFlowPushRelabel(TEXT, BIGINT, ANYARRAY)
    IS 'pgr_maxFlowPushRelabel(Renamed function) use pgr_pushRelabel insteaad';
COMMENT ON FUNCTION  pgr_maxFlowPushRelabel(TEXT, ANYARRAY, BIGINT)
    IS 'pgr_maxFlowPushRelabel(Renamed function) use pgr_pushRelabel insteaad';
COMMENT ON FUNCTION  pgr_maxFlowPushRelabel(TEXT, ANYARRAY, ANYARRAY)
    IS 'pgr_maxFlowPushRelabel(Renamed function) use pgr_pushRelabel insteaad';


COMMENT ON FUNCTION  pgr_maxFlowEdmondsKarp(TEXT, BIGINT, BIGINT)
    IS 'pgr_maxFlowEdmondsKarp(Renamed function) use pgr_edmondsKarp insteaad';
COMMENT ON FUNCTION  pgr_maxFlowEdmondsKarp(TEXT, BIGINT, ANYARRAY)
    IS 'pgr_maxFlowEdmondsKarp(Renamed function) use pgr_edmondsKarp insteaad';
COMMENT ON FUNCTION  pgr_maxFlowEdmondsKarp(TEXT, ANYARRAY, BIGINT)
    IS 'pgr_maxFlowEdmondsKarp(Renamed function) use pgr_edmondsKarp insteaad';
COMMENT ON FUNCTION  pgr_maxFlowEdmondsKarp(TEXT, ANYARRAY, ANYARRAY)
    IS 'pgr_maxFlowEdmondsKarp(Renamed function) use pgr_edmondsKarp insteaad';

COMMENT ON FUNCTION  pgr_maxFlowBoykovKolmogorov(TEXT, BIGINT, BIGINT)
    IS 'pgr_maxFlowBoykovKolmogorov(Renamed function) use pgr_boykovKolmogorov insteaad';
COMMENT ON FUNCTION  pgr_maxFlowBoykovKolmogorov(TEXT, BIGINT, ANYARRAY)
    IS 'pgr_maxFlowBoykovKolmogorov(Renamed function) use pgr_boykovKolmogorov insteaad';
COMMENT ON FUNCTION  pgr_maxFlowBoykovKolmogorov(TEXT, ANYARRAY, BIGINT)
    IS 'pgr_maxFlowBoykovKolmogorov(Renamed function) use pgr_boykovKolmogorov insteaad';
COMMENT ON FUNCTION  pgr_maxFlowBoykovKolmogorov(TEXT, ANYARRAY, ANYARRAY)
    IS 'pgr_maxFlowBoykovKolmogorov(Renamed function) use pgr_boykovKolmogorov insteaad';

------------------------
-- Deprecated functions
-----------------------

COMMENT ON FUNCTION pgr_flipedges(geometry[])
    IS 'pgr_flipedges(Deprecated function)';

COMMENT ON FUNCTION pgr_texttopoints(text,  integer)
    IS 'pgr_texttopoints(Deprecated function)';

COMMENT ON FUNCTION pgr_pointstovids(pnts geometry[], edges text, tol float8)
    IS 'pgr_pointstovids(Deprecated function)';

COMMENT ON FUNCTION pgr_pointtoedgenode(edges text, pnt geometry, tol float8)
    IS 'pgr_pointtoedgenode(Deprecated function)';

COMMENT ON FUNCTION pgr_pointstodmatrix(geometry[], integer)
    IS 'pgr_pointstodmatrix(Deprecated function)';

COMMENT ON FUNCTION pgr_vidstodmatrix( integer[],  geometry[],  text, float8)
    IS 'pgr_vidstodmatrix(Deprecated function)';

COMMENT ON FUNCTION pgr_vidsToDMatrix(TEXT,  INTEGER[], BOOLEAN, BOOLEAN, BOOLEAN)
    IS 'pgr_vidstodmatrix(Deprecated function)';




COMMENT ON FUNCTION pgr_getTableName(IN tab text)
    IS 'pgr_getTableName(Deprecated function)';

COMMENT ON FUNCTION pgr_getColumnName(tab text, col text)
    IS 'pgr_getColumnName(Deprecated function)';

COMMENT ON FUNCTION pgr_isColumnInTable(tab text, col text)
    IS 'pgr_isColumnInTable(Deprecated function)';

COMMENT ON FUNCTION pgr_isColumnIndexed(tab text, col text)
    IS 'pgr_isColumnIndexed(Deprecated function)';


COMMENT ON FUNCTION pgr_quote_ident(idname text)
    IS 'pgr_quote_ident(Deprecated function)';

COMMENT ON FUNCTION pgr_versionless(v1 text, v2 text)
    IS 'pgr_versionless(Deprecated function)';

COMMENT ON FUNCTION pgr_startPoint(g geometry)
    IS 'pgr_startPoint(Deprecated function)';

COMMENT ON FUNCTION pgr_endPoint(g geometry)
    IS 'pgr_endPoint(Deprecated function)';
