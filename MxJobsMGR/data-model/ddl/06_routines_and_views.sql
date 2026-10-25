-- MxJobsMGR · wms DDL package · 06 import / export of *.jobspace documents, and views
--
--   SELECT wms.import_jobspace(pg_read_file(...)::jsonb, '/path/x.jobspace');   -- new jobspace_id
--   SELECT wms.import_jobspace(doc, path, sample_id => 'attribution', p_jobspace_id => <id>);  -- replace
--   SELECT jsonb_pretty(wms.export_jobspace(<id>));                              -- the document again
--
-- Missing keys fall back to the app's defaults, as when MxJobsMGR opens an older file. Settings
-- objects are kept only for the kinds that use them (an "approval" on an API Data Read is dropped,
-- as the app ignores it). Ids are written upper-case, like Swift's UUID.uuidString.

CREATE FUNCTION wms.import_jobspace(p_doc jsonb, p_file_path text DEFAULT NULL,
                                    p_sample_id text DEFAULT NULL, p_jobspace_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_id   uuid := coalesce(p_jobspace_id, gen_random_uuid());
    v_run  jsonb := coalesce(p_doc -> 'run', '{}');
    s      record;
    n      record;
    v_kind text;
    v_spec text;
    v_layer smallint;
BEGIN
    IF coalesce(p_doc ->> 'format', 'mxjobspace') <> 'mxjobspace' THEN
        RAISE EXCEPTION 'Not a jobspace (format %)', p_doc ->> 'format';
    END IF;
    IF p_jobspace_id IS NOT NULL THEN
        DELETE FROM wms.jobspace WHERE jobspace_id = p_jobspace_id;
    END IF;

    INSERT INTO wms.jobspace (jobspace_id, name, description, format_version, sample_id, file_path,
                              run_operations, run_agents, run_data, breakpoints_enabled, stop_on_error, step_delay)
    VALUES (v_id, coalesce(p_doc ->> 'name', 'Untitled Jobspace'), coalesce(p_doc ->> 'description', ''),
            coalesce((p_doc ->> 'formatVersion')::int, 1), p_sample_id, p_file_path,
            coalesce(v_run ->> 'operations', 'interactive'), coalesce(v_run ->> 'agents', 'run'),
            coalesce(v_run ->> 'data', 'mock'), coalesce((v_run ->> 'breakpointsEnabled')::boolean, true),
            coalesce((v_run ->> 'stopOnError')::boolean, true), coalesce((v_run ->> 'stepDelay')::float8, 0.4));

    FOR s IN SELECT e, i FROM jsonb_array_elements(coalesce(p_doc -> 'subscriptions', '[]')) WITH ORDINALITY AS t (e, i) LOOP
        INSERT INTO wms.api_subscription (jobspace_id, subscription_id, ordinal, name, provider, base_url, auth, key_name,
                                          rate_limit_per_minute, plan, docs_url, notes, project_folder, ide, service_id)
        VALUES (v_id, coalesce((s.e ->> 'id')::uuid, gen_random_uuid()), s.i,
                coalesce(s.e ->> 'name', 'New Subscription'), coalesce(s.e ->> 'provider', ''),
                coalesce(s.e ->> 'baseURL', 'https://'), coalesce(s.e ->> 'auth', 'queryParameter'),
                coalesce(s.e ->> 'keyName', 'apikey'), coalesce((s.e ->> 'rateLimitPerMinute')::int, 0),
                coalesce(s.e ->> 'plan', ''), coalesce(s.e ->> 'docsURL', ''), coalesce(s.e ->> 'notes', ''),
                coalesce(s.e ->> 'projectFolder', ''), coalesce(s.e ->> 'ide', 'vscode'),
                (SELECT ls.service_id FROM wms.layer3_service ls
                  WHERE s.e ->> 'baseURL' ~ ('^http://(127\.0\.0\.1|localhost):' || ls.port || '(/|$)')));
        INSERT INTO wms.subscription_header (jobspace_id, subscription_id, ordinal, item_id, key, value)
        SELECT v_id, (s.e ->> 'id')::uuid, h.i, coalesce((h.e ->> 'id')::uuid, gen_random_uuid()),
               coalesce(h.e ->> 'key', ''), coalesce(h.e ->> 'value', '')
          FROM jsonb_array_elements(coalesce(s.e -> 'defaultHeaders', '[]')) WITH ORDINALITY AS h (e, i);
    END LOOP;

    FOR n IN SELECT e, i FROM jsonb_array_elements(coalesce(p_doc -> 'nodes', '[]')) WITH ORDINALITY AS t (e, i) LOOP
        v_kind := n.e ->> 'kind';
        SELECT k.layer, k.spec INTO v_layer, v_spec FROM wms.node_kind k WHERE k.kind = v_kind;
        IF NOT FOUND THEN RAISE EXCEPTION 'Unknown step kind % (step %)', v_kind, n.e ->> 'title'; END IF;

        INSERT INTO wms.job_node (jobspace_id, node_id, kind, layer, title, notes, x, y, enabled, breakpoint, ordinal,
                                  outcome_description, success_status, output_name,
                                  on_failure, max_retries, retry_delay_seconds, exponential_backoff, timeout_seconds,
                                  fallback_value, notify_user)
        VALUES (v_id, (n.e ->> 'id')::uuid, v_kind, v_layer, coalesce(n.e ->> 'title', ''), coalesce(n.e ->> 'notes', ''),
                coalesce((n.e ->> 'x')::float8, 0), coalesce((n.e ->> 'y')::float8, 0),
                coalesce((n.e ->> 'enabled')::boolean, true), coalesce((n.e ->> 'breakpoint')::boolean, false), n.i,
                coalesce(n.e #>> '{outcome,description}', ''), coalesce(n.e #>> '{outcome,successStatus}', '200-299'),
                coalesce(n.e #>> '{outcome,outputName}', ''),
                coalesce(n.e #>> '{exceptions,onFailure}', 'retry'), coalesce((n.e #>> '{exceptions,maxRetries}')::int, 2),
                coalesce((n.e #>> '{exceptions,retryDelaySeconds}')::int, 5),
                coalesce((n.e #>> '{exceptions,exponentialBackoff}')::boolean, true),
                coalesce((n.e #>> '{exceptions,timeoutSeconds}')::int, 30),
                coalesce(n.e #>> '{exceptions,fallbackValue}', ''), coalesce((n.e #>> '{exceptions,notifyUser}')::boolean, true));

        INSERT INTO wms.node_argument (jobspace_id, node_id, ordinal, item_id, name, type, value, required)
        SELECT v_id, (n.e ->> 'id')::uuid, a.i, coalesce((a.e ->> 'id')::uuid, gen_random_uuid()),
               coalesce(a.e ->> 'name', ''), coalesce(a.e ->> 'type', 'text'), coalesce(a.e ->> 'value', ''),
               coalesce((a.e ->> 'required')::boolean, false)
          FROM jsonb_array_elements(coalesce(n.e -> 'arguments', '[]')) WITH ORDINALITY AS a (e, i);
        INSERT INTO wms.node_required_field (jobspace_id, node_id, ordinal, field_path)
        SELECT v_id, (n.e ->> 'id')::uuid, f.i, f.e
          FROM jsonb_array_elements_text(coalesce(n.e #> '{outcome,requiredFields}', '[]')) WITH ORDINALITY AS f (e, i);
        INSERT INTO wms.node_assertion (jobspace_id, node_id, ordinal, item_id, path, op, value)
        SELECT v_id, (n.e ->> 'id')::uuid, a.i, coalesce((a.e ->> 'id')::uuid, gen_random_uuid()),
               coalesce(a.e ->> 'path', ''), coalesce(a.e ->> 'op', '=='), coalesce(a.e ->> 'value', '')
          FROM jsonb_array_elements(coalesce(n.e #> '{outcome,assertions}', '[]')) WITH ORDINALITY AS a (e, i);

        IF v_spec = 'schedule' AND n.e ? 'schedule' THEN
            INSERT INTO wms.node_schedule (jobspace_id, node_id, mode, run_time, time_zone, interval_minutes)
            VALUES (v_id, (n.e ->> 'id')::uuid, coalesce(n.e #>> '{schedule,mode}', 'weekdays'),
                    coalesce(n.e #>> '{schedule,time}', '07:30'), coalesce(n.e #>> '{schedule,timeZone}', 'America/New_York'),
                    coalesce((n.e #>> '{schedule,intervalMinutes}')::int, 60));
        ELSIF v_spec = 'agent' AND n.e ? 'agent' THEN
            INSERT INTO wms.node_agent (jobspace_id, node_id, kind, instructions, model, output_format)
            VALUES (v_id, (n.e ->> 'id')::uuid, v_kind, coalesce(n.e #>> '{agent,instructions}', ''),
                    coalesce(n.e #>> '{agent,model}', ''), coalesce(n.e #>> '{agent,outputFormat}', ''));
            INSERT INTO wms.node_agent_input (jobspace_id, node_id, ordinal, input_name)
            SELECT v_id, (n.e ->> 'id')::uuid, x.i, x.e
              FROM jsonb_array_elements_text(coalesce(n.e #> '{agent,inputs}', '[]')) WITH ORDINALITY AS x (e, i);
        ELSIF v_spec = 'approval' AND n.e ? 'approval' THEN
            INSERT INTO wms.node_approval (jobspace_id, node_id, approver, channel, expires_after_minutes,
                                           require_comment, summary_template)
            VALUES (v_id, (n.e ->> 'id')::uuid, coalesce(n.e #>> '{approval,approver}', ''),
                    coalesce(n.e #>> '{approval,channel}', 'inApp'),
                    coalesce((n.e #>> '{approval,expiresAfterMinutes}')::int, 120),
                    coalesce((n.e #>> '{approval,requireComment}')::boolean, false),
                    coalesce(n.e #>> '{approval,summaryTemplate}', ''));
        ELSIF v_spec = 'execution' AND n.e ? 'execution' THEN
            INSERT INTO wms.node_execution (jobspace_id, node_id, target, mode, confirm_before_send)
            VALUES (v_id, (n.e ->> 'id')::uuid, coalesce(n.e #>> '{execution,target}', ''),
                    coalesce(n.e #>> '{execution,mode}', 'dryRun'),
                    coalesce((n.e #>> '{execution,confirmBeforeSend}')::boolean, true));
        ELSIF v_spec = 'report' AND n.e ? 'report' THEN
            INSERT INTO wms.node_report (jobspace_id, node_id, recipients, detailed, include_failures)
            VALUES (v_id, (n.e ->> 'id')::uuid, coalesce(n.e #>> '{report,recipients}', ''),
                    coalesce((n.e #>> '{report,detailed}')::boolean, false),
                    coalesce((n.e #>> '{report,includeFailures}')::boolean, true));
        ELSIF v_spec = 'api_call' AND n.e ? 'api' THEN
            INSERT INTO wms.node_api_call (jobspace_id, node_id, subscription_id, method, path, body)
            VALUES (v_id, (n.e ->> 'id')::uuid, (n.e #>> '{api,subscriptionID}')::uuid,
                    coalesce(n.e #>> '{api,method}', 'GET'), coalesce(n.e #>> '{api,path}', ''),
                    coalesce(n.e #>> '{api,body}', ''));
            INSERT INTO wms.node_api_param (jobspace_id, node_id, location, ordinal, item_id, key, value)
            SELECT v_id, (n.e ->> 'id')::uuid, loc, p.i, coalesce((p.e ->> 'id')::uuid, gen_random_uuid()),
                   coalesce(p.e ->> 'key', ''), coalesce(p.e ->> 'value', '')
              FROM (VALUES ('query'), ('header')) AS l (loc),
                   jsonb_array_elements(coalesce(n.e -> 'api' -> (CASE loc WHEN 'query' THEN 'query' ELSE 'headers' END), '[]'))
                       WITH ORDINALITY AS p (e, i);
        ELSIF v_spec = 'script' AND n.e ? 'script' THEN
            INSERT INTO wms.node_script (jobspace_id, node_id, code, interpreter, subscription_id)
            VALUES (v_id, (n.e ->> 'id')::uuid, coalesce(n.e #>> '{script,code}', ''),
                    coalesce(n.e #>> '{script,interpreter}', ''), (n.e #>> '{script,subscriptionID}')::uuid);
        ELSIF v_spec = 'transform' AND n.e ? 'transform' THEN
            INSERT INTO wms.node_transform_mapping (jobspace_id, node_id, ordinal, item_id, target, source_path)
            SELECT v_id, (n.e ->> 'id')::uuid, m.i, coalesce((m.e ->> 'id')::uuid, gen_random_uuid()),
                   coalesce(m.e ->> 'key', ''), coalesce(m.e ->> 'value', '')
              FROM jsonb_array_elements(coalesce(n.e #> '{transform,mappings}', '[]')) WITH ORDINALITY AS m (e, i);
        END IF;
    END LOOP;

    -- Links to missing steps are dropped, as Jobspace.init(from:) does.
    INSERT INTO wms.job_link (jobspace_id, link_id, from_node_id, to_node_id, label, ordinal)
    SELECT v_id, coalesce((l.e ->> 'id')::uuid, gen_random_uuid()), (l.e ->> 'from')::uuid, (l.e ->> 'to')::uuid,
           coalesce(l.e ->> 'label', ''), l.i
      FROM jsonb_array_elements(coalesce(p_doc -> 'links', '[]')) WITH ORDINALITY AS l (e, i)
     WHERE EXISTS (SELECT 1 FROM wms.job_node a WHERE a.jobspace_id = v_id AND a.node_id = (l.e ->> 'from')::uuid)
       AND EXISTS (SELECT 1 FROM wms.job_node b WHERE b.jobspace_id = v_id AND b.node_id = (l.e ->> 'to')::uuid);
    RETURN v_id;
END $$;
COMMENT ON FUNCTION wms.import_jobspace IS 'Loads a *.jobspace document into the wms tables; returns its jobspace_id';

CREATE FUNCTION wms.uuid_text(u uuid) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$ SELECT upper(u::text) $$;

CREATE FUNCTION wms.key_values(p_items jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT coalesce(p_items, '[]'::jsonb) $$;

CREATE FUNCTION wms.export_jobspace(p_jobspace_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'format', 'mxjobspace',
        'formatVersion', j.format_version,
        'name', j.name,
        'description', j.description,
        'run', jsonb_build_object('operations', j.run_operations, 'agents', j.run_agents, 'data', j.run_data,
                                  'breakpointsEnabled', j.breakpoints_enabled, 'stopOnError', j.stop_on_error,
                                  'stepDelay', j.step_delay),
        'subscriptions', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', wms.uuid_text(s.subscription_id), 'name', s.name, 'provider', s.provider,
                       'baseURL', s.base_url, 'auth', s.auth, 'keyName', s.key_name,
                       'rateLimitPerMinute', s.rate_limit_per_minute, 'plan', s.plan, 'docsURL', s.docs_url,
                       'notes', s.notes, 'projectFolder', s.project_folder, 'ide', s.ide,
                       'defaultHeaders', wms.key_values((
                           SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(h.item_id), 'key', h.key, 'value', h.value)
                                            ORDER BY h.ordinal)
                             FROM wms.subscription_header h
                            WHERE h.jobspace_id = s.jobspace_id AND h.subscription_id = s.subscription_id)))
                   ORDER BY s.ordinal)
              FROM wms.api_subscription s WHERE s.jobspace_id = j.jobspace_id), '[]'),
        'nodes', coalesce((
            SELECT jsonb_agg(
                       jsonb_build_object(
                           'id', wms.uuid_text(n.node_id), 'kind', n.kind, 'title', n.title, 'notes', n.notes,
                           'x', n.x, 'y', n.y, 'enabled', n.enabled, 'breakpoint', n.breakpoint,
                           'arguments', wms.key_values((
                               SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(a.item_id), 'name', a.name,
                                                                   'type', a.type, 'value', a.value, 'required', a.required)
                                                ORDER BY a.ordinal)
                                 FROM wms.node_argument a WHERE a.jobspace_id = n.jobspace_id AND a.node_id = n.node_id)),
                           'outcome', jsonb_build_object(
                               'description', n.outcome_description, 'successStatus', n.success_status,
                               'outputName', n.output_name,
                               'requiredFields', wms.key_values((
                                   SELECT jsonb_agg(f.field_path ORDER BY f.ordinal) FROM wms.node_required_field f
                                    WHERE f.jobspace_id = n.jobspace_id AND f.node_id = n.node_id)),
                               'assertions', wms.key_values((
                                   SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(x.item_id), 'path', x.path,
                                                                       'op', x.op, 'value', x.value) ORDER BY x.ordinal)
                                     FROM wms.node_assertion x WHERE x.jobspace_id = n.jobspace_id AND x.node_id = n.node_id))),
                           'exceptions', jsonb_build_object(
                               'onFailure', n.on_failure, 'maxRetries', n.max_retries,
                               'retryDelaySeconds', n.retry_delay_seconds, 'exponentialBackoff', n.exponential_backoff,
                               'timeoutSeconds', n.timeout_seconds, 'fallbackValue', n.fallback_value,
                               'notifyUser', n.notify_user))
                       || coalesce((SELECT jsonb_build_object('schedule', jsonb_build_object(
                                        'mode', sc.mode, 'time', sc.run_time, 'timeZone', sc.time_zone,
                                        'intervalMinutes', sc.interval_minutes))
                                      FROM wms.node_schedule sc WHERE sc.jobspace_id = n.jobspace_id AND sc.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('agent', jsonb_build_object(
                                        'instructions', ag.instructions, 'model', ag.model, 'outputFormat', ag.output_format,
                                        'inputs', wms.key_values((SELECT jsonb_agg(ai.input_name ORDER BY ai.ordinal)
                                                                    FROM wms.node_agent_input ai
                                                                   WHERE ai.jobspace_id = ag.jobspace_id AND ai.node_id = ag.node_id))))
                                      FROM wms.node_agent ag WHERE ag.jobspace_id = n.jobspace_id AND ag.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('approval', jsonb_build_object(
                                        'approver', ap.approver, 'channel', ap.channel,
                                        'expiresAfterMinutes', ap.expires_after_minutes, 'requireComment', ap.require_comment,
                                        'summaryTemplate', ap.summary_template))
                                      FROM wms.node_approval ap WHERE ap.jobspace_id = n.jobspace_id AND ap.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('execution', jsonb_build_object(
                                        'target', ex.target, 'mode', ex.mode, 'confirmBeforeSend', ex.confirm_before_send))
                                      FROM wms.node_execution ex WHERE ex.jobspace_id = n.jobspace_id AND ex.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('report', jsonb_build_object(
                                        'recipients', r.recipients, 'detailed', r.detailed, 'includeFailures', r.include_failures))
                                      FROM wms.node_report r WHERE r.jobspace_id = n.jobspace_id AND r.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('api', jsonb_strip_nulls(jsonb_build_object(
                                        'subscriptionID', wms.uuid_text(c.subscription_id), 'method', c.method,
                                        'path', c.path, 'body', c.body))
                                        || jsonb_build_object(
                                        'query', wms.key_values((SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(p.item_id),
                                                     'key', p.key, 'value', p.value) ORDER BY p.ordinal)
                                                   FROM wms.node_api_param p WHERE p.jobspace_id = c.jobspace_id
                                                    AND p.node_id = c.node_id AND p.location = 'query')),
                                        'headers', wms.key_values((SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(p.item_id),
                                                     'key', p.key, 'value', p.value) ORDER BY p.ordinal)
                                                   FROM wms.node_api_param p WHERE p.jobspace_id = c.jobspace_id
                                                    AND p.node_id = c.node_id AND p.location = 'header'))))
                                      FROM wms.node_api_call c WHERE c.jobspace_id = n.jobspace_id AND c.node_id = n.node_id), '{}')
                       || coalesce((SELECT jsonb_build_object('script', jsonb_strip_nulls(jsonb_build_object(
                                        'code', sp.code, 'interpreter', sp.interpreter,
                                        'subscriptionID', wms.uuid_text(sp.subscription_id))))
                                      FROM wms.node_script sp WHERE sp.jobspace_id = n.jobspace_id AND sp.node_id = n.node_id), '{}')
                       || CASE WHEN n.kind = 'dataNormalize' THEN jsonb_build_object('transform', jsonb_build_object(
                                        'mappings', wms.key_values((SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(m.item_id),
                                                     'key', m.target, 'value', m.source_path) ORDER BY m.ordinal)
                                                   FROM wms.node_transform_mapping m
                                                  WHERE m.jobspace_id = n.jobspace_id AND m.node_id = n.node_id))))
                               ELSE '{}' END
                   ORDER BY n.ordinal)
              FROM wms.job_node n WHERE n.jobspace_id = j.jobspace_id), '[]'),
        'links', coalesce((
            SELECT jsonb_agg(jsonb_build_object('id', wms.uuid_text(l.link_id), 'from', wms.uuid_text(l.from_node_id),
                                                'to', wms.uuid_text(l.to_node_id), 'label', l.label) ORDER BY l.ordinal)
              FROM wms.job_link l WHERE l.jobspace_id = j.jobspace_id), '[]'))
      FROM wms.jobspace j
     WHERE j.jobspace_id = p_jobspace_id
$$;
COMMENT ON FUNCTION wms.export_jobspace IS 'The jobspace as a *.jobspace document (format mxjobspace, formatVersion 1)';

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Links with what they mean on the canvas: a call down the layers, a result back up, or a
-- sequence within a lane; skips_agent_layer for a Layer 1 ↔ 3 link.
CREATE VIEW wms.v_job_link AS
SELECT l.jobspace_id, l.link_id, l.label,
       l.from_node_id, a.title AS from_title, a.layer AS from_layer,
       l.to_node_id, b.title AS to_title, b.layer AS to_layer,
       CASE WHEN b.layer > a.layer THEN 'call' WHEN b.layer < a.layer THEN 'result' ELSE 'sequence' END AS direction,
       abs(a.layer - b.layer) > 1 AS skips_agent_layer
  FROM wms.job_link l
  JOIN wms.job_node a ON a.jobspace_id = l.jobspace_id AND a.node_id = l.from_node_id
  JOIN wms.job_node b ON b.jobspace_id = l.jobspace_id AND b.node_id = l.to_node_id;

-- The Problems panel's checks that need only the database (Validation.swift). Key presence in
-- the Keychain and interpreter lookup stay in the app.
CREATE VIEW wms.v_jobspace_problem AS
WITH RECURSIVE upstream AS (
    SELECT n.jobspace_id, n.node_id AS target, l.from_node_id AS node_id
      FROM wms.job_node n JOIN wms.job_link l ON l.jobspace_id = n.jobspace_id AND l.to_node_id = n.node_id
     WHERE n.kind = 'executeRequest'
    UNION
    SELECT u.jobspace_id, u.target, l.from_node_id
      FROM upstream u JOIN wms.job_link l ON l.jobspace_id = u.jobspace_id AND l.to_node_id = u.node_id
)
SELECT n.jobspace_id, 'error' AS severity, n.node_id, NULL::uuid AS subscription_id,
       format('“%s” runs without a User Approval step before it.', n.title) AS message
  FROM wms.job_node n
 WHERE n.kind = 'executeRequest'
   AND NOT EXISTS (SELECT 1 FROM upstream u JOIN wms.job_node g ON g.jobspace_id = u.jobspace_id AND g.node_id = u.node_id
                    WHERE u.jobspace_id = n.jobspace_id AND u.target = n.node_id AND g.kind = 'approvalGate')
UNION ALL
SELECT c.jobspace_id, 'error', c.node_id, NULL, format('“%s” has no API subscription.', n.title)
  FROM wms.node_api_call c JOIN wms.job_node n USING (jobspace_id, node_id)
 WHERE c.subscription_id IS NULL
UNION ALL
SELECT n.jobspace_id, 'error', n.node_id, NULL, format('“%s” has no Python code.', n.title)
  FROM wms.job_node n LEFT JOIN wms.node_script sp USING (jobspace_id, node_id)
 WHERE n.kind = 'pythonScript' AND btrim(coalesce(sp.code, ''), E' \t\r\n') = ''
UNION ALL
SELECT s.jobspace_id, 'error', NULL, s.subscription_id, format('Subscription “%s” has no valid base URL.', s.name)
  FROM wms.api_subscription s
 WHERE s.base_url !~ '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#:]+'
UNION ALL
SELECT c.jobspace_id, 'warning', c.node_id, NULL, format('“%s” has no endpoint path.', n.title)
  FROM wms.node_api_call c JOIN wms.job_node n USING (jobspace_id, node_id)
 WHERE c.path = ''
UNION ALL
SELECT n.jobspace_id, 'warning', n.node_id, NULL, format('“%s” is not linked to anything.', n.title)
  FROM wms.job_node n
 WHERE (SELECT count(*) FROM wms.job_node m WHERE m.jobspace_id = n.jobspace_id) > 1
   AND NOT EXISTS (SELECT 1 FROM wms.job_link l WHERE l.jobspace_id = n.jobspace_id
                      AND n.node_id IN (l.from_node_id, l.to_node_id))
UNION ALL
SELECT a.jobspace_id, 'warning', a.node_id, NULL,
       format('“%s”: required argument “%s” has no value.', n.title, a.name)
  FROM wms.node_argument a JOIN wms.job_node n USING (jobspace_id, node_id)
 WHERE a.required AND btrim(a.value) = ''
UNION ALL
SELECT v.jobspace_id, 'warning', v.from_node_id, NULL, format('“%s” → “%s” skips the agent layer.', v.from_title, v.to_title)
  FROM wms.v_job_link v WHERE v.skips_agent_layer
UNION ALL
SELECT e.jobspace_id, 'info', e.node_id, NULL, format('“%s” sends live requests.', n.title)
  FROM wms.node_execution e JOIN wms.job_node n USING (jobspace_id, node_id) WHERE e.mode = 'live'
UNION ALL
SELECT n.jobspace_id, 'info', n.node_id, NULL, format('“%s” has no approver named.', n.title)
  FROM wms.job_node n LEFT JOIN wms.node_approval ap USING (jobspace_id, node_id)
 WHERE n.kind = 'approvalGate' AND coalesce(ap.approver, '') = '';
COMMENT ON VIEW wms.v_jobspace_problem IS 'Problems (⇧⌘K) checks that can be made in the database';

-- One row per jobspace: steps per layer, subscriptions, the services its subscriptions call,
-- problems, and the last run.
CREATE VIEW wms.v_jobspace_summary AS
SELECT j.jobspace_id, j.name, j.sample_id, j.file_path, j.run_data,
       count(*) FILTER (WHERE n.layer = 1) AS layer1_steps,
       count(*) FILTER (WHERE n.layer = 2) AS layer2_steps,
       count(*) FILTER (WHERE n.layer = 3) AS layer3_steps,
       (SELECT count(*) FROM wms.job_link l WHERE l.jobspace_id = j.jobspace_id) AS links,
       (SELECT count(*) FROM wms.api_subscription s WHERE s.jobspace_id = j.jobspace_id) AS subscriptions,
       (SELECT string_agg(DISTINCT s.service_id, ', ') FROM wms.api_subscription s WHERE s.jobspace_id = j.jobspace_id) AS services,
       (SELECT count(*) FROM wms.v_jobspace_problem p WHERE p.jobspace_id = j.jobspace_id AND p.severity = 'error') AS errors,
       (SELECT count(*) FROM wms.v_jobspace_problem p WHERE p.jobspace_id = j.jobspace_id AND p.severity = 'warning') AS warnings,
       r.started_at AS last_run_at, r.phase AS last_run_phase,
       j.updated_at
  FROM wms.jobspace j
  LEFT JOIN wms.job_node n ON n.jobspace_id = j.jobspace_id
  LEFT JOIN LATERAL (SELECT started_at, phase FROM wms.job_run r WHERE r.jobspace_id = j.jobspace_id
                      ORDER BY started_at DESC LIMIT 1) r ON true
 GROUP BY j.jobspace_id, r.started_at, r.phase;
