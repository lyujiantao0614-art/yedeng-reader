// UTF-16 offsets into decoded, untouched body text. Paths address childNodes
// from the documentElement in the same parser mode as the EPUB renderer.
export interface SectionTextRun { path: number[]; start: number; end: number; }
export interface SectionText {
  version: 1;
  extractor: 'body-text-1';
  index: number;
  href: string;
  parserMode: 'text/html' | 'application/xhtml+xml';
  text: string;
  runs: SectionTextRun[];
}
export interface SectionTextProvider { read: (index: number) => Promise<SectionText>; }
export interface SectionTextEndpoint { path: number[]; offset: number; }
export function sectionTextEndpoint(section: SectionText, offset: number, end: boolean): SectionTextEndpoint {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > section.text.length) throw new Error('Invalid text offset');
  const run = section.runs.find((item: SectionTextRun): boolean =>
    end ? offset > item.start && offset <= item.end : offset >= item.start && offset < item.end);
  if (!run) throw new Error('Text endpoint unavailable');
  return { path: run.path.slice(), offset: offset - run.start };
}
export function sectionTextOffset(section: SectionText, endpoint: SectionTextEndpoint): number {
  const path = JSON.stringify(endpoint.path);
  const run = section.runs.find((item: SectionTextRun): boolean => JSON.stringify(item.path) === path);
  if (!run || !Number.isSafeInteger(endpoint.offset) || endpoint.offset < 0 || endpoint.offset > run.end - run.start) {
    throw new Error('Invalid text node offset');
  }
  return run.start + endpoint.offset;
}
