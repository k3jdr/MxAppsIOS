-- V020: Massive (formerly Polygon.io) as a price source.
--
-- srm.py load massive-prices reads Massive's Flat Files — one end-of-day file a trading day covering every U.S.
-- listed and OTC ticker that traded — and stores their open, high, low, close and volume (not split- or
-- dividend-adjusted) as prices from this source.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('MASSIVE', 'Massive (formerly Polygon.io) Flat Files: U.S. stocks day aggregates (every listed and OTC ticker)',
     'https://massive.com/docs/flat-files/quickstart', 'Subscription: Flat Files keys (Keychain SRM-api massive-s3-access / massive-s3-secret)')
ON CONFLICT (code) DO NOTHING;
