-- V008: the calendar limit is about 12 months, not 9 (2025-10-21 onward was served on 2026-10-16).
UPDATE srm.data_source SET plan_note = replace(plan_note, 'about 9 months back', 'about 12 months back')
 WHERE code = 'FMP';
