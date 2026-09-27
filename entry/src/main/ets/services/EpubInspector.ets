import { EpubResourceLimits, inspectPublicationResource, validatePublicationXml } from './EpubResourceInspector';
import { ZipEntry } from './EpubZipIndex';
import { BoundedInflateError, InflateControl } from './BoundedInflater';
import { decodeReaderEpubXml, EpubInputError } from './EpubInputPolicy';
import { fileIo as fs } from '@kit.CoreFileKit';
import { joinRelative, parentPath, pathExists } from '../utils/FileUtils';
import { closeFile, openFile, readFile, readTextFile, statFile } from '../utils/FileIoBoundary';

export interface EpubResourceInspection {
  limits: EpubResourceLimits;
  entries: ZipEntry[];
  control: InflateControl;
}

export interface EpubInspection {
  title?: string;
  author?: string;
  coverAbsolutePath?: string;
}

interface ManifestItem {
  id: string;
  href: string;
  mediaType: string;
  properties: string;
}

export class EpubInspectionError extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function decodeEntities(value: string): string {
  return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").trim();
}

function validateXml(source: string, label: string, limits?: EpubResourceLimits): void {
  try {
    validatePublicationXml(source, limits);
  } catch (error) {
    if (error instanceof EpubInputError && error.code === 'resource_limit') throw error;
    throw new EpubInspectionError('malformed', `${label} is not valid XML`);
  }
}

