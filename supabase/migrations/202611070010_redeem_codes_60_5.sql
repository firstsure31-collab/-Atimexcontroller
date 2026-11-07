-- ATIMEX: add five one-time ৳60 redeem codes.
-- Existing redeem codes and redemption history are preserved.

DO $$
DECLARE
    v_constraint record;
BEGIN
    FOR v_constraint IN
        SELECT conname
        FROM pg_constraint
        WHERE conrelid = 'public.giveaway_codes'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) ILIKE '%reward_amount%'
    LOOP
        EXECUTE format('ALTER TABLE public.giveaway_codes DROP CONSTRAINT %I', v_constraint.conname);
    END LOOP;
END;
$$;

ALTER TABLE public.giveaway_codes
    ADD CONSTRAINT giveaway_codes_reward_amount_allowed_check
    CHECK (reward_amount IN (10, 20, 30, 50, 60, 100));

INSERT INTO public.giveaway_codes (code, reward_amount)
VALUES
    ('ATX60-R8K3-M2WP', 60),
    ('ATX60-N5V9-C4XJ', 60),
    ('ATX60-H7Q2-P6LA', 60),
    ('ATX60-W3J8-D9KF', 60),
    ('ATX60-B6Y4-X1NZ', 60)
ON CONFLICT (code) DO NOTHING;
