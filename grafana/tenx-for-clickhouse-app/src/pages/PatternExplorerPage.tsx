import React, { useEffect, useMemo, useState } from 'react';
import { dateTime } from '@grafana/data';
import { Alert, Button, Field, Input, LoadingPlaceholder, Select, useStyles2 } from '@grafana/ui';
import { css } from '@emotion/css';
import { AppPluginSettings, PatternExplorerQuery, TemplateRow } from '../types';
import { fetchTopTemplates } from '../components/queryClient';

interface Props {
  settings: AppPluginSettings;
}

const TOP_N_OPTIONS = [10, 25, 50, 100].map((n) => ({ label: `Top ${n}`, value: n }));

/**
 * Pattern Explorer page. Shows the top-N templates by estimated cost
 * (event count × average encoded payload size) in the selected time range,
 * with a one-click "filter by template" affordance.
 *
 * Click-to-filter currently copies a Grafana variable expression to the
 * clipboard. A future revision can integrate directly with the dashboard
 * variable system to apply the filter inline.
 */
export function PatternExplorerPage({ settings }: Props) {
  const styles = useStyles2(getStyles);

  const now = Date.now();
  const [from, setFrom] = useState<number>(now - 60 * 60 * 1000); // last 1h
  const [to, setTo] = useState<number>(now);
  const [topN, setTopN] = useState<number>(25);
  const [containerFilter, setContainerFilter] = useState('');
  const [namespaceFilter, setNamespaceFilter] = useState('');
  const [rows, setRows] = useState<TemplateRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const dsUid = settings.clickhouseDataSourceUid ?? '';
  const database = settings.database ?? 'tenx';

  const query = useMemo<PatternExplorerQuery>(
    () => ({ from, to, topN, containerFilter: containerFilter || undefined, namespaceFilter: namespaceFilter || undefined }),
    [from, to, topN, containerFilter, namespaceFilter]
  );

  const run = async () => {
    if (!dsUid) {
      setError('No ClickHouse data source configured. Open the app configuration page.');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const data = await fetchTopTemplates(dsUid, database, query);
      setRows(data);
    } catch (e) {
      setError(`Query failed: ${(e as Error).message}`);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (dsUid) {
      void run();
    }
    // We deliberately do NOT re-run on every state change; the user clicks Run.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const onClickFilter = async (row: TemplateRow) => {
    const expr = `templateHash = '${row.templateHash}'`;
    try {
      await navigator.clipboard.writeText(expr);
      setCopied(row.templateHash);
      setTimeout(() => setCopied(null), 2500);
    } catch {
      // ignore clipboard errors; we surface the expression visibly anyway
    }
  };

  return (
    <div className={styles.root}>
      <h2>Pattern Explorer</h2>
      <p className={styles.subtitle}>
        Top compact templates by estimated cost in the selected range. Click <em>Filter</em> to copy a
        templateHash predicate to the clipboard, then paste into your dashboard query.
      </p>

      <div className={styles.controls}>
        <Field label="From (epoch ms)">
          <Input type="number" value={from} onChange={(e) => setFrom(Number(e.currentTarget.value))} width={20} />
        </Field>
        <Field label="To (epoch ms)">
          <Input type="number" value={to} onChange={(e) => setTo(Number(e.currentTarget.value))} width={20} />
        </Field>
        <Field label="Top N">
          <Select options={TOP_N_OPTIONS} value={topN} onChange={(v) => setTopN(v.value ?? 25)} width={15} />
        </Field>
        <Field label="Container filter">
          <Input value={containerFilter} onChange={(e) => setContainerFilter(e.currentTarget.value)} placeholder="optional" width={20} />
        </Field>
        <Field label="Namespace filter">
          <Input value={namespaceFilter} onChange={(e) => setNamespaceFilter(e.currentTarget.value)} placeholder="optional" width={20} />
        </Field>
        <Button onClick={run} disabled={loading || !dsUid}>{loading ? 'Running…' : 'Run'}</Button>
      </div>

      {error ? <Alert title="" severity="error">{error}</Alert> : null}

      {loading ? (
        <LoadingPlaceholder text="Querying templates…" />
      ) : rows.length === 0 ? (
        <p className={styles.subtitle}>No templates found in the selected range.</p>
      ) : (
        <table className={styles.table}>
          <thead>
            <tr>
              <th>Template hash</th>
              <th>Template</th>
              <th className={styles.numeric}>Events</th>
              <th className={styles.numeric}>~Bytes</th>
              <th>Container</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.templateHash}>
                <td><code>{r.templateHash}</code></td>
                <td className={styles.templateCell}>{r.template}</td>
                <td className={styles.numeric}>{r.eventCount.toLocaleString()}</td>
                <td className={styles.numeric}>{formatBytes(r.estimatedBytes)}</td>
                <td>{r.sampleContainer ?? ''}</td>
                <td>
                  <Button size="sm" variant="secondary" onClick={() => onClickFilter(r)}>
                    {copied === r.templateHash ? 'Copied' : 'Filter'}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
}

const getStyles = () => ({
  root: css`
    padding: 16px 24px;
  `,
  subtitle: css`
    color: var(--text-color-secondary);
    margin-bottom: 16px;
  `,
  controls: css`
    display: flex;
    gap: 12px;
    align-items: flex-end;
    flex-wrap: wrap;
    margin-bottom: 16px;
  `,
  table: css`
    width: 100%;
    border-collapse: collapse;
    th, td {
      padding: 8px 12px;
      border-bottom: 1px solid var(--border-weak);
      vertical-align: top;
      font-size: 13px;
    }
    th { text-align: left; font-weight: 600; }
    tbody tr:hover { background: var(--background-secondary); }
  `,
  templateCell: css`
    font-family: var(--font-family-monospace);
    max-width: 480px;
    word-break: break-word;
  `,
  numeric: css`
    text-align: right;
    font-variant-numeric: tabular-nums;
  `,
});
