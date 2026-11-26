-- BURIN : ตั้งค่าฐานข้อมูล Supabase
-- วางทั้งไฟล์นี้ใน SQL Editor ของโปรเจกต์ แล้วกด Run รันซ้ำได้ไม่เสียหาย และไม่ลบข้อมูลที่มีอยู่
-- ไฟล์นี้ประกอบจาก 001_base.sql, 002_central.sql, 003_marks.sql, 004_show.sql, 005_plans.sql, 006_limits.sql, 007_listeners.sql, 008_consent.sql ด้วย tools/sql_build.py ห้ามแก้ไฟล์นี้โดยตรง
-- ทุกส่วนรันในคราวเดียว ถ้าส่วนใดไม่สำเร็จ ฐานข้อมูลจะกลับเป็นเหมือนก่อนรัน

begin;

-- ======== 001_base.sql ========

-- 001_base.sql: the database as it was before version 2 (the setup.sql of the site, 17 Nov 2026), unchanged.
-- Every later file builds on this one. Do not edit it: changes go into a new numbered file.

-- BURIN : ตั้งค่าฐานข้อมูล Supabase
-- วางทั้งไฟล์นี้ใน SQL Editor ของโปรเจกต์ แล้วกด Run ครั้งเดียว รันซ้ำได้ไม่เสียหาย

-- 1) ตารางเก็บสมุด หน้า และหมึก (หนึ่งแถวต่อหนึ่งเอกสาร)
create table if not exists public.docs (
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  path text not null,
  parent text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (owner, path)
);
create index if not exists docs_owner_parent on public.docs (owner, parent);

-- 2) ให้แต่ละบัญชีเห็นและแก้ได้เฉพาะข้อมูลของตัวเอง
alter table public.docs enable row level security;
drop policy if exists "docs: own rows" on public.docs;
create policy "docs: own rows" on public.docs
  for all to authenticated
  using (owner = auth.uid())
  with check (owner = auth.uid());
grant select, insert, update, delete on public.docs to authenticated;
revoke all on public.docs from anon;

-- 3) ส่งการเปลี่ยนแปลงแบบทันทีไปยังทุกเครื่อง
alter table public.docs replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- 4) ที่เก็บรูปและวิดีโอ (ไม่เปิดสาธารณะ ไฟล์ละไม่เกิน 25 MB)
insert into storage.buckets (id, name, public, file_size_limit)
values ('burin', 'burin', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

drop policy if exists "burin files: read own" on storage.objects;
drop policy if exists "burin files: add own" on storage.objects;
drop policy if exists "burin files: change own" on storage.objects;
drop policy if exists "burin files: delete own" on storage.objects;
create policy "burin files: read own" on storage.objects for select to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "burin files: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "burin files: change own" on storage.objects for update to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "burin files: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text);

-- 5) แชร์เลคเชอร์ให้ผู้เรียน (ใครมีลิงก์อ่านได้ เฉพาะเจ้าของแก้ได้)
create table if not exists public.shares (
  id text primary key,
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text,
  data jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.shares enable row level security;
drop policy if exists "shares: anyone with the link can read" on public.shares;
drop policy if exists "shares: owner writes" on public.shares;
create policy "shares: anyone with the link can read" on public.shares for select to anon, authenticated using (true);
create policy "shares: owner writes" on public.shares for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
grant select on public.shares to anon;
grant select, insert, update, delete on public.shares to authenticated;

-- 6) งานมอบหมายและการส่งงาน
--    ผู้เรียนส่งได้โดยไม่ต้องมีบัญชี เฉพาะงานที่เปิดรับและยังไม่เลยกำหนดส่ง (หรือครูขยายเวลาให้)
--    ผู้เรียนเปิดงานได้เฉพาะงานที่มีลิงก์ ดูรายการงานของห้องได้ด้วยรหัสห้อง ไม่มีใครดึงงานของครูทุกคนออกไปได้
--    เวลาส่งใช้เวลาของเซิร์ฟเวอร์ ผู้เรียนแก้เวลาส่งหรือใส่คะแนนให้ตัวเองไม่ได้ ครูเจ้าของงานเท่านั้นที่เห็นงานที่ส่ง
create table if not exists public.assignments (
  id text primary key,
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text,
  data jsonb not null,
  due timestamptz,
  open boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.assignments enable row level security;
drop policy if exists "assignments: read with the link" on public.assignments;
drop policy if exists "assignments: owner writes" on public.assignments;
create policy "assignments: owner writes" on public.assignments for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
revoke select on public.assignments from anon;
grant select, insert, update, delete on public.assignments to authenticated;

create table if not exists public.submissions (
  id text primary key,
  assignment text not null references public.assignments (id) on delete cascade,
  name text not null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists submissions_assignment on public.submissions (assignment);
alter table public.submissions enable row level security;

-- รับงานชิ้นนี้ได้ไหม: งานเปิดรับ ยังไม่เลยกำหนด หรือครูขยายเวลาให้ทั้งห้องหรือให้ผู้เรียนคนนี้
-- (รหัสผู้เรียนที่ได้ขยายเวลาเก็บเป็นค่าแฮช) เวลาส่งต้องเป็นเวลาจริง และผู้เรียนใส่คะแนนหรือผลตรวจเองไม่ได้
create or replace function public.hw_submit_ok(p_aid text, p_data jsonb, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = p_aid and (
    a.owner = auth.uid()
    or (a.open
      and p_at between now() - interval '5 minutes' and now() + interval '5 minutes'
      and not (coalesce(p_data, '{}'::jsonb) ?| array['manual', 'manualWork', 'ai'])
      and coalesce(p_data->>'by', '') <> 'teacher'
      and (a.due is null or now() <= a.due
        or now() <= nullif(a.data->'ext'->>'all', '')::timestamptz
        or (p_data->'stu' ? 'sid' and now() <= nullif(a.data->'ext'->'stu'->>left(encode(sha256(convert_to(coalesce(a.data->>'clsId', '') || '|id|' || lower(p_data->'stu'->>'sid'), 'UTF8')), 'hex'), 18), '')::timestamptz)))));
$$;
-- มีผู้เรียนคนใดที่ยังส่งงานนี้ได้อยู่ไหม (ใช้กับไฟล์แนบ ซึ่งยังไม่รู้ว่าเป็นของใคร)
create or replace function public.hw_accepts_any(aid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = aid and a.open and (
    a.due is null or now() <= a.due
    or now() <= nullif(a.data->'ext'->>'all', '')::timestamptz
    or exists (select 1 from jsonb_each_text(coalesce(a.data->'ext'->'stu', '{}'::jsonb)) e where now() <= nullif(e.value, '')::timestamptz)));
$$;

drop policy if exists "submissions: hand in to an open assignment" on public.submissions;
drop policy if exists "submissions: hand in on time" on public.submissions;
drop policy if exists "submissions: teacher reads" on public.submissions;
drop policy if exists "submissions: teacher marks" on public.submissions;
drop policy if exists "submissions: teacher deletes" on public.submissions;
create policy "submissions: hand in on time" on public.submissions for insert to anon, authenticated
  with check (public.hw_submit_ok(assignment, data, created_at));
create policy "submissions: teacher reads" on public.submissions for select to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()));
create policy "submissions: teacher marks" on public.submissions for update to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()));
create policy "submissions: teacher deletes" on public.submissions for delete to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()));
grant insert on public.submissions to anon;
grant select, insert, update, delete on public.submissions to authenticated;

