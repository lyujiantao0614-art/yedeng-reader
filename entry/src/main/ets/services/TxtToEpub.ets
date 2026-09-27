import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BoundedInflateError, InflateControl } from './BoundedInflater';
import { EpubInputError, strictUtf8 } from './EpubInputPolicy';
import { ImportWriteGuard } from './ImportStorageBudget';
import { closeFile, openFile, readFile, writeFile } from '../utils/FileIoBoundary';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

export const MAX_TXT_SOURCE_BYTES: number = 8 * 1024 * 1024;
const CHAPTER_CHARACTERS: number = 24000;
const MAX_GENERATED_EPUB_BYTES: number = 32 * 1024 * 1024;

interface ArchiveEntry {
  name: string;
  data: Uint8Array;
}

function bytes(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

function xml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

interface DecodedText {
  text: string;
  encoding: string;
}

function decodeText(source: Uint8Array, choice: TxtEncodingChoice): DecodedText {
  if (source.length === 0) throw new EpubInputError('malformed');
  let text: string;
  let encoding: string = choice;
  try {
    let offset = 0;
    let bom = '';
    if (source.length >= 3 && source[0] === 239 && source[1] === 187 && source[2] === 191) {
      bom = 'utf-8'; offset = 3;
    } else if (source.length >= 2 && source[0] === 255 && source[1] === 254) {
      bom = 'utf-16le'; offset = 2;
    } else if (source.length >= 2 && source[0] === 254 && source[1] === 255) {
      bom = 'utf-16be'; offset = 2;
    }
    if (bom.length > 0 && choice !== 'auto' && choice !== bom) throw new EpubInputError('unsupported_encoding');
    encoding = choice === 'auto' ? (bom.length > 0 ? bom : 'utf-8') : choice;
    const payload = source.subarray(offset);
    text = encoding === 'utf-8' ? strictUtf8(payload) :
      util.TextDecoder.create(encoding, { fatal: true, ignoreBOM: true }).decodeToString(payload);
  } catch (_) {
    throw new EpubInputError('unsupported_encoding');
  }
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(text)) {
    throw new EpubInputError('unsupported_encoding');
  }
  if (text.trim().length === 0) throw new EpubInputError('malformed');
  return { text: text.replace(/\r\n?/g, '\n'), encoding: encoding };
}

async function readTxtBytes(uri: string, control?: InflateControl): Promise<Uint8Array> {
  const source = await openFile(uri, fs.OpenMode.READ_ONLY);
  const parts: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      if (control?.isCancelled()) throw new BoundedInflateError('cancelled');
      const buffer = new ArrayBuffer(65536);
      const count = await readFile(source.fd, buffer);
      if (count <= 0) break;
      length += count;
      if (length > MAX_TXT_SOURCE_BYTES) throw new EpubInputError('resource_limit');
      parts.push(new Uint8Array(buffer.slice(0, count)));
    }
  } finally { closeFile(source); }
  const sourceBytes = new Uint8Array(length);
  let offset = 0;
  parts.forEach((part: Uint8Array): void => { sourceBytes.set(part, offset); offset += part.length; });
  return sourceBytes;
}

export async function previewTxt(uri: string, choice: TxtEncodingChoice): Promise<TxtPreview> {
  try {
    const decoded = decodeText(await readTxtBytes(uri), choice);
    return { valid: true, excerpt: decoded.text.substring(0, 600), encoding: decoded.encoding, message: '' };
  } catch (error) {
    if (error instanceof EpubInputError) {
      return { valid: false, excerpt: '', encoding: choice,
        message: error.code === 'resource_limit' ? 'TXT 超过 8 MiB。' :
          error.code === 'malformed' ? 'TXT 没有可阅读的正文。' : '无法按此编码读取，请选择其他编码。' };
    }
    return { valid: false, excerpt: '', encoding: choice, message: '无法读取这个文件。' };
  }
}

export interface TxtSection {
  title: string;
  html: string;
  inToc: boolean;
}

interface HeadingCandidate {
  line: number;
  title: string;
  style: string;
}

function headingCandidate(value: string, line: number): HeadingCandidate | undefined {
  const title = value.trim();
  if (title.length === 0 || title.length > 64) return undefined;
  if (/^第[ 　]*[0-9零〇一二两兩三四五六七八九十百千万萬亿億廿卅壹贰貳叁叄參肆伍陆陸柒捌玖拾佰仟]+[ 　]*[章节回篇话讲卷册部](?:[：:、.． 　-]*[^。！？!?]{0,36})?$/.test(title)) {
    return { line: line, title: title, style: 'zh' };
  }
  if (/^(?:Chapter|Part|Book|Volume|Section)[ .　]+(?:[0-9]+|[IVXLCDM]+)(?:[：:., 　-]+.{0,40})?$/i.test(title)) {
    return { line: line, title: title, style: 'en' };
  }
  if (/^[\u4e00-\u9fff]{1,8}第[零〇一二两兩三四五六七八九十百千万萬廿卅]+$/.test(title)) {
    return { line: line, title: title, style: 'classic' };
  }
  if (/^(?:序章|楔子|前言|序言|引言|尾声|尾聲|后记|後記|Prologue|Epilogue|Preface|Afterword)$/i.test(title)) {
    return { line: line, title: title, style: 'special' };
  }
  return undefined;
}

