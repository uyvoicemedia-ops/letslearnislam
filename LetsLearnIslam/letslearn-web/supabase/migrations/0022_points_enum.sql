-- ============================================================
-- LetsLearn — new kinds of coin entry (part 1 of the coin ledger)
-- ------------------------------------------------------------
-- Adds the four kinds the server-held coin ledger needs. It is a file of
-- its own because Postgres will not let a value added to an enum be USED
-- until the statement that added it has committed, and the Supabase SQL
-- editor runs a pasted file as one transaction. 0023 uses them.
--
--   welcome  the coins a child is given on joining a class
--   mission  a small daily task, validated by the server
--   spend    coins paid for something in the garden (a NEGATIVE entry)
--   refund   half of a spend given back when something is sold
-- ============================================================
alter type point_source add value if not exists 'welcome';
alter type point_source add value if not exists 'mission';
alter type point_source add value if not exists 'spend';
alter type point_source add value if not exists 'refund';
