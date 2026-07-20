-- =============================================================================
-- COMPLETE E-COMMERCE FUNCTION CATALOG (CORRECTED)
-- =============================================================================

-- =============================================================================
-- CART FUNCTIONS
-- =============================================================================

-- 1. cart_get
CREATE OR REPLACE FUNCTION cart_get(
    p_user_id uuid DEFAULT NULL,
    p_session_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'cart_id', c.id,
    'items', COALESCE(jsonb_agg(
      jsonb_build_object(
        'cart_item_id', ci.id,
        'quantity', ci.quantity,
        'variant', jsonb_build_object(
          'id', pv.id,
          'sku', pv.sku,
          'price', pv.price,
          'compare_at_price', pv.compare_at_price,
          'attributes', pv.attributes,
          'stock', pv.stock_quantity,
          'image', (
            SELECT pi.url FROM product_images pi
            WHERE pi.product_id = pv.product_id
            ORDER BY pi.sort_order LIMIT 1
          )
        ),
        'product', jsonb_build_object(
          'id', p.id,
          'name', p.name,
          'slug', p.slug
        ),
        'added_at', ci.added_at
      )
      ORDER BY ci.added_at
    ), '[]'::jsonb)
  )
  FROM carts c
  LEFT JOIN cart_items ci ON ci.cart_id = c.id
  LEFT JOIN product_variants pv ON pv.id = ci.variant_id
  LEFT JOIN products p ON p.id = pv.product_id
  WHERE (p_user_id IS NOT NULL AND c.user_id = p_user_id)
     OR (p_session_id IS NOT NULL AND c.session_id = p_session_id)
  GROUP BY c.id;
$$;