function chapterHeadings(lines: string[]): Map<number, string> {
  const candidates: HeadingCandidate[] = [];
  const counts: Map<string, number> = new Map<string, number>();
  lines.forEach((line: string, index: number): void => {
    const candidate = headingCandidate(line, index);
    if (candidate === undefined) return;
    candidates.push(candidate);
    counts.set(candidate.style, (counts.get(candidate.style) ?? 0) + 1);
  });
  const recognized: Map<number, string> = new Map<number, string>();
  if (!['zh', 'en', 'classic'].some((style: string): boolean => (counts.get(style) ?? 0) >= 2)) {
    return recognized;
  }
  candidates.forEach((candidate: HeadingCandidate): void => {
    if (candidate.style === 'special' || (counts.get(candidate.style) ?? 0) >= 2) {
      recognized.set(candidate.line, candidate.title);
    }
  });
  // A compact heading list near the start is usually a copied contents page.
  const early = candidates.filter((candidate: HeadingCandidate): boolean =>
    candidate.line < 200 && recognized.has(candidate.line));
  let run: HeadingCandidate[] = [];
  const discardRun = (): void => {
    if (run.length >= 3) run.forEach((candidate: HeadingCandidate): void => { recognized.delete(candidate.line); });
    run = [];
  };
  early.forEach((candidate: HeadingCandidate): void => {
    const previous = run[run.length - 1];
    if (previous !== undefined && (run.some((item: HeadingCandidate): boolean => item.title === candidate.title) ||
      lines.slice(previous.line + 1, candidate.line)
        .some((line: string): boolean => line.trim().length > 0))) discardRun();
    run.push(candidate);
  });
  discardRun();
  return recognized;
}

export function buildTxtSections(text: string): TxtSection[] {
  const lines = text.split('\n');
  const headings = chapterHeadings(lines);
  const detected = headings.size > 0;
  const result: TxtSection[] = [];
  let body = '';
  let characters = 0;
  let meaningful = false;
  let title = detected ? '开篇' : '正文';
  let inToc = true;
  const finish = (): void => {
    if (!meaningful) { body = ''; characters = 0; return; }
    const sectionTitle = detected ? title : `第 ${result.length + 1} 部分`;
    result.push({ title: sectionTitle, inToc: inToc,
      html: `<?xml version="1.0" encoding="UTF-8"?>` +
        `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>${xml(sectionTitle)}</title></head>` +
        `<body>${body}</body></html>` });
    body = '';
    characters = 0;
    meaningful = false;
  };
  lines.forEach((line: string, index: number): void => {
    const heading = headings.get(index);
    if (heading !== undefined) {
      finish();
      title = heading;
      inToc = true;
      body = `<h2>${xml(heading)}</h2>`;
      characters = heading.length;
      meaningful = true;
      return;
    }
    if (line.trim().length === 0) {
      if (characters + 1 > CHAPTER_CHARACTERS) {
        finish();
        if (detected) inToc = false;
      }
      body += '<p><br/></p>';
      characters += 1;
      return;
    }
    for (let start = 0; start < line.length;) {
      if (characters >= CHAPTER_CHARACTERS) {
        finish();
        if (detected) inToc = false;
      }
      let end = Math.min(line.length, start + CHAPTER_CHARACTERS - characters);
      if (end < line.length && /[\uD800-\uDBFF]/.test(line[end - 1])) end -= 1;
      if (end === start) {
        finish();
        if (detected) inToc = false;
        continue;
      }
      const segment = line.substring(start, end);
      body += `<p>${xml(segment)}</p>`;
      characters += segment.length;
      meaningful = true;
      start = end;
    }
  });
  finish();
  return result;
}

