-- MxAcctMGR · pmg DDL package · 04 market reports and reactions
--
-- The eighteen illustrative releases (Report Library, Morning Briefing, Report Walkthrough):
-- what was released, how to read it, how markets moved and which reactions the Behaviour Lab
-- simulates against staying with the plan. A reaction belongs to its report: the same id
-- (sell-single, every-time) is worded for each report and its company.

CREATE TABLE pmg.market_report (
    report_id        text PRIMARY KEY CHECK (report_id ~ '^[a-z0-9][a-z0-9-]*$'),
    title            text NOT NULL,
    symbol           text NOT NULL,
    source           text NOT NULL,         -- the illustrative release's source line
    headline         text NOT NULL,
    tier             smallint NOT NULL REFERENCES pmg.report_tier,
    publisher        text NOT NULL DEFAULT '',
    frequency        text NOT NULL DEFAULT '',
    impact           smallint NOT NULL DEFAULT 2 CHECK (impact BETWEEN 1 AND 3),   -- typical market impact
    top_five         smallint UNIQUE CHECK (top_five BETWEEN 1 AND 5),         -- "if you had to pick five"
    market_move      double precision NOT NULL,   -- the day's equity-market move
    rate_move        double precision NOT NULL,   -- the day's change in yields
    single_ticker    text REFERENCES pmg.security,   -- the one company a corporate report is about
    suggested_sample text REFERENCES pmg.account ON UPDATE CASCADE,   -- the account the walkthrough is written for
    sort_order       smallint NOT NULL
);
CREATE INDEX market_report_tier_idx ON pmg.market_report (tier);
COMMENT ON TABLE pmg.market_report IS 'An illustrative report release and the market''s move on it';

-- Ordered text lists of a report, one table: the reading guide, key metrics, why PMs care, takeaways.
CREATE TABLE pmg.report_text (
    report_id text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    list      text NOT NULL CHECK (list IN ('reading', 'key_metric', 'why_care', 'takeaway')),
    ordinal   smallint NOT NULL,
    text      text NOT NULL,
    PRIMARY KEY (report_id, list, ordinal)
);

CREATE TABLE pmg.report_line (
    report_id text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    ordinal   smallint NOT NULL,
    label     text NOT NULL,
    value     text NOT NULL,       -- as released
    expected  text NOT NULL,       -- consensus
    meaning   text NOT NULL,
    PRIMARY KEY (report_id, ordinal)
);
COMMENT ON TABLE pmg.report_line IS 'A figure of the release against what was expected';

CREATE TABLE pmg.report_term (
    report_id  text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    ordinal    smallint NOT NULL,
    term       text NOT NULL,
    definition text NOT NULL,
    PRIMARY KEY (report_id, ordinal)
);

CREATE TABLE pmg.report_asset_move (
    report_id text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    ordinal   smallint NOT NULL,
    asset     text NOT NULL,
    move      text NOT NULL,
    why       text NOT NULL,
    PRIMARY KEY (report_id, ordinal)
);
COMMENT ON TABLE pmg.report_asset_move IS 'The Market''s Move: what each market did and why';

CREATE TABLE pmg.report_driver (
    report_id text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    driver    text NOT NULL REFERENCES pmg.price_driver,
    ordinal   smallint NOT NULL,
    PRIMARY KEY (report_id, driver)
);
COMMENT ON TABLE pmg.report_driver IS 'Report × driver matrix: which price drivers a report moves';

-- The day's move in the factor model, so it lands on any account through its holdings.
CREATE TABLE pmg.report_factor_move (
    report_id text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    factor    text NOT NULL CHECK (factor IN ('sector', 'company')),
    name      text NOT NULL,          -- a pmg.sector or a pmg.security ticker
    move      double precision NOT NULL,
    PRIMARY KEY (report_id, factor, name)
);

CREATE TABLE pmg.report_context_series (
    report_id       text PRIMARY KEY REFERENCES pmg.market_report ON DELETE CASCADE,
    title           text NOT NULL,
    unit            text NOT NULL,
    kind            text NOT NULL DEFAULT 'line' CHECK (kind IN ('line', 'bar')),
    reference       double precision,       -- e.g. ISM's 50 line
    reference_label text NOT NULL DEFAULT '',
    note            text NOT NULL DEFAULT ''
);
COMMENT ON TABLE pmg.report_context_series IS 'The context chart of The Market''s Move (core CPI by month, ISM vs 50, ...)';

CREATE TABLE pmg.report_context_point (
    report_id text NOT NULL REFERENCES pmg.report_context_series ON DELETE CASCADE,
    ordinal   smallint NOT NULL,
    label     text NOT NULL,
    value     double precision NOT NULL,
    PRIMARY KEY (report_id, ordinal)
);

CREATE TABLE pmg.report_reaction (
    report_id   text NOT NULL REFERENCES pmg.market_report ON DELETE CASCADE,
    reaction_id text NOT NULL CHECK (reaction_id ~ '^[a-z0-9][a-z0-9-]*$' AND reaction_id <> 'plan'),
    ordinal     smallint NOT NULL,
    title       text NOT NULL,
    symbol      text NOT NULL,
    summary     text NOT NULL,
    after       text NOT NULL DEFAULT 'rebalanceToPlan' CHECK (after IN ('revert', 'permanent', 'rebalanceToPlan')),
    repeat_on_drawdown double precision CHECK (repeat_on_drawdown > 0 AND repeat_on_drawdown < 1),
    PRIMARY KEY (report_id, reaction_id),
    UNIQUE (report_id, ordinal) DEFERRABLE
);
COMMENT ON TABLE pmg.report_reaction IS 'An everyday reaction to the report the Behaviour Lab simulates against staying with the plan';

-- What a reaction does: move a fraction of one sleeve to another (several moves in order).
CREATE TABLE pmg.reaction_move (
    report_id   text NOT NULL,
    reaction_id text NOT NULL,
    ordinal     smallint NOT NULL,
    from_sleeve text NOT NULL REFERENCES pmg.sleeve,
    to_sleeve   text NOT NULL REFERENCES pmg.sleeve,
    fraction    double precision NOT NULL CHECK (fraction > 0 AND fraction <= 1),
    PRIMARY KEY (report_id, reaction_id, ordinal),
    CHECK (from_sleeve <> to_sleeve),
    FOREIGN KEY (report_id, reaction_id) REFERENCES pmg.report_reaction ON DELETE CASCADE
);