-- 2. cart_add_item (fixed – no defaults before required params)
CREATE OR REPLACE FUNCTION cart_add_item(
    p_user_id uuid,
    p_session_id text,
    p_variant_id uuid,
    p_quantity int
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_cart_id uuid;
    v_stock int;
    v_item_id uuid;
BEGIN
    -- Identify or create cart
    SELECT id INTO v_cart_id FROM carts
    WHERE (p_user_id IS NOT NULL AND user_id = p_user_id)
       OR (p_session_id IS NOT NULL AND session_id = p_session_id);

    IF v_cart_id IS NULL THEN
        INSERT INTO carts (user_id, session_id)
        VALUES (p_user_id, p_session_id)
        RETURNING id INTO v_cart_id;
    END IF;

    -- Check available stock (excluding expired reservations)
    SELECT pv.stock_quantity - COALESCE(SUM(cr.quantity), 0)
    INTO v_stock
    FROM product_variants pv
    LEFT JOIN cart_reservations cr ON cr.variant_id = pv.id AND cr.expires_at > now()
    WHERE pv.id = p_variant_id
    GROUP BY pv.stock_quantity;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Available: %', v_stock;
    END IF;

    -- If already in cart, increase quantity
    SELECT id INTO v_item_id FROM cart_items
    WHERE cart_id = v_cart_id AND variant_id = p_variant_id;

    IF v_item_id IS NOT NULL THEN
        UPDATE cart_items SET quantity = quantity + p_quantity WHERE id = v_item_id;
        UPDATE cart_reservations
        SET quantity = quantity + p_quantity,
            expires_at = now() + interval '15 minutes'
        WHERE cart_id = v_cart_id AND variant_id = p_variant_id;
    ELSE
        INSERT INTO cart_items (cart_id, variant_id, quantity)
        VALUES (v_cart_id, p_variant_id, p_quantity)
        RETURNING id INTO v_item_id;

        INSERT INTO cart_reservations (cart_id, variant_id, quantity, expires_at)
        VALUES (v_cart_id, p_variant_id, p_quantity, now() + interval '15 minutes');
    END IF;

    RETURN cart_get(p_user_id, p_session_id);
END;
$$;

-- 3. cart_update_quantity
CREATE OR REPLACE FUNCTION cart_update_quantity(
    p_cart_item_id uuid,
    p_quantity int
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_variant_id uuid;
    v_cart_id uuid;
    v_user_id uuid;
    v_session_id text;
    v_stock int;
BEGIN
    SELECT ci.variant_id, ci.cart_id
    INTO v_variant_id, v_cart_id
    FROM cart_items ci WHERE ci.id = p_cart_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cart item not found';
    END IF;

    SELECT c.user_id, c.session_id INTO v_user_id, v_session_id
    FROM carts c WHERE c.id = v_cart_id;

    IF p_quantity <= 0 THEN
        PERFORM cart_remove_item(p_cart_item_id);
        RETURN cart_get(v_user_id, v_session_id);
    END IF;

    SELECT pv.stock_quantity - COALESCE(SUM(cr.quantity), 0)
    INTO v_stock
    FROM product_variants pv
    LEFT JOIN cart_reservations cr ON cr.variant_id = pv.id AND cr.expires_at > now()
    WHERE pv.id = v_variant_id
    GROUP BY pv.stock_quantity;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Available: %', v_stock;
    END IF;

    UPDATE cart_items SET quantity = p_quantity WHERE id = p_cart_item_id;
    UPDATE cart_reservations
    SET quantity = p_quantity,
        expires_at = now() + interval '15 minutes'
    WHERE cart_id = v_cart_id AND variant_id = v_variant_id;

    RETURN cart_get(v_user_id, v_session_id);
END;
$$;

-- 4. cart_remove_item
CREATE OR REPLACE FUNCTION cart_remove_item(p_cart_item_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_cart_id uuid;
    v_variant_id uuid;
BEGIN
    SELECT cart_id, variant_id INTO v_cart_id, v_variant_id
    FROM cart_items WHERE id = p_cart_item_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cart item not found';
    END IF;

    DELETE FROM cart_reservations
    WHERE cart_id = v_cart_id AND variant_id = v_variant_id;

    DELETE FROM cart_items WHERE id = p_cart_item_id;
END;
$$;

-- 5. cart_merge (rewritten to avoid missing unique constraint)
CREATE OR REPLACE FUNCTION cart_merge(
    p_user_id uuid,
    p_session_id text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_session_cart_id uuid;
    v_user_cart_id uuid;
    v_item record;
BEGIN
    SELECT id INTO v_session_cart_id FROM carts WHERE session_id = p_session_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT id INTO v_user_cart_id FROM carts WHERE user_id = p_user_id;

    -- No user cart? Just reassign the session cart.
    IF v_user_cart_id IS NULL THEN
        UPDATE carts SET user_id = p_user_id, session_id = NULL
        WHERE id = v_session_cart_id;
        RETURN;
    END IF;

    -- For each item in the session cart, merge into user cart
    FOR v_item IN SELECT * FROM cart_items WHERE cart_id = v_session_cart_id LOOP
        -- Update if same variant exists, else insert
        UPDATE cart_items
        SET quantity = quantity + v_item.quantity
        WHERE cart_id = v_user_cart_id AND variant_id = v_item.variant_id;

        IF NOT FOUND THEN
            INSERT INTO cart_items (cart_id, variant_id, quantity)
            VALUES (v_user_cart_id, v_item.variant_id, v_item.quantity);
        END IF;

        -- Move reservations to user cart
        UPDATE cart_reservations
        SET cart_id = v_user_cart_id
        WHERE cart_id = v_session_cart_id AND variant_id = v_item.variant_id;
    END LOOP;

    DELETE FROM cart_items WHERE cart_id = v_session_cart_id;
    DELETE FROM carts WHERE id = v_session_cart_id;
END;
$$;

-- =============================================================================
-- CHECKOUT & ORDERS
-- =============================================================================

-- 6. checkout_preview
CREATE OR REPLACE FUNCTION checkout_preview(
    p_user_id uuid,
    p_shipping_address_id uuid,
    p_coupon_code text DEFAULT NULL,
    p_shipping_method_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_cart_id uuid;
    v_subtotal numeric;
    v_shipping_cost numeric := 0;
    v_discount_total numeric := 0;
    v_tax_rate numeric;
    v_tax_amount numeric;
    v_total numeric;
    v_coupon jsonb;
    v_offer jsonb;
    v_shipping_addr jsonb;
BEGIN
    SELECT id INTO v_cart_id FROM carts WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No cart found';
    END IF;

    SELECT COALESCE(SUM(pv.price * ci.quantity), 0)
    INTO v_subtotal
    FROM cart_items ci
    JOIN product_variants pv ON pv.id = ci.variant_id
    WHERE ci.cart_id = v_cart_id;

    v_offer := offer_best(v_subtotal, NULL, p_user_id);

    IF p_coupon_code IS NOT NULL THEN
        v_coupon := coupon_validate(p_coupon_code, v_subtotal, p_user_id);
        IF v_coupon IS NOT NULL AND v_coupon->>'valid' = 'true' THEN
            v_discount_total := COALESCE((v_coupon->>'discount')::numeric, 0);
        END IF;
    ELSIF v_offer IS NOT NULL THEN
        v_discount_total := COALESCE((v_offer->>'discount')::numeric, 0);
    END IF;

    IF p_shipping_method_id IS NOT NULL THEN
        SELECT base_cost INTO v_shipping_cost
        FROM shipping_methods WHERE id = p_shipping_method_id AND is_active = true;
    END IF;

    SELECT rate INTO v_tax_rate FROM tax_rates WHERE is_active = true LIMIT 1;
    IF v_tax_rate IS NULL THEN v_tax_rate := 0; END IF;

    v_tax_amount := round(((v_subtotal - v_discount_total + v_shipping_cost) * v_tax_rate / 100)::numeric, 2);
    v_total := v_subtotal - v_discount_total + v_shipping_cost + v_tax_amount;

    SELECT row_to_json(sa.*) INTO v_shipping_addr
    FROM shipping_addresses sa
    WHERE sa.id = p_shipping_address_id AND sa.user_id = p_user_id;

    RETURN jsonb_build_object(
        'subtotal', v_subtotal,
        'shipping_cost', v_shipping_cost,
        'discount_total', v_discount_total,
        'coupon_applied', v_coupon,
        'offer_applied', v_offer,
        'tax_rate', v_tax_rate,
        'tax_amount', v_tax_amount,
        'total', v_total,
        'shipping_address', v_shipping_addr
    );
END;
$$;

-- 7. checkout_create_order
CREATE OR REPLACE FUNCTION checkout_create_order(
    p_user_id uuid,
    p_shipping_address_id uuid,
    p_coupon_code text DEFAULT NULL,
    p_shipping_method_id uuid DEFAULT NULL,
    p_payment_method text DEFAULT 'card'
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_cart_id uuid;
    v_subtotal numeric;
    v_shipping_cost numeric := 0;
    v_discount_total numeric := 0;
    v_tax_rate numeric;
    v_tax_amount numeric;
    v_total numeric;
    v_order_id uuid;
    v_coupon jsonb;
    v_offer jsonb;
    v_shipping_addr jsonb;
    v_tax_rate_id uuid;
    v_item record;
    v_taxable_value numeric;
    v_item_tax numeric;
    v_cgst numeric := 0;
    v_sgst numeric := 0;
    v_igst numeric := 0;
BEGIN
    -- Lock cart row
    SELECT id INTO v_cart_id FROM carts WHERE user_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No cart found';
    END IF;

    SELECT COALESCE(SUM(pv.price * ci.quantity), 0)
    INTO v_subtotal
    FROM cart_items ci
    JOIN product_variants pv ON pv.id = ci.variant_id
    WHERE ci.cart_id = v_cart_id;

    v_offer := offer_best(v_subtotal, NULL, p_user_id);
    IF p_coupon_code IS NOT NULL THEN
        v_coupon := coupon_validate(p_coupon_code, v_subtotal, p_user_id);
        IF v_coupon IS NOT NULL AND v_coupon->>'valid' = 'true' THEN
            v_discount_total := COALESCE((v_coupon->>'discount')::numeric, 0);
        END IF;
    ELSIF v_offer IS NOT NULL THEN
        v_discount_total := COALESCE((v_offer->>'discount')::numeric, 0);
    END IF;

    IF p_shipping_method_id IS NOT NULL THEN
        SELECT base_cost INTO v_shipping_cost
        FROM shipping_methods WHERE id = p_shipping_method_id AND is_active = true;
    END IF;

    SELECT id, rate INTO v_tax_rate_id, v_tax_rate
    FROM tax_rates WHERE is_active = true LIMIT 1;
    IF v_tax_rate IS NULL THEN v_tax_rate := 0; END IF;

    v_tax_amount := round(((v_subtotal - v_discount_total + v_shipping_cost) * v_tax_rate / 100)::numeric, 2);
    v_total := v_subtotal - v_discount_total + v_shipping_cost + v_tax_amount;

    SELECT row_to_json(sa.*) INTO v_shipping_addr
    FROM shipping_addresses sa
    WHERE sa.id = p_shipping_address_id AND sa.user_id = p_user_id;
    IF v_shipping_addr IS NULL THEN
        RAISE EXCEPTION 'Invalid shipping address';
    END IF;

    INSERT INTO orders (
        user_id, status, total_amount, subtotal, shipping_cost, tax_amount,
        discount_total, coupon_code, tax_rate_id, shipping_method_id,
        shipping_address, payment_status, notes
    ) VALUES (
        p_user_id, 'pending', v_total, v_subtotal, v_shipping_cost, v_tax_amount,
        v_discount_total, p_coupon_code, v_tax_rate_id, p_shipping_method_id,
        v_shipping_addr, 'pending', ''
    )
    RETURNING id INTO v_order_id;

    -- Insert order items & deduct stock
    FOR v_item IN
        SELECT ci.variant_id, ci.quantity, pv.price, pv.hsn_code, p.seller_id,
               p.name AS product_name, pv.attributes
        FROM cart_items ci
        JOIN product_variants pv ON pv.id = ci.variant_id
        JOIN products p ON p.id = pv.product_id
        WHERE ci.cart_id = v_cart_id
    LOOP
        v_taxable_value := v_item.price * v_item.quantity;
        v_item_tax := round((v_taxable_value * v_tax_rate / 100)::numeric, 2);
        -- Simplification: treat all as IGST (inter‑state)
        v_igst := v_item_tax;
        v_cgst := 0;
        v_sgst := 0;

        INSERT INTO order_items (
            order_id, variant_id, product_name, variant_attributes,
            price, quantity, total, seller_id, seller_status,
            hsn_code, tax_rate_percent, taxable_value, tax_amount,
            cgst_amount, sgst_amount, igst_amount
        ) VALUES (
            v_order_id, v_item.variant_id, v_item.product_name, v_item.attributes,
            v_item.price, v_item.quantity, v_taxable_value, v_item.seller_id, 'pending',
            v_item.hsn_code, v_tax_rate, v_taxable_value, v_item_tax,
            v_cgst, v_sgst, v_igst
        );

        UPDATE product_variants
        SET stock_quantity = stock_quantity - v_item.quantity
        WHERE id = v_item.variant_id;
    END LOOP;

    DELETE FROM cart_reservations WHERE cart_id = v_cart_id;
    DELETE FROM cart_items WHERE cart_id = v_cart_id;
    DELETE FROM carts WHERE id = v_cart_id;

    INSERT INTO order_status_history (order_id, status, changed_by)
    VALUES (v_order_id, 'pending', p_user_id);

    INSERT INTO payments (order_id, amount, currency, method, status)
    VALUES (v_order_id, v_total, 'INR', p_payment_method, 'pending');

    RETURN jsonb_build_object('order_id', v_order_id, 'total', v_total);
END;
$$;

-- 8. order_get_by_id
CREATE OR REPLACE FUNCTION order_get_by_id(p_order_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'status', o.status,
    'total_amount', o.total_amount,
    'subtotal', o.subtotal,
    'shipping_cost', o.shipping_cost,
    'tax_amount', o.tax_amount,
    'discount_total', o.discount_total,
    'coupon_code', o.coupon_code,
    'shipping_address', o.shipping_address,
    'payment_status', o.payment_status,
    'created_at', o.created_at,
    'items', (
      SELECT jsonb_agg(jsonb_build_object(
        'product_name', oi.product_name,
        'quantity', oi.quantity,
        'price', oi.price,
        'total', oi.total,
        'variant_attributes', oi.variant_attributes,
        'seller_status', oi.seller_status,
        'hsn', oi.hsn_code,
        'tax_rate', oi.tax_rate_percent,
        'tax_amount', oi.tax_amount,
        'cgst', oi.cgst_amount,
        'sgst', oi.sgst_amount,
        'igst', oi.igst_amount,
        'seller', jsonb_build_object('name', s.store_name, 'id', s.id)
      ))
      FROM order_items oi
      JOIN sellers s ON s.id = oi.seller_id
      WHERE oi.order_id = o.id
    ),
    'status_history', (
      SELECT jsonb_agg(jsonb_build_object(
        'status', sh.status,
        'note', sh.note,
        'changed_at', sh.changed_at
      ) ORDER BY sh.changed_at)
      FROM order_status_history sh
      WHERE sh.order_id = o.id
    ),
    'payments', (
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id,
        'method', p.method,
        'status', p.status,
        'amount', p.amount,
        'gateway_transaction_id', p.gateway_transaction_id
      ))
      FROM payments p
      WHERE p.order_id = o.id
    ),
    'shipments', (
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id,
        'tracking', s.tracking_number,
        'carrier', s.carrier,
        'status', s.status,
        'shipped_at', s.shipped_at,
        'delivered_at', s.delivered_at
      ))
      FROM shipments s
      WHERE s.order_id = o.id
    )
  )
  FROM orders o
  WHERE o.id = p_order_id;
$$;

-- 9. order_list
CREATE OR REPLACE FUNCTION order_list(
    p_user_id uuid,
    p_page int DEFAULT 1,
    p_limit int DEFAULT 10
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH total AS (
    SELECT count(*) AS cnt FROM orders WHERE user_id = p_user_id
  )
  SELECT jsonb_build_object(
    'orders', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'status', o.status,
          'total_amount', o.total_amount,
          'created_at', o.created_at,
          'payment_status', o.payment_status,
          'item_count', (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id)
        )
        ORDER BY o.created_at DESC
      )
      FROM orders o
      WHERE o.user_id = p_user_id
      OFFSET (p_page - 1) * p_limit
      LIMIT p_limit
    ),
    'total', (SELECT cnt FROM total),
    'page', p_page,
    'pages', CEIL((SELECT cnt FROM total)::numeric / p_limit)
  );
