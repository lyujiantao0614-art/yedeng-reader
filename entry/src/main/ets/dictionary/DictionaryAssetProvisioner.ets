import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureDirectory, pathExists, removeTree } from '../utils/FileUtils';

const RAWFILE_ROOT: string = 'dictionary/';
const MANIFEST_RAWFILE: string = `${RAWFILE_ROOT}dictionary-manifest.json`;
const DICTIONARY_DIRECTORY: string = 'dictionary-v1';
const STATE_FILE: string = 'verified-assets.json';
const COPY_BUFFER_BYTES: number = 256 * 1024;

export const OMW_DATABASE_NAME: string = 'omw-en-zh.sqlite3';
export const CEDICT_DATABASE_NAME: string = 'cc-cedict-en-fallback.sqlite3';

interface ManifestArtifact {
  bytes: number;
  sha256: string;
}

interface RuntimeManifestArtifact extends ManifestArtifact {
  name: string;
}

interface RuntimeManifest {
  omw: RuntimeManifestArtifact;
  cedict: RuntimeManifestArtifact;
}

interface DictionaryManifest {
  schemaVersion: number;
  runtime: RuntimeManifest;
}

interface VerifiedAssetState {
  schemaVersion: number;
  omwSha256: string;
  cedictSha256: string;
}

export interface ProvisionedDictionaryAssets {
  customDir: string;
  omwName: string;
  cedictName: string;
}

function bytesToHex(bytes: Uint8Array): string {
  let output = '';
  for (const value of bytes) {
    output += value.toString(16).padStart(2, '0');
  }
  return output;
}

function isSha256(value: string): boolean {
  return /^[a-f0-9]{64}$/.test(value);
}

