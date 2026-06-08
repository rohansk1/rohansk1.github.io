-- Tennis League — Supabase schema
-- Run in the Supabase SQL Editor. Safe to re-run (drops first); destroys existing data.
-- Backend for tennis/index.html. Project: ggebhuxjelhqhjtkvhkl.supabase.co
--
-- Security model:
--   * RLS on everywhere; access opened explicitly via column-level grants.
--   * Public (anon) can read the leaderboard columns + match history, but NOT phone/email.
--   * Players can only edit their own name/phone/email — never their own elo/wins/losses.
--   * elo/wins/losses change ONLY via the apply_match_elo() trigger (server-side), when a
--     ranked match is confirmed by the opponent.

drop table if exists public.matches cascade;
drop table if exists public.profiles cascade;
drop function if exists public.apply_match_elo() cascade;

-- PROFILES
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  name       text,
  phone      text,
  email      text,
  elo        integer     not null default 1200,
  wins       integer     not null default 0,
  losses     integer     not null default 0,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;

grant select (id, name, elo, wins, losses) on public.profiles to anon;
grant select (id, name, phone, email, elo, wins, losses) on public.profiles to authenticated;
grant insert (id, name, phone, email) on public.profiles to authenticated;
grant update (name, phone, email) on public.profiles to authenticated;

create policy "Anyone can view profiles"
  on public.profiles for select using (true);
create policy "Users can insert their own profile"
  on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "Users can update their own profile"
  on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- MATCHES
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
  status         text     not null default 'pending',
  played_on      date     not null default current_date,
  logged_by      uuid     not null references public.profiles(id),
  confirmed_by   uuid     references public.profiles(id),
  elo_a_before   integer,
  elo_b_before   integer,
  elo_a_after    integer,
  elo_b_after    integer,
  created_at     timestamptz not null default now(),
  constraint distinct_players check (player_a <> player_b),
  constraint winner_is_player check (winner in (player_a, player_b)),
  constraint winner_won_more check ((winner = player_a and sets_a > sets_b) or (winner = player_b and sets_b > sets_a)),
  constraint valid_status check (status in ('pending','confirmed','disputed'))
);

alter table public.matches enable row level security;
revoke all on public.matches from anon, authenticated;

grant select on public.matches to anon, authenticated;
create policy "Anyone can view matches"
  on public.matches for select using (true);

grant insert (player_a, player_b, winner, sets, sets_a, sets_b, counts_for_elo, notes, played_on, logged_by) on public.matches to authenticated;
create policy "Players can log their own matches"
  on public.matches for insert to authenticated
  with check (logged_by = auth.uid() and auth.uid() in (player_a, player_b));

grant update (status, confirmed_by) on public.matches to authenticated;
create policy "Opponent can confirm a pending match"
  on public.matches for update to authenticated
  using (status = 'pending' and auth.uid() = case when logged_by = player_a then player_b else player_a end)
  with check (status in ('confirmed','disputed') and confirmed_by = auth.uid());

-- ELO (standard Elo, K=32, start 1200; applied when a ranked match is confirmed)
create or replace function public.apply_match_elo()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k constant integer := 32;
  ra integer; rb integer; ea numeric; sa numeric;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' and new.counts_for_elo then
    select elo into ra from public.profiles where id = new.player_a;
    select elo into rb from public.profiles where id = new.player_b;
    ea := 1.0 / (1.0 + power(10, (rb - ra) / 400.0));
    sa := case when new.winner = new.player_a then 1 else 0 end;
    new.elo_a_before := ra;
    new.elo_b_before := rb;
    new.elo_a_after := round(ra + k * (sa - ea))::int;
    new.elo_b_after := round(rb + k * ((1 - sa) - (1 - ea)))::int;
    update public.profiles set elo = new.elo_a_after, wins = wins + sa::int, losses = losses + (1 - sa)::int where id = new.player_a;
    update public.profiles set elo = new.elo_b_after, wins = wins + (1 - sa)::int, losses = losses + sa::int where id = new.player_b;
  end if;
  return new;
end $$;

create trigger trg_apply_match_elo
  before update on public.matches
  for each row execute function public.apply_match_elo();
