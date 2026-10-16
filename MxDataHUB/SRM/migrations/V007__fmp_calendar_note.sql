-- V007: FMP calendar endpoints only serve recent windows on this plan (found on the first full load).
UPDATE srm.data_source SET plan_note = plan_note ||
  ' Dividend / split calendars: only windows from about 9 months back (older 90-day windows return 402);'
  ' per-symbol dividends and splits return full history (fmp-corporate-actions --history).'
 WHERE code = 'FMP' AND plan_note NOT LIKE '%calendars: only%';
