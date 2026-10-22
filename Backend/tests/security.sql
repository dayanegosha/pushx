reset role;
do $$ declare v_function record; v_table record; begin
  if has_schema_privilege('anon', 'forma_private', 'USAGE')
    or has_schema_privilege('authenticated', 'forma_private', 'USAGE') then
    raise exception 'private schema exposed';
  end if;
  for v_function in
    select p.oid, p.proname, p.prosecdef, p.proconfig, n.nspname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'forma_private')
  loop
    if has_function_privilege('anon', v_function.oid, 'EXECUTE') then
      raise exception 'anonymous execute exposed on %', v_function.proname;
    end if;
    if v_function.nspname = 'forma_private'
      and has_function_privilege('authenticated', v_function.oid, 'EXECUTE') then
      raise exception 'private function exposed on %', v_function.proname;
    end if;
    if v_function.prosecdef and not ('search_path=""' = any(v_function.proconfig)) then
      raise exception 'security definer has unsafe search path on %', v_function.proname;
    end if;
  end loop;
  for v_table in select oid, relname, relrowsecurity from pg_class
    where relnamespace = 'public'::regnamespace and relkind = 'r'
  loop
    if not v_table.relrowsecurity then raise exception 'RLS disabled on %', v_table.relname; end if;
    if has_table_privilege('anon', v_table.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
      or has_table_privilege('authenticated', v_table.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') then
      raise exception 'table privileges exposed on %', v_table.relname;
    end if;
  end loop;
end; $$;

insert into auth.users(id) select md5('security-user-' || n)::uuid from generate_series(1, 34) n;
update public.profiles set friend_code = 'D' || lpad(upper(to_hex(n)), 9, '0')
  from generate_series(1, 34) n where id = md5('security-user-' || n)::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', md5('security-user-1')::uuid::text, true);
do $$ declare v_code text; v_index integer; v_bad record; v_start timestamptz; v_end timestamptz; begin
  begin
    perform public.set_display_name('Name', null);
    raise exception 'null import flag accepted';
  exception when invalid_parameter_value then
    if sqlerrm <> 'invalid_display_name' then raise; end if;
  end;
  foreach v_code in array array[null::text, '', 'DEADBEEF', repeat('F', 11), '00000000ZZ'] loop
    begin perform public.request_friend(v_code); raise exception 'malformed friend code accepted';
    exception when invalid_parameter_value then
      if sqlerrm <> 'invalid_friend_code' then raise; end if;
    end;
  end loop;
  begin perform public.request_friend('D000000001'); raise exception 'self friendship accepted';
  exception when invalid_parameter_value then if sqlerrm <> 'friend_unavailable' then raise; end if; end;
  begin perform public.block_user(auth.uid()); raise exception 'self block accepted';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_user' then raise; end if; end;
  begin perform public.get_daily_leaderboard((now() at time zone 'UTC')::date + 1); raise exception 'future board accepted';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_day' then raise; end if; end;
  begin perform public.get_daily_leaderboard((now() at time zone 'UTC')::date - 367); raise exception 'old board accepted';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_day' then raise; end if; end;
  for v_index in 2..21 loop
    perform public.request_friend('D' || lpad(to_hex(v_index), 9, '0'));
  end loop;
  begin perform public.request_friend('D000000016'); raise exception 'pending limit bypassed';
  exception when invalid_parameter_value then if sqlerrm <> 'too_many_pending_requests' then raise; end if; end;
  for v_index in 2..21 loop perform public.remove_friend(md5('security-user-' || v_index)::uuid); end loop;
  for v_index in 22..31 loop
    perform public.request_friend('D' || lpad(to_hex(v_index), 9, '0'));
    perform public.remove_friend(md5('security-user-' || v_index)::uuid);
  end loop;
  begin perform public.request_friend('D000000020'); raise exception 'hourly request limit bypassed';
  exception when invalid_parameter_value then if sqlerrm <> 'friend_request_rate_limit' then raise; end if; end;
  for v_bad in select * from (values
    ('-infinity'::timestamptz, now(), 10, 'camera'::text),
    (now(), 'infinity'::timestamptz, 10, 'camera'),
    (now() - interval '60 seconds', now(), 0, 'camera'),
    (now() - interval '60 seconds', now(), -1, 'camera'),
    (now() - interval '60 seconds', now(), 10, 'other'),
    (now() - interval '7 hours', now(), 10, 'camera')
  ) invalid(started_at, ended_at, repetitions, detection_mode) loop
    begin
      perform public.upload_workout(gen_random_uuid(), v_bad.started_at, v_bad.ended_at,
        v_bad.repetitions, v_bad.detection_mode);
      raise exception 'invalid workout accepted';
    exception when invalid_parameter_value then if sqlerrm <> 'invalid_workout' then raise; end if; end;
  end loop;
  v_start := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days';
  for v_index in 0..7 loop
    v_end := v_start + interval '5 minutes';
    perform public.upload_workout(gen_random_uuid(), v_start, v_end, 600, 'camera');
    v_start := v_end;
  end loop;
  perform public.upload_workout(gen_random_uuid(), v_start, v_start + interval '100 seconds', 200, 'camera');
  begin
    perform public.upload_workout(gen_random_uuid(), v_start + interval '100 seconds', v_start + interval '101 seconds', 1, 'camera');
    raise exception 'daily cap bypassed';
  exception when invalid_parameter_value then if sqlerrm <> 'daily_limit_reached' then raise; end if; end;
end; $$;
reset role;
