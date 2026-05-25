import React from 'react';
import { AppRootProps } from '@grafana/data';
import { AppPluginSettings } from '../types';
import { PatternExplorerPage } from '../pages/PatternExplorerPage';

/**
 * Root component. Currently single-page (Pattern Explorer). Multiple pages
 * can be added under different routes via the plugin.json `includes` list.
 */
export function App(props: AppRootProps<AppPluginSettings>) {
  const settings = props.meta.jsonData ?? {};
  return <PatternExplorerPage settings={settings} />;
}
