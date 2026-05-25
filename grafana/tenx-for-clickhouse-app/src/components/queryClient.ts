import { getBackendSrv } from '@grafana/runtime';
import { TemplateRow, PatternExplorerQuery } from '../types';

/**
 * Run a SQL query against the customer's ClickHouse data source via the
 * Grafana backend proxy. Returns rows as objects keyed by column name.
 *
 * This calls /api/datasources/proxy/uid/<dsUid>/?query=... which works for
 * both the official grafana-clickhouse-datasource and the older
 * vertamedia-clickhouse-datasource. If the customer has neither installed,
 * the app surfaces an error rather than failing silently.
 */
export async function runClickhouseQuery<T = Record<string, unknown>>(
  dsUid: string,
  sql: string
): Promise<T[]> {
  if (!dsUid) {
    throw new Error('No ClickHouse data source configured. Open the app configuration page.');
  }
  // ClickHouse-server HTTP interface returns JSONEachRow when the query
  // says so. We append the format directive only if the caller did not
  // already include FORMAT.
  const wrappedSql = /\bformat\s+\w+\s*$/i.test(sql.trim()) ? sql : `${sql} FORMAT JSONEachRow`;
  const body = await getBackendSrv().fetch<string>({
    url: `/api/datasources/proxy/uid/${dsUid}/`,
    method: 'POST',
    data: wrappedSql,
    headers: { 'Content-Type': 'text/plain' },
    responseType: 'text',
  }).toPromise();
  if (!body || !body.data) {
    return [];
  }
  // JSONEachRow returns one JSON object per line.
  return body.data
    .split('\n')
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l) as T);
}

/**
 * Fetch the top-N templates by event count in the user's selected time
 * range, ranked by estimated cost (count × average encoded payload size).
 */
export async function fetchTopTemplates(
  dsUid: string,
  database: string,
  q: PatternExplorerQuery
): Promise<TemplateRow[]> {
  const where: string[] = [
    `JSONExtractInt(raw, 'time') >= ${Math.floor(q.from / 1000)}`,
    `JSONExtractInt(raw, 'time') <  ${Math.floor(q.to / 1000) + 1}`,
    `templateHash != ''`,
  ];
  if (q.containerFilter) {
    where.push(`container = '${q.containerFilter.replace(/'/g, "''")}'`);
  }
  if (q.namespaceFilter) {
    where.push(`namespace = '${q.namespaceFilter.replace(/'/g, "''")}'`);
  }

  // We compute the rows from encoded_events (cheap, indexed materialized
  // columns) and join the template text from the templates table at the end.
  // No view is needed — we go straight at the columnar surface for speed.
  const sql = `
    WITH top AS (
        SELECT
            templateHash,
            count() AS eventCount,
            sum(length(raw)) AS estimatedBytes,
            any(container) AS sampleContainer,
            any(namespace) AS sampleNamespace
        FROM ${database}.encoded_events
        WHERE ${where.join(' AND ')}
        GROUP BY templateHash
        ORDER BY estimatedBytes DESC
        LIMIT ${Math.max(1, Math.min(q.topN, 100))}
    )
    SELECT
        top.templateHash       AS templateHash,
        coalesce(t.template, '(template missing from dictionary)') AS template,
        top.eventCount         AS eventCount,
        top.estimatedBytes     AS estimatedBytes,
        top.sampleContainer    AS sampleContainer,
        top.sampleNamespace    AS sampleNamespace
    FROM top
    LEFT JOIN ${database}.templates AS t USING (templateHash)
    ORDER BY top.estimatedBytes DESC
  `;
  return await runClickhouseQuery<TemplateRow>(dsUid, sql);
}
