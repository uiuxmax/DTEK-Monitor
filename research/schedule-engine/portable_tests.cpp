#include "test_support.h"

namespace engine_tests {
void run_portable_tests() {
    auto s = fixture();
    check("01 future outage", s, base, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));
    fresh_at(s, base + 5400);
    check("02 during outage", s, base + 5400, fixed_zone,
          ready(EventKind::power_restored, 1800, "Відновлення через 30 хв"));
    fresh_at(s, base + 3600);
    check("03 exact start is inside", s, base + 3600, fixed_zone,
          ready(EventKind::power_restored, 3600, "Відновлення через 1 г"));
    fresh_at(s, base + 7200);
    check("04 exact end is outside", s, base + 7200, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    s = fixture(); s.days[0].outages.push_back({base + 9000, base + 10800});
    fresh_at(s, base + 7200);
    check("05 next start after end", s, base + 7200, fixed_zone,
          ready(EventKind::outage_starts, 1800, "Відключення через 30 хв"));
    s = fixture(); s.days[0].outages.push_back({base + 7200, base + 9000});
    fresh_at(s, base + 5400);
    check("06 adjacent intervals merge", s, base + 5400, fixed_zone,
          ready(EventKind::power_restored, 3600, "Відновлення через 1 г"));
    s = fixture(); s.days[0].outages.push_back({base + 6000, base + 9000});
    fresh_at(s, base + 5400);
    check("07 overlapping intervals merge", s, base + 5400, fixed_zone,
          ready(EventKind::power_restored, 3600, "Відновлення через 1 г"));

    s = fixture(); s.address.displayed_house = "36А";
    check("08 house suffix mismatch", s, base, fixed_zone,
          denied(OutcomeKind::address_unverified));
    s = fixture(); s.address.exact_source_match = false;
    check("09 unresolved address", s, base, fixed_zone,
          denied(OutcomeKind::address_unverified));
    s = fixture(); s.address.identities.push_back({"synthetic-provider", "line-b"});
    check("10 two lines ambiguous", s, base, fixed_zone,
          denied(OutcomeKind::ambiguous_line));
    s.address.line_explicitly_resolved = true;
    check("11 two lines explicitly resolved", s, base, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));
    s = fixture(); s.days[0].identity.provider = "other-provider";
    check("12 cross-provider identity", s, base, fixed_zone,
          denied(OutcomeKind::unsupported_schema));

