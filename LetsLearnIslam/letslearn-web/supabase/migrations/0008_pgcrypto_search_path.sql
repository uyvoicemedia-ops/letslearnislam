-- On Supabase, pgcrypto lives in the "extensions" schema, so functions that
-- pin search_path = public, pg_temp cannot see crypt() or gen_salt().
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and (p.prosrc ilike '%crypt(%' or p.prosrc ilike '%gen_salt%')
  loop
    execute format(
      'alter function %s set search_path = public, extensions, pg_temp', f.sig);
  end loop;
end $$;
