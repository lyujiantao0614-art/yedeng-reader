import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DictionaryAssetProvisioner, ProvisionedDictionaryAssets } from './DictionaryAssetProvisioner';
import { dictionaryPartOfSpeech, normalizeSelectedWord, regularLemmaCandidates } from './DictionaryLookup';
import {
  DictionaryEntry, DictionaryLookupQuery, DictionaryMatchKind, DictionaryMetadata, DictionarySense
} from './DictionaryModels';
import { DictionaryProvider } from './DictionaryProvider';

const BUNDLED_PROVIDER_ID: string = 'bundled-en-zh-v1';
const OMW_PROVIDER_ID: string = 'omw-2.0';
const CEDICT_PROVIDER_ID: string = 'cc-cedict-2026-08-14';
const MAX_OMW_GROUPS: number = 24;
const MAX_MEANINGS_PER_GROUP: number = 8;
const MAX_FALLBACK_MEANINGS: number = 12;

export class BundledDictionaryProvider implements DictionaryProvider {
  private context: common.UIAbilityContext;
  private provisioner: DictionaryAssetProvisioner;
  private primaryStore?: relationalStore.RdbStore;
  private fallbackStore?: relationalStore.RdbStore;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.provisioner = new DictionaryAssetProvisioner(context);
  }

  getMetadata(): DictionaryMetadata {
    return {
      providerId: BUNDLED_PROVIDER_ID,
      version: '1',
      sourceLanguage: 'en',
      targetLanguage: 'zh-Hans',
      offline: true
    };
  }

  private async closeStores(): Promise<void> {
    if (this.primaryStore !== undefined) {
      const store = this.primaryStore;
      this.primaryStore = undefined;
      try { await store.close(); } catch (_) {}
    }
    if (this.fallbackStore !== undefined) {
      const store = this.fallbackStore;
      this.fallbackStore = undefined;
      try { await store.close(); } catch (_) {}
    }
  }

  async close(): Promise<void> {
    await this.closeStores();
  }

  private async metadataValue(store: relationalStore.RdbStore, key: string): Promise<string | undefined> {
    const result = await store.querySql('SELECT value FROM metadata WHERE key=?', [key]);
    try {
      return result.goToNextRow() ? result.getString(0) : undefined;
    } finally {
      result.close();
    }
  }

  private async validateStore(store: relationalStore.RdbStore, role: string): Promise<void> {
    const schema = await this.metadataValue(store, 'schema_version');
    const databaseRole = await this.metadataValue(store, 'database_role');
    if (schema !== '1' || databaseRole !== role) {
      throw new Error('Bundled dictionary database metadata is invalid');
    }
  }

  private async openStore(name: string, customDir: string, role: string): Promise<relationalStore.RdbStore> {
    let store: relationalStore.RdbStore | undefined;
    try {
      store = await relationalStore.getRdbStore(this.context, {
        name: name,
        securityLevel: relationalStore.SecurityLevel.S1,
        customDir: customDir,
        isReadOnly: true
      });
      await this.validateStore(store, role);
      return store;
    } catch (_) {
      if (store !== undefined) {
        try { await store.close(); } catch (_) {}
      }
    }
    try {
      store = await relationalStore.getRdbStore(this.context, {
        name: name,
        securityLevel: relationalStore.SecurityLevel.S1,
        customDir: customDir
      });
    } catch (_) {
      throw new Error(`WRITABLE_OPEN_${role}`);
    }
    try {
      await store.executeSql('PRAGMA query_only=ON');
    } catch (_) {
      try { await store.close(); } catch (_) {}
      throw new Error(`QUERY_ONLY_${role}`);
    }
    try {
      await this.validateStore(store, role);
      return store;
    } catch (_) {
      try { await store.close(); } catch (_) {}
      throw new Error(`METADATA_${role}`);
    }
  }

  private async openPreparedAssets(assets: ProvisionedDictionaryAssets): Promise<void> {
    this.primaryStore = await this.openStore(assets.omwName, assets.customDir, 'primary');
    try {
      this.fallbackStore = await this.openStore(assets.cedictName, assets.customDir, 'fallback');
    } catch (error) {
      await this.closeStores();
      const code = error instanceof Error ? error.message : 'UNKNOWN';
      throw new Error(`FALLBACK_${code}`);
    }
  }

  async initialize(): Promise<void> {
    await this.closeStores();
    let assets: ProvisionedDictionaryAssets;
    try {
      assets = await this.provisioner.prepare();
    } catch (_) {
      throw new Error('PROVISION');
    }
    try {
      await this.openPreparedAssets(assets);
    } catch (_) {
      await this.closeStores();
      try {
        await this.provisioner.invalidate();
        assets = await this.provisioner.prepare(true);
      } catch (_) {
        throw new Error('REPAIR_PROVISION');
      }
      try {
        await this.openPreparedAssets(assets);
      } catch (error) {
        const code = error instanceof Error ? error.message : 'UNKNOWN';
        throw new Error(`OPEN_${code}`);
      }
    }
  }

  private requirePrimary(): relationalStore.RdbStore {
    if (this.primaryStore === undefined) {
      throw new Error('Bundled dictionary is not initialized');
    }
    return this.primaryStore;
  }

  private requireFallback(): relationalStore.RdbStore {
    if (this.fallbackStore === undefined) {
      throw new Error('Bundled dictionary is not initialized');
    }
    return this.fallbackStore;
  }

  private async primaryEntry(headword: string, matchKind: DictionaryMatchKind): Promise<DictionaryEntry | undefined> {
    const result = await this.requirePrimary().querySql(
      'SELECT part_of_speech,sense_order,meaning FROM meaning WHERE headword=? ' +
      'ORDER BY part_of_speech,sense_order,meaning_order LIMIT 512', [headword]);
    const senses: DictionarySense[] = [];
    const seenMeanings: string[] = [];
    let currentKey = '';
    let currentSense: DictionarySense | undefined;
    try {
      while (result.goToNextRow()) {
        const partOfSpeech = result.getString(0);
        const senseOrder = result.getLong(1);
        const meaning = result.getString(2);
        const key = `${partOfSpeech}:${senseOrder}`;
        if (key !== currentKey) {
          currentKey = key;
          currentSense = undefined;
        }
        if (seenMeanings.includes(meaning)) {
          continue;
        }
        if (currentSense === undefined) {
          if (senses.length >= MAX_OMW_GROUPS) {
            break;
          }
          currentSense = { partOfSpeech: dictionaryPartOfSpeech(partOfSpeech), meanings: [] };
          senses.push(currentSense);
        }
        if (currentSense.meanings.length < MAX_MEANINGS_PER_GROUP) {
          currentSense.meanings.push(meaning);
          seenMeanings.push(meaning);
        }
      }
    } finally {
      result.close();
    }
    if (senses.length === 0) {
      return undefined;
    }
    return { providerId: OMW_PROVIDER_ID, headword: headword, matchKind: matchKind, senses: senses };
  }

  private async fallbackEntry(headword: string, matchKind: DictionaryMatchKind): Promise<DictionaryEntry | undefined> {
    const result = await this.requireFallback().querySql(
      `SELECT meaning FROM fallback_meaning WHERE headword=? ORDER BY meaning_order LIMIT ${MAX_FALLBACK_MEANINGS}`,
      [headword]);
    const meanings: string[] = [];
    try {
      while (result.goToNextRow()) {
        const meaning = result.getString(0);
        if (!meanings.includes(meaning)) {
          meanings.push(meaning);
        }
      }
    } finally {
      result.close();
    }
    if (meanings.length === 0) {
      return undefined;
    }
    return {
      providerId: CEDICT_PROVIDER_ID,
      headword: headword,
      matchKind: matchKind,
      senses: [{ meanings: meanings }]
    };
  }

  private async evidencedHeadwords(surface: string): Promise<string[]> {
    const result = await this.requirePrimary().querySql(
      'SELECT headword FROM inflection WHERE surface_form=? ORDER BY headword LIMIT 8', [surface]);
    const values: string[] = [];
    try {
      while (result.goToNextRow()) {
        const value = result.getString(0);
        if (value !== surface && !values.includes(value)) {
          values.push(value);
        }
      }
    } finally {
      result.close();
    }
    return values;
  }

  private async firstEntry(headwords: string[], matchKind: DictionaryMatchKind,
    primaryFirst: boolean = true): Promise<DictionaryEntry | undefined> {
    for (const headword of headwords) {
      if (primaryFirst) {
        const primary = await this.primaryEntry(headword, matchKind);
        if (primary !== undefined) return primary;
      }
      const fallback = await this.fallbackEntry(headword, matchKind);
      if (fallback !== undefined) return fallback;
    }
    return undefined;
  }

  async lookup(query: DictionaryLookupQuery): Promise<DictionaryEntry[]> {
    if ((query.sourceLanguage !== undefined && query.sourceLanguage !== 'en') ||
      (query.targetLanguage !== undefined && query.targetLanguage !== 'zh-Hans')) {
      return [];
    }
    const normalized = normalizeSelectedWord(query.term);
    if (normalized === undefined) {
      return [];
    }
    const term = normalized.normalizedTerm;
    const exactPrimary = await this.primaryEntry(term, 'exact');
    const evidenced = await this.evidencedHeadwords(term);
    if (exactPrimary !== undefined) {
      const entries: DictionaryEntry[] = [exactPrimary];
      const alternative = await this.firstEntry(evidenced, 'inflection');
      if (alternative !== undefined && alternative.headword !== term) {
        entries.push(alternative);
      }
      return entries;
    }

    const evidencedEntry = await this.firstEntry(evidenced, 'inflection');
    if (evidencedEntry !== undefined) {
      return [evidencedEntry];
    }

    const candidates = regularLemmaCandidates(term);
    for (const candidate of candidates) {
      const primary = await this.primaryEntry(candidate, 'suffix');
      if (primary !== undefined) {
        return [primary];
      }
    }

    const exactFallback = await this.fallbackEntry(term, 'exact');
    if (exactFallback !== undefined) {
      return [exactFallback];
    }
    const fallbackCandidate = await this.firstEntry(candidates, 'suffix', false);
    return fallbackCandidate === undefined ? [] : [fallbackCandidate];
  }
}