    s = fixture(); s.days[0].applicability = Applicability::emergency;
    check("13 emergency blocks populated table", s, base, fixed_zone,
          denied(OutcomeKind::emergency));
    s = fixture(); s.days[0].applicability = Applicability::unknown;
    check("14 unknown status", s, base, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));
    s = fixture(); s.days[0].applicability = Applicability::no_outages_unverified;
    check("15 unverified NoOutages", s, base, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));
    s = fixture(); s.days[0].outages.clear();
    check("16 empty intervals", s, base, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));
    s = fixture(); s.days[0].interval_semantics_verified = false;
    check("17 unverified interval semantics", s, base, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    s = fixture(); s.fetched_at_utc = base - 4000;
    check("18 stale fetch", s, base, fixed_zone,
          denied(OutcomeKind::stale));
    s = fixture(); s.source_updated_at_utc = base - 4000;
    check("19 fresh fetch old source update", s, base, fixed_zone,
          denied(OutcomeKind::stale));
    s = fixture(); s.failure = Failure::dns;
    check("20 DNS failure", s, base, fixed_zone,
          denied(OutcomeKind::source_unavailable));
    s = fixture(); s.failure = Failure::unexpected_body;
    check("21 HTML challenge body", s, base, fixed_zone,
          denied(OutcomeKind::source_unavailable));
    s = fixture(); s.parse_state = ParseState::unsupported_schema;
    check("22 changed schema", s, base, fixed_zone,
          denied(OutcomeKind::unsupported_schema));
    s = fixture(); s.days[0].outages = {{base + 3600, base + 3600}};
    check("23 zero length interval", s, base, fixed_zone,
          denied(OutcomeKind::unsupported_schema));
    s = fixture(); s.days[0].timezone = TimeZoneId::unsupported;
    check("24 wrong timezone", s, base, fixed_zone,
          denied(OutcomeKind::unsupported_schema));
    s = fixture(); s.days[0].local_date = {2026, 1, 14};
    s.days[0].outages = {{utc(2026, 1, 14, 10), utc(2026, 1, 14, 11)}};
    check("25 missing local day", s, base, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    // A date rollover requires both applicable dated records. Each is synthetic.
    const auto midnight_now = utc(2026, 1, 15, 21, 30);
    s = fixture();
    s.fetched_at_utc = midnight_now - 60;
    s.source_updated_at_utc = midnight_now - 120;
    s.days[0].outages = {{utc(2026, 1, 15, 20), utc(2026, 1, 15, 21)}};
    s.days.push_back({{2026, 1, 16}, TimeZoneId::europe_kyiv, {"synthetic-provider", "line-a"},
                      Applicability::explicitly_applicable, true,
                      {{utc(2026, 1, 15, 22, 30), utc(2026, 1, 15, 23)}}});
    check("26 next local day", s, midnight_now, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));
    s.days.pop_back();
    check("27 next day missing", s, midnight_now, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    // Supplied offset transition is an invented TEST INPUT, not a Kyiv DST rule.
    const ExplicitKyivOffset offset_change({
        {utc(2026, 1, 15, 0), utc(2026, 1, 15, 12), 120},
        {utc(2026, 1, 15, 12), utc(2026, 1, 16, 0), 180}});
    s = fixture(); s.days[0].outages = {{base + 3 * 3600, base + 4 * 3600}};
    check("28 supplied forward offset change", s, base, offset_change,
          ready(EventKind::outage_starts, 10800, "Відключення через 3 г"));

    s = fixture(); s.days[0].outages = {{base + 7200, base + 9000}};
    check("29 outage in exactly 2 hours", s, base, fixed_zone,
          ready(EventKind::outage_starts, 7200, "Відключення через 2 г"));
    s.days[0].outages = {{base + 300, base + 900}};
    check("30 outage in exactly 5 minutes", s, base, fixed_zone,
          ready(EventKind::outage_starts, 300, "Відключення через 5 хв"));
    s.days[0].outages = {{base + 30, base + 900}};
    check("31 outage in under a minute", s, base, fixed_zone,
          ready(EventKind::outage_starts, 30, "Відключення через менше 1 хв"));

    // Midnight restoration requires an applicable record on both local dates.
    const auto before_midnight = utc(2026, 1, 15, 21, 59);
    s = fixture(); fresh_at(s, before_midnight);
    s.days[0].outages = {{utc(2026, 1, 15, 21, 55), utc(2026, 1, 15, 22, 10)}};
    s.days.push_back({{2026, 1, 16}, TimeZoneId::europe_kyiv, {"synthetic-provider", "line-a"},
                      Applicability::explicitly_applicable, true,
                      {{utc(2026, 1, 15, 22, 30), utc(2026, 1, 15, 23)}}});
    check("32 restoration past local midnight", s, before_midnight, fixed_zone,
          ready(EventKind::power_restored, 660, "Відновлення через 11 хв"));
    s.days[1].applicability = Applicability::unknown;
    check("33 tomorrow unpublished", s, before_midnight, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    s = fixture(); fresh_at(s, base + 1800);
    check("34 sleep resume recalculates before event", s, base + 1800, fixed_zone,
          ready(EventKind::outage_starts, 1800, "Відключення через 30 хв"));
    fresh_at(s, base + 4500);
    check("35 sleep resume recalculates inside interval", s, base + 4500, fixed_zone,
          ready(EventKind::power_restored, 2700, "Відновлення через 45 хв"));
    s = fixture(); fresh_at(s, base - 900);
    check("36 backward clock correction recalculates", s, base - 900, fixed_zone,
          ready(EventKind::outage_starts, 4500, "Відключення через 1 г 15 хв"));
    s = fixture(); fresh_at(s, base + 10800);
    check("37 no event in verified horizon", s, base + 10800, fixed_zone,
          denied(OutcomeKind::schedule_unavailable));

    // Synthetic seasonal transition supplied by fixture; not a Kyiv DST rule.
    const ExplicitKyivOffset seasonal_zone({
        {utc(2026, 3, 28, 0), utc(2026, 3, 29, 1), 120},
        {utc(2026, 3, 29, 1), utc(2026, 3, 30, 0), 180}});
    const auto seasonal_now = utc(2026, 3, 29, 0, 30);
    s = fixture(); fresh_at(s, seasonal_now);
    s.days[0].local_date = {2026, 3, 29};
    s.days[0].outages = {{utc(2026, 3, 29, 1, 30), utc(2026, 3, 29, 2)}};
    check("38 supplied seasonal offset transition", s, seasonal_now, seasonal_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));

    s = fixture(); s.days[0].local_date = {2026, 1, 14};
    check("39 contradictory interval start date", s, base, fixed_zone,
          denied(OutcomeKind::unsupported_schema));

    s = fixture();
    check("50 missing timezone data fails closed", s, base, UnavailableKyivTimeZone{},
          denied(OutcomeKind::unsupported_schema));

    s = fixture();
    s.days.push_back({{2026, 1, 14}, TimeZoneId::europe_kyiv, {"synthetic-provider", "line-a"},
                      Applicability::emergency, true,
                      {{utc(2026, 1, 14, 21), base + 1800}}});
    check("65 yesterday emergency cannot supply restoration", s, base, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));
    s.days[1].applicability = Applicability::unknown;
    check("66 yesterday unknown cannot supply restoration", s, base, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));
    s.days[1].applicability = Applicability::explicitly_applicable;
    s.days[1].interval_semantics_verified = false;
    check("67 yesterday unverified cannot supply restoration", s, base, fixed_zone,
          ready(EventKind::outage_starts, 3600, "Відключення через 1 г"));

    // These raw values must be rejected BEFORE chrono fields can narrow them.
    for (const auto& invalid : oversized_dates) {
        s = fixture();
        auto malformed = s.days.front();
        malformed.local_date = invalid.date;
        malformed.outages.clear();
        s.days.push_back(malformed);
        const std::string engine_label = std::string("engine rejects ") + invalid.name;
        check(engine_label.c_str(), s, base, fixed_zone, denied(OutcomeKind::unsupported_schema));
    }
    s = fixture();
    s.fetched_at_utc = UtcInstant{std::numeric_limits<std::int64_t>::max()};
    s.source_updated_at_utc = s.fetched_at_utc;
    check("freshness at maximum UTC reaches timezone validation", s, s.fetched_at_utc,
          fixed_zone, denied(OutcomeKind::unsupported_schema));

    s = fixture();
    s.source_updated_at_utc = base - 600;
    check("independent source budget accepts exact fetch and source age limits", s,
          base, fixed_zone, ready(EventKind::outage_starts, 3600, "Відключення через 1 г"),
          FreshnessPolicy{60, 300, 600});
    s.fetched_at_utc = base - 61;
    check_freshness("longer source budget cannot extend fetch lifetime", s, base,
                    FreshnessPolicy{60, 300, 600}, false);
    s = fixture(); s.source_updated_at_utc = base - 121;
    check_freshness("omitted source budget retains legacy shared age", s, base,
                    FreshnessPolicy{120}, false);
    check_freshness("explicit source budget rejects one second beyond limit", s, base,
                    FreshnessPolicy{3600, 300, 120}, false);

    s = fixture(); s.fetched_at_utc = base + 300;
    s.source_updated_at_utc = s.fetched_at_utc;
    check_freshness("future timestamp at second positional skew limit is accepted", s,
                    base, FreshnessPolicy{0, 300, 0}, true);
    s.fetched_at_utc = base + 301;
    check_freshness("future fetch beyond skew is rejected", s, base,
                    FreshnessPolicy{3600, 300, 3600}, false);
    s = fixture(); s.fetched_at_utc = base - 300;
    s.source_updated_at_utc = base + 1;
    check_freshness("source after fetch beyond skew is rejected", s, base,
                    FreshnessPolicy{3600, 300, 3600}, false);
    s = fixture(); s.source_updated_at_utc.reset();
    check_freshness("missing source update is rejected with independent budget", s, base,
                    FreshnessPolicy{3600, 300, 3600}, false);

    s = fixture();
    check_result("negative fetch source and skew policies are rejected",
                 !is_fresh(s, base, FreshnessPolicy{-1, 300, 600}) &&
                 !is_fresh(s, base, FreshnessPolicy{60, -1, 600}) &&
                 !is_fresh(s, base, FreshnessPolicy{60, 300, -1}));

    const auto lowest = std::numeric_limits<std::int64_t>::min();
    const auto highest = std::numeric_limits<std::int64_t>::max();
    const struct {
        const char* label;
        UtcInstant fetched;
        UtcInstant now;
        bool expected;
    } extreme_ages[] = {
        {"maximum signed age at minimum timestamp remains inclusive",
         UtcInstant{lowest}, UtcInstant{-1}, true},
        {"age exceeding signed maximum is rejected without wrapping",
         UtcInstant{lowest}, UtcInstant{highest}, false},
        {"future distance exceeding signed maximum is rejected without wrapping",
         UtcInstant{highest}, UtcInstant{lowest}, false},
        {"maximum permitted future skew remains inclusive",
         UtcInstant{highest}, UtcInstant{0}, true},
    };
    bool extreme_ages_ok = true;
    for (const auto& value : extreme_ages) {
        s.fetched_at_utc = value.fetched;
        s.source_updated_at_utc = value.fetched;
        if (is_fresh(s, value.now, FreshnessPolicy{highest, highest, highest}) != value.expected) {
            std::cout << "  mismatch: " << value.label << '\n';
            extreme_ages_ok = false;
        }
    }
    check_result("timestamp distances at signed integer extremes do not wrap", extreme_ages_ok);

    s = Snapshot{}; s.fetched_at_utc = base;
    s.source_updated_at_utc = base;
    s.failure = Failure::dns; s.parse_state = ParseState::unsupported_schema;
    check_freshness("freshness checks timestamps independently of source address and days",
                    s, base, FreshnessPolicy{0, 0, 0}, true);

    if (format_ukrainian_countdown(EventKind::outage_starts, 61) !=
        "Відключення через 2 хв") ++failures;
    ++checks;
    if (format_ukrainian_countdown(EventKind::power_restored, 0) !=
        "Відновлення зараз") ++failures;
    ++checks;
    if (format_ukrainian_countdown(EventKind::outage_starts, 8100) !=
        "Відключення через 2 г 15 хв") ++failures;
    ++checks;
    if (format_ukrainian_countdown(EventKind::outage_starts, 3540) !=
        "Відключення через 59 хв") ++failures;
    ++checks;
    if (format_ukrainian_countdown(EventKind::outage_starts, 3900) !=
        "Відключення через 1 г 5 хв") ++failures;
    ++checks;
    if (format_ukrainian_countdown(EventKind::outage_starts, 60) !=
        "Відключення через 1 хв") ++failures;
    ++checks;
    std::cout << "Rounding checks: 61s -> 2 хв; 0s -> зараз; 8100s -> 2 г 15 хв; 3540s -> 59 хв; 3900s -> 1 г 5 хв; 60s -> 1 хв\n";
}
} // namespace engine_tests
