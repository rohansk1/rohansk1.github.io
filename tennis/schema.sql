-- Tennis League — Supabase schema (v2)
-- Adds: one-step match logging (ELO applies immediately), opt-in masked contact
-- sharing, and an email whitelist for signups.
--
-- Run in the Supabase SQL Editor. It recreates the public tables (they're empty),
-- so nothing real is lost. Your login (auth.users) is untouched — if you'd already
-- set a name, just re-enter it once.
--
-- Security model:
--   * RLS everywhere; access opened only via explicit grants.
--   * Public (logged-out) sees leaderboard + match history, never phone/email.
--   * Members NEVER read phone/email directly; only through the `players` view,
--     which reveals a person's contact only if THAT person opted to share it
--     (you always see your own).
--   * elo/wins/losses change only via the match triggers (server-side).
--   * Only whitelisted emails can create an account.

-- ---------- reset ----------
drop view     if exists public.players cascade;
drop table    if exists public.matches cascade;
drop table    if exists public.profiles cascade;
drop table    if exists public.join_requests cascade;
drop function if exists public.apply_match_elo() cascade;
drop function if exists public.apply_match_elo_insert() cascade;
drop function if exists public.reverse_match_elo_delete() cascade;
drop function if exists public.enforce_email_allowlist() cascade;

-- ---------- profiles ----------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text,
  phone       text,
  email       text,
  share_phone boolean not null default false,
  share_email boolean not null default false,
  elo         integer not null default 1200,
  wins        integer not null default 0,
  losses      integer not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

-- Only leaderboard columns are directly readable; phone/email are NOT (view only).
grant select (id, name, elo, wins, losses) on public.profiles to anon, authenticated;
grant insert (id, name, phone, email, share_phone, share_email) on public.profiles to authenticated;
grant update (name, phone, email, share_phone, share_email) on public.profiles to authenticated;

create policy "Anyone can view profiles"
  on public.profiles for select using (true);
create policy "Users can insert their own profile"
  on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "Users can update their own profile"
  on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- ---------- players view (masked contact) ----------
-- Logged-in members only. You always see your own contact; you see someone else's
-- phone/email only if they turned sharing on. Runs with definer rights so it can
-- read the protected columns and mask them.
create view public.players
with (security_invoker = off) as
  select
    id, name, elo, wins, losses,
    (id = auth.uid()) as is_me,
    share_phone,
    share_email,
    case when id = auth.uid() or share_phone then phone end as phone,
    case when id = auth.uid() or share_email then email end as email
  from public.profiles
  where name is not null;

revoke all on public.players from anon, authenticated;
grant select on public.players to authenticated;

-- ---------- matches ----------
create table public.matches (
  id             bigint generated always as identity primary key,
  player_a       uuid not null references public.profiles(id) on delete cascade,
  player_b       uuid not null references public.profiles(id) on delete cascade,
  winner         uuid not null references public.profiles(id),
  sets           jsonb    not null,
  sets_a         smallint not null,
  sets_b         smallint not null,
  counts_for_elo boolean  not null default true,
  notes          text,
  played_on      date     not null default current_date,
  logged_by      uuid     not null references public.profiles(id),
  elo_a_before   integer,
  elo_b_before   integer,
  elo_a_after    integer,
  elo_b_after    integer,
  created_at     timestamptz not null default now(),
  constraint distinct_players check (player_a <> player_b),
  constraint winner_is_player check (winner in (player_a, player_b)),
  constraint winner_won_more check ((winner = player_a and sets_a > sets_b) or (winner = player_b and sets_b > sets_a))
);

alter table public.matches enable row level security;
revoke all on public.matches from anon, authenticated;

grant select on public.matches to anon, authenticated;
grant insert (player_a, player_b, winner, sets, sets_a, sets_b, counts_for_elo, notes, played_on, logged_by) on public.matches to authenticated;
grant delete on public.matches to authenticated;

create policy "Anyone can view matches"
  on public.matches for select using (true);
create policy "Players can log a match they were in"
  on public.matches for insert to authenticated
  with check (logged_by = auth.uid() and auth.uid() in (player_a, player_b));
create policy "The logger can delete their match"
  on public.matches for delete to authenticated
  using (logged_by = auth.uid());

-- ---------- ELO: applied on log, reversed on delete ----------
create function public.apply_match_elo_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare k constant integer := 32; ra integer; rb integer; ea numeric; sa numeric;
begin
  if new.counts_for_elo then
    select elo into ra from public.profiles where id = new.player_a;
    select elo into rb from public.profiles where id = new.player_b;
    ea := 1.0 / (1.0 + power(10, (rb - ra) / 400.0));
    sa := case when new.winner = new.player_a then 1 else 0 end;
    new.elo_a_before := ra;
    new.elo_b_before := rb;
    new.elo_a_after := round(ra + k * (sa - ea))::int;
    new.elo_b_after := round(rb + k * ((1 - sa) - (1 - ea)))::int;
    update public.profiles set elo = new.elo_a_after, wins = wins + sa::int,       losses = losses + (1 - sa)::int where id = new.player_a;
    update public.profiles set elo = new.elo_b_after, wins = wins + (1 - sa)::int,  losses = losses + sa::int       where id = new.player_b;
  end if;
  return new;
end $$;

create trigger trg_match_elo_insert
  before insert on public.matches
  for each row execute function public.apply_match_elo_insert();

create function public.reverse_match_elo_delete()
returns trigger language plpgsql security definer set search_path = public as $$
declare sa numeric;
begin
  if old.counts_for_elo and old.elo_a_after is not null then
    sa := case when old.winner = old.player_a then 1 else 0 end;
    update public.profiles
      set elo = elo - (old.elo_a_after - old.elo_a_before), wins = wins - sa::int,      losses = losses - (1 - sa)::int
      where id = old.player_a;
    update public.profiles
      set elo = elo - (old.elo_b_after - old.elo_b_before), wins = wins - (1 - sa)::int, losses = losses - sa::int
      where id = old.player_b;
  end if;
  return old;
end $$;

create trigger trg_match_elo_delete
  before delete on public.matches
  for each row execute function public.reverse_match_elo_delete();

-- ---------- email whitelist ----------
create table public.allowed_emails (
  email    text primary key,
  added_at timestamptz not null default now()
);
alter table public.allowed_emails enable row level security;
revoke all on public.allowed_emails from anon, authenticated;

create function public.enforce_email_allowlist()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.allowed_emails where lower(email) = lower(new.email)) then
    raise exception 'This email is not approved for the league.';
  end if;
  return new;
end $$;

drop trigger if exists trg_enforce_email_allowlist on auth.users;
create trigger trg_enforce_email_allowlist
  before insert on auth.users
  for each row execute function public.enforce_email_allowlist();

-- Seed the whitelist — ADD YOUR PLAYERS HERE (include your own email!).
insert into public.allowed_emails (email) values
  ('rohankumar8551@gmail.com')
on conflict (email) do nothing;

-- ---------- access requests (self-service "request to join") ----------
-- A not-yet-approved person can submit their email; the league-access Edge Function
-- emails Rohan an approve link. Only the server (service role) can read this table.
create table public.join_requests (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  token      uuid not null default gen_random_uuid(),
  status     text not null default 'pending',
  created_at timestamptz not null default now()
);
alter table public.join_requests enable row level security;
revoke all on public.join_requests from anon, authenticated;
grant insert (email) on public.join_requests to anon, authenticated;
create policy "Anyone can request access"
  on public.join_requests for insert to anon, authenticated with check (true);
