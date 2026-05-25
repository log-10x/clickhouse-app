import React, { useState } from 'react';
import { PluginConfigPageProps, AppPluginMeta, PluginMeta } from '@grafana/data';
import { getBackendSrv, getDataSourceSrv } from '@grafana/runtime';
import { Field, Input, Button, FieldSet, Alert, useStyles2 } from '@grafana/ui';
import { css } from '@emotion/css';
import { AppPluginSettings } from '../types';

interface Props extends PluginConfigPageProps<AppPluginMeta<AppPluginSettings>> {}

/**
 * Plugin configuration page. The customer points the app at their existing
 * ClickHouse data source (by UID or by name). We do NOT install or wrap a
 * data source — we sit alongside whichever ClickHouse data source already
 * serves their logs.
 */
export function AppConfig({ plugin }: Props) {
  const styles = useStyles2(getStyles);
  const jsonData = plugin.meta.jsonData ?? {};

  const [dsUid, setDsUid] = useState<string>(jsonData.clickhouseDataSourceUid ?? '');
  const [database, setDatabase] = useState<string>(jsonData.database ?? 'tenx');
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const candidates = getDataSourceSrv()
    .getList({ type: ['grafana-clickhouse-datasource', 'vertamedia-clickhouse-datasource'] })
    .map((d) => ({ uid: d.uid, name: d.name, type: d.type }));

  const onSave = async () => {
    setError(null);
    setSuccess(null);
    setSaving(true);
    try {
      await getBackendSrv().post(`/api/plugins/${plugin.meta.id}/settings`, {
        enabled: true,
        pinned: true,
        jsonData: { clickhouseDataSourceUid: dsUid, database },
      });
      setSuccess('Saved. Reload the page for the Pattern Explorer to pick up the new settings.');
    } catch (e) {
      setError(`Failed to save: ${(e as Error).message}`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className={styles.root}>
      <FieldSet label="ClickHouse data source">
        <p className={styles.help}>
          Point this app at an existing ClickHouse data source. The Pattern Explorer queries the
          {' '}<code>tenx.templates</code> and <code>tenx.encoded_events</code> tables created by{' '}
          <a href="https://github.com/log-10x/clickhouse-app" target="_blank" rel="noreferrer">
            tenx-for-clickhouse
          </a>.
        </p>

        <Field label="Data source UID" description={candidates.length === 0 ? 'No ClickHouse data sources detected.' : `Detected: ${candidates.map((c) => `${c.name} (${c.uid})`).join(', ')}`}>
          <Input
            value={dsUid}
            onChange={(e) => setDsUid(e.currentTarget.value)}
            placeholder="e.g. P1809F7CD0C75ACF3"
            width={40}
          />
        </Field>

        <Field label="Database name" description="Default: tenx. Override if the install.sql was applied to a different database.">
          <Input
            value={database}
            onChange={(e) => setDatabase(e.currentTarget.value)}
            placeholder="tenx"
            width={20}
          />
        </Field>

        <Button onClick={onSave} disabled={saving || !dsUid}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
      </FieldSet>

      {success ? <Alert title="" severity="success">{success}</Alert> : null}
      {error ? <Alert title="" severity="error">{error}</Alert> : null}
    </div>
  );
}

const getStyles = () => ({
  root: css`
    max-width: 720px;
  `,
  help: css`
    color: var(--text-color-secondary);
    margin-bottom: 12px;
  `,
});
