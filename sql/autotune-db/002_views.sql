create or replace view autotune.v_current_champions as
with ranked as (
    select
        c.*,
        row_number() over (
            partition by coalesce(c.map_name, 'unknown'), coalesce(c.opponent_key, 'unknown')
            order by c.promoted_at desc, c.score desc nulls last
        ) as rn
    from autotune.champions c
)
select
    session_id,
    candidate_id,
    map_name,
    opponent_key,
    ai_matchup,
    promoted_at,
    score,
    avg_game_time,
    avg_mass_ratio,
    version,
    fingerprint,
    git_commit,
    config_json
from ranked
where rn = 1;

create or replace view autotune.v_session_leaderboard as
select
    sr.session_id,
    sr.map_name,
    sr.opponent_key,
    sr.ai_matchup,
    sr.promoted,
    sr.best_candidate,
    sr.best_score,
    sr.best_avg_game_time,
    sr.best_avg_mass_ratio,
    sr.best_primary_failure_class,
    sr.baseline_score,
    sr.baseline_avg_game_time,
    sr.baseline_avg_mass_ratio,
    sr.margin,
    sr.version,
    sr.fingerprint,
    sr.git_commit,
    sr.created_at
from autotune.session_runs sr
where sr.session_kind = 'economy';

create or replace view autotune.v_param_effects as
select
    cp.param_name,
    count(*) as samples,
    round(avg(cp.param_value)::numeric, 4) as avg_value,
    round(avg(cr.score)::numeric, 2) as avg_score,
    round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
    round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time,
    round(corr(cp.param_value::double precision, cr.score::double precision)::numeric, 4) as score_corr,
    round(corr(cp.param_value::double precision, cr.avg_mass_ratio::double precision)::numeric, 4) as mass_ratio_corr,
    round(corr(cp.param_value::double precision, cr.avg_game_time::double precision)::numeric, 4) as game_time_corr
from autotune.candidate_parameters cp
join autotune.candidate_results cr
    on cr.session_id = cp.session_id
   and cr.candidate_id = cp.candidate_id
where cr.runtime_clean = true
  and cr.candidate_id <> 'baseline'
group by cp.param_name;

create or replace view autotune.v_failure_param_effects as
select
    cr.primary_failure_class,
    cp.param_name,
    count(*) as samples,
    round(avg(cp.param_value)::numeric, 4) as avg_value,
    round(avg(cr.score)::numeric, 2) as avg_score,
    round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
    round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time
from autotune.candidate_results cr
join autotune.candidate_parameters cp
    on cp.session_id = cr.session_id
   and cp.candidate_id = cr.candidate_id
where cr.candidate_id <> 'baseline'
group by cr.primary_failure_class, cp.param_name;

create or replace view autotune.v_map_opponent_profiles as
select
    coalesce(sr.map_name, 'unknown') as map_name,
    coalesce(sr.opponent_key, 'unknown') as opponent_key,
    coalesce(sr.ai_matchup, 'unknown') as ai_matchup,
    count(*) as sessions,
    round(avg(sr.best_score)::numeric, 2) as avg_best_score,
    round(avg(sr.best_avg_mass_ratio)::numeric, 4) as avg_best_mass_ratio,
    round(avg(sr.best_avg_game_time)::numeric, 2) as avg_best_game_time,
    round(avg(case when sr.promoted then 1 else 0 end)::numeric, 4) as promotion_rate
from autotune.session_runs sr
where sr.session_kind = 'economy'
group by coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'), coalesce(sr.ai_matchup, 'unknown');

create or replace view autotune.v_failure_hotspots as
select
    coalesce(sr.map_name, 'unknown') as map_name,
    coalesce(sr.opponent_key, 'unknown') as opponent_key,
    cr.primary_failure_class,
    count(*) as candidates,
    round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
    round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time,
    round(avg(cr.score)::numeric, 2) as avg_score
from autotune.candidate_results cr
join autotune.session_runs sr
    on sr.session_id = cr.session_id
where sr.session_kind = 'economy'
  and cr.candidate_id <> 'baseline'
group by coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'), cr.primary_failure_class;