$$;

-- 10. order_update_status
CREATE OR REPLACE FUNCTION order_update_status(
    p_order_id uuid,
    p_status text,
    p_note text DEFAULT NULL,
    p_changed_by uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE orders SET status = p_status, updated_at = now()
    WHERE id = p_order_id;

    INSERT INTO order_status_history (order_id, status, note, changed_by)
    VALUES (p_order_id, p_status, p_note, p_changed_by);
END;
$$;

-- 11. order_cancel
CREATE OR REPLACE FUNCTION order_cancel(
    p_order_id uuid,
    p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_order record;
    v_item record;
BEGIN
    SELECT * INTO v_order FROM orders WHERE id = p_order_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order not found or not owned by user';
    END IF;

    IF v_order.status IN ('cancelled', 'delivered', 'refunded') THEN
        RAISE EXCEPTION 'Order cannot be cancelled in its current state';
    END IF;

    FOR v_item IN
        SELECT variant_id, quantity FROM order_items WHERE order_id = p_order_id
    LOOP
        UPDATE product_variants
        SET stock_quantity = stock_quantity + v_item.quantity
        WHERE id = v_item.variant_id;
    END LOOP;

    UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;
    INSERT INTO order_status_history (order_id, status, note, changed_by)
    VALUES (p_order_id, 'cancelled', 'Cancelled by user', p_user_id);

    IF v_order.payment_status = 'paid' THEN
        UPDATE orders SET payment_status = 'refunded' WHERE id = p_order_id;
        UPDATE payments SET status = 'refunded' WHERE order_id = p_order_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

-- =============================================================================
-- PRODUCT FUNCTIONS
-- =============================================================================

-- 12. product_search
CREATE OR REPLACE FUNCTION product_search(
    p_search text DEFAULT NULL,
    p_category_id uuid DEFAULT NULL,
    p_filters jsonb DEFAULT NULL,
    p_sort text DEFAULT 'relevance',
    p_page int DEFAULT 1,
    p_limit int DEFAULT 20
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH filtered AS (
    SELECT p.id, p.name, p.slug, p.base_price, p.description,
           p.category_id, p.is_active,
           (SELECT jsonb_agg(jsonb_build_object(
              'id', pv.id, 'sku', pv.sku, 'price', pv.price,
              'stock', pv.stock_quantity, 'attributes', pv.attributes
            )) FROM product_variants pv WHERE pv.product_id = p.id AND pv.is_active) AS variants,
           (SELECT pi.url FROM product_images pi WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1) AS thumbnail
    FROM products p
    WHERE p.is_active = true
      AND (p_category_id IS NULL OR p.category_id = p_category_id)
      AND (p_search IS NULL OR to_tsvector('english', p.name || ' ' || p.description) @@ plainto_tsquery('english', p_search))
  ),
  total AS (SELECT count(*) AS cnt FROM filtered)
  SELECT jsonb_build_object(
    'products', (SELECT jsonb_agg(f.*) FROM (
      SELECT * FROM filtered
      ORDER BY
        CASE WHEN p_sort = 'price_asc' THEN (SELECT min(price) FROM product_variants WHERE product_id = filtered.id) END ASC,
        CASE WHEN p_sort = 'price_desc' THEN (SELECT min(price) FROM product_variants WHERE product_id = filtered.id) END DESC,
        CASE WHEN p_sort = 'newest' THEN NULL END,
        CASE WHEN p_sort = 'relevance' THEN NULL END
      LIMIT p_limit OFFSET (p_page - 1) * p_limit
    ) f),
    'total', (SELECT cnt FROM total),
    'page', p_page,
    'pages', CEIL((SELECT cnt FROM total)::numeric / p_limit)
  );
$$;

-- 13. product_get_by_slug
CREATE OR REPLACE FUNCTION product_get_by_slug(p_slug text)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'slug', p.slug,
    'description', p.description,
    'base_price', p.base_price,
    'category', (SELECT row_to_json(c.*) FROM categories c WHERE c.id = p.category_id),
    'variants', (
      SELECT jsonb_agg(jsonb_build_object(
        'id', pv.id, 'sku', pv.sku, 'price', pv.price,
        'compare_at_price', pv.compare_at_price,
        'stock', pv.stock_quantity, 'attributes', pv.attributes,
        'hsn_code', pv.hsn_code
      ))
      FROM product_variants pv WHERE pv.product_id = p.id AND pv.is_active
    ),
    'images', (
      SELECT jsonb_agg(jsonb_build_object(
        'url', pi.url, 'alt', pi.alt_text, 'sort_order', pi.sort_order
      ) ORDER BY pi.sort_order)
      FROM product_images pi WHERE pi.product_id = p.id
    ),
    'seller', (
      SELECT jsonb_build_object('store_name', s.store_name, 'is_verified', s.is_verified)
      FROM sellers s WHERE s.id = p.seller_id
    ),
    'reviews', (
      SELECT jsonb_build_object(
        'average_rating', COALESCE(AVG(rating)::numeric, 0),
        'count', COUNT(*)
      )
      FROM reviews r WHERE r.product_id = p.id AND r.is_approved
    )
  )
  FROM products p
  WHERE p.slug = p_slug AND p.is_active = true;
$$;

-- 14. product_variants_by_ids
CREATE OR REPLACE FUNCTION product_variants_by_ids(p_ids uuid[])
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_agg(jsonb_build_object(
    'id', pv.id,
    'sku', pv.sku,
    'price', pv.price,
    'stock', pv.stock_quantity,
    'attributes', pv.attributes,
    'product', jsonb_build_object('id', p.id, 'name', p.name, 'slug', p.slug)
  ))
  FROM product_variants pv
  JOIN products p ON p.id = pv.product_id
  WHERE pv.id = ANY(p_ids);
$$;

-- =============================================================================
-- OFFERS & COUPONS
-- =============================================================================

-- 15. offer_best
CREATE OR REPLACE FUNCTION offer_best(
    p_cart_total numeric,
    p_cart_items jsonb DEFAULT NULL,
    p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'offer_id', o.id,
    'name', o.name,
    'type', o.offer_type,
    'discount',
    CASE o.offer_type
      WHEN 'percentage_discount' THEN round(p_cart_total * o.value / 100, 2)
      WHEN 'fixed_discount' THEN o.value
      ELSE 0
    END
  )
  FROM offers o
  WHERE o.is_active = true
    AND o.auto_apply = true
    AND (o.valid_from IS NULL OR o.valid_from <= now())
    AND (o.valid_until IS NULL OR o.valid_until >= now())
    AND (o.min_order = 0 OR p_cart_total >= o.min_order)
  ORDER BY
    CASE o.offer_type
      WHEN 'percentage_discount' THEN p_cart_total * o.value / 100
      WHEN 'fixed_discount' THEN o.value
      ELSE 0
    END DESC
  LIMIT 1;
$$;

-- 16. coupon_validate
CREATE OR REPLACE FUNCTION coupon_validate(
    p_code text,
    p_cart_total numeric,
    p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_coupon record;
    v_discount numeric;
BEGIN
    SELECT * INTO v_coupon
    FROM coupons
    WHERE code = p_code AND is_active = true;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Coupon not found');
    END IF;

    IF v_coupon.valid_from IS NOT NULL AND v_coupon.valid_from > now() THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Coupon not yet valid');
    END IF;

    IF v_coupon.valid_until IS NOT NULL AND v_coupon.valid_until < now() THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Coupon expired');
    END IF;

    IF v_coupon.max_uses IS NOT NULL AND v_coupon.uses_count >= v_coupon.max_uses THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Coupon usage limit reached');
    END IF;

    IF p_cart_total < v_coupon.min_order_amount THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Minimum order amount not met');
    END IF;

    v_discount := CASE v_coupon.discount_type
        WHEN 'percentage' THEN round(p_cart_total * v_coupon.discount_value / 100, 2)
        WHEN 'fixed' THEN v_coupon.discount_value
        ELSE 0
    END;

    RETURN jsonb_build_object(
        'valid', true,
        'code', v_coupon.code,
        'discount_type', v_coupon.discount_type,
        'discount_value', v_coupon.discount_value,
        'discount', v_discount
    );
END;
$$;

-- =============================================================================
-- USERS & ADDRESSES
-- =============================================================================

-- 17. address_list
-- 17. address_list (fixed)
CREATE OR REPLACE FUNCTION address_list(p_user_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(row_to_json(sa.*) ORDER BY sa.is_default DESC, sa.created_at DESC),
    '[]'::jsonb
  )
  FROM shipping_addresses sa
  WHERE sa.user_id = p_user_id;
$$;

-- 18. address_set_default
CREATE OR REPLACE FUNCTION address_set_default(
    p_address_id uuid,
    p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE shipping_addresses SET is_default = false WHERE user_id = p_user_id;
    UPDATE shipping_addresses SET is_default = true WHERE id = p_address_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Address not found or not owned by user';
    END IF;
END;
$$;

-- 19. profile_get
CREATE OR REPLACE FUNCTION profile_get(p_user_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'profile', row_to_json(p.*),
    'default_address', (
      SELECT row_to_json(sa.*)
      FROM shipping_addresses sa
      WHERE sa.user_id = p_user_id AND sa.is_default = true
      LIMIT 1
    )
  )
  FROM profiles p
  WHERE p.id = p_user_id;
$$;

-- =============================================================================
-- SELLER FUNCTIONS
-- =============================================================================

-- 20. seller_dashboard
CREATE OR REPLACE FUNCTION seller_dashboard(p_seller_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_build_object(
    'total_orders', COUNT(DISTINCT oi.order_id),
    'pending_orders', COUNT(DISTINCT CASE WHEN oi.seller_status = 'pending' THEN oi.order_id END),
    'total_revenue', COALESCE(SUM(oi.total), 0),
    'store_name', (SELECT store_name FROM sellers WHERE id = p_seller_id)
  )
  FROM order_items oi
  WHERE oi.seller_id = p_seller_id;
$$;

-- 21. seller_order_items
-- 21. seller_order_items (fixed)
CREATE OR REPLACE FUNCTION seller_order_items(
    p_seller_id uuid,
    p_status text DEFAULT NULL,
    p_page int DEFAULT 1,
    p_limit int DEFAULT 20
)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH total AS (
    SELECT count(*) AS cnt
    FROM order_items oi
    WHERE oi.seller_id = p_seller_id
      AND (p_status IS NULL OR oi.seller_status = p_status)
  ),
  items_ordered AS (
    SELECT oi.id AS order_item_id,
           oi.order_id,
           oi.product_name,
           oi.quantity,
           oi.price,
           oi.total,
           oi.seller_status,
           oi.variant_attributes,
           o.created_at AS order_date
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    WHERE oi.seller_id = p_seller_id
      AND (p_status IS NULL OR oi.seller_status = p_status)
    ORDER BY o.created_at DESC
    OFFSET (p_page - 1) * p_limit
    LIMIT p_limit
  )
  SELECT jsonb_build_object(
    'items', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'order_item_id', io.order_item_id,
          'order_id', io.order_id,
          'product_name', io.product_name,
          'quantity', io.quantity,
          'price', io.price,
          'total', io.total,
          'seller_status', io.seller_status,
          'variant_attributes', io.variant_attributes,
          'order_date', io.order_date
        )
        ORDER BY io.order_date DESC
      )
      FROM items_ordered io
    ),
    'total', (SELECT cnt FROM total),
    'page', p_page,
    'pages', CEIL((SELECT cnt FROM total)::numeric / p_limit)
  );
$$;

-- 22. seller_update_item_status
CREATE OR REPLACE FUNCTION seller_update_item_status(
    p_order_item_id uuid,
    p_status text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_seller_id uuid;
BEGIN
    SELECT seller_id INTO v_seller_id FROM order_items WHERE id = p_order_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order item not found';
    END IF;

    -- In production, verify that auth.uid() belongs to the seller.
    UPDATE order_items SET seller_status = p_status WHERE id = p_order_item_id;
END;
$$;

-- =============================================================================
-- REVIEWS & WISHLIST
-- =============================================================================

-- 23. review_create
CREATE OR REPLACE FUNCTION review_create(
    p_product_id uuid,
    p_user_id uuid,
    p_order_item_id uuid,
    p_rating int,
    p_title text DEFAULT NULL,
    p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_review_id uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        WHERE oi.id = p_order_item_id
          AND o.user_id = p_user_id
          AND o.status = 'delivered'
    ) THEN
        RAISE EXCEPTION 'You can only review delivered items from your own orders';
    END IF;

    INSERT INTO reviews (product_id, user_id, order_item_id, rating, title, comment)
    VALUES (p_product_id, p_user_id, p_order_item_id, p_rating, p_title, p_comment)
    ON CONFLICT (order_item_id) DO NOTHING
    RETURNING id INTO v_review_id;

    IF v_review_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Review already exists for this item');
    END IF;

    RETURN jsonb_build_object('success', true, 'review_id', v_review_id);
END;
$$;

-- 24. wishlist_add
-- 24. wishlist_add (fixed parameter order)
CREATE OR REPLACE FUNCTION wishlist_add(
    p_user_id uuid,
    p_variant_id uuid,
    p_wishlist_name text DEFAULT 'Default'
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_wishlist_id uuid;
BEGIN
    SELECT id INTO v_wishlist_id FROM wishlists WHERE user_id = p_user_id AND name = p_wishlist_name;
    IF NOT FOUND THEN
        INSERT INTO wishlists (user_id, name) VALUES (p_user_id, p_wishlist_name)
        RETURNING id INTO v_wishlist_id;
    END IF;

    INSERT INTO wishlist_items (wishlist_id, variant_id)
    VALUES (v_wishlist_id, p_variant_id)
    ON CONFLICT (wishlist_id, variant_id) DO NOTHING;
END;
$$;

-- 25. wishlist_get
CREATE OR REPLACE FUNCTION wishlist_get(p_user_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT jsonb_agg(
    jsonb_build_object(
      'wishlist_id', w.id,
      'name', w.name,
      'is_public', w.is_public,
      'items', (
        SELECT jsonb_agg(jsonb_build_object(
          'variant_id', pv.id,
          'product_name', p.name,
          'price', pv.price,
          'stock', pv.stock_quantity,
          'image', (SELECT pi.url FROM product_images pi WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1)
        ))
        FROM wishlist_items wi
        JOIN product_variants pv ON pv.id = wi.variant_id
        JOIN products p ON p.id = pv.product_id
        WHERE wi.wishlist_id = w.id
      )
    )
  )
  FROM wishlists w
  WHERE w.user_id = p_user_id;
$$;
