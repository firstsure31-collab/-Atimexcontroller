-- ATIMEX: add five one-time ৳30 redeem codes.
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
    CHECK (reward_amount IN (10, 20, 30, 50, 100));

INSERT INTO public.giveaway_codes (code, reward_amount)
VALUES
    ('ATX30-Q8M4-K2WP', 30),
    ('ATX30-N6R9-V3CX', 30),
    ('ATX30-H2T7-P5LA', 30),
    ('ATX30-W4J8-D9KF', 30),
    ('ATX30-B7Y3-X6NZ', 30)
ON CONFLICT (code) DO NOTHING;
