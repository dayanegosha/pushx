\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003');
update public.profiles set friend_code = 'AAAAAAAAA1' where id = '00000000-0000-0000-0000-000000000001';
update public.profiles set friend_code = 'BBBBBBBBB2' where id = '00000000-0000-0000-0000-000000000002';
update public.profiles set friend_code = 'CCCCCCCCC3' where id = '00000000-0000-0000-0000-000000000003';

set local role anon;
do $$ begin
  begin perform public.get_profile(); raise exception 'anonymous RPC unexpectedly allowed';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from public.workouts; raise exception 'anonymous table unexpectedly allowed';
  exception when insufficient_privilege then null; end;
  begin perform public.set_display_name('Anonymous'); raise exception 'anonymous name update unexpectedly allowed';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$ declare a jsonb; b jsonb; v_bad_name text; begin
  if (select count(*) from public.profiles) <> 1 then raise exception 'profile RLS'; end if;
  if public.get_profile()->>'friend_code' <> 'AAAAAAAAA1' then raise exception 'profile shape'; end if;
  if public.get_profile()->'display_name' is distinct from 'null'::jsonb then raise exception 'legacy name should be null'; end if;
  if public.get_daily_leaderboard()->0->'display_name' is distinct from 'null'::jsonb then raise exception 'legacy leaderboard name should be null'; end if;
  begin
    update public.profiles set display_name = 'Direct write' where id = auth.uid();
    raise exception 'direct name write unexpectedly allowed';
  exception when insufficient_privilege then null; end;
  a := public.set_display_name(U&'\0009\00A0Георгий\3000\2003Журик\000A', true);
  if a->>'display_name' <> 'Георгий Журик' or a->>'friend_code' <> 'AAAAAAAAA1'
    or a->>'id' <> auth.uid()::text or a->>'created_at' is null then raise exception 'normalized name profile shape'; end if;
  if public.set_display_name('Apple fallback', true)->>'display_name' <> 'Георгий Журик' then raise exception 'automatic import replaced a custom name'; end if;
  if public.set_display_name('George')->>'display_name' <> 'George' then raise exception 'manual name update'; end if;
  if public.set_display_name(U&'Jose\0301')->>'display_name' <> 'José' then raise exception 'name NFC normalization'; end if;
  if char_length(public.set_display_name(repeat('林', 64))->>'display_name') <> 64 then raise exception '64 scalar unicode name rejected'; end if;
  foreach v_bad_name in array array[null::text, '', '  ', U&'\0009\00A0\3000', repeat('林', 65),
    U&'A\0001B', U&'A\007FB', U&'A\009FB', U&'A\200BB', U&'A\202EB', U&'A\FEFFB'] loop
    begin
      perform public.set_display_name(v_bad_name);
      raise exception 'invalid display name accepted';
    exception when invalid_parameter_value then
      if sqlerrm <> 'invalid_display_name' then raise; end if;
    end;
  end loop;
  if public.set_display_name('Георгий Журик')->>'display_name' <> 'Георгий Журик' then raise exception 'owner name update'; end if;
  if public.get_friends() <> '[]'::jsonb then raise exception 'empty friend shape'; end if;
  begin
    insert into public.workouts(id, user_id, started_at, ended_at, repetitions, detection_mode)
    values (gen_random_uuid(), auth.uid(), now() - interval '60 seconds', now(), 1, 'touch');
    raise exception 'direct write unexpectedly allowed';
  exception when insufficient_privilege then null; end;
  if public.request_friend('bbbbbbbbb2') <> 'outgoing' then raise exception 'create request'; end if;
  if public.request_friend('BBBBBBBBB2') <> 'outgoing' then raise exception 'request idempotency'; end if;
  if public.get_friends()->0->>'status' <> 'outgoing' then raise exception 'outgoing shape'; end if;
  if public.get_friends()->0->'display_name' is distinct from 'null'::jsonb then raise exception 'unnamed friend should be null'; end if;
  begin
    perform public.respond_friend_request('00000000-0000-0000-0000-000000000002', true);
    raise exception 'sender accepted own request';
  exception when invalid_parameter_value then
    if sqlerrm <> 'friend_request_not_found' then raise; end if;
  end;
  if jsonb_array_length(public.get_daily_leaderboard()) <> 1 then raise exception 'pending user leaked in board'; end if;
  a := public.upload_workout('10000000-0000-0000-0000-000000000001', now() - interval '11 minutes', now() - interval '10 minutes', 20, 'camera');
  b := public.upload_workout('10000000-0000-0000-0000-000000000001', now() - interval '11 minutes', now() - interval '10 minutes', 20, 'camera');
  if a <> b then raise exception 'upload idempotency'; end if;
  if (select count(*) from public.workouts) <> 1 then raise exception 'duplicate workout'; end if;
  begin
    perform public.upload_workout('10000000-0000-0000-0000-000000000001', now() - interval '11 minutes', now() - interval '10 minutes', 21, 'camera');
    raise exception 'changed idempotent content allowed';
  exception when invalid_parameter_value then if sqlerrm <> 'workout_id_conflict' then raise; end if; end;
  begin
    perform public.upload_workout(gen_random_uuid(), now() - interval '11 minutes', now() - interval '10 minutes', 20, 'touch');
    raise exception 'overlap allowed';
  exception when invalid_parameter_value then if sqlerrm <> 'workout_time_overlap' then raise; end if; end;
  begin
    perform public.upload_workout(gen_random_uuid(), now() - interval '11 minutes', now() - interval '10 minutes', 601, 'touch');
    raise exception 'rep cap not enforced';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_workout' then raise; end if; end;
  begin
    perform public.upload_workout(gen_random_uuid(), now() - interval '11 minutes', now() - interval '10 minutes', 500, 'camera');
    raise exception 'implausible duration allowed';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_workout' then raise; end if; end;
  begin
    perform public.upload_workout(gen_random_uuid(), now() - interval '32 days', now() - interval '31 days', 20, 'camera');
    raise exception 'stale upload allowed';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_workout' then raise; end if; end;
  begin
    perform public.upload_workout(gen_random_uuid(), now() + interval '1 hour', now() + interval '2 hours', 20, 'camera');
    raise exception 'future upload allowed';
  exception when invalid_parameter_value then if sqlerrm <> 'invalid_workout' then raise; end if; end;
