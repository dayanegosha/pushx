begin;

create schema if not exists forma_private;
revoke all on schema forma_private from public, anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  friend_code text not null unique check (friend_code ~ '^[0-9A-F]{10}$'),
  created_at timestamptz not null default now()
);

create table public.friendships (
  low_id uuid not null references public.profiles(id) on delete cascade,
  high_id uuid not null references public.profiles(id) on delete cascade,
  requested_by uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (low_id, high_id),
  check (low_id < high_id),
  check (requested_by in (low_id, high_id))
);
create index friendships_high_idx on public.friendships(high_id);

create table public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index user_blocks_blocked_idx on public.user_blocks(blocked_id);

create table public.workouts (
  id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  repetitions integer not null check (repetitions between 1 and 600),
  detection_mode text not null check (detection_mode in ('camera', 'touch')),
  day_utc date generated always as ((ended_at at time zone 'UTC')::date) stored,
  received_at timestamptz not null default now(),
  check (ended_at >= started_at + repetitions * interval '0.5 seconds'),
  check (ended_at <= started_at + interval '6 hours')
);
create index workouts_user_day_idx on public.workouts(user_id, day_utc);
create index workouts_user_time_idx on public.workouts(user_id, ended_at desc, id desc);

create table forma_private.friend_request_events (
  user_id uuid not null references public.profiles(id) on delete cascade,
  occurred_at timestamptz not null default now()
);
create index friend_request_events_user_time_idx on forma_private.friend_request_events(user_id, occurred_at);

create function forma_private.require_user() returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := auth.uid();
begin
  if v_id is null or not exists (select 1 from public.profiles where id = v_id) then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  return v_id;
end;
$$;

create function forma_private.lock_users(p_a uuid, p_b uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(p_a, p_b)::text, 42));
  if p_a <> p_b then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(greatest(p_a, p_b)::text, 42));
  end if;
end;
$$;

create function forma_private.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  loop
    begin
      insert into public.profiles(id, friend_code)
      values (new.id, upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)));
      return new;
    exception when unique_violation then
      if exists (select 1 from public.profiles where id = new.id) then return new; end if;
    end;
  end loop;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function forma_private.create_profile();

do $$
declare v_user record; v_code text;
begin
  for v_user in select id from auth.users where id not in (select id from public.profiles) loop
    loop
      v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
      begin
        insert into public.profiles(id, friend_code) values (v_user.id, v_code);
        exit;
      exception when unique_violation then null;
      end;
    end loop;
  end loop;
end;
$$;

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.user_blocks enable row level security;
alter table public.workouts enable row level security;
alter table forma_private.friend_request_events enable row level security;

create policy profile_select_own on public.profiles for select to authenticated
using (id = (select auth.uid()));
create policy friendship_select_own on public.friendships for select to authenticated
using ((select auth.uid()) in (low_id, high_id));
create policy block_select_own on public.user_blocks for select to authenticated
using (blocker_id = (select auth.uid()));
create policy workout_select_own on public.workouts for select to authenticated
using (user_id = (select auth.uid()));
revoke all on public.profiles, public.friendships, public.user_blocks, public.workouts from public, anon, authenticated;
grant select on public.profiles, public.friendships, public.user_blocks, public.workouts to authenticated;

create function public.get_profile() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  return (select jsonb_build_object('id', id, 'friend_code', friend_code, 'created_at', created_at)
    from public.profiles where id = v_id);
end;
$$;

create function public.get_friends() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
    'user_id', p.id, 'friend_code', p.friend_code,
    'status', case when f.status = 'accepted' then 'accepted'
                   when f.requested_by = v_id then 'outgoing' else 'incoming' end,
    'requested_at', f.created_at) order by f.created_at desc, p.id)
    from public.friendships f join public.profiles p
      on p.id = case when f.low_id = v_id then f.high_id else f.low_id end
    where v_id in (f.low_id, f.high_id)), '[]'::jsonb);
end;
$$;

create function public.get_blocked_users() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'friend_code', p.friend_code)
    order by b.created_at desc, p.id)
    from public.user_blocks b join public.profiles p on p.id = b.blocked_id
    where b.blocker_id = v_id), '[]'::jsonb);
end;
$$;