create or replace function public.hw_is_owner(aid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = aid and a.owner = auth.uid());
$$;
-- เปิดงานด้วยลิงก์ และดูรายการงานของห้อง
create or replace function public.hw_get(p_id text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select * from public.assignments where id = p_id;
$$;
create or replace function public.hw_class(p_cls text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select * from public.assignments where p_cls is not null and length(p_cls) >= 6 and data->>'clsId' = p_cls order by created_at limit 300;
$$;
-- ผู้เรียนดูว่าตัวเองส่งงานใดไปแล้วเมื่อไร (ไม่เห็นคำตอบหรือคะแนน และไม่เห็นงานของคนอื่น)
create or replace function public.hw_mine(p_cls text, p_sid text, p_ids text[] default '{}')
returns table (a_id text, s_id text, at timestamptz) language sql stable security definer set search_path = public as $$
  select s.assignment, s.id, s.created_at from public.submissions s join public.assignments a on a.id = s.assignment
  where (p_cls is not null and p_sid is not null and length(p_sid) > 0 and a.data->>'clsId' = p_cls and lower(s.data->'stu'->>'sid') = lower(p_sid))
     or s.id = any(coalesce(p_ids, '{}'))
  order by s.created_at desc limit 500;
$$;
grant execute on function public.hw_get(text), public.hw_class(text), public.hw_mine(text, text, text[]), public.hw_accepts_any(text), public.hw_submit_ok(text, jsonb, timestamptz), public.hw_is_owner(text) to anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit)
values ('burin-sub', 'burin-sub', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;
drop policy if exists "homework files: hand in" on storage.objects;
drop policy if exists "homework files: teacher reads" on storage.objects;
drop policy if exists "homework files: teacher deletes" on storage.objects;
create policy "homework files: hand in" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'burin-sub' and (public.hw_accepts_any((storage.foldername(name))[1]) or public.hw_is_owner((storage.foldername(name))[1])));
create policy "homework files: teacher reads" on storage.objects for select to authenticated
  using (bucket_id = 'burin-sub' and exists (select 1 from public.assignments a where a.id = (storage.foldername(name))[1] and a.owner = auth.uid()));
create policy "homework files: teacher deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'burin-sub' and exists (select 1 from public.assignments a where a.id = (storage.foldername(name))[1] and a.owner = auth.uid()));

-- ======== 002_central.sql ========

-- 002_central.sql: database version 2 (task 1.1)
-- Builds on 001_base.sql. Safe to run again, and safe to run over a version 1 database that holds data:
-- it adds tables, functions, triggers and rules, and replaces rules; it never drops a table or deletes a row.
--
-- What changes for people:
--   1. Shared lectures and the public keys of live rooms can no longer be listed by anyone with the publishable key.
--      They are read one at a time by their code (share_get, room_key) and the answer never holds an account id.
--   2. Homework read with a link (hw_get, hw_class) no longer shows the teacher's account id.
--   3. The live channel between the devices of one account (room-<account id>) and the change feed (docs-<account id>)
--      can be joined only by that account, once the app joins them as private channels (task 1.2).
--      Class rooms (class-<code>) stay open to learners without an account; their messages are signed by the teacher.
--   4. Space per account is counted by the database (account_usage) against a limit the user cannot change
--      (account_limits, or the default in burin_settings). A full account cannot add more, but can always delete,
--      change settings, use live rooms and mark homework.
--   5. Homework handed in without an account is limited per hand-in and per assignment.
--   6. Sign-up can be limited to invited e-mail addresses (burin_settings 'signup').
--   7. delete_my_account() removes the signed-in account and everything it owns (files are removed by the app first).
--   8. Nothing is open to people who are not signed in except what learners need.
--
-- IMPORTANT: version 1 apps (before task 1.2) read shared lectures and room keys straight from the shares table.
-- After this file runs they cannot, so do not run it on a project that a version 1 app still uses.

-- 0) the version the app asks for (a version 1 database has no such function)
create or replace function public.burin_version() returns integer language sql immutable as $$ select 2 $$;

-- 1) settings only the owner of the project changes (in the SQL Editor or Table Editor)
create table if not exists public.burin_settings (
  key text primary key,
  value text,
  note text
);
alter table public.burin_settings enable row level security;
insert into public.burin_settings (key, value, note) values
  ('quota_bytes', null, 'space per account in bytes when account_limits has no row for it; empty means no limit (central cloud: 209715200 = 200 MB)'),
  ('signup', 'open', 'open: anyone can sign up; invite: only e-mail addresses in the invites table; closed: nobody'),
  ('hw_sub_bytes', '262144', 'largest hand-in without its files, in bytes'),
  ('hw_max_subs', '2000', 'most hand-ins one assignment takes'),
  ('hw_max_files', '3000', 'most files one assignment takes'),
  ('hw_sub_files', '30', 'most files in one hand-in')
on conflict (key) do nothing;