end; $$;

set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';
do $$ begin
  if (select count(*) from public.workouts) <> 0 then raise exception 'workout RLS'; end if;
  if public.get_friends()->0->>'status' <> 'incoming' then raise exception 'incoming shape'; end if;
  if public.get_profile()->'display_name' is distinct from 'null'::jsonb then raise exception 'name update affected another user'; end if;
  if public.get_friends()->0->>'display_name' <> 'Георгий Журик' then raise exception 'incoming friend display name'; end if;
  if public.set_display_name(U&'\3000小明\00A0王\0009')->>'display_name' <> '小明 王' then raise exception 'chinese display name'; end if;
  perform public.respond_friend_request('00000000-0000-0000-0000-000000000001', true);
  if public.get_friends()->0->>'status' <> 'accepted' then raise exception 'accept'; end if;
  if jsonb_array_length(public.get_daily_leaderboard()) <> 2 then raise exception 'accepted board'; end if;
  if public.get_daily_leaderboard(((now() - interval '10 minutes') at time zone 'UTC')::date)->0->>'repetitions' <> '20' then raise exception 'leaderboard total'; end if;
  if public.get_daily_leaderboard(((now() - interval '10 minutes') at time zone 'UTC')::date)->0->>'is_me' <> 'false' then raise exception 'leaderboard identity'; end if;
  if public.get_daily_leaderboard(((now() - interval '10 minutes') at time zone 'UTC')::date)->0->>'display_name' <> 'Георгий Журик' then raise exception 'leaderboard friend display name'; end if;
  if public.get_daily_leaderboard(((now() - interval '10 minutes') at time zone 'UTC')::date)->1->>'display_name' <> '小明 王' then raise exception 'leaderboard owner display name'; end if;
  begin
    perform public.upload_workout('10000000-0000-0000-0000-000000000001', now() - interval '11 minutes', now() - interval '10 minutes', 20, 'camera');
    raise exception 'foreign UUID overwritten';
  exception when invalid_parameter_value then if sqlerrm <> 'workout_id_conflict' then raise; end if; end;
  perform public.block_user('00000000-0000-0000-0000-000000000001');
  if public.get_friends() <> '[]'::jsonb then raise exception 'block did not remove friend'; end if;
  if jsonb_array_length(public.get_daily_leaderboard()) <> 1 then raise exception 'blocked board'; end if;
  if public.get_blocked_users()->0->>'friend_code' <> 'AAAAAAAAA1' then raise exception 'block list'; end if;
  if public.get_blocked_users()->0->>'display_name' <> 'Георгий Журик' then raise exception 'blocked display name'; end if;
end; $$;

set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$ begin
  begin perform public.request_friend('BBBBBBBBB2'); raise exception 'blocked re-request';
  exception when invalid_parameter_value then if sqlerrm <> 'friend_unavailable' then raise; end if; end;
  if (select count(*) from public.user_blocks) <> 0 then raise exception 'other block leaked'; end if;
  if public.get_blocked_users() <> '[]'::jsonb then raise exception 'other block list leaked'; end if;
end; $$;

set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000003';
do $$ begin
  if public.get_friends() <> '[]'::jsonb then raise exception 'third party friend RLS'; end if;
  if (select count(*) from public.friendships) <> 0 then raise exception 'friendship RLS'; end if;
  if public.get_profile()->'display_name' is distinct from 'null'::jsonb then raise exception 'unrelated name modified'; end if;
  if (select count(*) from public.profiles where display_name is not null) <> 0 then raise exception 'third party name leaked'; end if;
end; $$;

reset role;
delete from auth.users where id = '00000000-0000-0000-0000-000000000001';
do $$ begin
  if exists (select 1 from public.workouts) then raise exception 'deletion workout cascade'; end if;
  if exists (select 1 from public.user_blocks) then raise exception 'deletion block cascade'; end if;
  if exists (select 1 from forma_private.friend_request_events) then raise exception 'deletion event cascade'; end if;
end; $$;
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
do $$ begin
  begin perform public.get_profile(); raise exception 'deleted JWT still uses RPC';
  exception when insufficient_privilege then if sqlerrm <> 'authentication_required' then raise; end if; end;
  begin perform public.set_display_name('Deleted'); raise exception 'deleted JWT still edits name';
  exception when insufficient_privilege then if sqlerrm <> 'authentication_required' then raise; end if; end;
end; $$;
rollback;
\echo 'pushx PostgreSQL regression passed'
