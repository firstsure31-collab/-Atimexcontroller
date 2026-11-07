-- ATIMEX: add ten one-time ৳100 redeem codes.
-- Existing ৳10/৳20/৳50 codes and redemption history are preserved.

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
    CHECK (reward_amount IN (10, 20, 50, 100));

INSERT INTO public.giveaway_codes (code, reward_amount)
VALUES
    ('ATX100-K7Q9-M4XP', 100),
    ('ATX100-V2N8-R6JW', 100),
    ('ATX100-H5C3-Z9TA', 100),
    ('ATX100-P8Y4-D2LK', 100),
    ('ATX100-W6F1-Q7NB', 100),
    ('ATX100-M9R2-X5CE', 100),
    ('ATX100-B4T7-K8VP', 100),
    ('ATX100-J3L6-W1QZ', 100),
    ('ATX100-C9X5-N2HF', 100),
    ('ATX100-R7P4-A6DM', 100)
ON CONFLICT (code) DO NOTHING;
