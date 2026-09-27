import { probePublicationResource } from './EpubResourceProbe';
import { checkCssReferences, MarkupReferencePolicy } from './EpubResourceReferences';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util, xml } from '@kit.ArkTS';
import { EpubInputError, decodeReaderEpubXml, strictUtf8 } from './EpubInputPolicy';
import { closeFile, openFile, readFile, statFile } from '../utils/FileIoBoundary';

// Values are supplied by a measured policy (or explicit isolated-test policy).
export interface EpubResourceLimits {
  sectionBytes: number;
  xmlDepth: number;
  xmlElements: number;
  imageBytes: number;
  imageDimension: number;
  imagePixels: number;
  imageFrames: number;
  fontBytes: number;
  fontExpandedBytes: number;
}

export function validateResourceLimits(limits: EpubResourceLimits): void {
  const values: number[] = [limits.sectionBytes, limits.xmlDepth, limits.xmlElements, limits.imageBytes,
    limits.imageDimension, limits.imagePixels, limits.imageFrames, limits.fontBytes, limits.fontExpandedBytes];
  for (const value of values) if (!Number.isSafeInteger(value) || value <= 0) throw new EpubInputError('resource_limit');
}

export async function readBoundedResource(path: string, maximumBytes: number): Promise<Uint8Array> {
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
    return bytes;
  } finally { closeFile(file); }
}

function isXmlWhitespace(value: string): boolean {
  return value === ' ' || value === '\t' || value === '\r' || value === '\n';
}

function tagEnd(source: string, start: number): number {
  let quote = '';
  for (let index = start; index < source.length; index++) {
    const value = source[index];
    if (quote.length > 0) {
      if (value === quote) quote = '';
    } else if (value === '"' || value === "'") quote = value;
    else if (value === '>') return index;
  }
  return -1;
}

function isXmlNameStart(code: number): boolean {
  return code === 0x3a || code === 0x5f || (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a) ||
    (code >= 0xc0 && code <= 0xd6) || (code >= 0xd8 && code <= 0xf6) || (code >= 0xf8 && code <= 0x2ff) ||
    (code >= 0x370 && code <= 0x37d) || (code >= 0x37f && code <= 0x1fff) ||
    (code >= 0x200c && code <= 0x200d) || (code >= 0x2070 && code <= 0x218f) ||
    (code >= 0x2c00 && code <= 0x2fef) || (code >= 0x3001 && code <= 0xd7ff) ||
    (code >= 0xf900 && code <= 0xfdcf) || (code >= 0xfdf0 && code <= 0xfffd) ||
    (code >= 0x10000 && code <= 0xeffff);
}

function isXmlName(code: number): boolean {
  return isXmlNameStart(code) || code === 0x2d || code === 0x2e || (code >= 0x30 && code <= 0x39) ||
    code === 0xb7 || (code >= 0x300 && code <= 0x36f) || (code >= 0x203f && code <= 0x2040);
}

function xmlNameEnd(source: string, start: number, end: number): number {
  let index = start;
  let code = source.codePointAt(index) ?? 0;
  if (!isXmlNameStart(code)) return start;
  index += code > 0xffff ? 2 : 1;
  while (index < end) {
    code = source.codePointAt(index) ?? 0;
    if (!isXmlName(code)) break;
    index += code > 0xffff ? 2 : 1;
  }
  return index;
}

function isXmlCharacter(code: number): boolean {
  return code === 0x9 || code === 0xa || code === 0xd || (code >= 0x20 && code <= 0xd7ff) ||
    (code >= 0xe000 && code <= 0xfffd) || (code >= 0x10000 && code <= 0x10ffff);
}

function decodeXmlReferences(value: string): string {
  let cursor = 0;
  let output = '';
  while (cursor < value.length) {
    const opening = value.indexOf('&', cursor);
    if (opening < 0) { output += value.substring(cursor); break; }
    output += value.substring(cursor, opening);
    const closing = value.indexOf(';', opening + 1);
    if (closing < 0) throw new EpubInputError('malformed');
    const reference = value.substring(opening + 1, closing);
    if (reference === 'amp') output += '&';
    else if (reference === 'lt') output += '<';
    else if (reference === 'gt') output += '>';
    else if (reference === 'apos') output += "'";
    else if (reference === 'quot') output += '"';
    else if (reference === 'nbsp') output += '\u00a0';
    else if (/^#[0-9]+$/.test(reference) || /^#x[0-9a-f]+$/i.test(reference)) {
      const code = Number.parseInt(reference.substring(reference[1].toLowerCase() === 'x' ? 2 : 1),
        reference[1].toLowerCase() === 'x' ? 16 : 10);
      if (!Number.isSafeInteger(code) || !isXmlCharacter(code)) throw new EpubInputError('malformed');
      output += String.fromCodePoint(code);
    } else throw new EpubInputError('malformed');
    cursor = closing + 1;
  }
  return output;
}