function attribute(tag: string, name: string): string {
  const expression = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(["'])(.*?)\\1`, 'i');
  const match = expression.exec(tag);
  return match === null ? '' : decodeEntities(match[2]);
}

function textElement(source: string, localName: string): string | undefined {
  const expression = new RegExp(`<(?:(?:[\\w.-]+):)?${localName}\\b[^>]*>([\\s\\S]*?)<\\/(?:(?:[\\w.-]+):)?${localName}>`, 'i');
  const match = expression.exec(source);
  if (match === null) {
    return undefined;
  }
  const value = decodeEntities(match[1].replace(/<[^>]+>/g, ''));
  return value.length > 0 ? value : undefined;
}

function manifestItems(packageXml: string): ManifestItem[] {
  const items: ManifestItem[] = [];
  const expression = /<(?:(?:[\w.-]+):)?item\b[^>]*>/gi;
  let match: RegExpExecArray | null = expression.exec(packageXml);
  while (match !== null) {
    const tag = match[0];
    items.push({
      id: attribute(tag, 'id'),
      href: attribute(tag, 'href'),
      mediaType: attribute(tag, 'media-type'),
      properties: attribute(tag, 'properties')
    });
    match = expression.exec(packageXml);
  }
  return items;
}

function safePackagePath(root: string, base: string, relative: string): string {
  if (/^[a-z][a-z0-9+.-]*:/i.test(relative) || relative.startsWith('//')) throw new EpubInputError('unsupported_resource');
  let decoded: string;
  try { decoded = decodeURIComponent(relative.split(/[?#]/)[0]); } catch (_) { throw new EpubInputError('malformed'); }
  const resolved = joinRelative(base, decoded);
  const normalizedRoot = root.replace(/\\/g, '/');
  const normalized = resolved.replace(/\\/g, '/');
  if (normalized !== normalizedRoot && !normalized.startsWith(`${normalizedRoot}/`)) {
    throw new EpubInspectionError('malformed', 'EPUB contains a path outside its package');
  }
  return resolved;
}

async function readXml(path: string, maximumBytes?: number): Promise<string> {
  if (maximumBytes === undefined) return readTextFile(path);
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) throw new EpubInputError('resource_limit');
  const file = await openFile(path, fs.OpenMode.READ_ONLY);
  try {
    const size = (await statFile(file.fd)).size;
    if (size > maximumBytes) throw new EpubInputError('resource_limit');
    const bytes = new Uint8Array(size);
    let offset = 0;
    while (offset < size) {
      const chunk = new ArrayBuffer(Math.min(65536, size - offset));
      const count = await readFile(file.fd, chunk);
      if (count <= 0) throw new EpubInputError('malformed');
      bytes.set(new Uint8Array(chunk, 0, count), offset);
      offset += count;
    }
    const decoded = decodeReaderEpubXml(bytes, maximumBytes);
    return decoded.replace(/^<\?xml\s[\s\S]*?\?>/, (declaration: string): string =>
      declaration.replace(/\bencoding\s*=\s*(["'])[^"']+\1/i, 'encoding="UTF-8"'));
  } finally { closeFile(file); }
}

export class EpubInspector {
  async inspect(extractedRoot: string, maximumXmlBytes?: number, resources?: EpubResourceInspection): Promise<EpubInspection> {
    const mimePath = `${extractedRoot}/mimetype`;
    if (!await pathExists(mimePath)) {
      throw new EpubInspectionError('not_epub', 'Missing EPUB mimetype file');
    }
    const mime = (await readTextFile(mimePath)).trim();
    if (mime !== 'application/epub+zip') {
      throw new EpubInspectionError('not_epub', 'The selected file is not an EPUB');
    }
    if (await pathExists(`${extractedRoot}/META-INF/encryption.xml`) ||
      await pathExists(`${extractedRoot}/META-INF/rights.xml`) ||
      await pathExists(`${extractedRoot}/META-INF/license.lcpl`)) {
      throw new EpubInspectionError('encrypted', 'Encrypted or DRM-protected EPUBs are unsupported');
    }

    const containerPath = `${extractedRoot}/META-INF/container.xml`;
    if (!await pathExists(containerPath)) {
      throw new EpubInspectionError('malformed', 'Missing META-INF/container.xml');
    }
    const containerXml = await readXml(containerPath, maximumXmlBytes);
    validateXml(containerXml, 'container.xml', resources?.limits);
    const rootfileTag = /<(?:(?:[\w.-]+):)?rootfile\b[^>]*>/i.exec(containerXml);
    if (rootfileTag === null) {
      throw new EpubInspectionError('malformed', 'EPUB container has no package document');
    }
    const packageRelative = attribute(rootfileTag[0], 'full-path');
    if (packageRelative.length === 0) {
      throw new EpubInspectionError('malformed', 'EPUB package path is missing');
    }
    const packagePath = safePackagePath(extractedRoot, extractedRoot, packageRelative);
    if (!await pathExists(packagePath)) {
      throw new EpubInspectionError('malformed', 'EPUB package document does not exist');
    }

    const packageXml = await readXml(packagePath, maximumXmlBytes);
    validateXml(packageXml, 'package document', resources?.limits);
    const items = manifestItems(packageXml);
    const packageDirectory = parentPath(packagePath);
    const itemById = new Map<string, ManifestItem>();
    for (const item of items) {
      if (item.id.length > 0) {
        if (itemById.has(item.id)) throw new EpubInputError('malformed');
        itemById.set(item.id, item);
      }
    }

    const spineExpression = /<(?:(?:[\w.-]+):)?itemref\b[^>]*>/gi;
    let spineCount = 0;
    let spineMatch: RegExpExecArray | null = spineExpression.exec(packageXml);
    while (spineMatch !== null) {
      const idref = attribute(spineMatch[0], 'idref');
      const item = itemById.get(idref);
      if (item === undefined || item.href.length === 0 ||
        !await pathExists(safePackagePath(extractedRoot, packageDirectory, item.href))) {
        throw new EpubInspectionError('malformed', 'EPUB spine references a missing resource');
      }
      spineCount++;
      spineMatch = spineExpression.exec(packageXml);
    }
    if (spineCount === 0) {
      throw new EpubInspectionError('malformed', 'EPUB has no readable spine');
    }

    let cover = items.find((item) => item.properties.split(/\s+/).includes('cover-image'));
    if (cover === undefined) {
      const coverMeta = /<(?:(?:[\w.-]+):)?meta\b[^>]*\bname\s*=\s*(["'])cover\1[^>]*>/i.exec(packageXml);
      if (coverMeta !== null) {
        cover = itemById.get(attribute(coverMeta[0], 'content'));
      }
    }
    let coverAbsolutePath: string | undefined;
    if (cover !== undefined && cover.href.length > 0) {
      const candidate = safePackagePath(extractedRoot, packageDirectory, cover.href);
      if (await pathExists(candidate)) {
        coverAbsolutePath = candidate;
      }
    }

    if (resources !== undefined && maximumXmlBytes !== undefined) {
      const mediaTypes = new Map<string, string>();
      for (const item of items) {
        const resourcePath = safePackagePath(extractedRoot, packageDirectory, item.href);
        const previousType = mediaTypes.get(resourcePath);
        if (previousType !== undefined && previousType !== item.mediaType) throw new EpubInputError('malformed');
        mediaTypes.set(resourcePath, item.mediaType);
      }
      for (const entry of resources.entries) {
        if (resources.control.isCancelled()) throw new BoundedInflateError('cancelled');
        if (entry.directory) continue;
        const path = extractedRoot + '/' + entry.name;
        const usable = await inspectPublicationResource(path, mediaTypes.get(path) ?? '', maximumXmlBytes,
          resources.limits, path === coverAbsolutePath);
        if (!usable && path === coverAbsolutePath) coverAbsolutePath = undefined;
      }
    }

    return {
      title: textElement(packageXml, 'title'),
      author: textElement(packageXml, 'creator'),
      coverAbsolutePath: coverAbsolutePath
    };
  }
}
