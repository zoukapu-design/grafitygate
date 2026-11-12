-- テスト用：Lyric Path と共有している表（profiles・follows・lp_blocks）の、gf_ が読む部分だけ。
-- 本物は Lyric Path 側の SQL で作られている。ここでは形をそろえるだけ。

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 30),
  handle text not null unique,
  created_at timestamptz not null default now()
);
create table public.follows (
  follower uuid not null references public.profiles(id) on delete cascade,
  followee uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followee),
  check (follower <> followee)
);
create table public.lp_blocks (
  blocker uuid not null references public.profiles(id) on delete cascade,
  blocked uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.profiles enable row level security;
alter table public.follows enable row level security;
alter table public.lp_blocks enable row level security;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
create policy "follows readable" on public.follows for select to authenticated using (true);
create policy "blocks own read" on public.lp_blocks for select to authenticated using (blocker = auth.uid());