function validateXmlText(source: string, start: number, end: number, insideRoot: boolean,
  references?: MarkupReferencePolicy): void {
  if (start >= end) return;
  const value = source.substring(start, end);
  if (!insideRoot) {
    for (let index = 0; index < value.length; index++) if (!isXmlWhitespace(value[index]) && value.charCodeAt(index) !== 0xfeff) {
      throw new EpubInputError('malformed');
    }
  }
  if (value.includes(']]>')) throw new EpubInputError('malformed');
  const decoded = value.includes('&') ? decodeXmlReferences(value) : value;
  if (references?.tracksText()) references.text(decoded);
}

// Count and match lexical qualified element names without asking the native
// parser to cross the ArkTS boundary for every text/start/end token. The native
// parser still validates dense XML below; sparse large-text chapters finish in
// this single resource-bounded pass.
function validateXmlStructure(source: string, limits?: EpubResourceLimits, references?: MarkupReferencePolicy): void {
  const stack: string[] = [];
  let roots = 0;
  let elements = 0;
  let doctypeSeen = false;
  let cursor = 0;
  while (cursor < source.length) {
    const opening = source.indexOf('<', cursor);
    if (opening < 0) { validateXmlText(source, cursor, source.length, stack.length > 0, references); cursor = source.length; break; }
    validateXmlText(source, cursor, opening, stack.length > 0, references);
    if (source.startsWith('<!--', opening)) {
      const end = source.indexOf('-->', opening + 4);
      if (end < 0) throw new EpubInputError('malformed');
      if (source.substring(opening + 4, end).includes('--')) throw new EpubInputError('malformed');
      cursor = end + 3; continue;
    }
    if (source.startsWith('<![CDATA[', opening)) {
      if (stack.length === 0) throw new EpubInputError('malformed');
      const end = source.indexOf(']]>', opening + 9);
      if (end < 0) throw new EpubInputError('malformed');
      if (references?.tracksText()) references.text(source.substring(opening + 9, end));
      cursor = end + 3; continue;
    }
    if (source.startsWith('<?', opening)) {
      const end = source.indexOf('?>', opening + 2);
      if (end < 0) throw new EpubInputError('malformed');
      const targetStart = opening + 2;
      const targetEnd = xmlNameEnd(source, targetStart, end);
      if (targetEnd === targetStart) throw new EpubInputError('malformed');
      const target = source.substring(targetStart, targetEnd);
      if (target.toLowerCase() === 'xml' && opening !== 0) throw new EpubInputError('malformed');
      if (targetEnd < end && !isXmlWhitespace(source[targetEnd])) throw new EpubInputError('malformed');
      cursor = end + 2; continue;
    }
    const end = tagEnd(source, opening + 1);
    if (end < 0) throw new EpubInputError('malformed');
    if (source.substring(opening, opening + 9).toLowerCase() === '<!doctype') {
      if (doctypeSeen || roots !== 0 || stack.length !== 0 || !isXmlWhitespace(source[opening + 9])) {
        throw new EpubInputError('malformed');
      }
      let nameStart = opening + 10;
      while (nameStart < end && isXmlWhitespace(source[nameStart])) nameStart++;
      if (xmlNameEnd(source, nameStart, end) === nameStart) throw new EpubInputError('malformed');
      doctypeSeen = true;
      cursor = end + 1;
      continue;
    }
    if (source.startsWith('<!', opening)) throw new EpubInputError('malformed');
    const closing = source.startsWith('</', opening);
    let nameStart = opening + (closing ? 2 : 1);
    const nameEnd = xmlNameEnd(source, nameStart, end);
    const name = source.substring(nameStart, nameEnd);
    if (name.length === 0) throw new EpubInputError('malformed');
    if (closing) {
      for (let index = nameEnd; index < end; index++) if (!isXmlWhitespace(source[index])) throw new EpubInputError('malformed');
      if (stack.pop() !== name) throw new EpubInputError('malformed');
      references?.end(name);
    } else {
      const attributes = new Set<string>();
      let index = nameEnd;
      let selfClosing = false;
      while (index < end) {
        while (index < end && isXmlWhitespace(source[index])) index++;
        if (index >= end) break;
        if (source[index] === '/') { selfClosing = true; index++; if (index !== end) throw new EpubInputError('malformed'); break; }
        const attributeStart = index;
        const attributeEnd = xmlNameEnd(source, attributeStart, end);
        if (attributeEnd === attributeStart) throw new EpubInputError('malformed');
        const attributeName = source.substring(attributeStart, attributeEnd);
        if (attributes.has(attributeName)) throw new EpubInputError('malformed');
        attributes.add(attributeName); index = attributeEnd;
        while (index < end && isXmlWhitespace(source[index])) index++;
        if (source[index] !== '=') throw new EpubInputError('malformed');
        index++; while (index < end && isXmlWhitespace(source[index])) index++;
        const quote = source[index];
        if (quote !== '"' && quote !== "'") throw new EpubInputError('malformed');
        const valueStart = ++index;
        const valueEnd = source.indexOf(quote, valueStart);
        if (valueEnd < 0 || valueEnd > end) throw new EpubInputError('malformed');
        const rawValue = source.substring(valueStart, valueEnd);
        if (rawValue.includes('<')) throw new EpubInputError('malformed');
        const value = decodeXmlReferences(rawValue);
        if (references !== undefined && !references.attribute(name, attributeName, value)) references.assertAllowed();
        index = valueEnd + 1;
        if (index < end && !isXmlWhitespace(source[index]) && source[index] !== '/') throw new EpubInputError('malformed');
      }
      if (stack.length === 0) roots++;
      stack.push(name); elements++;
      if (limits !== undefined && (stack.length > limits.xmlDepth || elements > limits.xmlElements)) {
        throw new EpubInputError('resource_limit');
      }
      if (references !== undefined && !references.start(name)) references.assertAllowed();
      if (selfClosing) { stack.pop(); references?.end(name); }
    }
    cursor = end + 1;
  }
  references?.assertAllowed();
  if (stack.length !== 0 || roots !== 1) throw new EpubInputError('malformed');
}

