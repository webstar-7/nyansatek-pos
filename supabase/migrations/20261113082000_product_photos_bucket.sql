-- Product photos: public to view, each shop writes only to its own folder (<org_id>/...)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy product_photos_read on storage.objects for select
  using (bucket_id = 'product-photos');
create policy product_photos_shop_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos' and (storage.foldername(name))[1] = public.current_org_id()::text);
create policy product_photos_shop_update on storage.objects for update to authenticated
  using (bucket_id = 'product-photos' and (storage.foldername(name))[1] = public.current_org_id()::text)
  with check (bucket_id = 'product-photos' and (storage.foldername(name))[1] = public.current_org_id()::text);
create policy product_photos_shop_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos' and (storage.foldername(name))[1] = public.current_org_id()::text);
