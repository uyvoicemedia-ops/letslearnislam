-- ============================================================
-- LetsLearn — one more kind of coin entry (own file: see 0022 for why)
--   salah  the small reward for ticking a prayer (honour system, so it
--          counts towards the same daily ceiling as practice)
-- ============================================================
alter type point_source add value if not exists 'salah';