create function public.request_friend(p_friend_code text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user(); v_other uuid; v_existing public.friendships%rowtype;
begin
  if p_friend_code is null or upper(trim(p_friend_code)) !~ '^[0-9A-F]{10}$' then
    raise exception using errcode = '22023', message = 'invalid_friend_code';
  end if;
  select id into v_other from public.profiles where friend_code = upper(trim(p_friend_code));
  if v_other is null or v_other = v_id then
    raise exception using errcode = '22023', message = 'friend_unavailable';
  end if;
  perform forma_private.lock_users(v_id, v_other);
  if exists (select 1 from public.user_blocks
      where (blocker_id = v_id and blocked_id = v_other) or (blocker_id = v_other and blocked_id = v_id)) then
    raise exception using errcode = '22023', message = 'friend_unavailable';
  end if;
  select * into v_existing from public.friendships where low_id = least(v_id, v_other) and high_id = greatest(v_id, v_other);
  if found then
    return case when v_existing.status = 'accepted' then 'accepted'
      when v_existing.requested_by = v_id then 'outgoing' else 'incoming' end;
  end if;
  if (select count(*) from public.friendships where status = 'pending' and requested_by = v_id) >= 20 then
    raise exception using errcode = '22023', message = 'too_many_pending_requests';
  end if;
  if (select count(*) from public.friendships where status = 'accepted' and v_id in (low_id, high_id)) >= 100 then
    raise exception using errcode = '22023', message = 'friend_limit_reached';
  end if;
  if (select count(*) from forma_private.friend_request_events where user_id = v_id and occurred_at > now() - interval '1 hour') >= 30 then
    raise exception using errcode = '22023', message = 'friend_request_rate_limit';
  end if;
  delete from forma_private.friend_request_events where user_id = v_id and occurred_at < now() - interval '1 hour';
  insert into forma_private.friend_request_events(user_id) values (v_id);
  insert into public.friendships(low_id, high_id, requested_by, status)
    values (least(v_id, v_other), greatest(v_id, v_other), v_id, 'pending');
  return 'outgoing';
end;
$$;

create function public.respond_friend_request(p_user_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  if p_user_id is null or p_user_id = v_id or p_accept is null then
    raise exception using errcode = '22023', message = 'invalid_friend_request';
  end if;
  perform forma_private.lock_users(v_id, p_user_id);
  if not exists (select 1 from public.friendships where low_id = least(v_id, p_user_id)
      and high_id = greatest(v_id, p_user_id) and requested_by = p_user_id and status = 'pending') then
    raise exception using errcode = '22023', message = 'friend_request_not_found';
  end if;
  if p_accept then
    if exists (select 1 from public.user_blocks where
      (blocker_id = v_id and blocked_id = p_user_id) or (blocker_id = p_user_id and blocked_id = v_id)) then
      raise exception using errcode = '22023', message = 'friend_unavailable';
    end if;
    if (select count(*) from public.friendships where status = 'accepted' and v_id in (low_id, high_id)) >= 100
      or (select count(*) from public.friendships where status = 'accepted' and p_user_id in (low_id, high_id)) >= 100 then
      raise exception using errcode = '22023', message = 'friend_limit_reached';
    end if;
    update public.friendships set status = 'accepted'
      where low_id = least(v_id, p_user_id) and high_id = greatest(v_id, p_user_id);
  else
    delete from public.friendships where low_id = least(v_id, p_user_id) and high_id = greatest(v_id, p_user_id);
  end if;
end;
$$;

create function public.remove_friend(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  if p_user_id is null or p_user_id = v_id then
    raise exception using errcode = '22023', message = 'invalid_user';
  end if;
  perform forma_private.lock_users(v_id, p_user_id);
  delete from public.friendships where low_id = least(v_id, p_user_id) and high_id = greatest(v_id, p_user_id);
end;
$$;

create function public.block_user(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  if p_user_id is null or p_user_id = v_id or not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception using errcode = '22023', message = 'invalid_user';
  end if;
  perform forma_private.lock_users(v_id, p_user_id);
  insert into public.user_blocks(blocker_id, blocked_id) values (v_id, p_user_id) on conflict do nothing;
  delete from public.friendships where low_id = least(v_id, p_user_id) and high_id = greatest(v_id, p_user_id);
end;
$$;

create function public.unblock_user(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  if p_user_id is null or p_user_id = v_id then
    raise exception using errcode = '22023', message = 'invalid_user';
  end if;
  perform forma_private.lock_users(v_id, p_user_id);
  delete from public.user_blocks where blocker_id = v_id and blocked_id = p_user_id;
end;
$$;

create function public.upload_workout(p_id uuid, p_started_at timestamptz, p_ended_at timestamptz,
  p_repetitions integer, p_detection_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user(); v_row public.workouts%rowtype; v_day date;
begin
  if p_id is null or p_started_at is null or p_ended_at is null or p_repetitions is null or p_detection_mode is null then
    raise exception using errcode = '22023', message = 'invalid_workout';
  end if;
  perform forma_private.lock_users(v_id, v_id);
  select * into v_row from public.workouts where id = p_id;
  if found then
    if v_row.user_id <> v_id or v_row.started_at <> p_started_at or v_row.ended_at <> p_ended_at
      or v_row.repetitions <> p_repetitions or v_row.detection_mode <> p_detection_mode then
      raise exception using errcode = '22023', message = 'workout_id_conflict';
    end if;
  else
    if p_repetitions not between 1 and 600 or p_detection_mode not in ('camera', 'touch')
      or not isfinite(p_started_at) or not isfinite(p_ended_at)
      or p_ended_at < p_started_at + p_repetitions * interval '0.5 seconds'
      or p_ended_at > p_started_at + interval '6 hours'
      or p_ended_at > now() + interval '5 minutes' or p_ended_at < now() - interval '30 days' then
      raise exception using errcode = '22023', message = 'invalid_workout';
    end if;
    v_day := (p_ended_at at time zone 'UTC')::date;
    if exists (select 1 from public.workouts where user_id = v_id and started_at < p_ended_at and ended_at > p_started_at) then
      raise exception using errcode = '22023', message = 'workout_time_overlap';
    end if;
    if (select coalesce(sum(repetitions), 0) from public.workouts where user_id = v_id and day_utc = v_day) + p_repetitions > 5000 then
      raise exception using errcode = '22023', message = 'daily_limit_reached';
    end if;
    insert into public.workouts(id, user_id, started_at, ended_at, repetitions, detection_mode)
      values (p_id, v_id, p_started_at, p_ended_at, p_repetitions, p_detection_mode) returning * into v_row;
  end if;
  return jsonb_build_object('id', v_row.id, 'started_at', v_row.started_at, 'ended_at', v_row.ended_at,
    'repetitions', v_row.repetitions, 'detection_mode', v_row.detection_mode,
    'day_utc', v_row.day_utc, 'received_at', v_row.received_at);
end;
$$;

create function public.get_daily_leaderboard(p_day date default (now() at time zone 'UTC')::date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := forma_private.require_user();
begin
  if p_day is null or p_day < (now() at time zone 'UTC')::date - 366 or p_day > (now() at time zone 'UTC')::date then
    raise exception using errcode = '22023', message = 'invalid_day';
  end if;
  return coalesce((with participants as (
    select v_id as id
    union
    select case when low_id = v_id then high_id else low_id end from public.friendships
      where status = 'accepted' and v_id in (low_id, high_id)
  ), totals as (
    select p.id, p.friend_code, coalesce(sum(w.repetitions), 0)::bigint as repetitions
      from participants members join public.profiles p on p.id = members.id
      left join public.workouts w on w.user_id = p.id and w.day_utc = p_day
      group by p.id, p.friend_code
  ), ranked as (
    select *, dense_rank() over (order by repetitions desc) as rank from totals
  ) select jsonb_agg(jsonb_build_object('user_id', id, 'friend_code', friend_code,
    'repetitions', repetitions, 'rank', rank, 'is_me', id = v_id)
    order by rank, friend_code) from ranked), '[]'::jsonb);
end;
$$;

revoke all on all functions in schema forma_private from public, anon, authenticated;
revoke all on function public.get_profile(), public.get_friends(), public.get_blocked_users(), public.request_friend(text),
  public.respond_friend_request(uuid, boolean), public.remove_friend(uuid), public.block_user(uuid),
  public.unblock_user(uuid), public.upload_workout(uuid, timestamptz, timestamptz, integer, text),
  public.get_daily_leaderboard(date) from public, anon, authenticated;
grant execute on function public.get_profile(), public.get_friends(), public.get_blocked_users(), public.request_friend(text),
  public.respond_friend_request(uuid, boolean), public.remove_friend(uuid), public.block_user(uuid),
  public.unblock_user(uuid), public.upload_workout(uuid, timestamptz, timestamptz, integer, text),
  public.get_daily_leaderboard(date) to authenticated;

commit;
