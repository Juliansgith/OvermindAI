from __future__ import annotations

from typing import Iterable

import pandas as pd
import streamlit as st

from db import get_engine, read_sql


st.set_page_config(page_title="Overmind Autotune Dashboard", layout="wide")


@st.cache_resource(show_spinner=False)
def load_engine():
    return get_engine()


def sql_in_filter(column: str, values: Iterable[str], params: dict[str, object], prefix: str) -> str:
    items = [value for value in values if value]
    if not items:
        return ""
    names = []
    for index, value in enumerate(items):
        key = f"{prefix}_{index}"
        params[key] = value
        names.append(f":{key}")
    return f" and {column} in ({', '.join(names)})"


def build_session_where(
    maps: list[str],
    opponents: list[str],
    ai_matchups: list[str],
    versions: list[str],
    fingerprints: list[str],
    promoted_only: bool,
    created_after: str | None,
    created_before: str | None,
) -> tuple[str, dict[str, object]]:
    params: dict[str, object] = {}
    clauses = ["where sr.session_kind = 'economy'"]
    clauses.append(sql_in_filter("coalesce(sr.map_name, 'unknown')", maps, params, "map"))
    clauses.append(sql_in_filter("coalesce(sr.opponent_key, 'unknown')", opponents, params, "opp"))
    clauses.append(sql_in_filter("coalesce(sr.ai_matchup, 'unknown')", ai_matchups, params, "match"))
    if versions:
        version_values = []
        for value in versions:
            try:
                version_values.append(int(value))
            except ValueError:
                continue
        if version_values:
            clauses.append(sql_in_filter("cast(sr.version as text)", [str(value) for value in version_values], params, "ver"))
    clauses.append(sql_in_filter("coalesce(sr.fingerprint, 'unknown')", fingerprints, params, "fp"))
    if promoted_only:
        clauses.append(" and coalesce(sr.promoted, false) = true")
    if created_after:
        params["created_after"] = created_after
        clauses.append(" and sr.created_at >= cast(:created_after as timestamptz)")
    if created_before:
        params["created_before"] = created_before
        clauses.append(" and sr.created_at < cast(:created_before as timestamptz) + interval '1 day'")
    return "".join(clauses), params


@st.cache_data(show_spinner=False, ttl=60)
def load_filter_values():
    engine = load_engine()
    result = {}
    for key, query in {
        "maps": """
            select distinct coalesce(map_name, 'unknown') as value
            from autotune.session_runs
            where session_kind = 'economy'
            order by 1
        """,
        "opponents": """
            select distinct coalesce(opponent_key, 'unknown') as value
            from autotune.session_runs
            where session_kind = 'economy'
            order by 1
        """,
        "ai_matchups": """
            select distinct coalesce(ai_matchup, 'unknown') as value
            from autotune.session_runs
            where session_kind = 'economy'
            order by 1
        """,
        "versions": """
            select cast(version as text) as value
            from (
                select distinct version
                from autotune.session_runs
                where session_kind = 'economy'
                  and version is not null
            ) v
            order by version desc
        """,
        "fingerprints": """
            select distinct coalesce(fingerprint, 'unknown') as value
            from autotune.session_runs
            where session_kind = 'economy'
            order by 1
        """,
    }.items():
        frame = read_sql(engine, query)
        result[key] = frame["value"].dropna().tolist()
    return result


