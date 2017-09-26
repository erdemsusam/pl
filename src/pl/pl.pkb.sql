CREATE OR REPLACE package body UTIL.pl
as

  ------------------------------------------------------------------------------
  -- License
  ------------------------------------------------------------------------------
  -- BSD 2-Clause License
  -- Copyright (c) 2017, bluecolor, All rights reserved.
  -- Redistribution and use in source and binary forms, with or without modification, are permitted 
  -- provided that the following conditions are met:
  -- 
  -- * Redistributions of source code must retain the above copyright notice, 
  -- this list of conditions and the following disclaimer.
  -- 
  -- * Redistributions in binary form must reproduce the above copyright notice, 
  -- this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
  --
  -- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, 
  -- INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR 
  -- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY 
  -- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, 
  -- PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
  -- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, 
  -- STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, 
  -- EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  ------------------------------------------------------------------------------

  -- name of this package
  gv_package varchar2(30) := 'PL'; 
  
  -- dynamic task for execute immediate
  gv_sql  long;
  gv_proc varchar2(128);


  -- exceptions
  partition_not_found   exception;
  table_not_partitioned exception;

  pragma exception_init(partition_not_found,   -20170);
  pragma exception_init(table_not_partitioned, -20171);

  ------------------------------------------------------------------------------
  -- check if table exists
  ------------------------------------------------------------------------------
  function table_exists(i_owner varchar2, i_table varchar2) return boolean
  IS
    v_proc varchar2(1000) := gv_package || '.table_exists';
    v_cnt  number := 0;
  begin

    gv_sql := '
      select count(1)
      from all_tables
      where table_name = upper ('''||i_table||''') and owner = upper ('''||i_owner||''')
    ';
    execute immediate gv_sql into v_cnt;
    return case v_cnt when 0 then false else true end; 

  exception
    when others then
      logger.error(SQLERRM, gv_sql);
      raise;
  end;

  function find_partition_prefix(i_part_name varchar2) return varchar2
  is
    v_chr char(2);
    v_part_prefix varchar2(10) := '';
  begin
    
    --printl('v_part_name: ' || i_part_name);    
  
    for i in 1 .. length(i_part_name) loop
      v_chr := substr(i_part_name,i,1);
      if(is_number(v_chr)) then
        exit;
      else 
        v_part_prefix := v_part_prefix || v_chr;
      end if;
    end loop;
    
    --printl('part prefix: ' || v_part_prefix);    

    return trim(v_part_prefix);
  end;

  function to_date(i_str long) return date
  is
    v_col   varchar2(1000);
    v_date  date;
  begin
    
    v_col := case length(i_str) 
      when 4 then 'to_date('''||i_str||''',''yyyy'')'   
      when 6 then 'to_date('''||i_str||''',''yyyymm'')'
      when 8 then 'to_date('''||i_str||''',''yyyymmdd'')'
      else i_str 
    end;

    gv_sql := 'select '||v_col||' from dual';
    execute immediate gv_sql into v_date; 
    return v_date;
  end;

  function find_prev_high_value(i_range_type char, i_next_high_val long) return long
  is
    v_high_date date;
    v_return long;
  begin

    v_high_date := to_date(i_next_high_val);

    v_return := case i_range_type
        when 'd' then to_char(v_high_date-1,'yyyymmdd')
        when 'm' then to_char(add_months(v_high_date,-1),'yyyymm')
        when 'y' then to_char(add_months(v_high_date,-12),'yyyy')
        else date_string(v_high_date-1)
    end;
    
    return v_return;  

  end;
  
  function find_next_high_value(i_range_type char, i_prev_high_val long) return long
  is
    v_high_date date;
    v_return long;
  begin

    v_high_date := to_date(i_prev_high_val);
    
    v_return := case i_range_type
        when 'd' then to_char(v_high_date+1,'yyyymmdd')
        when 'm' then to_char(add_months(v_high_date,1),'yyyymm')
        when 'y' then to_char(add_months(v_high_date,12),'yyyy')
        else date_string(v_high_date+1)
    end;
    
    return v_return;

  end;

  function find_partition_range_type(i_owner varchar2, i_table varchar2) return char
  is
    v_part_name varchar2(100);
    v_col_data_type varchar2(20)  := 'DATE';
    v_part_prefix varchar2(10) := '';
    v_part_suffix varchar2(10) := '';
    v_range_type  char(1):= 'D';
  begin
    gv_sql := '
      select partition_name from all_tab_partitions 
      where 
        table_owner = '''||upper(i_owner) ||''' and
        table_name = '''||upper(i_table) ||''' and
        rownum = 1
    ';
    --printl(gv_sql);
    
    execute immediate gv_sql into v_part_name;
    
    --printl(v_part_name);
    
    v_part_prefix := find_partition_prefix(v_part_name);
    v_part_suffix := ltrim(v_part_name, v_part_prefix);
    
    v_col_data_type := find_partition_col_type(i_owner, i_table);
    
    v_range_type  := case v_col_data_type
    when 'DATE' then
        case length(v_part_suffix)
            when 8 then 'D'
        end
    else
        case length(v_part_suffix)
            when 4 then 'y'
            when 6 then 'm'
            when 8 then 'd'
        end
    end; 
    return v_range_type;   
  end;

  -- Splits string by separator.
  -- Arguments: 
  --    [i_str='']    (varchar2): The string to split.
  --    [i_split=','] (varchar2): The separator pattern to split by.
  --    [i_limit]     (number): The length to truncate results to.
  -- Returns
  --    (varchar2_table): Returns the string segments.
  function split(i_str varchar2, i_split varchar2 default ',', i_limit number default null) return dbms_sql.varchar2_table
  is
    i number := 0;
    v_str varchar2(4000) := i_str;
    v_res dbms_sql.varchar2_table;
  begin
    loop
      i := i + 1;
      v_str := ltrim(i_str, i_split);
      if v_str is not null and instr(v_str,i_split) > 0 then
        v_res(i) := substr(v_str,1,instr(v_str,i_split)-1);
        v_str := ltrim(v_str, v_res(i));
      else
        if  length(v_str) > 0 then
          v_res(i) := v_str;
        end if;
        exit;
      end if;

      if i_limit is not null and i_limit >= i then exit; end if;

    end loop;

    return v_res;
  end;

  function find_min_partition(i_owner varchar2, i_table varchar2) return long
  is
    v_part long;
    v_partition_name varchar2(20);
    v_high_value varchar2(4000);
  begin

    select partition_name, high_value into v_partition_name, v_high_value 
    from
      (
        select 
          partition_name,
          high_value,
          row_number() over(partition by table_owner, table_name order by partition_position asc) rank_id 
        from all_tab_partitions 
        where table_owner = upper(i_owner) and table_name = upper(i_table)
      )
    where rank_id = 1;

    return v_partition_name||':'||v_high_value;
  end;  

  function find_max_partition(i_owner varchar2, i_table varchar2) return long
  is
    v_part long;
    v_partition_name varchar2(20);
    v_high_value varchar2(4000);
  begin

    select partition_name, high_value into v_partition_name, v_high_value 
    from
      (
        select 
          partition_name,
          high_value,
          row_number() over(partition by table_owner, table_name order by partition_position desc) rank_id 
        from all_tab_partitions 
        where table_owner = upper(i_owner) and table_name = upper(i_table)
      )
    where rank_id = 1;

    return v_partition_name||':'||v_high_value;
  end;  

  
  function find_partition_col_type(i_owner varchar2, i_table varchar2) return varchar2
  is
    v_col_data_type varchar2(20)  := 'DATE';
  begin
    gv_sql :='
      select 
        c.data_type
      from 
        ALL_TAB_COLS         c,
        ALL_PART_KEY_COLUMNS p
      where
        p.owner       = c.owner             and
        p.column_name = c.column_name       and
        c.table_name = '''||upper(i_table)||''' and
        p.name = '''||upper(i_table)||''' and
        p.owner= '''||upper(i_owner)||'''
    ';
    execute immediate gv_sql into v_col_data_type;
    return v_col_data_type;
  end;



  function is_number(i_str varchar2) return boolean 
  is
  begin
    return case nvl(length(trim(translate(i_str, ' +-.0123456789', ' '))),0) when 0 then true else false end;
  end;

  ------------------------------------------------------------------------------
  -- return a string representation of date object.
  -- this method is useful when you use dynamic sql with exec. immediate
  -- and want to use a date object in your dynamic sql string.  
  ------------------------------------------------------------------------------
  function date_string(i_date date) return varchar2
  is
  begin
    return 'to_date('''||to_char(i_date, 'ddmmyyyy hh24:mi:ss')|| ''',''ddmmyyyy hh24:mi:ss'')';
  end;

  function escape_sq(i_string varchar2) return varchar2
  is
  begin
    return replace(i_string, '''', '''''');
  end;

  ------------------------------------------------------------------------------
  -- truncate table given with schema name, and table name 
  -- eg. pl.truncate_table('UTIL','LOGS')
  ------------------------------------------------------------------------------
  procedure truncate_table(i_owner varchar2, i_table in varchar2)
  is
    v_proc varchar2(1000) := gv_package || '.truncate_table';
  begin
    logger := logtype.init(v_proc);
    gv_sql := 'truncate table '|| i_owner || '.' || i_table;
    execute immediate gv_sql;
    logger.success(i_owner || '.' || i_table|| ' truncated', gv_sql);
  exception 
    when others then
      logger.error(SQLERRM, gv_sql);
      raise;
  end;


  ------------------------------------------------------------------------------
  -- drop table given with schema name, and table name 
  -- eg. pl.truncate_table('UTIL','LOGS') ignores errors if table not found
  ------------------------------------------------------------------------------
  procedure drop_table(i_owner varchar2, i_table in varchar2, i_ignore_err boolean default true)
  is
    v_proc varchar2(1000) := gv_package || '.drop_table';
  begin
    logger := logtype.init(v_proc);
    gv_sql := 'drop table '|| i_owner || '.' || i_table;
    execute immediate gv_sql;
    logger.success(i_owner || '.' || i_table|| ' dropped', gv_sql);
    
  exception 
    when others then
      logger.error(SQLERRM, gv_sql);
      if i_ignore_err = false then raise; end if;
  end;


  ------------------------------------------------------------------------------
  -- enable parallel dml for the current session
  ------------------------------------------------------------------------------
  procedure enable_parallel_dml
  is
    v_proc varchar2(1000) := gv_package || '.enable_parallel_dml';
  begin  
    gv_sql := 'alter session enable parallel dml';
    execute immediate gv_sql;
    logger.success( ' enabled parallel dml for current session', gv_sql);
  exception
    when others then
      logger.error(SQLERRM, gv_sql);
      raise;
  end;


  ------------------------------------------------------------------------------
  -- truncates given partition, raises error if partition not found.
  ------------------------------------------------------------------------------
  procedure truncate_partition(i_owner varchar2, i_table varchar2, i_partition varchar2)
  is
    v_proc varchar2(1000) := gv_package || '.truncate_partition';
    v_cnt  number := 0;
  begin
    gv_sql := '
      select count(1)
      from all_tab_partitions
      where 
        table_name = upper('''||i_table||''') and 
        table_owner = upper('''||i_owner||''')      and
        partition_name = upper('''||i_partition||''') 
    ';
    execute immediate gv_sql into v_cnt;

    if v_cnt = 0 then
      raise partition_not_found;
    else 
      gv_sql := 'alter table '|| i_owner||'.'||i_table||' truncate partition '||i_partition;
      execute immediate gv_sql;
      logger.success( ' partition '||i_partition||' truncated', gv_sql);
    end if;
  
  exception 
    when partition_not_found then
      logger.error(v_proc||' partition '||i_partition||' not found!', gv_sql);
      raise_application_error (
        -20170,
        v_proc||' partition '||i_partition||' not found!'
      );
    when others then 
      logger.error(SQLERRM, gv_sql);
      raise;
  end;
  
    ------------------------------------------------------------------------------
  -- truncates given partition, raises error if partition not found.
  ------------------------------------------------------------------------------
  procedure truncate_partition(i_owner varchar2, i_table varchar2, i_date date)
  is
    v_proc varchar2(1000) := gv_package || '.truncate_partition';
    v_cnt  number := 0;
    v_partition_name varchar2(100);
    v_range_type  char(1):= 'd';
    v_prev_high_value varchar2(100);
  begin
    gv_sql := '
      select count(1)
      from all_tab_partitions
      where 
        table_name = upper('''||i_table||''') and 
        table_owner = upper('''||i_owner||''')
    ';
    
    execute immediate gv_sql into v_cnt;

    v_range_type  := find_partition_range_type(i_owner, i_table); 

    if v_cnt = 0 then
      raise partition_not_found;
    else
      for c1 in (
        select 
            t.partition_name, t.high_value 
        from all_tab_partitions t 
        where 
            upper(t.table_owner)= upper(i_owner) and
            upper(t.table_name) = upper(i_table)  
      ) loop
      
        v_prev_high_value := find_prev_high_value(v_range_type, c1.high_value);
        printl(v_prev_high_value);
      
        if to_date(v_prev_high_value) = i_date then 
            v_partition_name := c1.partition_name;
            printl(v_partition_name);
            exit;
        end if;
      end loop;

      gv_sql := 'alter table '|| i_owner||'.'||i_table||' truncate partition '||v_partition_name;
      printl(gv_sql);
      execute immediate gv_sql;
      logger.success( ' partition '||v_partition_name||' truncated', gv_sql);
    end if;
  
  exception 
    when partition_not_found then
      logger.error(v_proc||' partition for '||i_date||' not found!', gv_sql);
      raise_application_error (
        -20170,
        v_proc||' partition for '||i_date||' not found!'
      );
    when others then 
      logger.error(SQLERRM, gv_sql);
      raise;
  end;
  
    ------------------------------------------------------------------------------
    -- truncates given partitions starting from date through number of patitions,
    -- raises error if partition not found.
    ------------------------------------------------------------------------------

  procedure truncate_partitions(i_owner varchar2, i_table varchar2, i_date date, i_num_part number)
  is
    v_range_type  char(1):= 'd';
    v_max_date    number(8);
    i number := 0;
    v_cnt  number;
    v_num_part number;
  begin
    
    gv_proc   := 'pl.truncate_partitions'; 
    logger := logtype.init(gv_proc);
    
    v_range_type  := find_partition_range_type(i_owner, i_table); 
    
    gv_sql := '
      select count(1)
      from all_tab_partitions
      where 
        table_name = upper('''||i_table||''') and 
        table_owner = upper('''||i_owner||''')
    ';

    execute immediate gv_sql into v_cnt;
    
    if v_cnt < i_num_part 
        then v_num_part := v_cnt; 
    else v_num_part := i_num_part;
    end if;

    printl(v_num_part);
    
    while i < v_num_part
    loop 

      v_max_date := case v_range_type
        when 'd' then to_char(i_date-i,'yyyymmdd')
        when 'm' then to_char(add_months(i_date,-i),'yyyymm')
        when 'y' then to_char(add_months(i_date,-i),'yyyy')
      end;
      
      printl(v_max_date);
      truncate_partition(i_owner, i_table, v_max_date);
      printl('part name: P'||v_max_date);
      printl('i: '|| i);
      i := i + 1;
    end loop;

  exception 
  when others then 
    pl.logger.error(SQLERRM, gv_sql);
    raise;
  end;

    ------------------------------------------------------------------------------
    -- truncates given partitions starting from date through number of patitions,
    -- raises error if partition not found.
    ------------------------------------------------------------------------------

  procedure truncate_partitions(i_owner varchar2, i_table varchar2, i_start_date date, i_end_date date)
  is
    v_range_type  char(1):= 'D';
    v_high_value  long;
    v_part long;
    v_part_date date;
    v_part_name varchar2(100);
    v_partition_col_type varchar2(100);
    v_max_date date;
    v_min_date date;
  begin
    gv_proc   := 'pl.truncate_partitions'; 
    logger := logtype.init(gv_proc);

    v_range_type  := find_partition_range_type(i_owner, i_table); 
    v_partition_col_type := find_partition_col_type(i_owner, i_table);
    
    
    v_part := find_max_partition(i_owner, i_table);
    v_part_name   := substr(v_part, 1, instr(v_part, ':')-1);
    v_high_value  := ltrim(v_part, v_part_name||':');
    
    
    if v_partition_col_type = 'DATE' then
      gv_sql := 'select '||v_high_value||' from dual';   
    elsif v_range_type = 'y' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyy'') from dual';
    elsif v_range_type = 'm' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyymm'') from dual';
    elsif v_range_type = 'd' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyymmdd'') from dual';    
    end if;

    execute immediate gv_sql into v_max_date;
    
    --printl('max date'||v_max_date);
    
    v_part := find_min_partition(i_owner, i_table);
    v_part_name   := substr(v_part, 1, instr(v_part, ':')-1);
    v_high_value  := ltrim(v_part, v_part_name||':');
    
    if v_partition_col_type = 'DATE' then
      gv_sql := 'select '||v_high_value||' from dual';   
    elsif v_range_type = 'y' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyy'') from dual';
    elsif v_range_type = 'm' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyymm'') from dual';
    elsif v_range_type = 'd' then
      gv_sql := 'select to_date('|| to_char(v_high_value) ||',''yyyymmdd'') from dual';    
    end if;

    execute immediate gv_sql into v_min_date;
    
    
    for c1 in (
      select 
        t.partition_name partition_name, t.high_value high_value
      from 
        all_tab_partitions t 
      where 
        upper(t.table_owner)= upper(i_owner) and
        upper(t.table_name) = upper(i_table)  
      order by partition_position desc
    )
    loop        
        gv_sql := 'select '||c1.high_value||' from dual';   

        execute immediate gv_sql into v_part_date;

        
        if v_part_date-1 > to_date(i_end_date) 
            then continue;
        elsif v_part_date-1 >= to_date(i_start_date) then
            truncate_partition(i_owner, i_table, c1.partition_name);
            printl('part name '||c1.partition_name);
        else exit;
        end if;

    end loop;
    
    exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;

  end;
  
  procedure drop_partition(
    i_owner varchar2,
    i_table varchar2, 
    i_date date, 
    i_operator varchar2 default '<'
  )
  is
    v_proc          varchar2(20)  := 'drop_partition';
    v_col_name      varchar2(200) := '';
    v_col_data_type varchar2(20)  := 'DATE';
    v_cnt           number;
    
  begin
    logger := logtype.init(v_proc);

    v_col_data_type := find_partition_col_type(i_owner, i_table);

    for c1 in (
      select 
        t.partition_name, t.high_value 
      from 
        all_tab_partitions t 
      where 
        upper(t.table_owner)= upper(i_owner) and
        upper(t.table_name) = upper(i_table)  
    ) loop

      gv_sql := 'select count(1) from dual where 
        ' || c1.high_value || i_operator || 
        case v_col_data_type 
          when 'DATE' then date_string(trunc(i_date)) 
          else to_char(i_date,'yyyymmdd') 
        end; 
      execute immediate gv_sql into v_cnt;

      if v_cnt = 1 then 
        gv_sql := 'alter table '||i_owner||'.'||i_table||' drop partition '|| c1.partition_name; 
        execute immediate gv_sql;
        logger.success('op:'||i_operator, gv_sql);
      end if;

    end loop;
    
  
  exception 
    when others then 
      logger.error(SQLERRM, gv_sql);
      raise;
  end;

  ------------------------------------------------------------------------------
  -- drops given partition
  ------------------------------------------------------------------------------
  procedure drop_partition(i_owner varchar2, i_table varchar2, i_partition varchar2)
  is
    v_proc varchar2(1000) := gv_package || '.drop_partition';
    v_cnt  number := 0;
  begin
    gv_sql := '
      select count(1)
      from all_tab_partitions
      where 
        table_name = upper('''||i_table||''') and 
        table_owner = upper('''||i_owner||''')      and
        partition_name = upper('''||i_partition||''') 
    ';
    execute immediate gv_sql into v_cnt;

    if v_cnt = 0 then
      logger.info(' partition '||i_partition||' not found', gv_sql);
    else 
      gv_sql := 'alter table '|| i_owner||'.'||i_table||' drop partition '||i_partition;
      execute immediate gv_sql;
      logger.success( ' partition '||i_partition||' dropped', gv_sql);
    end if;
  
  exception 
    when others then 
      logger.error( SQLERRM, gv_sql);
      raise;
  end;
  

  procedure drop_partition_lt(i_owner varchar2, i_table varchar2, i_date date)
  is
  begin
    drop_partition(i_owner, i_table, i_date,'<');
  end;  

  procedure drop_partition_lte(i_owner varchar2, i_table varchar2, i_date date)
  is
  begin
    drop_partition(i_owner, i_table, i_date,'<=');
  end;  

  procedure drop_partition_gt(i_owner varchar2, i_table varchar2, i_date date)
  is
  begin
    drop_partition(i_owner, i_table, i_date,'>');
  end;  

  procedure drop_partition_gte(i_owner varchar2, i_table varchar2,i_date date)
  is
  begin
    drop_partition(i_owner, i_table, i_date,'>=');
  end;  

  procedure drop_partition_btw(i_owner varchar2, i_table varchar2, i_start_date date, i_end_date date)
  is
  begin
    NULL;
    -- implement body
  end;

  ------------------------------------------------------------------------------
  -- drops all partitions that are <= piv_max_date
  ------------------------------------------------------------------------------

  procedure add_partitions(i_owner varchar2, i_table varchar2, i_date date)
  is
    v_part long := find_max_partition(i_owner, i_table);
    v_part_name   varchar2(50);
    v_high_value  long;
    v_part_prefix varchar2(10) := '';
    v_range_type  char(1):= 'd';
    v_partition_col_type varchar2(20) := find_partition_col_type(i_owner, i_table);  
    v_max_date    date;
  begin
    
    gv_proc   := 'pl.add_partitions'; 
    logger := logtype.init(gv_proc);
    
    v_part_name   := substr(v_part, 1, instr(v_part, ':')-1);
    v_part_prefix := find_partition_prefix(v_part_name);
    v_high_value  := substr(v_part, instr(v_part, ':')+1);
    v_range_type  := find_partition_range_type(i_owner, i_table); 
    
    v_max_date := to_date(v_high_value);

    loop 

      v_max_date := case v_range_type
        when 'D' then v_max_date + 1
        when 'd' then v_max_date + 1
        when 'm' then add_months(v_max_date,1)
        when 'y' then add_months(v_max_date,12)
      end;
      add_partition(i_owner, i_table);

      exit when v_max_date > i_date; 
    end loop;

  exception 
  when others then 
    pl.logger.error(SQLERRM, gv_sql);
    raise;
  end;


  procedure add_partition(i_owner varchar2, i_table varchar2)
  is
    v_high_value long;
    v_part_name  varchar2(50);
    v_partition_col_type varchar2(20);
    v_last_part   long;
    v_part_prefix varchar2(20);
    v_part_suffix varchar2(10);
    v_range_type  char(1):= 'd';
    v_date date;
  begin
  
    gv_proc := gv_package||'.add_partition';
    logger := logtype.init(gv_proc);

    v_partition_col_type := find_partition_col_type(i_owner, i_table);
    v_last_part   := find_max_partition(i_owner, i_table);
    v_part_name   := substr(v_last_part,1,instr(v_last_part,':')-1);
    v_high_value  := substr(v_last_part,instr(v_last_part,':')+1);
    v_part_prefix := find_partition_prefix(v_part_name);
    v_part_suffix := ltrim(v_part_name, v_part_prefix);
    v_range_type  := find_partition_range_type(i_owner, i_table);
    
    v_date := to_date(v_high_value);
    
    v_part_name := case v_range_type
        when 'y' then v_part_prefix || to_char(v_date, 'yyyy')
        when 'm' then v_part_prefix || to_char(v_date, 'yyyymm')
        else v_part_prefix || to_char(v_date, 'yyyymmdd')
    end;
    
        
    gv_sql :=  'alter table '||i_owner||'.'||i_table||' add partition '|| v_part_name ||
      ' values less than (
          '||find_next_high_value(v_range_type, v_high_value)||'
        )';
    
    printl(gv_sql);
    execute immediate gv_sql;
    
    logger.success('partition '||v_part_name ||' added to '||i_owner||'.'||i_table, gv_sql);

  exception 
  when others then 
   pl.logger.error(SQLERRM, gv_sql);
   raise;
  end;

  
  procedure window_partitions(i_owner varchar2, i_table varchar2, i_date date, i_window_size number)
  is
    v_range_type char(2) := find_partition_range_type(i_owner, i_table);
  begin
    gv_proc := 'pl.window_partitions';
    add_partitions(i_owner,i_table,i_date);
    drop_partition_lt(i_owner,i_table, i_date-i_window_size);
  end;  

  procedure gather_table_stats(i_owner varchar2, i_table varchar2, i_part_name varchar2 default null) 
  is
  begin
    dbms_stats.gather_table_stats (i_owner,i_table,i_part_name);
  end;

  procedure manage_constraints(i_owner varchar2, i_table varchar2, i_order varchar2 default 'ENABLE') 
  is
  begin

    for c in (select owner, constraint_name from dba_constraints where owner = upper(i_owner) and table_name = upper(i_table) )
    loop
      gv_sql :=  'alter table '||i_owner||'.'||i_table||' '|| i_order ||' constraint ' ||c.constraint_name;
      execute immediate gv_sql;
      pl.logger.success('Manage constraint', gv_sql);
    end loop;

  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;

  procedure enable_constraints(i_owner varchar2, i_table varchar2) 
  is
  begin
    manage_constraints(i_owner, i_table);
  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;

  procedure disable_constraints(i_owner varchar2, i_table varchar2) 
  is
  begin
    manage_constraints(i_owner, i_table, 'DISABLE');
  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;

  procedure drop_constraint(i_owner varchar2, i_table varchar2, i_constraint varchar2)
  is
  begin
    gv_sql :=  'alter table ' ||i_owner||'.'||i_table|| ' drop constraint ' ||i_constraint;
    execute immediate gv_sql;
  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;
  end;

  procedure add_unique_constraint(i_owner varchar2, i_table varchar2, i_col_list varchar2, i_constraint varchar2)
  is
  begin
    gv_sql :=  'alter table ' ||i_owner||'.'||i_table|| ' add (constraint ' ||i_constraint||' 
      unique ('||i_col_list||') enable validate)
    ';
    execute immediate gv_sql;

  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;
  end;



  procedure manage_indexes(i_owner varchar2, i_table varchar2, i_order varchar2 default 'ENABLE') 
  is
  begin

    for c in (select owner, index_name from dba_indexes where table_owner = upper(i_owner) and table_name = upper(i_table))
    loop
      gv_sql := 'alter index '|| c.owner||'.'||c.index_name||' '||case lower(i_order) when 'disable' then 'unusable' else 'rebuild' end;
      execute immediate gv_sql;
    end loop;

  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;

  procedure enable_indexes(i_owner varchar2, i_table varchar2) 
  is
  begin
    manage_indexes(i_owner, i_table);
  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;

  procedure disable_indexes(i_owner varchar2, i_table varchar2) 
  is
  begin
    manage_indexes(i_owner, i_table, 'DISABLE');
  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;


  procedure exchange_partition(
    i_owner     varchar2, 
    i_table_1   varchar2, 
    i_part_name varchar2,
    i_table_2   varchar2,
    i_validate  boolean default false
  ) IS
  begin

    gv_proc := gv_package||'.exchange_partition';
    logger := logtype.init(gv_proc);

    gv_sql := 
      'alter table '||i_owner||'.'||i_table_1||' exchange partition '|| i_part_name||'
      with table '||i_table_2||case i_validate when false then ' without validation' else '' end;
    
    execute immediate gv_sql;

    logger.success('partition exchange', gv_sql);

  exception 
    when others then 
      pl.logger.error(SQLERRM, gv_sql);
      raise;  
  end;



  ------------------------------------------------------------------------------
  -- disable parallel dml for the current session
  ------------------------------------------------------------------------------
  procedure disable_parallel_dml
  is
    v_proc varchar2(1000) := gv_package || '.enable_parallel_dml';
  begin
      
      gv_sql := 'alter session disable parallel dml';
      execute immediate gv_sql;
      logger.success(' disabled parallel dml for current session', gv_sql);
  exception
    when others then
      logger.error( SQLERRM, gv_sql);
      raise;
  end;


  -- procedure async_exec(piv_sql varchar2)
  -- is 
  -- begin
  --   dbms_scheduler.create_job (  
  --     name          =>  'ASYNC_EXEC',
  --     job_type      =>  'PLSQL_BLOCK',  
  --     job_action    =>  'BEGIN ' || piv_sql || ' END;',  
  --     start_date    =>  sysdate,  
  --     enabled       =>  true,  
  --     auto_drop     =>  true
  --   ); 
  -- end;


  ------------------------------------------------------------------------------
  -- for those who struggels to remember dbms_output.putline! :) like me
  ------------------------------------------------------------------------------
  procedure printl(i_message varchar2)
  is
  begin
    dbms_output.put_line(i_message);
  end;

  procedure println(i_message varchar2)
  is
  begin
    dbms_output.put_line(i_message);
  end;

  procedure p(i_message varchar2)
  is
  begin
    dbms_output.put_line(i_message);
  end;

  ------------------------------------------------------------------------------
  -- for those who struggels to remember dbmsoutput.put! :) like me
  ------------------------------------------------------------------------------
  procedure print(i_message varchar2)
  is
  begin
    dbms_output.put(i_message);
  end;


end;
/