create or replace function public.burin_setting(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from public.burin_settings where key = p_key;
$$;
create or replace function public.burin_num(p_key text, p_default bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(case when public.burin_setting(p_key) ~ '^[0-9]{1,18}$' then public.burin_setting(p_key)::bigint end, p_default);
$$;

-- 2) shared lectures: no more reading the whole table. The owner still reads and writes its own rows.
drop policy if exists "shares: anyone with the link can read" on public.shares;
drop policy if exists "shares: owner writes" on public.shares;
create policy "shares: owner writes" on public.shares for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

-- one lecture by its code, without the owner's account id (room keys are read with room_key)
create or replace function public.share_get(p_id text)
returns table (id text, title text, data jsonb, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.title, s.data, s.created_at from public.shares s
  where s.id = p_id and s.id not like 'room-%';
$$;

-- 3) live room keys: the teacher claims a room code with the public half of its key; learners read only that half
create or replace function public.room_key(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('kty', 'EC', 'crv', 'P-256', 'x', s.data->>'x', 'y', s.data->>'y')
  from public.shares s where s.id = 'room-' || p_code and s.data ? 'x' and s.data ? 'y';
$$;
-- 'ok' when the room is this account's (now or already), 'taken' when another account has it,
-- 'bad' for a code or key that is not one, 'signin' when not signed in
create or replace function public.room_claim(p_code text, p_pub jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); who uuid;
begin
  if me is null then return 'signin'; end if;
  if p_code is null or p_code !~ '^[A-Z2-9]{6}$' then return 'bad'; end if;
  if p_pub is null or jsonb_typeof(p_pub) <> 'object' or coalesce(p_pub->>'x', '') !~ '^[A-Za-z0-9_-]{20,100}$'
     or coalesce(p_pub->>'y', '') !~ '^[A-Za-z0-9_-]{20,100}$' then return 'bad'; end if;
  insert into public.shares as s (id, owner, title, data)
  values ('room-' || p_code, me, 'room ' || p_code, jsonb_build_object('kty', 'EC', 'crv', 'P-256', 'x', p_pub->>'x', 'y', p_pub->>'y'))
  on conflict (id) do update set data = excluded.data where s.owner = me
  returning s.owner into who;
  if who is null then return 'taken'; end if;
  return 'ok';
end $$;

-- 4) homework read with a link or a class code: the same rows as before, without the teacher's account id
create or replace function public.hw_get(p_id text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select (jsonb_populate_record(null::public.assignments, to_jsonb(a) - 'owner')).* from public.assignments a where a.id = p_id;
$$;
create or replace function public.hw_class(p_cls text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select (jsonb_populate_record(null::public.assignments, to_jsonb(a) - 'owner')).* from public.assignments a
  where p_cls is not null and length(p_cls) >= 6 and a.data->>'clsId' = p_cls order by a.created_at limit 300;
$$;

-- 5) space per account
create table if not exists public.account_limits (
  owner uuid primary key references auth.users (id) on delete cascade,
  quota_bytes bigint,
  note text
);
comment on column public.account_limits.quota_bytes is 'bytes this account may use; empty: the default in burin_settings; below 0: no limit';
alter table public.account_limits enable row level security;
drop policy if exists "account_limits: read own" on public.account_limits;
create policy "account_limits: read own" on public.account_limits for select to authenticated using (owner = auth.uid());

create table if not exists public.account_usage (
  owner uuid primary key references auth.users (id) on delete cascade,
  docs_bytes bigint not null default 0,
  file_bytes bigint not null default 0,
  hw_bytes bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.account_usage enable row level security;
drop policy if exists "account_usage: read own" on public.account_usage;
create policy "account_usage: read own" on public.account_usage for select to authenticated using (owner = auth.uid());

create or replace function public.quota_of(p_owner uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select case when l.owner is not null and l.quota_bytes is not null then (case when l.quota_bytes < 0 then null else l.quota_bytes end)
              else case when public.burin_setting('quota_bytes') ~ '^[0-9]{1,18}$' then public.burin_setting('quota_bytes')::bigint end end
  from (select 1) one left join public.account_limits l on l.owner = p_owner;
$$;
create or replace function public.usage_of(p_owner uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce((select docs_bytes + file_bytes + hw_bytes from public.account_usage where owner = p_owner), 0);
$$;
-- is there still room (the account is under its limit)
create or replace function public.quota_room(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_owner is not null and (public.quota_of(p_owner) is null or public.usage_of(p_owner) < public.quota_of(p_owner));
$$;
create or replace function public.quota_ok_mine() returns boolean
language sql stable security definer set search_path = public as $$
  select public.quota_room(auth.uid());
$$;
-- what the signed-in account uses and may use (quota empty: no limit)
create or replace function public.my_usage()
returns table (used bigint, docs bigint, files bigint, homework bigint, quota bigint)
language sql stable security definer set search_path = public as $$
  select coalesce(u.docs_bytes + u.file_bytes + u.hw_bytes, 0), coalesce(u.docs_bytes, 0), coalesce(u.file_bytes, 0), coalesce(u.hw_bytes, 0), public.quota_of(m.me)
  from (select auth.uid() as me) m left join public.account_usage u on u.owner = m.me where m.me is not null;
$$;

create or replace function public.usage_add(p_owner uuid, p_docs bigint, p_files bigint, p_hw bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_owner is null or (p_docs = 0 and p_files = 0 and p_hw = 0) then return; end if;
  update public.account_usage set docs_bytes = greatest(0, docs_bytes + p_docs), file_bytes = greatest(0, file_bytes + p_files),
    hw_bytes = greatest(0, hw_bytes + p_hw), updated_at = now() where owner = p_owner;
  if not found and (p_docs > 0 or p_files > 0 or p_hw > 0) and exists (select 1 from auth.users where id = p_owner) then
    insert into public.account_usage as u (owner, docs_bytes, file_bytes, hw_bytes) values (p_owner, greatest(p_docs, 0), greatest(p_files, 0), greatest(p_hw, 0))
    on conflict (owner) do update set docs_bytes = greatest(0, u.docs_bytes + p_docs), file_bytes = greatest(0, u.file_bytes + p_files),
      hw_bytes = greatest(0, u.hw_bytes + p_hw), updated_at = now();
  end if;
end $$;

-- rows a full account may still write: live rooms, devices, settings and the bin (deleting puts a note in the bin)
create or replace function public.usage_free(p_table text, p_key text) returns boolean
language sql immutable as $$
  select case p_table when 'docs' then coalesce(p_key, '') ~ '^(live|devices|settings|trash)/'
                      when 'shares' then coalesce(p_key, '') like 'room-%' else false end;
$$;

-- docs, shares and assignments: count the size of each row for its owner.
-- argument 'grow': a full account cannot add or enlarge a row; 'insert': it cannot add one (changes stay allowed)
create or replace function public.usage_rows() returns trigger
language plpgsql security definer set search_path = public as $$
declare o bigint := 0; n bigint := 0; q bigint; k text;
begin
  if tg_op <> 'INSERT' then o := octet_length(old::text); end if;
  if tg_op <> 'DELETE' then n := octet_length(new::text); end if;
  if tg_op = 'DELETE' then perform public.usage_add(old.owner, -o, 0, 0); return null; end if;
  if tg_op = 'UPDATE' and old.owner is distinct from new.owner then perform public.usage_add(old.owner, -o, 0, 0); o := 0; end if;
  perform public.usage_add(new.owner, n - o, 0, 0);
  if (tg_argv[0] = 'grow' and n > o) or (tg_argv[0] = 'insert' and tg_op = 'INSERT') then
    k := coalesce(to_jsonb(new)->>'path', to_jsonb(new)->>'id');
    if not public.usage_free(tg_table_name, k) then
      q := public.quota_of(new.owner);
      if q is not null and public.usage_of(new.owner) > q then
        raise exception 'BURIN_QUOTA: this account has used all of its space' using errcode = 'P0001', hint = 'quota';
      end if;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists burin_usage on public.docs;
create trigger burin_usage after insert or update or delete on public.docs for each row execute function public.usage_rows('grow');
drop trigger if exists burin_usage on public.shares;
create trigger burin_usage after insert or update or delete on public.shares for each row execute function public.usage_rows('grow');
drop trigger if exists burin_usage on public.assignments;
create trigger burin_usage after insert or update or delete on public.assignments for each row execute function public.usage_rows('insert');

-- hand-ins count for the teacher who owns the assignment
create or replace function public.usage_subs() returns trigger
language plpgsql security definer set search_path = public as $$
declare who uuid;
begin
  select a.owner into who from public.assignments a where a.id = coalesce(new.assignment, old.assignment);
  if who is not null then
    perform public.usage_add(who, 0, 0, coalesce(octet_length(new::text), 0) - coalesce(octet_length(old::text), 0));
  end if;
  return null;
end $$;
drop trigger if exists burin_usage on public.submissions;
create trigger burin_usage after insert or update or delete on public.submissions for each row execute function public.usage_subs();

-- deleting an assignment removes its hand-ins with it (the assignment is already gone when they go)
create or replace function public.usage_assign_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.usage_add(old.owner, 0, 0, -coalesce((select sum(octet_length(s::text)) from public.submissions s where s.assignment = old.id), 0));
  return old;
end $$;
drop trigger if exists burin_usage_gone on public.assignments;
create trigger burin_usage_gone before delete on public.assignments for each row execute function public.usage_assign_gone();

-- files: the size the storage service records; 'burin' counts for the account in the first folder,
-- 'burin-sub' for the teacher who owns the assignment in the first folder
create or replace function public.file_size(p_meta jsonb) returns bigint
language sql immutable as $$
  select case when coalesce(p_meta->>'size', '') ~ '^[0-9]{1,15}$' then (p_meta->>'size')::bigint else 0 end;
$$;
create or replace function public.file_owner(p_bucket text, p_name text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare f text := (storage.foldername(p_name))[1]; who uuid;
begin
  if p_bucket = 'burin' then
    if f ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then return f::uuid; end if;
    return null;
  elsif p_bucket = 'burin-sub' then
    select a.owner into who from public.assignments a where a.id = f;
    return who;
  end if;
  return null;
end $$;
create or replace function public.usage_files() returns trigger
language plpgsql security definer set search_path = public as $$
declare who uuid; d bigint;
begin
  if tg_op <> 'INSERT' and old.bucket_id in ('burin', 'burin-sub') then
    who := public.file_owner(old.bucket_id, old.name); d := -public.file_size(old.metadata);
    if old.bucket_id = 'burin' then perform public.usage_add(who, 0, d, 0); else perform public.usage_add(who, 0, 0, d); end if;
  end if;
  if tg_op <> 'DELETE' and new.bucket_id in ('burin', 'burin-sub') then
    who := public.file_owner(new.bucket_id, new.name); d := public.file_size(new.metadata);
    if new.bucket_id = 'burin' then perform public.usage_add(who, 0, d, 0); else perform public.usage_add(who, 0, 0, d); end if;
  end if;
  return null;
end $$;
drop trigger if exists burin_usage on storage.objects;
create trigger burin_usage after insert or update or delete on storage.objects for each row execute function public.usage_files();

-- a full account cannot add files (one file can still finish when it was started just under the limit)
drop policy if exists "burin files: add own" on storage.objects;
drop policy if exists "burin files: change own" on storage.objects;
create policy "burin files: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and public.quota_ok_mine());
create policy "burin files: change own" on storage.objects for update to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and public.quota_ok_mine());

-- 6) homework without an account: limits per hand-in and per assignment, and the teacher's space
create or replace function public.hw_sub_ok(p_aid text, p_data jsonb) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare who uuid;
begin
  select a.owner into who from public.assignments a where a.id = p_aid;
  if who is null or not public.quota_room(who) then return false; end if;
  if who = auth.uid() then return true; end if;
  if octet_length(coalesce(p_data, '{}'::jsonb)::text) > public.burin_num('hw_sub_bytes', 262144) then return false; end if;
  if (select count(*) from public.submissions s where s.assignment = p_aid) >= public.burin_num('hw_max_subs', 2000) then return false; end if;
  return true;
end $$;
drop policy if exists "submissions: hand in on time" on public.submissions;
drop policy if exists "submissions: hand in on time, within limits" on public.submissions;
create policy "submissions: hand in on time, within limits" on public.submissions for insert to anon, authenticated
  with check (public.hw_submit_ok(assignment, data, created_at) and public.hw_sub_ok(assignment, data));

create or replace function public.like_prefix(p text) returns text
language sql immutable as $$ select replace(replace(replace(p, '\', '\\'), '%', '\%'), '_', '\_') || '%' $$;
-- a file handed in goes to <assignment>/<hand-in>/<file>; the teacher may add any file to its own assignment
create or replace function public.hw_file_ok(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare f text[] := storage.foldername(p_name); who uuid;
begin
  select a.owner into who from public.assignments a where a.id = f[1];
  if who is null or not public.quota_room(who) then return false; end if;
  if who = auth.uid() then return true; end if;
  if coalesce(array_length(f, 1), 0) < 2 or not public.hw_accepts_any(f[1]) then return false; end if;
  if (select count(*) from storage.objects o where o.bucket_id = 'burin-sub' and o.name like public.like_prefix(f[1] || '/'))
     >= public.burin_num('hw_max_files', 3000) then return false; end if;
  if (select count(*) from storage.objects o where o.bucket_id = 'burin-sub' and o.name like public.like_prefix(f[1] || '/' || f[2] || '/'))
     >= public.burin_num('hw_sub_files', 30) then return false; end if;
  return true;
end $$;
drop policy if exists "homework files: hand in" on storage.objects;
create policy "homework files: hand in" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'burin-sub' and public.hw_file_ok(name));

-- 7) live channels (Realtime Authorization, used by channels the app joins as private)
do $$ begin
  if to_regclass('realtime.messages') is not null then
    drop policy if exists "burin: own account channels, receive" on realtime.messages;
    drop policy if exists "burin: own account channels, send" on realtime.messages;
    drop policy if exists "burin: class rooms, receive" on realtime.messages;
    drop policy if exists "burin: class rooms, send" on realtime.messages;
    create policy "burin: own account channels, receive" on realtime.messages for select to authenticated
      using (realtime.topic() in ('room-' || auth.uid()::text, 'docs-' || auth.uid()::text));
    create policy "burin: own account channels, send" on realtime.messages for insert to authenticated
      with check (realtime.topic() in ('room-' || auth.uid()::text, 'docs-' || auth.uid()::text));
    create policy "burin: class rooms, receive" on realtime.messages for select to anon, authenticated
      using (realtime.topic() like 'class-%');
    create policy "burin: class rooms, send" on realtime.messages for insert to anon, authenticated
      with check (realtime.topic() like 'class-%');
  end if;
end $$;

-- 8) sign-up by invitation (burin_settings 'signup' = 'invite'); the project owner adds addresses to invites
create table if not exists public.invites (
  email text primary key,
  note text,
  created_at timestamptz not null default now()
);
alter table public.invites enable row level security;
create or replace function public.signup_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare mode text := coalesce(public.burin_setting('signup'), 'open');
begin
  if mode = 'closed' or (mode = 'invite' and not exists (select 1 from public.invites i where lower(i.email) = lower(new.email))) then
    raise exception 'BURIN_SIGNUP: sign-up is by invitation only' using errcode = 'P0001', hint = 'invite';
  end if;
  return new;
end $$;
drop trigger if exists burin_signup_gate on auth.users;
create trigger burin_signup_gate before insert on auth.users for each row execute function public.signup_gate();

-- 9) delete my account: notebooks, pages, settings, lectures, assignments, hand-ins and the counts go with it.
--    The app removes the files first through the storage service (the database cannot); while any are left
--    the account is kept and the answer says so.
create or replace function public.delete_my_account() returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then return 'signin'; end if;
  if exists (select 1 from storage.objects o where o.bucket_id = 'burin' and (storage.foldername(o.name))[1] = me::text)
     or exists (select 1 from storage.objects o join public.assignments a on a.id = (storage.foldername(o.name))[1]
                where o.bucket_id = 'burin-sub' and a.owner = me) then
    return 'files';
  end if;
  delete from auth.users where id = me;
  return 'deleted';
end $$;

-- 10) count again what every account uses now (fixes any drift, and fills the counts on a version 1 database)
insert into public.account_usage as u (owner, docs_bytes, file_bytes, hw_bytes, updated_at)
select z.owner, sum(z.d), sum(z.f), sum(z.h), now() from (
  select owner, octet_length(x::text)::bigint d, 0::bigint f, 0::bigint h from public.docs x
  union all select owner, octet_length(x::text), 0, 0 from public.shares x
  union all select owner, octet_length(x::text), 0, 0 from public.assignments x
  union all select a.owner, 0, 0, octet_length(s::text) from public.submissions s join public.assignments a on a.id = s.assignment
  union all select public.file_owner(o.bucket_id, o.name), 0, public.file_size(o.metadata), 0 from storage.objects o where o.bucket_id = 'burin'
  union all select a.owner, 0, 0, public.file_size(o.metadata) from storage.objects o join public.assignments a on a.id = (storage.foldername(o.name))[1] where o.bucket_id = 'burin-sub'
  union all select id, 0, 0, 0 from auth.users
) z where z.owner is not null and exists (select 1 from auth.users w where w.id = z.owner)
group by z.owner
on conflict (owner) do update set docs_bytes = excluded.docs_bytes, file_bytes = excluded.file_bytes, hw_bytes = excluded.hw_bytes, updated_at = now();

-- 11) who may do what. Supabase gives new tables and functions to everyone by default, so take it all back
--     and give only what the app needs. Rows are still guarded by the row rules above.
revoke all on table public.docs, public.shares, public.assignments, public.submissions,
  public.burin_settings, public.account_limits, public.account_usage, public.invites from anon, authenticated;
grant select, insert, update, delete on public.docs, public.shares, public.assignments, public.submissions to authenticated;
grant insert on public.submissions to anon;
grant select on public.account_limits, public.account_usage to authenticated;

revoke all on function public.burin_setting(text), public.burin_num(text, bigint), public.quota_of(uuid), public.usage_of(uuid),
  public.quota_room(uuid), public.usage_add(uuid, bigint, bigint, bigint), public.usage_free(text, text), public.usage_rows(),
  public.usage_subs(), public.usage_assign_gone(), public.file_size(jsonb), public.file_owner(text, text), public.usage_files(),
  public.like_prefix(text), public.signup_gate() from public, anon, authenticated;
revoke all on function public.burin_version(), public.share_get(text), public.room_key(text), public.room_claim(text, jsonb),
  public.hw_get(text), public.hw_class(text), public.hw_mine(text, text, text[]), public.hw_accepts_any(text),
  public.hw_submit_ok(text, jsonb, timestamptz), public.hw_is_owner(text), public.hw_sub_ok(text, jsonb), public.hw_file_ok(text),
  public.quota_ok_mine(), public.my_usage(), public.delete_my_account() from public, anon, authenticated;
-- learners without an account: open a lecture, a room key or homework by its code, and hand homework in
grant execute on function public.burin_version(), public.share_get(text), public.room_key(text),
  public.hw_get(text), public.hw_class(text), public.hw_mine(text, text, text[]), public.hw_accepts_any(text),
  public.hw_submit_ok(text, jsonb, timestamptz), public.hw_is_owner(text), public.hw_sub_ok(text, jsonb), public.hw_file_ok(text)
  to anon, authenticated;
-- signed in
grant execute on function public.room_claim(text, jsonb), public.quota_ok_mine(), public.my_usage(), public.delete_my_account() to authenticated;

-- ======== 003_marks.sql ========

-- 003_marks.sql: a learner cannot mark its own answer (found while doing task 2.9, 23 Nov 2026)
-- Builds on 001_base.sql (works on version 1 and version 2). Safe to run again; changes one function, no table, no row.
--
-- The rule that takes a hand-in refused the teacher's marks manual, manualWork and ai, but not manualAns, the teacher's
-- "the answer is right or wrong" for a question that shows the working. A learner who sent its own hand-in straight to
-- the cloud (not through the app) could mark its own answers right. This adds manualAns to the refused marks.
-- The app never sends manualAns from a learner, so nothing a learner does in the app changes.
-- This file alone may also run on a version 1 project (it does not need 002).

create or replace function public.hw_submit_ok(p_aid text, p_data jsonb, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = p_aid and (
    a.owner = auth.uid()
    or (a.open
      and p_at between now() - interval '5 minutes' and now() + interval '5 minutes'
      and not (coalesce(p_data, '{}'::jsonb) ?| array['manual', 'manualWork', 'manualAns', 'ai'])
      and coalesce(p_data->>'by', '') <> 'teacher'
      and (a.due is null or now() <= a.due
        or now() <= nullif(a.data->'ext'->>'all', '')::timestamptz
        or (p_data->'stu' ? 'sid' and now() <= nullif(a.data->'ext'->'stu'->>left(encode(sha256(convert_to(coalesce(a.data->>'clsId', '') || '|id|' || lower(p_data->'stu'->>'sid'), 'UTF8')), 'hex'), 18), '')::timestamptz)))));
$$;

-- ======== 004_show.sql ========

-- 004_show.sql: homework the teacher set to show later stays closed in the database too (owner chose 24 Nov 2026, task 1.5)
-- Builds on 002_central.sql (hw_get and hw_class without the teacher's account id) and 003_marks.sql (hw_submit_ok).
-- Safe to run again; changes functions only, no table and no row.
--
-- The app (switch hwshow) keeps data.show on an assignment: a time (ISO) or 'end' (after the teacher closes the live room,
-- when the app writes the time it closed). Until then the app hides the work, but the database still handed it out whole
-- and took hand-ins. Now, for anyone but the teacher who owns it, until data.show has passed:
--   hw_get and hw_class give the row with only data.show, data.clsId and data.kind (title, due and open stay), so the app
--   still says when it opens and can ask again then, and the questions are not out early;
--   hw_submit_ok and hw_accepts_any refuse, so no hand-in and no file is taken before it opens.
-- data.show that is missing, empty or not a time means shown, as before (old assignments are not affected).

create or replace function public.hw_shown(p_data jsonb, p_owner uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v text := coalesce(p_data->>'show', '');
begin
  if p_owner is not null and p_owner = auth.uid() then return true; end if;
  if v = '' then return true; end if;
  if v = 'end' then return false; end if;
  begin
    return v::timestamptz <= now();
  exception when others then
    return true;
  end;
end $$;

-- the row a learner may see: whole when shown, otherwise only when it opens
create or replace function public.hw_get(p_id text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select (jsonb_populate_record(null::public.assignments,
    case when public.hw_shown(a.data, a.owner) then to_jsonb(a) - 'owner'
    else (to_jsonb(a) - 'owner') || jsonb_build_object('data', jsonb_strip_nulls(jsonb_build_object(
      'show', a.data->'show', 'clsId', a.data->'clsId', 'kind', a.data->'kind'))) end)).*
  from public.assignments a where a.id = p_id;
$$;
create or replace function public.hw_class(p_cls text)
returns setof public.assignments language sql stable security definer set search_path = public as $$
  select (jsonb_populate_record(null::public.assignments,
    case when public.hw_shown(a.data, a.owner) then to_jsonb(a) - 'owner'
    else (to_jsonb(a) - 'owner') || jsonb_build_object('data', jsonb_strip_nulls(jsonb_build_object(
      'show', a.data->'show', 'clsId', a.data->'clsId', 'kind', a.data->'kind'))) end)).*
  from public.assignments a
  where p_cls is not null and length(p_cls) >= 6 and a.data->>'clsId' = p_cls order by a.created_at limit 300;
$$;

-- 003_marks.sql's rule, and not before the work is shown
create or replace function public.hw_submit_ok(p_aid text, p_data jsonb, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = p_aid and (
    a.owner = auth.uid()
    or (a.open
      and public.hw_shown(a.data, a.owner)
      and p_at between now() - interval '5 minutes' and now() + interval '5 minutes'
      and not (coalesce(p_data, '{}'::jsonb) ?| array['manual', 'manualWork', 'manualAns', 'ai'])
      and coalesce(p_data->>'by', '') <> 'teacher'
      and (a.due is null or now() <= a.due
        or now() <= nullif(a.data->'ext'->>'all', '')::timestamptz
        or (p_data->'stu' ? 'sid' and now() <= nullif(a.data->'ext'->'stu'->>left(encode(sha256(convert_to(coalesce(a.data->>'clsId', '') || '|id|' || lower(p_data->'stu'->>'sid'), 'UTF8')), 'hex'), 18), '')::timestamptz)))));
$$;
-- files of a hand-in: as before, and not before the work is shown
create or replace function public.hw_accepts_any(aid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.id = aid and a.open and public.hw_shown(a.data, a.owner) and (
    a.due is null or now() <= a.due
    or now() <= nullif(a.data->'ext'->>'all', '')::timestamptz
    or exists (select 1 from jsonb_each_text(coalesce(a.data->'ext'->'stu', '{}'::jsonb)) e where now() <= nullif(e.value, '')::timestamptz)));
$$;

revoke all on function public.hw_shown(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.hw_get(text), public.hw_class(text), public.hw_submit_ok(text, jsonb, timestamptz),
  public.hw_accepts_any(text) from public, anon, authenticated;
grant execute on function public.hw_get(text), public.hw_class(text), public.hw_submit_ok(text, jsonb, timestamptz),
  public.hw_accepts_any(text) to anon, authenticated;

-- ======== 005_plans.sql ========

-- 005_plans.sql: the plan of each account and when it ends (task 4.1)
-- Builds on 002_central.sql (account_limits). Safe to run again; adds columns and functions, never drops or deletes.
--
-- Plans: 'free' (เริ่มต้น), 'presenter' (ผู้นำเสนอ), 'creator' (ผู้สร้างสื่อ). A higher plan has everything of a lower one.
-- The plan is kept on account_limits next to the space of the account:
--   plan        'presenter' or 'creator'; empty: the default in burin_settings ('plan_default'), else 'free'
--   plan_until  when it ends; empty: no end (a lifetime purchase, or given by the owner of the project)
--   plan_source where it came from: 'apple', 'google', 'trial', 'grant' (given by hand) ...
--   plan_ref    the purchase it came from (the original transaction of the store), for task 4.4
-- People can read their own row (002) but never write it: only the owner of the project (SQL Editor, Table Editor)
-- and the server function that checks store receipts (task 4.4, service role) change it.
-- A plan that has ended counts as 'free'; nothing is deleted and everything stays readable and exportable.
--
-- my_plan() tells the signed-in account its plan now. The app opens or closes what runs on the device by it (switch
-- "plans"); what costs the server (space, devices, rooms, open work, listeners) is checked by the database in task 4.2.
--
-- Give someone a plan by hand, for example a year of presenter:
--   insert into public.account_limits (owner, plan, plan_until, plan_source)
--   select id, 'presenter', now() + interval '1 year', 'grant' from auth.users where email = 'someone@example.com'
--   on conflict (owner) do update set plan = excluded.plan, plan_until = excluded.plan_until, plan_source = excluded.plan_source;

alter table public.account_limits add column if not exists plan text;
alter table public.account_limits add column if not exists plan_until timestamptz;
alter table public.account_limits add column if not exists plan_source text;
alter table public.account_limits add column if not exists plan_ref text;
alter table public.account_limits drop constraint if exists account_limits_plan_check;
alter table public.account_limits add constraint account_limits_plan_check check (plan is null or plan in ('free', 'presenter', 'creator'));
comment on column public.account_limits.plan is 'free, presenter or creator; empty: the default in burin_settings (plan_default), else free';
comment on column public.account_limits.plan_until is 'when the plan ends; empty: no end. After it ends the account is free';
comment on column public.account_limits.plan_source is 'where the plan came from: apple, google, trial, grant';
comment on column public.account_limits.plan_ref is 'the purchase the plan came from (original transaction id of the store)';

insert into public.burin_settings (key, value, note) values
  ('plan_default', null, 'the plan of an account that has none of its own: free, presenter or creator; empty means free')
on conflict (key) do nothing;

-- the plan an account has now (ended or unknown: free)
create or replace function public.plan_of(p_owner uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when l.owner is not null and l.plan in ('presenter', 'creator') and (l.plan_until is null or l.plan_until > now()) then l.plan
    when coalesce(l.plan, '') = '' and public.burin_setting('plan_default') in ('presenter', 'creator') then public.burin_setting('plan_default')
    else 'free' end
  from (select 1) one left join public.account_limits l on l.owner = p_owner;
$$;

-- the plan of the signed-in account: plan now, the plan bought (also when it has ended), when it ends, where it came
-- from, and the time of the server (so a device with a wrong clock still knows whether it has ended)
create or replace function public.my_plan()
returns table (plan text, paid text, until timestamptz, source text, server_now timestamptz)
language sql stable security definer set search_path = public as $$
  select public.plan_of(m.me), coalesce(nullif(l.plan, ''), public.burin_setting('plan_default'), 'free'), l.plan_until, l.plan_source, now()
  from (select auth.uid() as me) m left join public.account_limits l on l.owner = m.me where m.me is not null;
$$;

revoke all on function public.plan_of(uuid) from public, anon, authenticated;
revoke all on function public.my_plan() from public, anon, authenticated;
grant execute on function public.my_plan() to authenticated;

-- ======== 006_limits.sql ========

-- 006_limits.sql: what a plan allows of what costs the server, checked by the database (task 4.2, part 1)
-- Builds on 002_central.sql and 005_plans.sql. Safe to run again; adds a table, settings, functions and rules,
-- replaces rules under their old names, never drops a table or deletes a row of people's work.
--
-- Every limit here is a setting in burin_settings. Empty means no limit, and that is how this file leaves them,
-- so running it changes nothing for anybody until the owner of the project fills them in (central cloud, task 4.2):
--   quota_bytes        space of a free account (002). A paid plan gets quota_presenter or quota_creator, never less
--   quota_presenter    space of a presenter account in bytes (5 GB); used only when quota_bytes has a limit
--   quota_creator      space of a creator account in bytes (20 GB)
--   devices_max        devices (sign-ins) one account uses at once, every plan (3)
--   devices_idle_days  a device not used for this many days stops counting and is signed out (60; empty: never)
--   rooms_free         classes (gradebook rooms, docs classes/...) a free account keeps (2); rooms_presenter, rooms_creator too
--   open_free          assignments a free account has taking work at once (10); open_presenter, open_creator too
-- A row of account_limits with quota_bytes still wins over all of them for that account (002).
--
-- Devices: a device is a sign-in, the session_id in the token Supabase gives it. Windows of one browser share it,
-- so the audience screen in a second window or the installed app does not count. A room screen (#show) is not
-- signed in. A device that only shows (a TV in present mode) says so (device_hello screen = true): it does not
-- count, may read and follow the live room, but may not write. The first devices_max devices, by when they signed
-- in, have a seat; a newer one waits until one is removed (device_remove signs that device out at once; its
-- notebooks on the device are not touched). A waiting device cannot read or write anything of the account.
-- Limits of a plan that ended (or was never bought) are those of free; nothing already there is deleted: a class
-- or an open assignment above the limit stays and can still be changed, only adding one more is refused.

insert into public.burin_settings (key, value, note) values
  ('quota_presenter', '5368709120', 'space of a presenter account in bytes (5 GB); used only when quota_bytes has a limit, never less than it'),
  ('quota_creator', '21474836480', 'space of a creator account in bytes (20 GB); used only when quota_bytes has a limit, never less than it'),
  ('devices_max', null, 'devices (sign-ins) one account may use at once; empty: no limit (central cloud: 3)'),
  ('devices_idle_days', '60', 'a device not used for this many days stops counting and is signed out when another device of the account opens the app; empty: never'),
  ('rooms_free', null, 'classes a free account may keep; empty: no limit (central cloud: 2). rooms_presenter and rooms_creator work the same'),
  ('open_free', null, 'assignments a free account may have taking work at once; empty: no limit (central cloud: 10). open_presenter and open_creator work the same')
on conflict (key) do nothing;

-- a limit of the plan the account has now: <what>_<plan> in burin_settings, empty: no limit
create or replace function public.plan_limit(p_owner uuid, p_what text) returns bigint
language sql stable security definer set search_path = public as $$
  select case when public.burin_setting(p_what || '_' || public.plan_of(p_owner)) ~ '^[0-9]{1,15}$'
              then public.burin_setting(p_what || '_' || public.plan_of(p_owner))::bigint end;
$$;

-- 1) space by plan (replaces 002's quota_of: a row of its own first, then the plan, then the default)
create or replace function public.quota_of(p_owner uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select case when l.owner is not null and l.quota_bytes is not null then (case when l.quota_bytes < 0 then null else l.quota_bytes end)
              when public.burin_setting('quota_bytes') ~ '^[0-9]{1,18}$' then
                greatest(public.burin_setting('quota_bytes')::bigint,
                  case p.plan when 'presenter' then public.burin_num('quota_presenter', 0) when 'creator' then public.burin_num('quota_creator', 0) else 0 end)
         end
  from (select 1) one left join public.account_limits l on l.owner = p_owner cross join (select public.plan_of(p_owner) as plan) p;
$$;

-- 2) devices
create table if not exists public.account_devices (
  session uuid primary key,
  owner uuid not null references auth.users (id) on delete cascade,
  name text,
  kind text,
  screen boolean not null default false,
  seen_at timestamptz not null default now()
);
comment on table public.account_devices is 'what each sign-in of an account calls itself (device_hello); the sign-ins themselves are auth.sessions';
create index if not exists account_devices_owner on public.account_devices (owner);
alter table public.account_devices enable row level security;

create or replace function public.ts_or_null(p text) returns timestamptz
language plpgsql immutable as $$
begin return nullif(p, '')::timestamptz; exception when others then return null; end $$;

-- the session of the request (empty: a token without one, or not signed in)
create or replace function public.my_session() returns uuid
language plpgsql stable as $$
begin return nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id', '')::uuid;
exception when others then return null; end $$;

-- every sign-in of an account that has not ended: when it began, when it was last used, whether it only shows,
-- whether it is idle, and whether it has a seat. p_me is the session asking (it is in use, so never idle).
-- Optional columns of auth.sessions are read through to_jsonb, so a project on an older Supabase still works.
create or replace function public.device_seats(p_owner uuid, p_me uuid)
returns table (session uuid, made timestamptz, active timestamptz, agent text, screen boolean, idle boolean, seat boolean)
language sql stable security definer set search_path = public as $$
  with s as (
    select x.id, x.created_at as made,
      greatest(x.created_at, x.updated_at, public.ts_or_null(to_jsonb(x) ->> 'refreshed_at'),
        (select max(greatest(r.created_at, r.updated_at)) from auth.refresh_tokens r where r.session_id = x.id)) as active,
      to_jsonb(x) ->> 'user_agent' as agent
    from auth.sessions x
    where x.user_id = p_owner and (public.ts_or_null(to_jsonb(x) ->> 'not_after') is null or public.ts_or_null(to_jsonb(x) ->> 'not_after') > now())
  ), k as (
    select s.*, coalesce(d.screen, false) as screen,
      coalesce(s.id is distinct from p_me and public.burin_num('devices_idle_days', 0) > 0
        and s.active < now() - make_interval(days => public.burin_num('devices_idle_days', 0)::int), false) as idle
    from s left join public.account_devices d on d.session = s.id and d.owner = p_owner
  )
  select k.id, k.made, k.active, k.agent, k.screen, k.idle,
    not k.screen and not k.idle and public.burin_num('devices_max', 0) > 0
      and row_number() over (partition by (not k.screen and not k.idle) order by k.made, k.id) <= public.burin_num('devices_max', 0)
  from k;
$$;

-- may this request touch the account's data (p_write: add or change). No limit set, not signed in, or a token
-- without a session: yes, as before. Otherwise the session must have a seat; a screen may only read.
create or replace function public.device_ok(p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); sid uuid;
begin
  if public.burin_num('devices_max', 0) <= 0 or me is null then return true; end if;
  sid := public.my_session();
  if sid is null then return true; end if;
  return exists (select 1 from public.device_seats(me, sid) d where d.session = sid and (d.seat or (d.screen and not p_write)));
end $$;

-- a device says what it is when the app opens (and again when that changes). Signs out devices of the account that
-- have been idle too long, forgets names of sign-ins that ended, and answers where this device stands:
-- state 'off' (no limit), 'ok' (has a seat), 'screen' (shows only), 'full' (waits), 'signin'; max, used (seats taken)
create or replace function public.device_hello(p_name text, p_kind text, p_screen boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); sid uuid := public.my_session(); mx bigint := public.burin_num('devices_max', 0); st text; used bigint;
begin
  if me is null then return jsonb_build_object('state', 'signin'); end if;
  if sid is not null and exists (select 1 from auth.sessions x where x.id = sid and x.user_id = me) then
    if mx > 0 then
      begin
        delete from auth.sessions x where x.user_id = me and x.id <> sid and x.id in (select d.session from public.device_seats(me, sid) d where d.idle);
      exception when others then null; -- a project that does not let this file sign sessions out: idle ones just do not count
      end;
    end if;
    delete from public.account_devices d where d.owner = me and d.session <> sid and not exists (select 1 from auth.sessions x where x.id = d.session);
    insert into public.account_devices as d (session, owner, name, kind, screen, seen_at)
    values (sid, me, left(coalesce(p_name, ''), 40), left(coalesce(p_kind, ''), 40), coalesce(p_screen, false), now())
    on conflict (session) do update set name = excluded.name, kind = excluded.kind, screen = excluded.screen, seen_at = now()
    where d.owner = me;
  end if;
  if mx <= 0 then return jsonb_build_object('state', 'off'); end if;
  select count(*) filter (where d.seat) into used from public.device_seats(me, sid) d;
  select case when sid is null then 'ok' when d.seat then 'ok' when d.screen then 'screen' else 'full' end into st
  from (select 1) one left join public.device_seats(me, sid) d on d.session = sid;
  return jsonb_build_object('state', st, 'max', mx, 'used', used);
end $$;

-- the devices of the signed-in account, this one first, then by seat and last use
create or replace function public.my_devices()
returns table (session uuid, name text, kind text, agent text, made timestamptz, active timestamptz, screen boolean, idle boolean, seat boolean, me boolean)
language sql stable security definer set search_path = public as $$
  select d.session, a.name, a.kind, d.agent, d.made, d.active, d.screen, d.idle, d.seat, d.session = public.my_session()
  from public.device_seats(auth.uid(), public.my_session()) d left join public.account_devices a on a.session = d.session
  where auth.uid() is not null
  order by (d.session = public.my_session()) desc nulls last, d.seat desc, d.active desc;
$$;

-- sign one device of this account out at once ('ok'; 'none': no such device; 'signin'). Also from a device that waits.
create or replace function public.device_remove(p_session uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null then return 'signin'; end if;
  delete from auth.sessions x where x.id = p_session and x.user_id = me;
  get diagnostics n = row_count;
  delete from public.account_devices d where d.session = p_session and d.owner = me;
  return case when n > 0 then 'ok' else 'none' end;
end $$;

-- the rules of 001 and 002 again, each with the device check (same names, so running again replaces them)
drop policy if exists "docs: own rows" on public.docs;
create policy "docs: own rows" on public.docs for all to authenticated
  using (owner = auth.uid() and (select public.device_ok(false)))
  with check (owner = auth.uid() and (select public.device_ok(true)));
drop policy if exists "shares: owner writes" on public.shares;
create policy "shares: owner writes" on public.shares for all to authenticated
  using (owner = auth.uid() and (select public.device_ok(false)))
  with check (owner = auth.uid() and (select public.device_ok(true)));
drop policy if exists "assignments: owner writes" on public.assignments;
create policy "assignments: owner writes" on public.assignments for all to authenticated
  using (owner = auth.uid() and (select public.device_ok(false)))
  with check (owner = auth.uid() and (select public.device_ok(true)));
drop policy if exists "submissions: teacher reads" on public.submissions;
drop policy if exists "submissions: teacher marks" on public.submissions;
drop policy if exists "submissions: teacher deletes" on public.submissions;
create policy "submissions: teacher reads" on public.submissions for select to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()) and (select public.device_ok(false)));
create policy "submissions: teacher marks" on public.submissions for update to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()) and (select public.device_ok(true)));
create policy "submissions: teacher deletes" on public.submissions for delete to authenticated
  using (exists (select 1 from public.assignments a where a.id = assignment and a.owner = auth.uid()) and (select public.device_ok(false)));

drop policy if exists "burin files: read own" on storage.objects;
drop policy if exists "burin files: add own" on storage.objects;
drop policy if exists "burin files: change own" on storage.objects;
drop policy if exists "burin files: delete own" on storage.objects;
create policy "burin files: read own" on storage.objects for select to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and (select public.device_ok(false)));
create policy "burin files: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and public.quota_ok_mine() and (select public.device_ok(true)));
create policy "burin files: change own" on storage.objects for update to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and (select public.device_ok(true)))
  with check (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and public.quota_ok_mine() and (select public.device_ok(true)));
create policy "burin files: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'burin' and (storage.foldername(name))[1] = auth.uid()::text and (select public.device_ok(false)));
drop policy if exists "homework files: teacher reads" on storage.objects;
drop policy if exists "homework files: teacher deletes" on storage.objects;
create policy "homework files: teacher reads" on storage.objects for select to authenticated
  using (bucket_id = 'burin-sub' and exists (select 1 from public.assignments a where a.id = (storage.foldername(name))[1] and a.owner = auth.uid()) and (select public.device_ok(false)));
create policy "homework files: teacher deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'burin-sub' and exists (select 1 from public.assignments a where a.id = (storage.foldername(name))[1] and a.owner = auth.uid()) and (select public.device_ok(false)));

do $$ begin
  if to_regclass('realtime.messages') is not null then
    drop policy if exists "burin: own account channels, receive" on realtime.messages;
    drop policy if exists "burin: own account channels, send" on realtime.messages;
    create policy "burin: own account channels, receive" on realtime.messages for select to authenticated
      using (realtime.topic() in ('room-' || auth.uid()::text, 'docs-' || auth.uid()::text) and (select public.device_ok(false)));
    create policy "burin: own account channels, send" on realtime.messages for insert to authenticated
      with check (realtime.topic() in ('room-' || auth.uid()::text, 'docs-' || auth.uid()::text) and (select public.device_ok(false)));
  end if;
end $$;

-- a waiting device cannot claim a room for live teaching ('device'); otherwise as in 002
create or replace function public.room_claim(p_code text, p_pub jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); who uuid;
begin
  if me is null then return 'signin'; end if;
  if not public.device_ok(true) then return 'device'; end if;
  if p_code is null or p_code !~ '^[A-Z2-9]{6}$' then return 'bad'; end if;
  if p_pub is null or jsonb_typeof(p_pub) <> 'object' or coalesce(p_pub->>'x', '') !~ '^[A-Za-z0-9_-]{20,100}$'
     or coalesce(p_pub->>'y', '') !~ '^[A-Za-z0-9_-]{20,100}$' then return 'bad'; end if;
  insert into public.shares as s (id, owner, title, data)
  values ('room-' || p_code, me, 'room ' || p_code, jsonb_build_object('kty', 'EC', 'crv', 'P-256', 'x', p_pub->>'x', 'y', p_pub->>'y'))
  on conflict (id) do update set data = excluded.data where s.owner = me
  returning s.owner into who;
  if who is null then return 'taken'; end if;
  return 'ok';
end $$;

-- 3) classes (rooms of the gradebook): a new one beyond the plan is refused; changing one that is there is not
create or replace function public.rooms_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim bigint;
begin
  if new.path !~ '^classes/[^/]+$' then return new; end if;
  if exists (select 1 from public.docs d where d.owner = new.owner and d.path = new.path) then return new; end if;
  lim := public.plan_limit(new.owner, 'rooms');
  if lim is not null and (select count(*) from public.docs d where d.owner = new.owner and d.path ~ '^classes/[^/]+$') >= lim then
    raise exception 'BURIN_PLAN: this plan keeps % classes', lim using errcode = 'P0001', hint = 'rooms';
  end if;
  return new;
end $$;
drop trigger if exists burin_rooms on public.docs;
create trigger burin_rooms before insert on public.docs for each row execute function public.rooms_gate();

-- 4) assignments taking work: open, and its due time (or a time given to the class or to one learner) not passed
create or replace function public.hw_taking(p_open boolean, p_due timestamptz, p_data jsonb) returns boolean
language plpgsql stable as $$
begin
  return coalesce(p_open, false) and coalesce(p_due is null or now() <= p_due
    or now() <= public.ts_or_null(p_data->'ext'->>'all')
    or exists (select 1 from jsonb_each_text(case when jsonb_typeof(p_data->'ext'->'stu') = 'object' then p_data->'ext'->'stu' else '{}'::jsonb end) e
               where now() <= public.ts_or_null(e.value)), false);
end $$;
-- a new assignment that takes work, or one that starts taking work again (opened, due time moved later), is refused
-- when the plan's number is reached; changing one that already takes work is not
create or replace function public.open_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim bigint;
begin
  if not public.hw_taking(new.open, new.due, new.data) then return new; end if;
  if tg_op = 'UPDATE' and public.hw_taking(old.open, old.due, old.data) then return new; end if;
  lim := public.plan_limit(new.owner, 'open');
  if lim is not null and (select count(*) from public.assignments a where a.owner = new.owner and a.id <> new.id and public.hw_taking(a.open, a.due, a.data)) >= lim then
    raise exception 'BURIN_PLAN: this plan takes work in % assignments at once', lim using errcode = 'P0001', hint = 'work';
  end if;
  return new;
end $$;
drop trigger if exists burin_open on public.assignments;
create trigger burin_open before insert or update on public.assignments for each row execute function public.open_gate();

-- what the signed-in account may still add: classes and assignments taking work now and their limits (empty: none)
create or replace function public.my_limits()
returns table (rooms bigint, rooms_max bigint, open_work bigint, open_max bigint, devices_max bigint)
language sql stable security definer set search_path = public as $$
  select (select count(*) from public.docs d where d.owner = m.me and d.path ~ '^classes/[^/]+$'), public.plan_limit(m.me, 'rooms'),
    (select count(*) from public.assignments a where a.owner = m.me and public.hw_taking(a.open, a.due, a.data)), public.plan_limit(m.me, 'open'),
    nullif(public.burin_num('devices_max', 0), 0)
  from (select auth.uid() as me) m where m.me is not null;
$$;

revoke all on table public.account_devices from anon, authenticated;
revoke all on function public.plan_limit(uuid, text), public.ts_or_null(text), public.my_session(), public.device_seats(uuid, uuid),
  public.rooms_gate(), public.hw_taking(boolean, timestamptz, jsonb), public.open_gate(),
  public.quota_of(uuid) from public, anon, authenticated;
-- device_ok is part of the rules above, so whoever is signed in runs it (it only answers for its own request)
revoke all on function public.device_ok(boolean), public.device_hello(text, text, boolean), public.my_devices(), public.device_remove(uuid),
  public.my_limits(), public.room_claim(text, jsonb) from public, anon, authenticated;
grant execute on function public.device_ok(boolean), public.device_hello(text, text, boolean), public.my_devices(), public.device_remove(uuid),
  public.my_limits(), public.room_claim(text, jsonb) to authenticated;

-- ======== 007_listeners.sql ========

-- 007_listeners.sql: listeners in a live room by the plan of its teacher (task 4.2, part 2)
-- Builds on 002_central.sql (room_claim), 005_plans.sql and 006_limits.sql (plan_limit). Safe to run again;
-- adds a table, a setting and functions, never drops a table or deletes a row of people's work.
--
-- A live room is the public channel class-<code>; learners join it without an account, so the channel itself cannot
-- count them. Before joining, the app asks room_seat(code, seat) with the random id of the device (the same on every
-- visit, so coming back does not take a second seat). The room belongs to the account that claimed the code
-- (room_claim, the shares row room-<code>); its plan sets listeners_<plan> in burin_settings (empty: no limit, and
-- that is how this file leaves them; central cloud: listeners_free 40). A seat lasts 3 minutes and the app renews it
-- every minute while in the room; leaving gives it back (room_leave). A room screen (#show) does not ask.
-- Limit of this way: someone who changes the app on their own device can still join the public channel without a
-- seat. A room without an owner (a version 1 room, or a code nobody claimed) has no limit.

insert into public.burin_settings (key, value, note) values
  ('listeners_free', null, 'learners at once in a live room of a free account; empty: no limit (central cloud: 40). listeners_presenter and listeners_creator work the same')
on conflict (key) do nothing;

create table if not exists public.room_seats (
  code text not null,
  seat text not null,
  at timestamptz not null default now(),
  primary key (code, seat)
);
comment on table public.room_seats is 'learners in a live room now (room_seat); a seat not renewed for 3 minutes is free again';
create index if not exists room_seats_at on public.room_seats (at);
alter table public.room_seats enable row level security;

-- a seat in room <code> for the device <seat>: state 'ok' (in; max and used when the room has a limit), 'full'
-- (max), or 'bad' (not a room code or seat id). A device that has a seat keeps it and renews it.
create or replace function public.room_seat(p_code text, p_seat text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare who uuid; lim bigint; used bigint;
begin
  if p_code is null or p_code !~ '^[A-Z2-9]{6}$' or p_seat is null or p_seat !~ '^[A-Za-z0-9_-]{4,64}$' then
    return jsonb_build_object('state', 'bad');
  end if;
  select s.owner into who from public.shares s where s.id = 'room-' || p_code;
  lim := case when who is null then null else public.plan_limit(who, 'listeners') end;
  if lim is null then return jsonb_build_object('state', 'ok'); end if;
  perform pg_advisory_xact_lock(hashtext('burin-room-' || p_code));
  delete from public.room_seats r where r.code = p_code and r.at < now() - interval '3 minutes';
  if random() < 0.02 then delete from public.room_seats r where r.at < now() - interval '1 day'; end if;
  update public.room_seats r set at = now() where r.code = p_code and r.seat = p_seat;
  if not found then
    select count(*) into used from public.room_seats r where r.code = p_code;
    if used >= lim then return jsonb_build_object('state', 'full', 'max', lim); end if;
    insert into public.room_seats (code, seat) values (p_code, p_seat) on conflict (code, seat) do update set at = now();
  end if;
  select count(*) into used from public.room_seats r where r.code = p_code;
  return jsonb_build_object('state', 'ok', 'max', lim, 'used', used);
end $$;

-- the device leaves the room: its seat is free at once
create or replace function public.room_leave(p_code text, p_seat text) returns void
language sql security definer set search_path = public as $$
  delete from public.room_seats r where r.code = p_code and r.seat = p_seat;
$$;

revoke all on table public.room_seats from anon, authenticated;
revoke all on function public.room_seat(text, text), public.room_leave(text, text) from public, anon, authenticated;
grant execute on function public.room_seat(text, text), public.room_leave(text, text) to anon, authenticated;

-- ======== 008_consent.sql ========

-- 008_consent.sql: a record of each agreement to the terms and the privacy policy that the account cannot change
-- (task 1.10). Builds on 002_central.sql. Safe to run again; adds a table, a function and a trigger on auth.users,
-- never drops a table or deletes a row of people's work.
--
-- The app sends the agreement with the sign-up and later with updateUser, as user_metadata.consent
-- { v, at, age, guardian, by }. user_metadata can be rewritten by the account itself, so it alone is no proof of what
-- was agreed and when. Every time that consent changes (a new account, or a new version agreed), the trigger below
-- copies it here with the time of the server. The account reads its own rows (my_consents); nobody can change or
-- remove a row through the API. Deleting the account removes its rows with it (the policy promises deletion).

create table if not exists public.consents (
  id bigserial primary key,
  owner uuid not null references auth.users (id) on delete cascade,
  at timestamptz not null default now(),
  v text not null default '' check (char_length(v) <= 20),
  age text not null default '' check (char_length(age) <= 10),
  guardian text not null default '' check (char_length(guardian) <= 80),
  by text not null default '' check (char_length(by) <= 10),
  told_at text not null default '' check (char_length(told_at) <= 40)
);
comment on table public.consents is 'each agreement to the terms and privacy policy, copied from user_metadata.consent with the server time (008_consent.sql); read with my_consents()';
create index if not exists consents_owner on public.consents (owner, at);
alter table public.consents enable row level security;
revoke all on public.consents from anon, authenticated;
revoke all on sequence public.consents_id_seq from anon, authenticated;
-- no policy: rows are written by the trigger and read by my_consents() only

create or replace function public.consent_keep() returns trigger
language plpgsql security definer set search_path = public as $$
declare c jsonb; o jsonb;
begin
  c := coalesce(new.raw_user_meta_data, '{}'::jsonb) -> 'consent';
  if c is null or jsonb_typeof(c) <> 'object' then return new; end if;
  if tg_op = 'UPDATE' then
    o := coalesce(old.raw_user_meta_data, '{}'::jsonb) -> 'consent';
    if o is not distinct from c then return new; end if;
  end if;
  insert into public.consents (owner, v, age, guardian, by, told_at)
  values (new.id, left(coalesce(c ->> 'v', ''), 20), left(coalesce(c ->> 'age', ''), 10),
          left(coalesce(c ->> 'guardian', ''), 80), left(coalesce(c ->> 'by', ''), 10), left(coalesce(c ->> 'at', ''), 40));
  return new;
end $$;
revoke all on function public.consent_keep() from public, anon, authenticated;

drop trigger if exists consent_keep on auth.users;
create trigger consent_keep after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.consent_keep();

-- the agreements of the signed-in account, newest first
create or replace function public.my_consents()
returns table (at timestamptz, v text, age text, guardian text, by text)
language sql stable security definer set search_path = public as $$
  select c.at, c.v, c.age, c.guardian, c.by from public.consents c where c.owner = auth.uid() order by c.at desc, c.id desc
$$;
revoke all on function public.my_consents() from public, anon;
grant execute on function public.my_consents() to authenticated;

-- an account made before this file: the agreement it already sent is copied once, with the time it was run
insert into public.consents (owner, v, age, guardian, by, told_at)
select u.id, left(coalesce(u.raw_user_meta_data -> 'consent' ->> 'v', ''), 20), left(coalesce(u.raw_user_meta_data -> 'consent' ->> 'age', ''), 10),
       left(coalesce(u.raw_user_meta_data -> 'consent' ->> 'guardian', ''), 80), left(coalesce(u.raw_user_meta_data -> 'consent' ->> 'by', ''), 10),
       left(coalesce(u.raw_user_meta_data -> 'consent' ->> 'at', ''), 40)
from auth.users u
where jsonb_typeof(u.raw_user_meta_data -> 'consent') = 'object'
  and not exists (select 1 from public.consents c where c.owner = u.id);

commit;