@st.cache_data(show_spinner=False, ttl=60)
def load_overview(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    metrics = read_sql(
        engine,
        f"""
        select
            count(*)::int as sessions,
            count(*) filter (where coalesce(sr.promoted, false))::int as promotions,
            round(avg(sr.best_avg_mass_ratio)::numeric, 4) as avg_best_mass_ratio,
            round(avg(sr.best_avg_game_time)::numeric, 2) as avg_best_game_time,
            round(avg(sr.margin)::numeric, 2) as avg_margin,
            round(max(sr.best_avg_mass_ratio)::numeric, 4) as best_mass_ratio_seen
        from autotune.session_runs sr
        {where_sql}
        """,
        params,
    )
    candidates = read_sql(
        engine,
        f"""
        select
            count(*)::int as candidates,
            count(*) filter (where coalesce(cr.promoted, false))::int as promoted_candidates,
            count(*) filter (where cr.candidate_id = 'baseline')::int as baseline_candidates
        from autotune.candidate_results cr
        join autotune.session_runs sr on sr.session_id = cr.session_id
        {where_sql}
        """,
        params,
    )
    games = read_sql(
        engine,
        f"""
        select count(*)::int as games
        from autotune.game_results gr
        join autotune.session_runs sr on sr.session_id = gr.session_id
        {where_sql}
        """,
        params,
    )
    trend = read_sql(
        engine,
        f"""
        with game_counts as (
            select session_id, count(*)::int as session_games
            from autotune.game_results
            group by session_id
        )
        select
            sr.created_at,
            sr.session_id,
            sr.baseline_avg_mass_ratio,
            sr.best_avg_mass_ratio,
            sr.baseline_avg_game_time,
            sr.best_avg_game_time,
            sr.margin,
            coalesce(gc.session_games, 0) as session_games,
            row_number() over (order by sr.created_at) as session_index
        from autotune.session_runs sr
        left join game_counts gc on gc.session_id = sr.session_id
        {where_sql}
        order by sr.created_at
        """,
        params,
    )
    cumulative = trend.copy()
    if not cumulative.empty:
        cumulative["games_processed"] = cumulative["session_games"].fillna(0).cumsum()
        cumulative["best_so_far_mass_ratio"] = cumulative["best_avg_mass_ratio"].cummax()
        cumulative["best_so_far_game_time"] = cumulative["best_avg_game_time"].cummax()
    recent = read_sql(
        engine,
        f"""
        select
            sr.created_at,
            sr.session_id,
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            sr.best_candidate,
            sr.best_score,
            sr.best_avg_mass_ratio,
            sr.best_avg_game_time,
            sr.promoted,
            sr.best_primary_failure_class
        from autotune.session_runs sr
        {where_sql}
        order by sr.created_at desc
        limit 25
        """,
        params,
    )
    return metrics, candidates, games, trend, cumulative, recent


@st.cache_data(show_spinner=False, ttl=60)
def load_kpi_rollup(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    return read_sql(
        engine,
        f"""
        with baseline_kpis as (
            select
                sr.session_id,
                avg(gk.first_mex_5_time) as first_mex_5_time,
                avg(gk.first_mex_8_time) as first_mex_8_time,
                avg(gk.first_factory_2_time) as first_factory_2_time,
                avg(gk.max_mex_ready) as max_mex_ready,
                avg(gk.max_factory_total) as max_factory_total,
                avg(gk.mex_at_240) as mex_at_240,
                avg(gk.mex_at_360) as mex_at_360,
                avg(gk.mex_at_600) as mex_at_600,
                avg(gk.fac_total_at_240) as fac_total_at_240,
                avg(gk.fac_total_at_600) as fac_total_at_600,
                avg(gk.expansion_orders_total) as expansion_orders_total,
                avg(gk.reclaim_field_orders_total) as reclaim_field_orders_total,
                avg(gk.stagnation_seconds_est) as stagnation_seconds_est,
                avg(gk.overmind_mass_in_ratio) as overmind_mass_in_ratio
            from autotune.game_kpis gk
            join autotune.session_runs sr on sr.session_id = gk.session_id
            where gk.candidate_id = 'baseline'
            group by sr.session_id
        ),
        best_kpis as (
            select
                sr.session_id,
                avg(gk.first_mex_5_time) as first_mex_5_time,
                avg(gk.first_mex_8_time) as first_mex_8_time,
                avg(gk.first_factory_2_time) as first_factory_2_time,
                avg(gk.max_mex_ready) as max_mex_ready,
                avg(gk.max_factory_total) as max_factory_total,
                avg(gk.mex_at_240) as mex_at_240,
                avg(gk.mex_at_360) as mex_at_360,
                avg(gk.mex_at_600) as mex_at_600,
                avg(gk.fac_total_at_240) as fac_total_at_240,
                avg(gk.fac_total_at_600) as fac_total_at_600,
                avg(gk.expansion_orders_total) as expansion_orders_total,
                avg(gk.reclaim_field_orders_total) as reclaim_field_orders_total,
                avg(gk.stagnation_seconds_est) as stagnation_seconds_est,
                avg(gk.overmind_mass_in_ratio) as overmind_mass_in_ratio
            from autotune.game_kpis gk
            join autotune.session_runs sr on sr.session_id = gk.session_id
            where gk.candidate_id = sr.best_candidate
            group by sr.session_id
        )
        select
            sr.created_at,
            sr.session_id,
            bk.first_mex_5_time as baseline_first_mex_5_time,
            ck.first_mex_5_time as best_first_mex_5_time,
            bk.first_mex_8_time as baseline_first_mex_8_time,
            ck.first_mex_8_time as best_first_mex_8_time,
            bk.first_factory_2_time as baseline_first_factory_2_time,
            ck.first_factory_2_time as best_first_factory_2_time,
            bk.max_mex_ready as baseline_max_mex_ready,
            ck.max_mex_ready as best_max_mex_ready,
            bk.max_factory_total as baseline_max_factory_total,
            ck.max_factory_total as best_max_factory_total,
            bk.mex_at_240 as baseline_mex_at_240,
            ck.mex_at_240 as best_mex_at_240,
            bk.mex_at_360 as baseline_mex_at_360,
            ck.mex_at_360 as best_mex_at_360,
            bk.mex_at_600 as baseline_mex_at_600,
            ck.mex_at_600 as best_mex_at_600,
            bk.fac_total_at_240 as baseline_fac_total_at_240,
            ck.fac_total_at_240 as best_fac_total_at_240,
            bk.fac_total_at_600 as baseline_fac_total_at_600,
            ck.fac_total_at_600 as best_fac_total_at_600,
            bk.expansion_orders_total as baseline_expansion_orders_total,
            ck.expansion_orders_total as best_expansion_orders_total,
            bk.reclaim_field_orders_total as baseline_reclaim_field_orders_total,
            ck.reclaim_field_orders_total as best_reclaim_field_orders_total,
            bk.stagnation_seconds_est as baseline_stagnation_seconds_est,
            ck.stagnation_seconds_est as best_stagnation_seconds_est,
            bk.overmind_mass_in_ratio as baseline_overmind_mass_in_ratio,
            ck.overmind_mass_in_ratio as best_overmind_mass_in_ratio
        from autotune.session_runs sr
        left join baseline_kpis bk on bk.session_id = sr.session_id
        left join best_kpis ck on ck.session_id = sr.session_id
        {where_sql}
        order by sr.created_at
        """,
        params,
    )


@st.cache_data(show_spinner=False, ttl=60)
def load_failure_views(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    failure_counts = read_sql(
        engine,
        f"""
        select
            coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
            count(*)::int as candidates,
            round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
            round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time,
            round(avg(cr.score)::numeric, 2) as avg_score
        from autotune.candidate_results cr
        join autotune.session_runs sr on sr.session_id = cr.session_id
        {where_sql}
          and cr.candidate_id <> 'baseline'
        group by coalesce(cr.primary_failure_class, 'unknown')
        order by candidates desc, primary_failure_class
        """,
        params,
    )
    failure_timeline = read_sql(
        engine,
        f"""
        select
            date_trunc('day', sr.created_at) as created_day,
            coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
            count(*)::int as candidates
        from autotune.candidate_results cr
        join autotune.session_runs sr on sr.session_id = cr.session_id
        {where_sql}
          and cr.candidate_id <> 'baseline'
        group by date_trunc('day', sr.created_at), coalesce(cr.primary_failure_class, 'unknown')
        order by created_day, primary_failure_class
        """,
        params,
    )
    return failure_counts, failure_timeline


def load_hotspots(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    return read_sql(
        engine,
        f"""
        select
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
            count(*)::int as candidates,
            round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
            round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time,
            round(avg(cr.score)::numeric, 2) as avg_score
        from autotune.candidate_results cr
        join autotune.session_runs sr on sr.session_id = cr.session_id
        {where_sql}
          and cr.candidate_id <> 'baseline'
        group by coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'), coalesce(cr.primary_failure_class, 'unknown')
        order by candidates desc, avg_score asc
        """,
        params,
    )


@st.cache_data(show_spinner=False, ttl=60)
def load_champion_views(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    champions = read_sql(
        engine,
        f"""
        select distinct on (coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'))
            c.session_id,
            c.candidate_id,
            coalesce(c.map_name, 'unknown') as map_name,
            coalesce(c.opponent_key, 'unknown') as opponent_key,
            coalesce(c.ai_matchup, 'unknown') as ai_matchup,
            c.promoted_at,
            c.score,
            c.avg_game_time,
            c.avg_mass_ratio,
            c.version,
            c.fingerprint
        from autotune.champions c
        join autotune.session_runs sr on sr.session_id = c.session_id
        {where_sql}
        order by coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'), c.promoted_at desc, c.score desc nulls last
        """,
        params,
    )
    leaderboard = read_sql(
        engine,
        f"""
        select
            sr.session_id,
            sr.created_at,
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            coalesce(sr.ai_matchup, 'unknown') as ai_matchup,
            sr.promoted,
            sr.best_candidate,
            sr.best_score,
            sr.best_avg_mass_ratio,
            sr.best_avg_game_time,
            sr.margin,
            sr.best_primary_failure_class,
            sr.version,
            sr.fingerprint
        from autotune.session_runs sr
        {where_sql}
        order by sr.best_score desc nulls last
        limit 50
        """,
        params,
    )
    profiles = read_sql(
        engine,
        f"""
        select
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            coalesce(sr.ai_matchup, 'unknown') as ai_matchup,
            count(*)::int as sessions,
            round(avg(sr.best_score)::numeric, 2) as avg_best_score,
            round(avg(sr.best_avg_mass_ratio)::numeric, 4) as avg_best_mass_ratio,
            round(avg(sr.best_avg_game_time)::numeric, 2) as avg_best_game_time,
            round(avg(case when sr.promoted then 1 else 0 end)::numeric, 4) as promotion_rate
        from autotune.session_runs sr
        {where_sql}
        group by coalesce(sr.map_name, 'unknown'), coalesce(sr.opponent_key, 'unknown'), coalesce(sr.ai_matchup, 'unknown')
        order by sessions desc, avg_best_score desc
        """,
        params,
    )
    return champions, leaderboard, profiles


@st.cache_data(show_spinner=False, ttl=60)
def load_parameter_views(where_sql: str, params: dict[str, object], failure_class: str | None):
    engine = load_engine()
    params_effects = read_sql(
        engine,
        f"""
        select
            cp.param_name,
            count(*)::int as samples,
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
        join autotune.session_runs sr on sr.session_id = cp.session_id
        {where_sql}
          and cr.runtime_clean = true
          and cr.candidate_id <> 'baseline'
        group by cp.param_name
        order by mass_ratio_corr desc nulls last, score_corr desc nulls last
        limit 100
        """,
        params,
    )
    failure_params = read_sql(
        engine,
        f"""
        select
            coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
            cp.param_name,
            count(*)::int as samples,
            round(avg(cp.param_value)::numeric, 4) as avg_value,
            round(avg(cr.score)::numeric, 2) as avg_score,
            round(avg(cr.avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
            round(avg(cr.avg_game_time)::numeric, 2) as avg_game_time
        from autotune.candidate_results cr
        join autotune.candidate_parameters cp
            on cp.session_id = cr.session_id
           and cp.candidate_id = cr.candidate_id
        join autotune.session_runs sr on sr.session_id = cr.session_id
        {where_sql}
          and cr.candidate_id <> 'baseline'
          {"and coalesce(cr.primary_failure_class, 'unknown') = :failure_class" if failure_class else ""}
        group by coalesce(cr.primary_failure_class, 'unknown'), cp.param_name
        order by samples desc, avg_score desc
        limit 100
        """,
        {**params, **({"failure_class": failure_class} if failure_class else {})},
    )
    return params_effects, failure_params


@st.cache_data(show_spinner=False, ttl=60)
def load_action_views(
    where_sql: str,
    params: dict[str, object],
    window_seconds: int,
    min_samples: int,
):
    engine = load_engine()
    choices = read_sql(
        engine,
        f"""
        select
            ao.subsystem,
            ao.action_type,
            coalesce(ao.action_value, 'none') as action_value,
            ao.window_seconds,
            count(*)::int as samples,
            round(avg(ao.reward)::numeric, 2) as avg_reward,
            round(avg(ao.delta_mex_ready)::numeric, 4) as avg_delta_mex_ready,
            round(avg(ao.delta_factory_total)::numeric, 4) as avg_delta_factory_total,
            round(avg(ao.delta_reclaim_mass)::numeric, 2) as avg_delta_reclaim_mass,
            round(avg(ao.delta_map_control)::numeric, 4) as avg_delta_map_control,
            round(avg(ao.delta_force_guard)::numeric, 4) as avg_delta_force_guard,
            round(avg(ao.delta_force_main)::numeric, 4) as avg_delta_force_main,
            round(avg(ao.delta_force_outer)::numeric, 4) as avg_delta_force_outer,
            round(avg(ao.delta_force_raid)::numeric, 4) as avg_delta_force_raid,
            round(avg(case when ao.survived_window then 1 else 0 end)::numeric, 4) as survival_rate,
            round(avg(ao.final_mass_ratio)::numeric, 4) as avg_final_mass_ratio
        from autotune.action_outcomes ao
        join autotune.candidate_results cr
            on cr.session_id = ao.session_id
           and cr.candidate_id = ao.candidate_id
        join autotune.session_runs sr
            on sr.session_id = ao.session_id
        {where_sql}
          and cr.runtime_clean = true
          and cr.candidate_id <> 'baseline'
          and ao.window_seconds = :window_seconds
        group by ao.subsystem, ao.action_type, coalesce(ao.action_value, 'none'), ao.window_seconds
        having count(*) >= :min_samples
        order by avg_reward desc, samples desc
        limit 200
        """,
        {**params, "window_seconds": window_seconds, "min_samples": min_samples},
    )
    subsystem = read_sql(
        engine,
        f"""
        select
            ao.subsystem,
            ao.action_type,
            ao.window_seconds,
            count(*)::int as samples,
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
        {where_sql}
          and cr.runtime_clean = true
          and cr.candidate_id <> 'baseline'
          and ao.window_seconds = :window_seconds
        group by ao.subsystem, ao.action_type, ao.window_seconds
        having count(*) >= :min_samples
        order by avg_reward desc, samples desc
        limit 100
        """,
        {**params, "window_seconds": window_seconds, "min_samples": min_samples},
    )
    precursors = read_sql(
        engine,
        f"""
        select
            coalesce(cr.primary_failure_class, 'unknown') as primary_failure_class,
            ae.subsystem,
            ae.action_type,
            coalesce(ae.action_value, 'none') as action_value,
            ao.window_seconds,
            count(*)::int as samples,
            round(avg(ae.event_time)::numeric, 2) as avg_event_time,
            round(avg(ao.reward)::numeric, 2) as avg_reward,
            round(avg(ao.delta_mex_ready)::numeric, 4) as avg_delta_mex_ready,
            round(avg(ao.delta_factory_total)::numeric, 4) as avg_delta_factory_total,
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
        {where_sql}
          and cr.candidate_id <> 'baseline'
          and ao.window_seconds = :window_seconds
          and ae.event_time <= 900
        group by
            coalesce(cr.primary_failure_class, 'unknown'),
            ae.subsystem,
            ae.action_type,
            coalesce(ae.action_value, 'none'),
            ao.window_seconds
        having count(*) >= :min_samples
        order by avg_reward asc, samples desc
        limit 150
        """,
        {**params, "window_seconds": window_seconds, "min_samples": min_samples},
    )
    return choices, subsystem, precursors


@st.cache_data(show_spinner=False, ttl=60)
def load_live_monitor():
    engine = load_engine()
    freshness = read_sql(
        engine,
        """
        select
            now() as db_now,
            (select count(*) from autotune.session_runs where session_kind = 'economy')::int as session_count,
            (select count(*) from autotune.session_runs where session_kind = 'economy' and created_at >= now() - interval '24 hours')::int as sessions_last_24h,
            (select count(*) from autotune.game_results)::int as game_count,
            (select count(*) from autotune.action_events)::int as action_event_count,
            (select max(created_at) from autotune.session_runs where session_kind = 'economy') as latest_session_created_at,
            (select max(created_at) from autotune.overnight_runs) as latest_overnight_created_at,
            (select max(ingested_at) from autotune.overnight_runs) as latest_overnight_ingested_at
        """,
    )
    latest_sessions = read_sql(
        engine,
        """
        select
            sr.created_at,
            sr.session_id,
            coalesce(sr.overnight_session_id, 'standalone') as overnight_session_id,
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            sr.best_candidate,
            sr.best_score,
            sr.best_avg_mass_ratio,
            sr.best_avg_game_time,
            sr.promoted
        from autotune.session_runs sr
        where sr.session_kind = 'economy'
        order by sr.created_at desc
        limit 20
        """,
    )
    overnight_progress = read_sql(
        engine,
        """
        select
            sr.overnight_session_id,
            min(sr.created_at) as first_campaign_at,
            max(sr.created_at) as last_campaign_at,
            count(*)::int as campaigns_seen,
            count(*) filter (where coalesce(sr.promoted, false))::int as promotions_seen,
            round(avg(sr.best_avg_mass_ratio)::numeric, 4) as avg_best_mass_ratio,
            round(max(sr.best_avg_mass_ratio)::numeric, 4) as peak_mass_ratio
        from autotune.session_runs sr
        where sr.session_kind = 'economy'
          and sr.overnight_session_id is not null
        group by sr.overnight_session_id
        order by last_campaign_at desc
        limit 20
        """,
    )
    overnight_registered = read_sql(
        engine,
        """
        select
            overnight_session_id,
            map_name,
            campaigns_requested,
            campaigns_completed,
            promotions,
            created_at,
            ingested_at
        from autotune.overnight_runs
        order by created_at desc
        limit 20
        """,
    )
    return freshness, latest_sessions, overnight_progress, overnight_registered


@st.cache_data(show_spinner=False, ttl=60)
def load_session_catalog(where_sql: str, params: dict[str, object]):
    engine = load_engine()
    return read_sql(
        engine,
        f"""
        select
            sr.session_id,
            sr.created_at,
            coalesce(sr.map_name, 'unknown') as map_name,
            coalesce(sr.opponent_key, 'unknown') as opponent_key,
            sr.best_candidate,
            sr.best_score,
            sr.best_avg_mass_ratio,
            sr.best_avg_game_time,
            sr.promoted
        from autotune.session_runs sr
        {where_sql}
        order by sr.created_at desc
        limit 200
        """,
        params,
    )


@st.cache_data(show_spinner=False, ttl=60)
def load_session_detail(session_id: str):
    engine = load_engine()
    meta = read_sql(
        engine,
        """
        select
            session_id,
            overnight_session_id,
            created_at,
            coalesce(map_name, 'unknown') as map_name,
            coalesce(opponent_key, 'unknown') as opponent_key,
            coalesce(ai_matchup, 'unknown') as ai_matchup,
            promoted,
            no_promote,
            best_candidate,
            best_score,
            best_avg_mass_ratio,
            best_avg_game_time,
            best_primary_failure_class,
            baseline_score,
            baseline_avg_mass_ratio,
            baseline_avg_game_time,
            baseline_primary_failure_class,
            margin,
            promotion_allowed,
            promotion_blocked_reasons,
            version,
            fingerprint,
            git_commit
        from autotune.session_runs
        where session_id = :session_id
        """,
        {"session_id": session_id},
    )
    candidates = read_sql(
        engine,
        """
        select
            candidate_id,
            parent_candidate_id,
            games,
            score,
            win_rate,
            avg_game_time,
            avg_mass_ratio,
            primary_failure_class,
            runtime_clean,
            promoted
        from autotune.candidate_results
        where session_id = :session_id
        order by score desc nulls last, candidate_id
        """,
        {"session_id": session_id},
    )
    kpis = read_sql(
        engine,
        """
        select
            candidate_id,
            round(avg(first_mex_5_time)::numeric, 2) as first_mex_5_time,
            round(avg(first_mex_8_time)::numeric, 2) as first_mex_8_time,
            round(avg(first_factory_2_time)::numeric, 2) as first_factory_2_time,
            round(avg(max_mex_ready)::numeric, 2) as max_mex_ready,
            round(avg(max_factory_total)::numeric, 2) as max_factory_total,
            round(avg(mex_at_240)::numeric, 2) as mex_at_240,
            round(avg(mex_at_360)::numeric, 2) as mex_at_360,
            round(avg(mex_at_600)::numeric, 2) as mex_at_600,
            round(avg(fac_total_at_240)::numeric, 2) as fac_total_at_240,
            round(avg(fac_total_at_600)::numeric, 2) as fac_total_at_600,
            round(avg(expansion_orders_total)::numeric, 2) as expansion_orders_total,
            round(avg(reclaim_field_orders_total)::numeric, 2) as reclaim_field_orders_total,
            round(avg(stagnation_seconds_est)::numeric, 2) as stagnation_seconds_est,
            round(avg(overmind_mass_in_ratio)::numeric, 4) as overmind_mass_in_ratio
        from autotune.game_kpis
        where session_id = :session_id
        group by candidate_id
        order by candidate_id
        """,
        {"session_id": session_id},
    )
    games = read_sql(
        engine,
        """
        select
            candidate_id,
            log_name,
            winner_name,
            winner_type,
            winner_score,
            warnings,
            errors,
            top_warning,
            top_overmind_event,
            game_time_seconds,
            sim_speed,
            startup_ok,
            config_loaded
        from autotune.game_results
        where session_id = :session_id
        order by candidate_id, log_name
        """,
        {"session_id": session_id},
    )
    econ = read_sql(
        engine,
        """
        select
            gps.candidate_id,
            round(avg(case when gps.is_overmind then gps.mass_in end)::numeric, 2) as avg_overmind_mass_in,
            round(avg(case when gps.is_overmind then gps.mass_out end)::numeric, 2) as avg_overmind_mass_out,
            round(avg(case when gps.is_overmind then gps.score end)::numeric, 2) as avg_overmind_score,
            round(avg(case when gps.is_opponent then gps.mass_in end)::numeric, 2) as avg_opponent_mass_in,
            round(avg(case when gps.is_opponent then gps.mass_out end)::numeric, 2) as avg_opponent_mass_out,
            round(avg(case when gps.is_opponent then gps.score end)::numeric, 2) as avg_opponent_score
        from autotune.game_player_stats gps
        where gps.session_id = :session_id
        group by gps.candidate_id
        order by gps.candidate_id
        """,
        {"session_id": session_id},
    )
    params = read_sql(
        engine,
        """
        select
            candidate_id,
            param_name,
            param_value
        from autotune.candidate_parameters
        where session_id = :session_id
        order by candidate_id, param_name
        """,
        {"session_id": session_id},
    )
    return meta, candidates, kpis, games, econ, params


def render_metric_delta(label: str, baseline: pd.Series, best: pd.Series, higher_is_better: bool):
    base_value = baseline.mean(skipna=True)
    best_value = best.mean(skipna=True)
    if pd.isna(base_value) or pd.isna(best_value):
        st.metric(label, "n/a")
        return
    delta = best_value - base_value
    if not higher_is_better:
        delta = -delta
    st.metric(label, f"{best_value:.2f}", delta=f"{delta:.2f}")


def main():
    st.title("Overmind Autotune Analytics")
    st.caption("DB-backed experiment dashboard for session trends, KPIs, failures, champions, parameters, and action-learning.")

    try:
        load_engine().connect().close()
    except Exception as exc:
        st.error(f"Database connection failed: {exc}")
        st.stop()

    filters = load_filter_values()
    with st.sidebar:
        st.header("Filters")
        if st.button("Refresh Now", use_container_width=True):
            st.cache_data.clear()
            st.rerun()
        maps = st.multiselect("Map", filters["maps"])
        opponents = st.multiselect("Opponent", filters["opponents"])
        ai_matchups = st.multiselect("AI Matchup", filters["ai_matchups"])
        versions = st.multiselect("Version", filters["versions"])
        fingerprints = st.multiselect("Fingerprint", filters["fingerprints"])
        promoted_only = st.checkbox("Promoted Sessions Only", value=False)
        created_after = st.date_input("Created After", value=None)
        created_before = st.date_input("Created Before", value=None)
        action_window = st.selectbox("Action Window", [30, 60, 120, 300], index=1)
        min_action_samples = st.slider("Min Action Samples", 5, 200, 25, 5)
        failure_spotlight = st.text_input("Failure Spotlight", value="")

    where_sql, params = build_session_where(
        maps=maps,
        opponents=opponents,
        ai_matchups=ai_matchups,
        versions=versions,
        fingerprints=fingerprints,
        promoted_only=promoted_only,
        created_after=created_after.isoformat() if created_after else None,
        created_before=created_before.isoformat() if created_before else None,
    )

    freshness, latest_sessions, overnight_progress, overnight_registered = load_live_monitor()
    overview_metrics, candidate_metrics, game_metrics, trend, cumulative, recent = load_overview(where_sql, params)
    kpis = load_kpi_rollup(where_sql, params)
    failure_counts, failure_timeline = load_failure_views(where_sql, params)
    hotspots = load_hotspots(where_sql, params)
    champions, leaderboard, profiles = load_champion_views(where_sql, params)
    params_effects, failure_params = load_parameter_views(where_sql, params, failure_spotlight or None)
    action_choices, action_subsystem, action_precursors = load_action_views(where_sql, params, action_window, min_action_samples)
    session_catalog = load_session_catalog(where_sql, params)

    tabs = st.tabs(["Live Monitor", "Overview", "KPIs", "Failures", "Champions", "Parameters", "Action Learning", "Session Detail"])

    with tabs[0]:
        fresh = freshness.iloc[0] if not freshness.empty else None
        top = st.columns(5)
        top[0].metric("Total Sessions", int(fresh["session_count"]) if fresh is not None else 0)
        top[1].metric("Sessions Last 24h", int(fresh["sessions_last_24h"]) if fresh is not None else 0)
        top[2].metric("Total Games", int(fresh["game_count"]) if fresh is not None else 0)
        top[3].metric("Action Events", int(fresh["action_event_count"]) if fresh is not None else 0)
        top[4].metric("Latest Session", str(fresh["latest_session_created_at"]) if fresh is not None else "n/a")
        left, right = st.columns([1, 1])
        with left:
            st.subheader("Latest Sessions")
            st.dataframe(latest_sessions, use_container_width=True, hide_index=True)
        with right:
            st.subheader("Overnight Progress")
            st.dataframe(overnight_progress, use_container_width=True, hide_index=True)
        st.subheader("Registered Overnight Runs")
        st.dataframe(overnight_registered, use_container_width=True, hide_index=True)

    with tabs[1]:
        metric_cols = st.columns(6)
        metric_cols[0].metric("Sessions", int(overview_metrics.iloc[0]["sessions"]) if not overview_metrics.empty else 0)
        metric_cols[1].metric("Candidates", int(candidate_metrics.iloc[0]["candidates"]) if not candidate_metrics.empty else 0)
        metric_cols[2].metric("Games", int(game_metrics.iloc[0]["games"]) if not game_metrics.empty else 0)
        metric_cols[3].metric("Promotions", int(overview_metrics.iloc[0]["promotions"]) if not overview_metrics.empty else 0)
        metric_cols[4].metric("Avg Best Mass Ratio", f"{float(overview_metrics.iloc[0]['avg_best_mass_ratio']):.4f}" if not overview_metrics.empty and pd.notna(overview_metrics.iloc[0]["avg_best_mass_ratio"]) else "n/a")
        metric_cols[5].metric("Best Mass Ratio Seen", f"{float(overview_metrics.iloc[0]['best_mass_ratio_seen']):.4f}" if not overview_metrics.empty and pd.notna(overview_metrics.iloc[0]["best_mass_ratio_seen"]) else "n/a")
        if not trend.empty:
            trend_view = trend.copy()
            trend_view["mass_ratio_delta"] = trend_view["best_avg_mass_ratio"] - trend_view["baseline_avg_mass_ratio"]
            trend_view["game_time_delta"] = trend_view["best_avg_game_time"] - trend_view["baseline_avg_game_time"]
            st.subheader("Session Trend")
            st.line_chart(
                trend.set_index("created_at")[["baseline_avg_mass_ratio", "best_avg_mass_ratio", "baseline_avg_game_time", "best_avg_game_time"]],
                height=320,
            )
            st.subheader("Session Delta")
            st.line_chart(
                trend_view.set_index("created_at")[["mass_ratio_delta", "game_time_delta"]],
                height=220,
            )
        if not cumulative.empty:
            st.subheader("Best-So-Far Progress")
            st.line_chart(
                cumulative.set_index("games_processed")[["best_so_far_mass_ratio", "best_so_far_game_time"]],
                height=280,
            )
        st.subheader("Recent Sessions")
        st.dataframe(recent, use_container_width=True, hide_index=True)

    with tabs[2]:
        if kpis.empty:
            st.info("No KPI rows matched the current filters.")
        else:
            overview_cols = st.columns(4)
            with overview_cols[0]:
                render_metric_delta("First Mex 5", kpis["baseline_first_mex_5_time"], kpis["best_first_mex_5_time"], higher_is_better=False)
            with overview_cols[1]:
                render_metric_delta("Max Mex Ready", kpis["baseline_max_mex_ready"], kpis["best_max_mex_ready"], higher_is_better=True)
            with overview_cols[2]:
                render_metric_delta("Factories @600", kpis["baseline_fac_total_at_600"], kpis["best_fac_total_at_600"], higher_is_better=True)
            with overview_cols[3]:
                render_metric_delta("Mass Ratio", kpis["baseline_overmind_mass_in_ratio"], kpis["best_overmind_mass_in_ratio"], higher_is_better=True)
            kpi_options = {
                "First Mex 5": ("baseline_first_mex_5_time", "best_first_mex_5_time"),
                "First Mex 8": ("baseline_first_mex_8_time", "best_first_mex_8_time"),
                "First Factory 2": ("baseline_first_factory_2_time", "best_first_factory_2_time"),
                "Max Mex Ready": ("baseline_max_mex_ready", "best_max_mex_ready"),
                "Max Factory Total": ("baseline_max_factory_total", "best_max_factory_total"),
                "Mex @240": ("baseline_mex_at_240", "best_mex_at_240"),
                "Mex @360": ("baseline_mex_at_360", "best_mex_at_360"),
                "Mex @600": ("baseline_mex_at_600", "best_mex_at_600"),
                "Factories @240": ("baseline_fac_total_at_240", "best_fac_total_at_240"),
                "Factories @600": ("baseline_fac_total_at_600", "best_fac_total_at_600"),
                "Expansion Orders": ("baseline_expansion_orders_total", "best_expansion_orders_total"),
                "Reclaim Field Orders": ("baseline_reclaim_field_orders_total", "best_reclaim_field_orders_total"),
                "Stagnation Seconds": ("baseline_stagnation_seconds_est", "best_stagnation_seconds_est"),
                "Mass In Ratio": ("baseline_overmind_mass_in_ratio", "best_overmind_mass_in_ratio"),
            }
            selected_kpi = st.selectbox("KPI", list(kpi_options.keys()))
            baseline_col, best_col = kpi_options[selected_kpi]
            chart = kpis[["created_at", baseline_col, best_col]].copy().set_index("created_at")
            st.line_chart(chart, height=320)
            delta_table = kpis[["session_id", "created_at", baseline_col, best_col]].copy()
            delta_table["delta"] = delta_table[best_col] - delta_table[baseline_col]
            st.dataframe(delta_table.sort_values("created_at", ascending=False), use_container_width=True, hide_index=True)

    with tabs[3]:
        left, right = st.columns([1, 2])
        with left:
            st.subheader("Failure Counts")
            st.dataframe(failure_counts, use_container_width=True, hide_index=True)
        with right:
            if not failure_timeline.empty:
                st.subheader("Failure Trend")
                pivot = failure_timeline.pivot(index="created_day", columns="primary_failure_class", values="candidates").fillna(0)
                st.line_chart(pivot, height=300)
        st.subheader("Failure Hotspots")
        st.dataframe(hotspots, use_container_width=True, hide_index=True)

    with tabs[4]:
        st.subheader("Current Champions")
        st.dataframe(champions, use_container_width=True, hide_index=True)
        st.subheader("Session Leaderboard")
        st.dataframe(leaderboard, use_container_width=True, hide_index=True)
        st.subheader("Map / Opponent Profiles")
        st.dataframe(profiles, use_container_width=True, hide_index=True)

    with tabs[5]:
        left, right = st.columns(2)
        with left:
            st.subheader("Parameter Effects")
            st.dataframe(params_effects, use_container_width=True, hide_index=True)
        with right:
            st.subheader("Failure-Class Parameter Patterns")
            st.dataframe(failure_params, use_container_width=True, hide_index=True)

    with tabs[6]:
        st.subheader("Top Action Choices")
        st.dataframe(action_choices, use_container_width=True, hide_index=True)
        sub_left, sub_right = st.columns(2)
        with sub_left:
            st.subheader("Action Value by Subsystem")
            st.dataframe(action_subsystem, use_container_width=True, hide_index=True)
        with sub_right:
            st.subheader("Failure Precursors")
            st.dataframe(action_precursors, use_container_width=True, hide_index=True)

    with tabs[7]:
        if session_catalog.empty:
            st.info("No sessions matched the current filters.")
        else:
            selected_session = st.selectbox("Session", session_catalog["session_id"].tolist(), index=0)
            meta, session_candidates, session_kpis, session_games, session_econ, session_params = load_session_detail(selected_session)
            if meta.empty:
                st.warning("Selected session has no detail rows.")
            else:
                info = meta.iloc[0]
                summary = st.columns(6)
                summary[0].metric("Best Candidate", str(info["best_candidate"]))
                summary[1].metric("Best Score", f"{float(info['best_score']):.2f}" if pd.notna(info["best_score"]) else "n/a")
                summary[2].metric("Best Mass Ratio", f"{float(info['best_avg_mass_ratio']):.4f}" if pd.notna(info["best_avg_mass_ratio"]) else "n/a")
                summary[3].metric("Best Avg Time", f"{float(info['best_avg_game_time']):.1f}" if pd.notna(info["best_avg_game_time"]) else "n/a")
                summary[4].metric("Baseline Mass Ratio", f"{float(info['baseline_avg_mass_ratio']):.4f}" if pd.notna(info["baseline_avg_mass_ratio"]) else "n/a")
                summary[5].metric("Promoted", str(bool(info["promoted"])))
                st.write(
                    {
                        "session_id": info["session_id"],
                        "overnight_session_id": info["overnight_session_id"],
                        "created_at": str(info["created_at"]),
                        "map_name": info["map_name"],
                        "opponent_key": info["opponent_key"],
                        "ai_matchup": info["ai_matchup"],
                        "version": info["version"],
                        "fingerprint": info["fingerprint"],
                        "margin": info["margin"],
                        "best_primary_failure_class": info["best_primary_failure_class"],
                        "baseline_primary_failure_class": info["baseline_primary_failure_class"],
                        "promotion_allowed": info["promotion_allowed"],
                        "promotion_blocked_reasons": info["promotion_blocked_reasons"],
                    }
                )
                left, right = st.columns([1, 1])
                with left:
                    st.subheader("Candidate Results")
                    st.dataframe(session_candidates, use_container_width=True, hide_index=True)
                    st.download_button(
                        "Download Candidates CSV",
                        session_candidates.to_csv(index=False).encode("utf-8"),
                        file_name=f"{selected_session}-candidates.csv",
                        mime="text/csv",
                    )
                with right:
                    st.subheader("Candidate KPI Rollup")
                    st.dataframe(session_kpis, use_container_width=True, hide_index=True)
                    st.download_button(
                        "Download KPI CSV",
                        session_kpis.to_csv(index=False).encode("utf-8"),
                        file_name=f"{selected_session}-kpis.csv",
                        mime="text/csv",
                    )
                lower_left, lower_right = st.columns([1, 1])
                with lower_left:
                    st.subheader("Per-Candidate Economy Summary")
                    st.dataframe(session_econ, use_container_width=True, hide_index=True)
                with lower_right:
                    selected_candidate = st.selectbox(
                        "Candidate Parameters",
                        session_candidates["candidate_id"].tolist(),
                        index=0,
                        key=f"candidate_params_{selected_session}",
                    )
                    st.dataframe(
                        session_params[session_params["candidate_id"] == selected_candidate],
                        use_container_width=True,
                        hide_index=True,
                    )
                st.subheader("Per-Game Results")
                st.dataframe(session_games, use_container_width=True, hide_index=True)
                st.download_button(
                    "Download Games CSV",
                    session_games.to_csv(index=False).encode("utf-8"),
                    file_name=f"{selected_session}-games.csv",
                    mime="text/csv",
                )


if __name__ == "__main__":
    main()
