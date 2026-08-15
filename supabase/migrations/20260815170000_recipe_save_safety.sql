-- Atomically save a recipe together with its groups, ingredients, and steps.
create or replace function public.save_recipe_with_contents(
  p_recipe_id bigint,
  p_title text,
  p_type text,
  p_time text,
  p_emoji text,
  p_description text,
  p_groups jsonb,
  p_steps jsonb
)
returns bigint
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_recipe_id bigint;
  v_group_id bigint;
  v_group jsonb;
  v_ingredient jsonb;
  v_step jsonb;
  v_sort_order integer;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if coalesce(trim(p_title), '') = '' then
    raise exception 'A recipe title is required';
  end if;

  if jsonb_typeof(coalesce(p_groups, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_steps, '[]'::jsonb)) <> 'array' then
    raise exception 'Recipe contents must be arrays';
  end if;

  -- Validate linked grocery items before replacing any existing recipe contents.
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_groups, '[]'::jsonb)) group_row,
         jsonb_array_elements(coalesce(group_row -> 'ingredients', '[]'::jsonb)) ingredient_row
    where nullif(ingredient_row ->> 'grocery_item_id', '') is not null
      and not exists (
        select 1
        from public.grocery_items item
        where item.id = (ingredient_row ->> 'grocery_item_id')::bigint
          and item.user_id = v_user_id
      )
  ) then
    raise exception 'A linked grocery item is invalid';
  end if;

  if p_recipe_id is null then
    select coalesce(max(sort_order), 0) + 1
      into v_sort_order
      from public.recipes
     where user_id = v_user_id;

    insert into public.recipes (
      user_id, title, type, time, emoji, description, active, sort_order, updated_at
    )
    values (
      v_user_id, trim(p_title), nullif(trim(p_type), ''), nullif(trim(p_time), ''),
      nullif(trim(p_emoji), ''), nullif(trim(p_description), ''), true, v_sort_order, now()
    )
    returning id into v_recipe_id;
  else
    update public.recipes
       set title = trim(p_title),
           type = nullif(trim(p_type), ''),
           time = nullif(trim(p_time), ''),
           emoji = nullif(trim(p_emoji), ''),
           description = nullif(trim(p_description), ''),
           updated_at = now()
     where id = p_recipe_id
       and user_id = v_user_id
     returning id into v_recipe_id;

    if v_recipe_id is null then
      raise exception 'Recipe not found';
    end if;
  end if;

  -- Deleting groups cascades to their ingredients. The function transaction rolls
  -- back all changes if any later insert fails.
  delete from public.recipe_groups where recipe_id = v_recipe_id;
  delete from public.recipe_steps where recipe_id = v_recipe_id;

  for v_group in
    select value from jsonb_array_elements(coalesce(p_groups, '[]'::jsonb))
  loop
    insert into public.recipe_groups (recipe_id, name, sort_order, updated_at)
    values (
      v_recipe_id,
      coalesce(nullif(trim(v_group ->> 'name'), ''), 'Ingredients'),
      coalesce((v_group ->> 'sort_order')::integer, 0),
      now()
    )
    returning id into v_group_id;

    for v_ingredient in
      select value from jsonb_array_elements(coalesce(v_group -> 'ingredients', '[]'::jsonb))
    loop
      insert into public.recipe_ingredients (
        recipe_id, group_id, grocery_item_id, quantity, ingredient_text, sort_order, updated_at
      )
      values (
        v_recipe_id,
        v_group_id,
        nullif(v_ingredient ->> 'grocery_item_id', '')::bigint,
        nullif(trim(v_ingredient ->> 'quantity'), ''),
        coalesce(nullif(trim(v_ingredient ->> 'ingredient_text'), ''), ''),
        coalesce((v_ingredient ->> 'sort_order')::integer, 0),
        now()
      );
    end loop;
  end loop;

  for v_step in
    select value from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb))
  loop
    insert into public.recipe_steps (recipe_id, step_number, instruction, updated_at)
    values (
      v_recipe_id,
      (v_step ->> 'step_number')::integer,
      coalesce(nullif(trim(v_step ->> 'instruction'), ''), ''),
      now()
    );
  end loop;

  return v_recipe_id;
end;
$$;

revoke all on function public.save_recipe_with_contents(
  bigint, text, text, text, text, text, jsonb, jsonb
) from public;
grant execute on function public.save_recipe_with_contents(
  bigint, text, text, text, text, text, jsonb, jsonb
) to authenticated;

-- Move one active recipe up or down in a single, user-scoped transaction.
create or replace function public.move_recipe(
  p_recipe_id bigint,
  p_direction integer
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_current_order integer;
  v_neighbor_id bigint;
  v_neighbor_order integer;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if p_direction not in (-1, 1) then
    raise exception 'Direction must be -1 or 1';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_user_id::text));

  select sort_order into v_current_order
    from public.recipes
   where id = p_recipe_id
     and user_id = v_user_id
     and active = true
   for update;

  if v_current_order is null then
    raise exception 'Recipe not found';
  end if;

  if p_direction = -1 then
    select id, sort_order into v_neighbor_id, v_neighbor_order
      from public.recipes
     where user_id = v_user_id
       and active = true
       and (sort_order, id) < (v_current_order, p_recipe_id)
     order by sort_order desc, id desc
     limit 1
     for update;
  else
    select id, sort_order into v_neighbor_id, v_neighbor_order
      from public.recipes
     where user_id = v_user_id
       and active = true
       and (sort_order, id) > (v_current_order, p_recipe_id)
     order by sort_order asc, id asc
     limit 1
     for update;
  end if;

  if v_neighbor_id is null then
    return;
  end if;

  update public.recipes
     set sort_order = v_neighbor_order,
         updated_at = now()
   where id = p_recipe_id;

  update public.recipes
     set sort_order = v_current_order,
         updated_at = now()
   where id = v_neighbor_id;
end;
$$;

revoke all on function public.move_recipe(bigint, integer) from public;
grant execute on function public.move_recipe(bigint, integer) to authenticated;
