import { util } from '@kit.ArkTS';

export type EpubInputFailure = 'malformed' | 'unsupported_encoding' | 'resource_limit' | 'encrypted' | 'unsupported_resource';
export class EpubInputError extends Error {
  code: EpubInputFailure;
  constructor(code: EpubInputFailure) { super(code); this.code = code; }
}

export function strictUtf8(bytes: Uint8Array): string {
  try {
    return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
  } catch (_) {
    throw new EpubInputError('unsupported_encoding');
  }
}

export function decodeEpubXml(bytes: Uint8Array, maximumBytes: number): string {
  if (bytes.byteLength > maximumBytes) throw new EpubInputError('resource_limit');
  let encoding = 'utf-8';
  let skip = 0;
  if (bytes.length >= 2 && bytes[0] === 255 && bytes[1] === 254) { encoding = 'utf-16le'; skip = 2; }
  else if (bytes.length >= 2 && bytes[0] === 254 && bytes[1] === 255) { encoding = 'utf-16be'; skip = 2; }
  else if (bytes.length >= 3 && bytes[0] === 239 && bytes[1] === 187 && bytes[2] === 191) { skip = 3; }
  else if (bytes.length >= 4 && bytes[0] === 0 && bytes[1] === 60 && bytes[2] === 0 && bytes[3] === 63) encoding = 'utf-16be';
  else if (bytes.length >= 4 && bytes[0] === 60 && bytes[1] === 0 && bytes[2] === 63 && bytes[3] === 0) encoding = 'utf-16le';
  let text: string;
  try {
    text = util.TextDecoder.create(encoding, { fatal: true, ignoreBOM: true }).decodeToString(bytes.subarray(skip));
  } catch (_) {
    throw new EpubInputError('unsupported_encoding');
  }
  const declaration = /^<\?xml\s[\s\S]*?\?>/.exec(text);
  if (declaration !== null) {
    const declared = /\bencoding\s*=\s*(["'])([^"']+)\1/i.exec(declaration[0]);
    if (declared !== null) {
      const value = declared[2].toLowerCase();
      const matches = value === encoding || (value === 'utf-16' && encoding.startsWith('utf-16'));
      if (!matches) throw new EpubInputError('unsupported_encoding');
    }
  }
  if (text.includes('\u0000')) throw new EpubInputError('unsupported_encoding');
  return text;
}

// The packaged JSZip string reader only interprets UTF-8. Decode first to
// classify declaration/sequence errors, then reject unsupported original bytes;
// never rewrite a managed EPUB or accept metadata that the Reader misdecodes.
export function decodeReaderEpubXml(bytes: Uint8Array, maximumBytes: number): string {
  const text = decodeEpubXml(bytes, maximumBytes);
  if ((bytes.length >= 2 && ((bytes[0] === 255 && bytes[1] === 254) ||
    (bytes[0] === 254 && bytes[1] === 255))) || bytes.subarray(0, 4).includes(0)) {
    throw new EpubInputError('unsupported_encoding');
  }
  return text;
}

// ZIP names remain unchanged on disk; canonical keys are for collision rejection.
export function zipPathKey(name: string, maximumCharacters: number): string {
  if (name.length === 0 || name.length > maximumCharacters) throw new EpubInputError('resource_limit');
  if (/[\u0000-\u001f\u007f\\:]/.test(name) || name.startsWith('/')) throw new EpubInputError('malformed');
  const relative = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
  for (const part of relative.split('/')) {
    if (part.length === 0 || part === '.' || part === '..') throw new EpubInputError('malformed');
  }
  return relative.normalize('NFC').toLowerCase();
}