function hasDenseMarkup(source: string): boolean {
  let count = 0;
  let cursor = 0;
  while (count <= 4096) {
    const next = source.indexOf('<', cursor);
    if (next < 0) return false;
    count++; cursor = next + 1;
  }
  return true;
}

function nativeParserSource(source: string): string {
  const opening = source.toLowerCase().indexOf('<!doctype');
  let withoutDoctype = source;
  if (opening >= 0) {
    const end = tagEnd(source, opening + 1);
    if (end < 0) throw new EpubInputError('malformed');
    withoutDoctype = source.substring(0, opening) + source.substring(end + 1);
  }
  // The native parser never loads DTDs. Resolve the accepted legacy XHTML
  // entity locally before the dense-document verification pass.
  return withoutDoctype.replace(/&nbsp;/g, '&#160;');
}

export function validatePublicationXml(source: string, limits?: EpubResourceLimits,
  references?: MarkupReferencePolicy, encoded?: Uint8Array): void {
  // Internal entities can multiply work before the parser produces any nodes.
  if (/<!ENTITY\b/i.test(source) || /<!DOCTYPE[^>]*\[/i.test(source)) throw new EpubInputError('malformed');
  const normalized = source.replace(/^<\?xml\s[\s\S]*?\?>/, (declaration: string): string =>
    declaration.replace(/\bencoding\s*=\s*(["'])[^"']+\1/i, 'encoding="UTF-8"'));
  try {
    const dense = hasDenseMarkup(normalized);
    if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/.test(normalized)) throw new EpubInputError('malformed');
    validateXmlStructure(normalized, limits, references);
    if (dense) {
      const parserSource = nativeParserSource(normalized);
      const bytes = encoded !== undefined && parserSource === source ? encoded :
        new util.TextEncoder().encodeInto(parserSource);
      new xml.XmlPullParser(bytes.buffer as ArrayBuffer, 'utf-8').parseXml({ supportDoctype: false, ignoreNameSpace: true });
    }
    references?.assertAllowed();
  } catch (error) {
    references?.assertAllowed();
    if (error instanceof EpubInputError) throw error;
    throw new EpubInputError('malformed');
  }
}

export function checkImageDimensions(width: number, height: number, frames: number,
  limits: EpubResourceLimits): void {
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) ||
    !Number.isSafeInteger(frames) || width <= 0 || height <= 0 || frames <= 0) {
    throw new EpubInputError('malformed');
  }
  if (width > limits.imageDimension || height > limits.imageDimension || frames > limits.imageFrames ||
    width * height > limits.imagePixels || width * height * frames > limits.imagePixels) {
    throw new EpubInputError('resource_limit');
  }
}

export function checkFontHeader(bytes: Uint8Array, limits: EpubResourceLimits): void {
  if (bytes.byteLength > limits.fontBytes) throw new EpubInputError('resource_limit');
  if (bytes.byteLength < 12) throw new EpubInputError('malformed');
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const signature = data.getUint32(0, false);
  if (signature === 0x774f4646 || signature === 0x774f4632) {
    // WOFF/WOFF2 may be small on disk but expand before the font decoder.
    const headerSize = signature === 0x774f4646 ? 44 : 48;
    if (bytes.length < headerSize || data.getUint32(8, false) !== bytes.length || data.getUint16(14, false) !== 0) {
      throw new EpubInputError('malformed');
    }
    if (data.getUint32(16, false) > limits.fontExpandedBytes) throw new EpubInputError('resource_limit');
    // WOFF2 transform expansion cannot be independently bounded with current APIs.
    if (signature === 0x774f4632) throw new EpubInputError('unsupported_resource');
    const count = data.getUint16(12, false);
    if (count === 0 || 44 + count * 20 > bytes.length) throw new EpubInputError('malformed');
    let expanded = 12 + count * 16;
    for (let index = 0; index < count; index++) {
      const offset = 44 + index * 20;
      const start = data.getUint32(offset + 4, false);
      const compressed = data.getUint32(offset + 8, false);
      const original = data.getUint32(offset + 12, false);
      if (compressed > original || start < 44 + count * 20 || start + compressed > bytes.length) {
        throw new EpubInputError('malformed');
      }
      expanded += Math.ceil(original / 4) * 4;
      if (expanded > limits.fontExpandedBytes) throw new EpubInputError('resource_limit');
    }
    if (expanded !== data.getUint32(16, false)) throw new EpubInputError('malformed');
    // Declared font expansion is not an actual decompressor limit.
    throw new EpubInputError('unsupported_resource');
  }
  if (signature !== 0x00010000 && signature !== 0x4f54544f && signature !== 0x74727565) {
    throw new EpubInputError('unsupported_resource');
  }
  if (bytes.length > limits.fontExpandedBytes) throw new EpubInputError('resource_limit');
  const count = data.getUint16(4, false);
  if (count === 0 || 12 + count * 16 > bytes.length) throw new EpubInputError('malformed');
  for (let index = 0; index < count; index++) {
    const offset = 12 + index * 16;
    const start = data.getUint32(offset + 8, false);
    const length = data.getUint32(offset + 12, false);
    if (start < 12 + count * 16 || start + length > bytes.length) throw new EpubInputError('malformed');
  }
}

export async function inspectPublicationResource(path: string, mediaType: string, xmlBytes: number,
  limits: EpubResourceLimits, optionalCover: boolean): Promise<boolean> {
  const probe = await probePublicationResource(path);
  const type = probe.mediaType ?? mediaType.toLowerCase();
  const extension = probe.mediaType === undefined ? path.substring(path.lastIndexOf('.') + 1).toLowerCase() : '';
  const isSvg = type === 'image/svg+xml' || extension === 'svg';
  const isXml = isSvg || type.includes('xml') || ['xml', 'opf', 'ncx', 'xhtml', 'html'].includes(extension);
  if (isXml) {
    const maximum = (type === 'application/xhtml+xml' || ['xhtml', 'html'].includes(extension)) ? limits.sectionBytes : xmlBytes;
    const bytes = await readBoundedResource(path, maximum);
    const text = decodeReaderEpubXml(bytes, maximum);
    validatePublicationXml(text, limits, new MarkupReferencePolicy(limits.imageDimension), bytes);
    // SVG references can recursively instantiate resources; the first bounded
    // candidate accepts self-contained drawings, pending reference-graph support.
    if (isSvg && (/<(?:[\w.-]+:)?(?:use|feImage|script|foreignObject)\b/i.test(text) ||
      /(?:url\s*\(|@import)/i.test(text))) throw new EpubInputError('unsupported_resource');
    return true;
  }
  if (type === 'text/css' || extension === 'css') {
    checkCssReferences(strictUtf8(await readBoundedResource(path, xmlBytes)));
    return true;
  }
  if (type.startsWith('font/') || type.includes('font') || ['ttf', 'otf', 'woff', 'woff2'].includes(extension)) {
    checkFontHeader(await readBoundedResource(path, limits.fontBytes), limits);
    return true;
  }
  if (type.startsWith('image/') || ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'avif', 'heic'].includes(extension)) {
    // Size check precedes native image-source creation; metadata precedes pixels.
    if (probe.size > limits.imageBytes) throw new EpubInputError('resource_limit');
    let source: image.ImageSource | undefined;
    try {
      source = image.createImageSource(path);
      const info = await source.getImageInfo();
      const frames = await source.getFrameCount();
      checkImageDimensions(info.size.width, info.size.height, frames, limits);
      let pixels = info.size.width * info.size.height;
      for (let index = 1; index < frames; index++) {
        const frame = await source.getImageInfo(index);
        checkImageDimensions(frame.size.width, frame.size.height, 1, limits);
        pixels += frame.size.width * frame.size.height;
        if (pixels > limits.imagePixels) throw new EpubInputError('resource_limit');
      }
      return true;
    } catch (error) {
      if (error instanceof EpubInputError) throw error;
      if (optionalCover) return false;
      throw new EpubInputError('malformed');
    } finally { if (source !== undefined) await source.release(); }
  }
  return true;
}
