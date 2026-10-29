begin;

alter table public.profiles add column display_name text;
alter table public.profiles add constraint profiles_display_name_length
  check (display_name is null or char_length(display_name) between 1 and 64);

create or replace function public.get_profile() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := pushx_private.require_user();
begin
  return (select jsonb_build_object('id', id, 'friend_code', friend_code,
    'created_at', created_at, 'display_name', display_name)
    from public.profiles where id = v_id);
end;
$$;

create function public.set_display_name(p_display_name text, p_only_if_empty boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := pushx_private.require_user();
  v_name text;
  v_whitespace text := U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000';
begin
  v_name := pg_catalog.btrim(pg_catalog.regexp_replace(
    pg_catalog.translate(pg_catalog.normalize(p_display_name, 'NFC'), v_whitespace,
      pg_catalog.repeat(' ', pg_catalog.char_length(v_whitespace))), ' +', ' ', 'g'));
  if p_only_if_empty is null or v_name is null or pg_catalog.char_length(v_name) not between 1 and 64
    or v_name ~ U&'[\0001-\001F\007F-\009F\00AD\061C\180E\200B-\200F\202A-\202E\2060-\206F\FEFF\FFF9-\FFFB]' then
    raise exception using errcode = '22023', message = 'invalid_display_name';
  end if;
  update public.profiles set display_name = v_name
    where id = v_id and (not p_only_if_empty or display_name is null);
  return public.get_profile();
end;
$$;

create or replace function public.get_friends() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := pushx_private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object(
    'user_id', p.id, 'friend_code', p.friend_code, 'display_name', p.display_name,
    'status', case when f.status = 'accepted' then 'accepted'
                   when f.requested_by = v_id then 'outgoing' else 'incoming' end,
    'requested_at', f.created_at) order by f.created_at desc, p.id)
    from public.friendships f join public.profiles p
      on p.id = case when f.low_id = v_id then f.high_id else f.low_id end
    where v_id in (f.low_id, f.high_id)), '[]'::jsonb);
end;
$$;

create or replace function public.get_blocked_users() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := pushx_private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id,
    'friend_code', p.friend_code, 'display_name', p.display_name)
    order by b.created_at desc, p.id)
    from public.user_blocks b join public.profiles p on p.id = b.blocked_id
    where b.blocker_id = v_id), '[]'::jsonb);
end;
$$;

create or replace function public.get_daily_leaderboard(p_day date default (now() at time zone 'UTC')::date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := pushx_private.require_user();
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
    select p.id, p.friend_code, p.display_name, coalesce(sum(w.repetitions), 0)::bigint as repetitions
      from participants members join public.profiles p on p.id = members.id
      left join public.workouts w on w.user_id = p.id and w.day_utc = p_day
      group by p.id, p.friend_code, p.display_name
  ), ranked as (
    select *, dense_rank() over (order by repetitions desc) as rank from totals
  ) select jsonb_agg(jsonb_build_object('user_id', id, 'friend_code', friend_code,
    'display_name', display_name, 'repetitions', repetitions, 'rank', rank, 'is_me', id = v_id)
    order by rank, friend_code) from ranked), '[]'::jsonb);
end;
$$;

revoke all on function public.set_display_name(text, boolean), public.get_profile(), public.get_friends(),
  public.get_blocked_users(), public.get_daily_leaderboard(date) from public, anon, authenticated;
grant execute on function public.set_display_name(text, boolean), public.get_profile(), public.get_friends(),
  public.get_blocked_users(), public.get_daily_leaderboard(date) to authenticated;

notify pgrst, 'reload schema';
commit;
