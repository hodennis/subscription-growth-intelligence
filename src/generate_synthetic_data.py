#!/usr/bin/env python3
"""Generate deterministic, synthetic subscription-marketing source extracts.

The generator creates four source-grain CSV files and a machine-readable QA
summary. It intentionally simulates a localized client-side tracking loss while
leaving underlying paid demand and backend trial creation unchanged.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "synthetic_scenarios.yml"
DEFAULT_OUTPUT = ROOT / "data" / "generated"
DEFAULT_SAMPLE = ROOT / "data" / "sample"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--sample-dir", type=Path, default=DEFAULT_SAMPLE)
    parser.add_argument("--sample-rows", type=int, default=100)
    return parser.parse_args()


def load_config(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def random_timestamp(rng: np.random.Generator, day: pd.Timestamp) -> pd.Timestamp:
    second = int(rng.integers(7 * 3600, 23 * 3600))
    return day + pd.Timedelta(seconds=second)


def source_refresh_timestamp(day: pd.Timestamp) -> pd.Timestamp:
    return day.normalize() + pd.Timedelta(days=1, hours=6)


def clip_probability(value: float) -> float:
    return float(np.clip(value, 0.001, 0.999))


def make_ad_performance(
    config: dict[str, Any], rng: np.random.Generator
) -> pd.DataFrame:
    project = config["project"]
    dates = pd.date_range(project["data_start_date"], project["data_end_date"], freq="D")
    rows: list[dict[str, Any]] = []

    for day_index, day in enumerate(dates):
        weekday_factor = 1.06 if day.dayofweek < 5 else 0.86
        seasonal_factor = 1.0 + 0.08 * math.sin(2 * math.pi * day_index / 45)
        for campaign in config["campaigns"]:
            noise = float(rng.lognormal(mean=0.0, sigma=0.08))
            impressions = max(
                1,
                int(round(campaign["daily_impressions"] * weekday_factor * seasonal_factor * noise)),
            )
            clicks = int(rng.binomial(impressions, clip_probability(campaign["click_through_rate"])))
            cpc_noise = max(0.65, float(rng.normal(1.0, 0.06)))
            spend = round(clicks * campaign["average_cpc_usd"] * cpc_noise, 2)
            rows.append(
                {
                    "ad_date": day.date().isoformat(),
                    "campaign_id": campaign["campaign_id"],
                    "campaign_name": campaign["campaign_name"],
                    "channel": campaign["channel"],
                    "platform": campaign["platform"],
                    "impressions": impressions,
                    "clicks": clicks,
                    "spend_usd": spend,
                    "source_updated_at": source_refresh_timestamp(day),
                }
            )

    return pd.DataFrame(rows)


def choose_device(rng: np.random.Generator, mobile_share: float) -> str:
    tablet_share = 0.04
    desktop_share = 1.0 - mobile_share - tablet_share
    return str(
        rng.choice(
            ["desktop", "mobile", "tablet"],
            p=[desktop_share, mobile_share, tablet_share],
        )
    )


def utm_values(campaign: dict[str, Any]) -> tuple[str, str, str]:
    platform = campaign["platform"]
    if platform == "Google Ads":
        source, medium = "google", "cpc"
    elif platform == "Microsoft Ads":
        source, medium = "bing", "cpc"
    else:
        source, medium = "meta", "paid_social"
    token = campaign["campaign_name"].lower().replace(" ", "_")
    return source, medium, token


def click_id_prefix(platform: str) -> str:
    return {
        "Google Ads": "gclid",
        "Microsoft Ads": "msclkid",
        "Meta Ads": "fbclid",
    }[platform]


def generate_sessions_and_trials(
    config: dict[str, Any],
    ads: pd.DataFrame,
    rng: np.random.Generator,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    project = config["project"]
    anomaly = config["tracking_anomaly"]
    anomaly_start = pd.Timestamp(anomaly["start_date"])
    anomaly_end = pd.Timestamp(anomaly["end_date"]) + pd.Timedelta(days=1)
    analysis_end = pd.Timestamp(project["analysis_date"]) + pd.Timedelta(days=1) - pd.Timedelta(seconds=1)
    campaign_lookup = {c["campaign_id"]: c for c in config["campaigns"]}

    web_rows: list[dict[str, Any]] = []
    subscription_rows: list[dict[str, Any]] = []
    paid_visitor_history: list[tuple[str, pd.Timestamp]] = []
    subscribed_visitors: set[str] = set()
    visitor_number = 0
    session_number = 0
    subscription_number = 0

    def add_subscription(
        visitor_id: str,
        trial_start: pd.Timestamp,
        signup_campaign_id: str | None,
        device: str,
        landing_page: str,
    ) -> None:
        nonlocal subscription_number
        if visitor_id in subscribed_visitors or trial_start > analysis_end:
            return
        subscription_number += 1
        plan_names = [plan["plan_name"] for plan in config["plans"]]
        plan_weights = [plan["selection_weight"] for plan in config["plans"]]
        plan_name = str(rng.choice(plan_names, p=plan_weights))
        plan = next(p for p in config["plans"] if p["plan_name"] == plan_name)
        subscription_rows.append(
            {
                "subscription_id": f"sub_{subscription_number:07d}",
                "customer_id": f"cus_{subscription_number:07d}",
                "visitor_id": visitor_id,
                "trial_start_ts": trial_start,
                "paid_start_ts": pd.NaT,
                "plan_name": plan_name,
                "monthly_price_usd": plan["monthly_price_usd"],
                "signup_campaign_id": signup_campaign_id,
                "signup_device_category": device,
                "signup_landing_page": landing_page,
                "cancel_ts": pd.NaT,
                "cancel_reason": None,
                "source_updated_at": source_refresh_timestamp(trial_start.normalize()),
            }
        )
        subscribed_visitors.add(visitor_id)

    for ad in ads.itertuples(index=False):
        day = pd.Timestamp(ad.ad_date)
        campaign = campaign_lookup[ad.campaign_id]
        session_count = int(rng.binomial(ad.clicks, clip_probability(campaign["sessions_per_click"])))
        utm_source, utm_medium, utm_campaign = utm_values(campaign)

        for _ in range(session_count):
            visitor_number += 1
            session_number += 1
            visitor_id = f"vis_{visitor_number:08d}"
            session_id = f"ses_{session_number:08d}"
            session_ts = random_timestamp(rng, day)
            device = choose_device(rng, campaign["mobile_share"])
            landing_page = campaign["default_landing_page"]
            paid_visitor_history.append((visitor_id, session_ts))

            affected = (
                anomaly_start <= session_ts < anomaly_end
                and campaign["campaign_id"] == anomaly["campaign_id"]
                and device == anomaly["device_category"]
                and landing_page == anomaly["landing_page"]
            )

            starts_trial = bool(rng.random() < campaign["backend_trial_rate"])
            trial_start = session_ts + pd.Timedelta(minutes=int(rng.integers(2, 61)))
            if starts_trial:
                add_subscription(
                    visitor_id,
                    trial_start,
                    campaign["campaign_id"],
                    device,
                    landing_page,
                )

            captured = bool(
                rng.random()
                < (anomaly["tracked_session_retention_rate"] if affected else 0.96)
            )
            if not captured:
                continue

            click_id_coverage = anomaly["click_id_retention_rate"] if affected else 0.93
            click_id = None
            if rng.random() < click_id_coverage:
                click_id = f"{click_id_prefix(campaign['platform'])}_{session_number:010d}"

            tracked_event_probability = (
                anomaly["tracked_trial_event_retention_rate"] if affected else 0.92
            )
            tracked_trial_event = starts_trial and bool(rng.random() < tracked_event_probability)
            web_rows.append(
                {
                    "session_id": session_id,
                    "visitor_id": visitor_id,
                    "session_ts": session_ts,
                    "campaign_id": campaign["campaign_id"],
                    "utm_source": utm_source,
                    "utm_medium": utm_medium,
                    "utm_campaign": utm_campaign,
                    "click_id": click_id,
                    "landing_page": landing_page,
                    "device_category": device,
                    "tracked_trial_event": tracked_trial_event,
                    "source_updated_at": source_refresh_timestamp(day),
                }
            )

    direct = config["direct_traffic"]
    dates = pd.date_range(project["data_start_date"], project["data_end_date"], freq="D")
    landing_pages = ["/", "/account", "/search"]
    for day in dates:
        direct_count = int(rng.poisson(direct["daily_sessions"] * (1.04 if day.dayofweek < 5 else 0.90)))
        eligible_returning = [item for item in paid_visitor_history if day - pd.Timedelta(days=30) <= item[1] < day]
        for _ in range(direct_count):
            session_number += 1
            returning = bool(eligible_returning and rng.random() < direct["returning_visitor_share"])
            if returning:
                visitor_id = eligible_returning[int(rng.integers(0, len(eligible_returning)))][0]
            else:
                visitor_number += 1
                visitor_id = f"vis_{visitor_number:08d}"
            session_ts = random_timestamp(rng, day)
            device = choose_device(rng, 0.64)
            landing_page = str(rng.choice(landing_pages, p=[0.55, 0.10, 0.35]))
            starts_trial = visitor_id not in subscribed_visitors and bool(
                rng.random() < direct["backend_trial_rate"]
            )
            if starts_trial:
                add_subscription(
                    visitor_id,
                    session_ts + pd.Timedelta(minutes=int(rng.integers(2, 61))),
                    None,
                    device,
                    landing_page,
                )
            web_rows.append(
                {
                    "session_id": f"ses_{session_number:08d}",
                    "visitor_id": visitor_id,
                    "session_ts": session_ts,
                    "campaign_id": None,
                    "utm_source": None,
                    "utm_medium": None,
                    "utm_campaign": None,
                    "click_id": None,
                    "landing_page": landing_page,
                    "device_category": device,
                    "tracked_trial_event": starts_trial and bool(rng.random() < 0.94),
                    "source_updated_at": source_refresh_timestamp(day),
                }
            )

    web = pd.DataFrame(web_rows).sort_values(["session_ts", "session_id"]).reset_index(drop=True)
    subscriptions = (
        pd.DataFrame(subscription_rows)
        .sort_values(["trial_start_ts", "subscription_id"])
        .reset_index(drop=True)
    )
    return web, subscriptions


def add_charge_event(
    rows: list[dict[str, Any]],
    event_number: int,
    subscription_id: str,
    event_ts: pd.Timestamp,
    cycle: int,
    status: str,
    gross: float,
    discount: float = 0.0,
) -> int:
    event_number += 1
    rows.append(
        {
            "billing_event_id": f"bill_{event_number:08d}",
            "subscription_id": subscription_id,
            "event_ts": event_ts,
            "event_type": "charge",
            "billing_cycle_number": cycle,
            "event_status": status,
            "gross_amount_usd": round(gross, 2),
            "discount_amount_usd": round(discount, 2),
            "refund_amount_usd": 0.0,
            "chargeback_amount_usd": 0.0,
            "net_amount_usd": round(gross - discount, 2) if status == "succeeded" else 0.0,
            "source_updated_at": source_refresh_timestamp(event_ts.normalize()),
        }
    )
    return event_number


def add_negative_event(
    rows: list[dict[str, Any]],
    event_number: int,
    subscription_id: str,
    event_ts: pd.Timestamp,
    event_type: str,
    amount: float,
) -> int:
    event_number += 1
    rows.append(
        {
            "billing_event_id": f"bill_{event_number:08d}",
            "subscription_id": subscription_id,
            "event_ts": event_ts,
            "event_type": event_type,
            "billing_cycle_number": None,
            "event_status": "succeeded",
            "gross_amount_usd": 0.0,
            "discount_amount_usd": 0.0,
            "refund_amount_usd": round(amount, 2) if event_type == "refund" else 0.0,
            "chargeback_amount_usd": round(amount, 2) if event_type == "chargeback" else 0.0,
            "net_amount_usd": round(-amount, 2),
            "source_updated_at": source_refresh_timestamp(event_ts.normalize()),
        }
    )
    return event_number


def generate_billing(
    config: dict[str, Any],
    subscriptions: pd.DataFrame,
    rng: np.random.Generator,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    analysis_end = (
        pd.Timestamp(config["project"]["analysis_date"])
        + pd.Timedelta(days=1)
        - pd.Timedelta(seconds=1)
    )
    trial_days = int(config["project"]["trial_length_days"])
    campaign_lookup = {c["campaign_id"]: c for c in config["campaigns"]}
    direct = config["direct_traffic"]
    event_rows: list[dict[str, Any]] = []
    event_number = 0

    subscriptions = subscriptions.copy()
    for index, subscription in subscriptions.iterrows():
        trial_start = pd.Timestamp(subscription["trial_start_ts"])
        first_due = trial_start + pd.Timedelta(days=trial_days)
        if first_due > analysis_end:
            continue

        campaign = campaign_lookup.get(subscription["signup_campaign_id"])
        conversion_rate = (
            campaign["paid_conversion_rate"] if campaign is not None else direct["paid_conversion_rate"]
        )
        retention_rate = (
            campaign["monthly_retention_rate"] if campaign is not None else direct["monthly_retention_rate"]
        )
        price = float(subscription["monthly_price_usd"])
        will_convert = bool(rng.random() < conversion_rate)

        if not will_convert:
            if rng.random() < 0.18:
                event_number = add_charge_event(
                    event_rows,
                    event_number,
                    subscription["subscription_id"],
                    first_due,
                    1,
                    "failed",
                    price,
                )
                cancel_reason = "payment_failure"
            else:
                cancel_reason = "trial_canceled"
            subscriptions.at[index, "cancel_ts"] = first_due
            subscriptions.at[index, "cancel_reason"] = cancel_reason
            continue

        paid_start = first_due
        if rng.random() < 0.08:
            event_number = add_charge_event(
                event_rows,
                event_number,
                subscription["subscription_id"],
                first_due,
                1,
                "failed",
                price,
            )
            paid_start = first_due + pd.Timedelta(days=int(rng.integers(1, 4)))

        first_discount = round(price * 0.10, 2) if rng.random() < 0.15 else 0.0
        event_number = add_charge_event(
            event_rows,
            event_number,
            subscription["subscription_id"],
            paid_start,
            1,
            "succeeded",
            price,
            first_discount,
        )
        subscriptions.at[index, "paid_start_ts"] = paid_start

        if rng.random() < 0.020 and paid_start + pd.Timedelta(days=10) <= analysis_end:
            refund_ts = paid_start + pd.Timedelta(days=int(rng.integers(2, 11)))
            event_number = add_negative_event(
                event_rows,
                event_number,
                subscription["subscription_id"],
                refund_ts,
                "refund",
                price - first_discount,
            )
            subscriptions.at[index, "cancel_ts"] = refund_ts
            subscriptions.at[index, "cancel_reason"] = "refunded"
            continue
        if rng.random() < 0.006 and paid_start + pd.Timedelta(days=20) <= analysis_end:
            chargeback_ts = paid_start + pd.Timedelta(days=int(rng.integers(10, 21)))
            event_number = add_negative_event(
                event_rows,
                event_number,
                subscription["subscription_id"],
                chargeback_ts,
                "chargeback",
                price - first_discount,
            )
            subscriptions.at[index, "cancel_ts"] = chargeback_ts
            subscriptions.at[index, "cancel_reason"] = "chargeback"
            continue

        cycle = 2
        next_due = paid_start + pd.Timedelta(days=30)
        while next_due <= analysis_end:
            if rng.random() >= retention_rate:
                if rng.random() < 0.55:
                    event_number = add_charge_event(
                        event_rows,
                        event_number,
                        subscription["subscription_id"],
                        next_due,
                        cycle,
                        "failed",
                        price,
                    )
                    cancel_reason = "payment_failure"
                else:
                    cancel_reason = "voluntary_churn"
                subscriptions.at[index, "cancel_ts"] = next_due
                subscriptions.at[index, "cancel_reason"] = cancel_reason
                break

            successful_ts = next_due
            if rng.random() < 0.06:
                event_number = add_charge_event(
                    event_rows,
                    event_number,
                    subscription["subscription_id"],
                    next_due,
                    cycle,
                    "failed",
                    price,
                )
                successful_ts = next_due + pd.Timedelta(days=int(rng.integers(1, 4)))
                if successful_ts > analysis_end:
                    break
            event_number = add_charge_event(
                event_rows,
                event_number,
                subscription["subscription_id"],
                successful_ts,
                cycle,
                "succeeded",
                price,
            )

            if rng.random() < 0.012 and successful_ts + pd.Timedelta(days=7) <= analysis_end:
                refund_ts = successful_ts + pd.Timedelta(days=int(rng.integers(2, 8)))
                event_number = add_negative_event(
                    event_rows,
                    event_number,
                    subscription["subscription_id"],
                    refund_ts,
                    "refund",
                    price,
                )
                subscriptions.at[index, "cancel_ts"] = refund_ts
                subscriptions.at[index, "cancel_reason"] = "refunded"
                break

            cycle += 1
            next_due = paid_start + pd.Timedelta(days=30 * (cycle - 1))

    billing = pd.DataFrame(event_rows).sort_values(["event_ts", "billing_event_id"]).reset_index(drop=True)
    subscriptions = subscriptions.sort_values(["trial_start_ts", "subscription_id"]).reset_index(drop=True)
    return subscriptions, billing


def qa_summary(
    config: dict[str, Any],
    ads: pd.DataFrame,
    web: pd.DataFrame,
    subscriptions: pd.DataFrame,
    billing: pd.DataFrame,
) -> dict[str, Any]:
    checks: dict[str, bool] = {}
    checks["ad_primary_key_unique"] = not ads.duplicated(["ad_date", "campaign_id"]).any()
    checks["session_primary_key_unique"] = web["session_id"].is_unique
    checks["subscription_primary_key_unique"] = subscriptions["subscription_id"].is_unique
    checks["billing_primary_key_unique"] = billing["billing_event_id"].is_unique
    checks["clicks_not_above_impressions"] = bool((ads["clicks"] <= ads["impressions"]).all())
    checks["nonnegative_spend"] = bool((ads["spend_usd"] >= 0).all())
    checks["billing_foreign_keys_valid"] = bool(
        billing["subscription_id"].isin(subscriptions["subscription_id"]).all()
    )
    checks["failed_charge_net_zero"] = bool(
        (
            billing.loc[
                (billing["event_type"] == "charge") & (billing["event_status"] == "failed"),
                "net_amount_usd",
            ]
            == 0
        ).all()
    )
    checks["negative_events_nonpositive"] = bool(
        (
            billing.loc[billing["event_type"].isin(["refund", "chargeback"]), "net_amount_usd"]
            <= 0
        ).all()
    )
    paid_subscriptions = set(subscriptions.loc[subscriptions["paid_start_ts"].notna(), "subscription_id"])
    first_payment_subscriptions = set(
        billing.loc[
            (billing["event_type"] == "charge")
            & (billing["billing_cycle_number"] == 1)
            & (billing["event_status"] == "succeeded"),
            "subscription_id",
        ]
    )
    checks["paid_start_matches_successful_first_payment"] = (
        paid_subscriptions == first_payment_subscriptions
    )

    anomaly = config["tracking_anomaly"]
    anomaly_dates = pd.date_range(anomaly["start_date"], anomaly["end_date"], freq="D")
    baseline_dates = pd.date_range(
        pd.Timestamp(anomaly["start_date"]) - pd.Timedelta(days=14),
        pd.Timestamp(anomaly["start_date"]) - pd.Timedelta(days=1),
        freq="D",
    )
    ad_date_values = pd.to_datetime(ads["ad_date"])
    session_dates = pd.to_datetime(web["session_ts"]).dt.normalize()
    trial_dates = pd.to_datetime(subscriptions["trial_start_ts"]).dt.normalize()

    def ad_clicks_per_day(dates: pd.DatetimeIndex) -> float:
        mask = (ads["campaign_id"] == anomaly["campaign_id"]) & ad_date_values.isin(dates)
        return float(ads.loc[mask, "clicks"].sum() / len(dates))

    def segment_sessions_per_day(dates: pd.DatetimeIndex) -> float:
        mask = (
            (web["campaign_id"] == anomaly["campaign_id"])
            & (web["device_category"] == anomaly["device_category"])
            & (web["landing_page"] == anomaly["landing_page"])
            & session_dates.isin(dates)
        )
        return float(mask.sum() / len(dates))

    def click_id_coverage(dates: pd.DatetimeIndex) -> float:
        mask = (
            (web["campaign_id"] == anomaly["campaign_id"])
            & (web["device_category"] == anomaly["device_category"])
            & (web["landing_page"] == anomaly["landing_page"])
            & session_dates.isin(dates)
        )
        return float(web.loc[mask, "click_id"].notna().mean()) if mask.any() else 0.0

    def backend_trials_per_day(dates: pd.DatetimeIndex) -> float:
        mask = (
            (subscriptions["signup_campaign_id"] == anomaly["campaign_id"])
            & (subscriptions["signup_device_category"] == anomaly["device_category"])
            & (subscriptions["signup_landing_page"] == anomaly["landing_page"])
            & trial_dates.isin(dates)
        )
        return float(mask.sum() / len(dates))

    ratios = {
        "ad_clicks_anomaly_vs_baseline": ad_clicks_per_day(anomaly_dates)
        / max(ad_clicks_per_day(baseline_dates), 1e-9),
        "captured_segment_sessions_anomaly_vs_baseline": segment_sessions_per_day(anomaly_dates)
        / max(segment_sessions_per_day(baseline_dates), 1e-9),
        "click_id_coverage_anomaly_vs_baseline": click_id_coverage(anomaly_dates)
        / max(click_id_coverage(baseline_dates), 1e-9),
        "backend_segment_trials_anomaly_vs_baseline": backend_trials_per_day(anomaly_dates)
        / max(backend_trials_per_day(baseline_dates), 1e-9),
    }
    checks["anomaly_ad_clicks_near_baseline"] = 0.65 <= ratios["ad_clicks_anomaly_vs_baseline"] <= 1.35
    checks["anomaly_captured_sessions_drop"] = ratios[
        "captured_segment_sessions_anomaly_vs_baseline"
    ] < 0.60
    checks["anomaly_click_id_coverage_drop"] = ratios[
        "click_id_coverage_anomaly_vs_baseline"
    ] < 0.50
    checks["anomaly_backend_trials_not_collapsed"] = ratios[
        "backend_segment_trials_anomaly_vs_baseline"
    ] >= 0.60

    failed = [name for name, passed in checks.items() if not passed]
    return {
        "status": "PASS" if not failed else "FAIL",
        "row_counts": {
            "ad_performance_daily": int(len(ads)),
            "web_sessions": int(len(web)),
            "subscriptions": int(len(subscriptions)),
            "billing_events": int(len(billing)),
        },
        "checks": checks,
        "anomaly_ratios": {name: round(value, 4) for name, value in ratios.items()},
        "failed_checks": failed,
    }


def write_outputs(
    output_dir: Path,
    sample_dir: Path,
    sample_rows: int,
    tables: dict[str, pd.DataFrame],
    summary: dict[str, Any],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    sample_dir.mkdir(parents=True, exist_ok=True)
    for name, frame in tables.items():
        frame.to_csv(output_dir / f"{name}.csv", index=False, date_format="%Y-%m-%d %H:%M:%S")
        frame.head(sample_rows).to_csv(
            sample_dir / f"{name}_sample.csv",
            index=False,
            date_format="%Y-%m-%d %H:%M:%S",
        )
    with (output_dir / "source_qa_summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)


def main() -> int:
    args = parse_args()
    config = load_config(args.config)
    rng = np.random.default_rng(int(config["project"]["random_seed"]))

    ads = make_ad_performance(config, rng)
    web, subscriptions = generate_sessions_and_trials(config, ads, rng)
    subscriptions, billing = generate_billing(config, subscriptions, rng)
    tables = {
        "ad_performance_daily": ads,
        "web_sessions": web,
        "subscriptions": subscriptions,
        "billing_events": billing,
    }
    summary = qa_summary(config, ads, web, subscriptions, billing)
    write_outputs(args.output_dir, args.sample_dir, args.sample_rows, tables, summary)

    print(json.dumps(summary, indent=2))
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

