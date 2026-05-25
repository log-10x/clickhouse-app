/**
 * Plugin-wide types for the 10x for ClickHouse Grafana app.
 */

export interface AppPluginSettings {
  /** UID of the ClickHouse data source to query for templates + compact events. */
  clickhouseDataSourceUid?: string;
  /** Database name where the tenx schema lives. Default: 'tenx'. */
  database?: string;
}

export interface TemplateRow {
  templateHash: string;
  template: string;
  eventCount: number;
  /** Estimated bytes the template's events occupy in the encoded_events table for the queried range. */
  estimatedBytes: number;
  /** Sample container, namespace, pod values for context. */
  sampleContainer?: string;
  sampleNamespace?: string;
}

export interface PatternExplorerQuery {
  from: number; // epoch ms
  to: number; // epoch ms
  topN: number; // 5..100
  containerFilter?: string;
  namespaceFilter?: string;
}