create or replace view autotune.v_action_value_by_choice as
select
    ao.subsystem,
    ao.action_type,
    coalesce(ao.action_value, 'none') as action_value,
    ao.window_seconds,
    count(*) as samples,
    round(avg(ao.reward)::numeric, 2) as avg_reward,
    round(stddev_pop(ao.reward)::numeric, 2) as reward_stddev,
    round(avg(ao.delta_mex_ready)::numeric, 4) as avg_delta_mex_ready,
    round(avg(ao.delta_factory_total)::numeric, 4) as avg_delta_factory_total,
    round(avg(ao.delta_reclaim_mass)::numeric, 2) as avg_delta_reclaim_mass,
    round(avg(ao.delta_map_control)::numeric, 4) as avg_delta_map_control,
    round(avg(ao.delta_idle_factories)::numeric, 4) as avg_delta_idle_factories,
    round(avg(ao.delta_engineer_count)::numeric, 4) as avg_delta_engineer_count,
    round(avg(ao.delta_force_guard)::numeric, 4) as avg_delta_force_guard,
    round(avg(ao.delta_force_main)::numeric, 4) as avg_delta_force_main,
    round(avg(ao.delta_force_outer)::numeric, 4) as avg_delta_force_outer,
    round(avg(ao.delta_force_raid)::numeric, 4) as avg_delta_force_raid,
    round(avg(case when ao.survived_window then 1 else 0 end)::numeric, 4) as survival_rate,
    round(avg(case when ao.game_ended_within_window then 1 else 0 end)::numeric, 4) as end_rate,
    round(avg(ao.final_mass_ratio)::numeric, 4) as avg_final_mass_ratio
from autotune.action_outcomes ao
join autotune.candidate_results cr
    on cr.session_id = ao.session_id
   and cr.candidate_id = ao.candidate_id
join autotune.session_runs sr
    on sr.session_id = ao.session_id
where sr.session_kind = 'economy'
  and cr.runtime_clean = true
  and cr.candidate_id <> 'baseline'
group by ao.subsystem, ao.action_type, coalesce(ao.action_value, 'none'), ao.window_seconds;

create or replace view autotune.v_action_value_by_subsystem as
select
    ao.subsystem,
    ao.action_type,
    ao.window_seconds,
    count(*) as samples,
    round(avg(ao.reward)::numeric, 2) as avg_reward,
    round(avg(ao.delta_mex_ready)::numeric, 4) as avg_delta_mex_ready,
    round(avg(ao.delta_factory_total)::numeric, 4) as avg_delta_factory_total,
    round(avg(ao.delta_reclaim_mass)::numeric, 2) as avg_delta_reclaim_mass,
    round(avg(ao.delta_map_control)::numeric, 4) as avg_delta_map_control,
    round(avg(case when ao.survived_window then 1 else 0 end)::numeric, 4) as survival_rate,
    round(avg(ao.final_mass_ratio)::numeric, 4) as avg_final_mass_ratio
from autotune.action_outcomes ao
join autotune.candidate_results cr
    on cr.session_id = ao.session_id
   and cr.candidate_id = ao.candidate_id
join autotune.session_runs sr
    on sr.session_id = ao.session_id
where sr.session_kind = 'economy'
  and cr.runtime_clean = true
  and cr.candidate_id <> 'baseline'
group by ao.subsystem, ao.action_type, ao.window_seconds;

create or replace view autotune.v_action_failure_precursors as
select
    coalesce(sr.map_name, 'unknown') as map_name,
    coalesce(sr.opponent_key, 'unknown') as opponent_key,
    coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
    ae.subsystem,
    ae.action_type,
    coalesce(ae.action_value, 'none') as action_value,
    ao.window_seconds,
    count(*) as samples,
    round(avg(ae.event_time)::numeric, 2) as avg_event_time,
    round(avg(ao.reward)::numeric, 2) as avg_reward,
    round(avg(ao.delta_mex_ready)::numeric, 4) as avg_delta_mex_ready,
    round(avg(ao.delta_factory_total)::numeric, 4) as avg_delta_factory_total,
    round(avg(ao.delta_reclaim_mass)::numeric, 2) as avg_delta_reclaim_mass,
    round(avg(ao.delta_map_control)::numeric, 4) as avg_delta_map_control,
    round(avg(case when ao.survived_window then 1 else 0 end)::numeric, 4) as survival_rate,
    round(avg(ao.final_mass_ratio)::numeric, 4) as avg_final_mass_ratio
from autotune.action_events ae
join autotune.action_outcomes ao
    on ao.session_id = ae.session_id
   and ao.candidate_id = ae.candidate_id
   and ao.log_name = ae.log_name
   and ao.event_index = ae.event_index
join autotune.candidate_results cr
    on cr.session_id = ae.session_id
   and cr.candidate_id = ae.candidate_id
join autotune.session_runs sr
    on sr.session_id = ae.session_id
where sr.session_kind = 'economy'
  and cr.candidate_id <> 'baseline'
  and ae.event_time <= 900
group by
    coalesce(sr.map_name, 'unknown'),
    coalesce(sr.opponent_key, 'unknown'),
    coalesce(cr.primary_failure_class, 'unknown'),
    ae.subsystem,
    ae.action_type,
    coalesce(ae.action_value, 'none'),
    ao.window_seconds;
