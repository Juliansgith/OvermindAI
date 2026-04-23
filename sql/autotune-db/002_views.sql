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
