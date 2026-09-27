import { util, xml } from '@kit.ArkTS';
import { EpubInputError } from './EpubInputPolicy';

export function checkCssReferences(source: string): void {
  const css = source.replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\\(?:\r\n|[\n\r\f])/g, '')
    .replace(/\\([a-f0-9]{1,6})(?:\r\n|[\t\n\r\f ])?/gi, (_match: string, digits: string): string => {
      const code = Number.parseInt(digits, 16);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '\ufffd';
    }).replace(/\\([^\n\r\f])/g, '$1');
  // Linked CSS files are byte-bounded separately. Nested imports and data-URI
  // decoders have no independent actual-output boundary in the current engine.
  if (/@import\b|data\s*:/i.test(css)) throw new EpubInputError('unsupported_resource');
}

function localName(value: string): string {
  const colon = value.lastIndexOf(':');
  return (colon < 0 ? value : value.substring(colon + 1)).toLowerCase();
}

function rawLocalName(value: string): string {
  const colon = value.lastIndexOf(':');
  return colon < 0 ? value : value.substring(colon + 1);
}

function hasLocalName(value: string, expected: string): boolean {
  return value.length === expected.length && value.toLowerCase() === expected;
}

// Shared by structural/resource inspection so a large chapter is parsed once.
export class MarkupReferencePolicy {
  private depth: number = 0;
  private svgDepth: number = 0;
  private styleDepth: number = 0;
  private failure?: 'resource_limit' | 'unsupported_resource';
  private maximumDimension: number;
  constructor(maximumDimension: number) { this.maximumDimension = maximumDimension; }
  start(qualifiedName: string): boolean {
    const tag = rawLocalName(qualifiedName);
    this.depth++;
    if (hasLocalName(tag, 'svg')) this.svgDepth++;
    if (hasLocalName(tag, 'style')) this.styleDepth = this.depth;
    if (this.svgDepth > 0 && ['use', 'feimage', 'foreignobject', 'script'].includes(tag.toLowerCase())) {
      this.failure = 'unsupported_resource';
    }
    return this.failure === undefined;
  }
  end(qualifiedName: string): boolean {
    const tag = rawLocalName(qualifiedName);
    if (hasLocalName(tag, 'svg')) this.svgDepth--;
    if (this.depth === this.styleDepth) this.styleDepth = 0;
    this.depth--;
    return this.failure === undefined;
  }
  tracksText(): boolean { return this.styleDepth > 0 && this.depth === this.styleDepth; }
  text(value: string): boolean {
    if (this.tracksText()) {
      try { checkCssReferences(value); } catch (_) { this.failure = 'unsupported_resource'; }
    }
    return this.failure === undefined;
  }
  token(event: xml.EventType, value: xml.ParseInfo, qualifiedName?: string): boolean {
    if (event === xml.EventType.START_TAG) {
      return this.start(qualifiedName ?? value.getName());
    } else if (event === xml.EventType.END_TAG) {
      return this.end(qualifiedName ?? value.getName());
    } else if (event === xml.EventType.TEXT && this.styleDepth > 0 && this.depth === this.styleDepth) {
      return this.text(value.getText());
    }
    return this.failure === undefined;
  }
  attribute(tagName: string, name: string, value: string): boolean {
    const attribute = localName(name);
    if (['src', 'href', 'poster', 'srcset'].includes(attribute) && /(?:^|[\s,])data\s*:/i.test(value)) {
      this.failure = 'unsupported_resource';
    }
    if (attribute === 'style') {
      try { checkCssReferences(value); } catch (_) { this.failure = 'unsupported_resource'; }
    }
    if (this.svgDepth > 0 && localName(tagName) === 'image' && ['href', 'src'].includes(attribute) &&
      /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(value.trim())) {
      this.failure = 'unsupported_resource';
    }
    if (localName(tagName) === 'svg' && (attribute === 'width' || attribute === 'height')) {
      const absolute = /^\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*$/i.exec(value);
      const percentage = /^\s*(\d+(?:\.\d+)?)\s*%\s*$/.exec(value);
      if (absolute === null && percentage === null) this.failure = 'unsupported_resource';
      else if (absolute !== null && Number(absolute[1]) > this.maximumDimension) this.failure = 'resource_limit';
    }
    return this.failure === undefined;
  }
  assertAllowed(): void { if (this.failure !== undefined) throw new EpubInputError(this.failure); }
}

export function checkMarkupReferences(source: string, maximumDimension: number): void {
  const normalized = source.replace(/^<\?xml\s[\s\S]*?\?>/, (declaration: string): string =>
    declaration.replace(/\bencoding\s*=\s*(["'])[^"']+\1/i, 'encoding="UTF-8"'));
  const bytes = new util.TextEncoder().encodeInto(normalized);
  const policy = new MarkupReferencePolicy(maximumDimension);
  try {
    new xml.XmlPullParser(bytes.buffer as ArrayBuffer, 'utf-8').parseXml({
      supportDoctype: false, ignoreNameSpace: true,
      tokenValueCallbackFunction: (event: xml.EventType, value: xml.ParseInfo): boolean => policy.token(event, value),
      attributeWithTagCallbackFunction: (tag: string, name: string, value: string): boolean => policy.attribute(tag, name, value)
    });
  } catch (_) { policy.assertAllowed(); throw new EpubInputError('malformed'); }
  policy.assertAllowed();
}
