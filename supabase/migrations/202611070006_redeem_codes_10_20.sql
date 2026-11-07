-- ATIMEX redeem codes: allow existing ৳50 rewards and new ৳10/৳20 rewards.
-- Existing codes are preserved.

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
    CHECK (reward_amount IN (10, 20, 50));

INSERT INTO public.giveaway_codes (code, reward_amount)
VALUES
    ('ATIMEX-GW-10-TQHEOFE1', 10),
    ('ATIMEX-GW-10-EUYSDHPK', 10),
    ('ATIMEX-GW-10-4E7X85TI', 10),
    ('ATIMEX-GW-10-66TKRXAW', 10),
    ('ATIMEX-GW-10-V8OYA6VP', 10),
    ('ATIMEX-GW-10-EILU6L3P', 10),
    ('ATIMEX-GW-10-XVRRZWC9', 10),
    ('ATIMEX-GW-10-7PU4CLC6', 10),
    ('ATIMEX-GW-10-6K35OFE0', 10),
    ('ATIMEX-GW-10-O1Y408CC', 10),
    ('ATIMEX-GW-20-5J7E186V', 20),
    ('ATIMEX-GW-20-ZP7TEOKU', 20),
    ('ATIMEX-GW-20-BH6M9GR5', 20),
    ('ATIMEX-GW-20-B4UK7RL9', 20),
    ('ATIMEX-GW-20-LQVBBQM4', 20),
    ('ATIMEX-GW-20-M56Y7L6K', 20),
    ('ATIMEX-GW-20-2YK0QD1V', 20),
    ('ATIMEX-GW-20-BU59XY7K', 20),
    ('ATIMEX-GW-20-JDTXB0DF', 20),
    ('ATIMEX-GW-20-RQSFB2V3', 20)
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.redeem_giveaway_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id uuid;
    v_amount integer;
    v_profile public.profiles;
    v_balance numeric;
    v_new_balance numeric;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Login required.');
    END IF;

    IF COALESCE(TRIM(p_code), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'Secret code দিন।');
    END IF;

    UPDATE public.giveaway_codes
    SET is_redeemed = true,
        redeemed_by = v_user_id,
        redeemed_at = NOW()
    WHERE UPPER(code) = UPPER(TRIM(p_code))
      AND is_redeemed = false
    RETURNING reward_amount INTO v_amount;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Code valid নয় অথবা আগে ব্যবহার হয়েছে।'
        );
    END IF;

    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found.';
    END IF;

    v_balance := COALESCE(
        NULLIF(v_profile.app_data #>> '{progressData,balance}', '')::numeric,
        v_profile.balance,
        0
    );
    v_new_balance := v_balance + v_amount;

    UPDATE public.profiles
    SET
        balance = v_new_balance,
        app_data = jsonb_set(
            COALESCE(app_data, '{}'::jsonb),
            '{progressData}',
            COALESCE(app_data->'progressData', '{}'::jsonb)
                || jsonb_build_object('balance', v_new_balance),
            true
        ),
        updated_at = NOW()
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'amount', v_amount,
        'balance', v_new_balance
    );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.redeem_giveaway_code(text) TO authenticated;
