-- Orders the team takes on a phone call (New phone order) are logged in Phone orders too.
alter table public.order_requests drop constraint if exists order_requests_kind_check;
alter table public.order_requests add constraint order_requests_kind_check check (kind in ('voice', 'callback', 'call'));