export class DictionaryAssetProvisioner {
  private context: common.UIAbilityContext;
  private rootPath: string;
  private statePath: string;
  private legacyRootPath: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.rootPath = `${context.databaseDir}/rdb/${DICTIONARY_DIRECTORY}`;
    this.statePath = `${this.rootPath}/${STATE_FILE}`;
    this.legacyRootPath = `${context.databaseDir}/${DICTIONARY_DIRECTORY}`;
  }

  private async readManifest(): Promise<DictionaryManifest> {
    const bytes = await this.context.resourceManager.getRawFileContent(MANIFEST_RAWFILE);
    const source = new util.TextDecoder('utf-8').decodeToString(bytes);
    const manifest = JSON.parse(source) as DictionaryManifest;
    const omw = manifest.runtime?.omw;
    const cedict = manifest.runtime?.cedict;
    if (manifest.schemaVersion !== 1 || omw === undefined || cedict === undefined ||
      omw.name !== OMW_DATABASE_NAME || cedict.name !== CEDICT_DATABASE_NAME ||
      !Number.isInteger(omw.bytes) || omw.bytes <= 0 || !isSha256(omw.sha256) ||
      !Number.isInteger(cedict.bytes) || cedict.bytes <= 0 || !isSha256(cedict.sha256)) {
      throw new Error('Bundled dictionary manifest is invalid');
    }
    return manifest;
  }

  private async stateMatches(manifest: DictionaryManifest): Promise<boolean> {
    try {
      const state = JSON.parse(fs.readTextSync(this.statePath)) as VerifiedAssetState;
      if (state.schemaVersion !== manifest.schemaVersion ||
        state.omwSha256 !== manifest.runtime.omw.sha256 ||
        state.cedictSha256 !== manifest.runtime.cedict.sha256) {
        return false;
      }
      const omw = await fs.stat(`${this.rootPath}/${OMW_DATABASE_NAME}`);
      const cedict = await fs.stat(`${this.rootPath}/${CEDICT_DATABASE_NAME}`);
      return omw.size === manifest.runtime.omw.bytes &&
        cedict.size === manifest.runtime.cedict.bytes;
    } catch (_) {
      return false;
    }
  }

  private async streamAndVerify(name: string, expected: ManifestArtifact, destination: string): Promise<void> {
    const rawPath = `${RAWFILE_ROOT}${name}`;
    const descriptor = await this.context.resourceManager.getRawFd(rawPath);
    let target: fs.File | undefined;
    let copied = 0;
    try {
      const digest = cryptoFramework.createMd('SHA256');
      target = await fs.open(destination, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.lseek(descriptor.fd, descriptor.offset, fs.WhenceType.SEEK_SET);
      while (copied < descriptor.length) {
        const requested = Math.min(COPY_BUFFER_BYTES, descriptor.length - copied);
        const buffer = new ArrayBuffer(requested);
        const count = await fs.read(descriptor.fd, buffer);
        if (count <= 0 || count > requested) {
          throw new Error('Bundled dictionary asset ended unexpectedly');
        }
        const chunk = count === requested ? buffer : buffer.slice(0, count);
        await digest.update({ data: new Uint8Array(chunk) });
        let written = 0;
        while (written < count) {
          const remaining = written === 0 ? chunk : chunk.slice(written);
          const next = await fs.write(target.fd, remaining,
            { offset: copied + written, length: count - written });
          if (next <= 0) {
            throw new Error('Bundled dictionary asset could not be copied');
          }
          written += next;
        }
        copied += count;
      }
      const hash = bytesToHex((await digest.digest()).data);
      if (copied !== descriptor.length || copied !== expected.bytes || hash !== expected.sha256) {
        throw new Error('Bundled dictionary asset failed integrity verification');
      }
    } finally {
      try {
        if (target !== undefined) {
          fs.closeSync(target);
        }
      } finally {
        await this.context.resourceManager.closeRawFd(rawPath);
      }
    }
  }

  private async replaceVerifiedFile(staging: string, destination: string): Promise<void> {
    const backup = `${destination}.previous`;
    await removeTree(backup);
    await removeTree(`${destination}-wal`);
    await removeTree(`${destination}-shm`);
    await removeTree(`${destination}-dwr`);
    await removeTree(`${destination}-compare`);
    const hadExisting = await pathExists(destination);
    if (hadExisting) {
      await fs.rename(destination, backup);
    }
    try {
      await fs.rename(staging, destination);
      await removeTree(backup);
    } catch (_) {
      if (hadExisting && !await pathExists(destination) && await pathExists(backup)) {
        await fs.rename(backup, destination);
      }
      throw new Error('Verified dictionary asset could not be installed');
    }
  }

  private async installAsset(name: string, expected: ManifestArtifact): Promise<void> {
    const destination = `${this.rootPath}/${name}`;
    const staging = `${destination}.staging-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    try {
      await this.streamAndVerify(name, expected, staging);
      await this.replaceVerifiedFile(staging, destination);
    } finally {
      await removeTree(staging);
    }
  }

  private async writeState(manifest: DictionaryManifest): Promise<void> {
    const state: VerifiedAssetState = {
      schemaVersion: manifest.schemaVersion,
      omwSha256: manifest.runtime.omw.sha256,
      cedictSha256: manifest.runtime.cedict.sha256
    };
    const staging = `${this.statePath}.staging`;
    const file = await fs.open(staging, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, JSON.stringify(state));
    } finally {
      fs.closeSync(file);
    }
    await removeTree(this.statePath);
    await fs.rename(staging, this.statePath);
  }

  async prepare(force: boolean = false): Promise<ProvisionedDictionaryAssets> {
    const manifest = await this.readManifest();
    await ensureDirectory(`${this.context.databaseDir}/rdb`);
    await ensureDirectory(this.rootPath);
    if (force || !await this.stateMatches(manifest)) {
      await this.installAsset(OMW_DATABASE_NAME, manifest.runtime.omw);
      await this.installAsset(CEDICT_DATABASE_NAME, manifest.runtime.cedict);
      await this.writeState(manifest);
    }
    await removeTree(this.legacyRootPath);
    return {
      customDir: DICTIONARY_DIRECTORY,
      omwName: OMW_DATABASE_NAME,
      cedictName: CEDICT_DATABASE_NAME
    };
  }

  async invalidate(): Promise<void> {
    await removeTree(this.statePath);
  }
}
