"""Sectors for the securities a company issues besides its shares: preferreds, warrants, units and rights take the FMP
sector and industry of their company's share. FMP's profiles rarely classify them (a preferred's profile is often
missing, a warrant's never), yet for screens, filters and attribution they belong with their issuer.

The share is found from srm.security_relation (V019: a unit's share, a warrant's or right's underlying share), else
as the same issuer's common stock, ADR or REIT that has a sector. The classification is
copied with source DERIVED, so it is told apart from FMP's own, and replaced when the share's changes; a security
FMP classifies itself is left alone. Runs after fmp-profiles in Identifiers & issuer data.
"""

from ..common import LoadRun, log
from ..model import set_classification, source_id

TYPES = ("Preferred Stock", "Warrant", "Unit", "Right", "Listed Note")


def run(conn, cfg, args):
    with LoadRun(conn, "DERIVED", "inherit_sectors", {}) as run, conn.cursor() as cur:
        derived = source_id(cur, "DERIVED")
        cur.execute("""
            WITH targets AS (
                SELECT v.security_id, v.security_type, s.issuer_id
                  FROM srm.v_security v JOIN srm.security s USING (security_id)
                 WHERE v.is_active AND v.security_type = ANY(%s)
                   AND NOT EXISTS (SELECT 1 FROM srm.security_classification c
                                    WHERE c.security_id = v.security_id AND c.scheme_code = 'FMP' AND c.level = 1
                                      AND current_date >= c.valid_from AND current_date < c.valid_to
                                      AND c.source_id <> %s)),
            classified AS (
                SELECT c.security_id, c.level, c.node_id FROM srm.security_classification c
                 WHERE c.scheme_code = 'FMP' AND c.level IN (1, 2) AND current_date >= c.valid_from AND current_date < c.valid_to)
            SELECT t.security_id, t.security_type, p.parent_id, p.how,
                   (SELECT node_id FROM classified WHERE security_id = p.parent_id AND level = 1),
                   (SELECT node_id FROM classified WHERE security_id = p.parent_id AND level = 2)
              FROM targets t
              LEFT JOIN LATERAL (
                  SELECT r.related_security_id AS parent_id, 'relation' AS how
                    FROM srm.security_relation r
                   WHERE r.security_id = t.security_id AND r.relation IN ('unit_share', 'warrant_underlying', 'right_underlying')
                     AND EXISTS (SELECT 1 FROM classified c WHERE c.security_id = r.related_security_id AND c.level = 1)
                  UNION ALL
                  SELECT s2.security_id, 'issuer'
                    FROM srm.security s2
                   WHERE t.issuer_id IS NOT NULL AND s2.issuer_id = t.issuer_id AND s2.security_id <> t.security_id
                     AND s2.is_active AND s2.security_type IN ('Common Stock', 'ADR', 'REIT')
                     AND EXISTS (SELECT 1 FROM classified c WHERE c.security_id = s2.security_id AND c.level = 1)
                  ORDER BY 2 DESC   -- 'relation' before 'issuer'
                  LIMIT 1) p ON true""", (list(TYPES), derived))
        rows = cur.fetchall()
        counts = {}
        for security_id, sec_type, parent_id, how, sector, industry in rows:
            key = (sec_type, how or "none")
            counts[key] = counts.get(key, 0) + 1
            if not parent_id:
                continue
            changed = set_classification(cur, security_id, "FMP", 1, sector, derived, run.load_id)
            if industry:
                set_classification(cur, security_id, "FMP", 2, industry, derived, run.load_id)
            if changed == "inserted":
                run.inserted += 1
            elif changed == "changed":
                run.updated += 1
        conn.commit()
        run.read = len(rows)
        for (sec_type, how), n in sorted(counts.items()):
            log(f"  {sec_type}: {n} {'from the related share' if how == 'relation' else 'from the issuer' + chr(39) + 's share' if how == 'issuer' else 'without a classified share'}")
        given = sum(n for (_, how), n in counts.items() if how != "none")
        run.message = f"{len(rows)} preferreds, warrants, units and rights without their own sector: {given} took their company's"
        log("  " + run.message)