function archiveEntries(text: string): ArchiveEntry[] {
  const sections = buildTxtSections(text);
  const manifest: string[] = [];
  const spine: string[] = [];
  const navigation: string[] = [];
  const entries: ArchiveEntry[] = [
    { name: 'mimetype', data: bytes('application/epub+zip') },
    { name: 'META-INF/container.xml', data: bytes('<?xml version="1.0" encoding="UTF-8"?>' +
      '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">' +
      '<rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>' +
      '</rootfiles></container>') }
  ];
  sections.forEach((section: TxtSection, index: number): void => {
    const number = index + 1;
    const name = `section-${number}.xhtml`;
    manifest.push(`<item id="s${number}" href="${name}" media-type="application/xhtml+xml"/>`);
    spine.push(`<itemref idref="s${number}"/>`);
    if (section.inToc) {
      const order = navigation.length + 1;
      navigation.push(`<navPoint id="n${order}" playOrder="${order}">` +
        `<navLabel><text>${xml(section.title)}</text></navLabel><content src="${name}"/></navPoint>`);
    }
    entries.push({ name: `OPS/${name}`, data: bytes(section.html) });
  });
  entries.splice(2, 0, { name: 'OPS/package.opf', data: bytes('<?xml version="1.0" encoding="UTF-8"?>' +
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">' +
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">' +
    '<dc:identifier id="id">urn:yedeng:txt-conversion:1</dc:identifier>' +
    '<dc:title>本地文本</dc:title><dc:language>zh</dc:language></metadata><manifest>' +
    manifest.join('') + '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>' +
    '</manifest><spine toc="ncx">' + spine.join('') + '</spine></package>') });
  entries.push({ name: 'OPS/toc.ncx', data: bytes('<?xml version="1.0" encoding="UTF-8"?>' +
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">' +
    '<head><meta name="dtb:uid" content="urn:yedeng:txt-conversion:1"/></head>' +
    '<docTitle><text>本地文本</text></docTitle><navMap>' + navigation.join('') +
    '</navMap></ncx>') });
  return entries;
}

function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (const value of data) {
    crc ^= value;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function zip(entries: ArchiveEntry[]): Uint8Array {
  const names = entries.map((entry: ArchiveEntry): Uint8Array => bytes(entry.name));
  let localSize = 0;
  let directorySize = 0;
  entries.forEach((entry: ArchiveEntry, index: number): void => {
    localSize += 30 + names[index].length + entry.data.length;
    directorySize += 46 + names[index].length;
  });
  const total = localSize + directorySize + 22;
  if (total > MAX_GENERATED_EPUB_BYTES || entries.length > 4096) throw new EpubInputError('resource_limit');
  const output = new Uint8Array(total);
  const view = new DataView(output.buffer);
  let cursor = 0;
  let central = localSize;
  entries.forEach((entry: ArchiveEntry, index: number): void => {
    const name = names[index];
    const offset = cursor;
    const checksum = crc32(entry.data);
    view.setUint32(cursor, 0x04034b50, true);
    view.setUint16(cursor + 4, 20, true);
    view.setUint16(cursor + 6, 0x800, true);
    view.setUint16(cursor + 8, 0, true);
    view.setUint32(cursor + 14, checksum, true);
    view.setUint32(cursor + 18, entry.data.length, true);
    view.setUint32(cursor + 22, entry.data.length, true);
    view.setUint16(cursor + 26, name.length, true);
    cursor += 30;
    output.set(name, cursor); cursor += name.length;
    output.set(entry.data, cursor); cursor += entry.data.length;
    view.setUint32(central, 0x02014b50, true);
    view.setUint16(central + 4, 20, true);
    view.setUint16(central + 6, 20, true);
    view.setUint16(central + 8, 0x800, true);
    view.setUint16(central + 10, 0, true);
    view.setUint32(central + 16, checksum, true);
    view.setUint32(central + 20, entry.data.length, true);
    view.setUint32(central + 24, entry.data.length, true);
    view.setUint16(central + 28, name.length, true);
    view.setUint32(central + 42, offset, true);
    central += 46;
    output.set(name, central); central += name.length;
  });
  view.setUint32(central, 0x06054b50, true);
  view.setUint16(central + 8, entries.length, true);
  view.setUint16(central + 10, entries.length, true);
  view.setUint32(central + 12, directorySize, true);
  view.setUint32(central + 16, localSize, true);
  return output;
}

export async function convertTxtToEpub(uri: string, targetPath: string,
  control?: InflateControl, storage?: ImportWriteGuard, choice: TxtEncodingChoice = 'auto'): Promise<void> {
  const sourceBytes = await readTxtBytes(uri, control);
  const epub = zip(archiveEntries(decodeText(sourceBytes, choice).text));
  if (control?.isCancelled()) throw new BoundedInflateError('cancelled');
  if (storage !== undefined) await storage.beforeWrite(epub.length, 'source-copy');
  const target = await openFile(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {
    let written = 0;
    while (written < epub.length) {
      if (control?.isCancelled()) throw new BoundedInflateError('cancelled');
      const count = await writeFile(target.fd, epub.buffer.slice(written),
        { offset: written, length: epub.length - written });
      if (count <= 0) throw new Error('TXT conversion write failed');
      written += count;
    }
  } finally { closeFile(target); }
}
